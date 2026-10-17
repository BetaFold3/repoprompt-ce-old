import Foundation
import JSONSchema
import MCP
import RepoPromptAgentCore

/// Window catalog entry for `code_mode` (plan §6 D3). Every connection's catalog carries the
/// tool; `tools/list` and `tools/call` expose it only under an installed run policy with
/// `.directTools` eligibility (`ServerNetworkManager.isCodeModeExposureAllowed`).
@MainActor
final class MCPCodeModeToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .codeMode

    private let runtime: MCPWindowToolRuntime

    init(runtime: MCPWindowToolRuntime, dependencies _: MCPWindowToolDependencies? = nil) {
        self.runtime = runtime
    }

    func buildTools() -> [Tool] {
        [codeModeTool()]
    }

    static let description = """
    Run a short JavaScript async function body that calls RepoPrompt's read-only exploration tools and returns one compact result. Use it for multi-step or fan-out exploration (many files, ranking, counting); call the direct tools for single lookups.

    **Tools** (each returns a Promise): `tools.read_file(args)`, `tools.file_search(args)`, `tools.get_code_structure(args)`, `tools.get_file_tree(args)`, with the same arguments as the direct tools. The script runs in this connection's bound context: code_mode cannot be routed, so routing arguments (`context_id`, `_tabID`, `_windowID`, `window_id`) are rejected on the code_mode call and inside the script; to use another context, call `bind_context` before code_mode. There is no filesystem, network, timers, modules or `Intl`: sort with explicit comparators.

    **Data first:** a call resolves to `{data, isError: false}` with the tool's structured value; read fields from `data` (count lines with `data.total_lines`, never by splitting text). `{text, isError: false}` appears only when a tool has no structured value. A failed call rejects with an Error carrying `code`; pass `{allowError: true}` as the second argument to receive `{isError: true, error, code}` instead. Check failures and retry only the failed items.

    **Pattern:** probe a few items before looping over many; use `Promise.all` for independent calls; emit small aggregate checkpoints with `text(...)` or `console.log(...)` after completed batches; return only the aggregate. Files read here are not added to the selection: select the shortlisted files afterwards.

    \(MCPCodeModeExecutor.descriptionNotes) The final result is at most 32 KiB: up to 28 KiB of output plus a footer of up to 4 KiB that always lists the status, call counts and every failed call. Any failed call, error, timeout or limit makes the result an error.
    """

    private func codeModeTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.codeMode,
            // Children apply their own freshness policies.
            freshnessPolicy: .none,
            description: Self.description,
            annotations: .repoPromptLocalReadOnly,
            inputSchema: .object(
                properties: [
                    "script": .string(
                        description: "Async function body (at most 32 KiB UTF-8), for example `const r = await tools.read_file({path: 'README.md'}); return r.data.total_lines;`."
                    )
                ],
                required: ["script"],
                additionalProperties: .boolean(false)
            ),
            outputSchema: MCPToolOutputSchemas.codeMode,
            implementation: { context, args in
                try await MCPCodeModeToolExecution.run(arguments: args, windowID: context.windowID)
            }
        )
    }
}

/// Structured `code_mode` tool errors raised before a script starts.
struct MCPCodeModeToolError: MCPStructuredToolError, Equatable {
    let code: String
    let message: String

    var errorDescription: String? {
        message
    }

    static let busy = Self(
        code: "code_mode_busy",
        message: "Another code_mode script is running for this connection or window. Wait for it to finish, then retry."
    )
}

/// The production parent bridge: argument checks, the script cap, and one executor run whose
/// children re-enter the connection's registered `tools/call` handler.
enum MCPCodeModeToolExecution {
    typealias ChildInvoker = MCPCodeModeExecutor.ChildInvoker

    static func run(
        arguments: [String: Value],
        windowID: Int,
        admission: MCPCodeModeScriptAdmission = .shared,
        retention: MCPCodeModeResultRetention? = MCPCodeModeResultRetention.current,
        connectionID: UUID? = ServerNetworkManager.currentConnectionID,
        parentInvocationID: UUID? = ServerNetworkManager.currentToolInvocationID,
        makeExecutor: (@escaping ChildInvoker) -> MCPCodeModeExecutor = { MCPCodeModeExecutor(limits: .production, invokeChild: $0) }
    ) async throws -> Value {
        let unexpected = arguments.keys.filter { $0 != "script" }.sorted()
        guard unexpected.isEmpty else {
            throw MCPError.invalidParams("code_mode accepts only `script`; unexpected: \(unexpected.joined(separator: ", ")).")
        }
        guard case let .string(script)? = arguments["script"] else {
            throw MCPError.invalidParams("code_mode requires `script`: a JavaScript async function body string.")
        }
        guard let connectionID, let parentInvocationID else {
            throw MCPError.internalError("code_mode has no connection or invocation context.")
        }
        // A handler that already gave up on this invocation never starts its script.
        guard retention?.begin() ?? true else {
            throw CancellationError()
        }
        // Fail fast, never queue: one script per connection and one per window.
        guard let lease = admission.tryAcquire(connectionID: connectionID, windowID: windowID) else {
            retention?.finish(nil)
            throw MCPCodeModeToolError.busy
        }
        let executor = makeExecutor { toolName, childArguments in
            try await ServerNetworkManager.shared.invokeCodeModeChild(
                connectionID: connectionID,
                parentInvocationID: parentInvocationID,
                params: CallTool.Parameters(name: toolName, arguments: childArguments)
            )
        }
        // The slots stay held until no engine thread remains, even past a cleanup timeout.
        let result = await executor.execute(script: script, onOwnerExit: { lease.release() })
        let value = MCPCodeModeToolResult.value(from: result)
        retention?.finish(value)
        return value
    }
}

/// Wire projection of one `code_mode` result. The provider value is the executor's
/// `structuredContent` plus the footer text under a private key, so the human-readable text is
/// `output + footer` without encoding the output twice.
enum MCPCodeModeToolResult {
    static let footerKey = "_footer"

    static func value(from result: MCPCodeModeExecutionResult) -> Value {
        guard case var .object(object) = result.structuredContent else { return result.structuredContent }
        // Split on UTF-8 bytes, never Characters: output ending in `\r` merges with the footer's
        // leading `\n` into one `\r\n` grapheme, which a Character prefix check would not match.
        let hasOutputPrefix = result.text.utf8.starts(with: result.output.utf8)
        let footer = hasOutputPrefix
            ? String(decoding: result.text.utf8.dropFirst(result.output.utf8.count), as: UTF8.self)
            : result.text
        if !hasOutputPrefix {
            // Never expected: keep the authoritative text and drop the duplicate output.
            object["output"] = .string("")
        }
        object[footerKey] = .string(footer)
        return .object(object)
    }

    static func text(from value: Value) -> String {
        let object = value.objectValue ?? [:]
        return (object["output"]?.stringValue ?? "") + (object[footerKey]?.stringValue ?? "")
    }

    /// Authoritative error flag: anything but an explicit `success` status is an error.
    static func isError(toolName: String, value: Value) -> Bool {
        guard toolName == MCPWindowToolName.codeMode else { return false }
        return value.objectValue?["status"]?.stringValue != MCPCodeModeExecutionResult.Status.success.rawValue
    }

    /// `structuredContent` for a schema-advertising connection; never carries the footer text.
    static func structuredContent(toolName: String, value: Value) -> Value {
        guard toolName == MCPWindowToolName.codeMode, case var .object(object) = value else { return value }
        object.removeValue(forKey: footerKey)
        return .object(object)
    }
}

/// One-per-connection and one-per-window script cap (plan §6 D3 admission). Atomic and
/// fail-fast: a second script on the same connection or window is rejected, never queued. A
/// lease is released only when the executor reports that the script's engine owner has exited,
/// so a runtime stuck past its cleanup allowance keeps both slots occupied.
final class MCPCodeModeScriptAdmission: @unchecked Sendable {
    static let shared = MCPCodeModeScriptAdmission()

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var onRelease: (() -> Void)?

        fileprivate init(onRelease: @escaping () -> Void) {
            self.onRelease = onRelease
        }

        /// Idempotent; returns whether this call released the slots.
        @discardableResult
        func release() -> Bool {
            lock.lock()
            let action = onRelease
            onRelease = nil
            lock.unlock()
            action?()
            return action != nil
        }
    }

    private let lock = NSLock()
    private var connections: Set<UUID> = []
    private var windows: Set<Int> = []

    func tryAcquire(connectionID: UUID, windowID: Int) -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard !connections.contains(connectionID), !windows.contains(windowID) else { return nil }
        connections.insert(connectionID)
        windows.insert(windowID)
        return Lease { [weak self] in
            self?.releaseSlots(connectionID: connectionID, windowID: windowID)
        }
    }

    func isHeld(connectionID: UUID? = nil, windowID: Int? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectionID.map(connections.contains) == true || windowID.map(windows.contains) == true
    }

    private func releaseSlots(connectionID: UUID, windowID: Int) {
        lock.lock()
        connections.remove(connectionID)
        windows.remove(windowID)
        lock.unlock()
    }
}

/// Per-invocation retention of a `code_mode` result (plan §6 D3 failure rule). The connection
/// handler installs one for each `code_mode` call; when the execution contract or a cancellation
/// would otherwise replace the result with a generic error, the handler formats the retained
/// partial result instead. A script that never began is abandoned, so it can never start late.
final class MCPCodeModeResultRetention: @unchecked Sendable {
    @TaskLocal static var current: MCPCodeModeResultRetention?

    private enum State {
        case idle
        case running
        case finished(Value?)
        case abandoned
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var waiters: [CheckedContinuation<Value?, Never>] = []

    /// False when the handler already abandoned this invocation.
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .idle = state else { return false }
        state = .running
        return true
    }

    /// Records the final value (nil when the script never ran) once and wakes any waiter.
    func finish(_ value: Value?) {
        lock.lock()
        guard case .running = state else {
            lock.unlock()
            return
        }
        state = .finished(value)
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        resumed.forEach { $0.resume(returning: value) }
    }

    /// The retained value: immediately when finished, nil (and abandoned) when the script never
    /// began, otherwise once the running script finishes. The executor bounds that wait: a
    /// cancelled script returns within its cleanup allowance.
    func resolve() async -> Value? {
        if let immediate = immediateResolution() {
            return immediate.value
        }
        return await withCheckedContinuation { continuation in
            enqueue(continuation)
        }
    }

    private struct Immediate {
        let value: Value?
    }

    private func immediateResolution() -> Immediate? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle:
            state = .abandoned
            return Immediate(value: nil)
        case .abandoned:
            return Immediate(value: nil)
        case let .finished(value):
            return Immediate(value: value)
        case .running:
            return nil
        }
    }

    private func enqueue(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        if case let .finished(value) = state {
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }
}
