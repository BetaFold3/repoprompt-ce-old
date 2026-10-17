import Foundation
import MCP

/// Final result of one `code_mode` script (plan §6 D3).
///
/// - `text` is the human-readable tool result: accepted guest output followed by a footer that
///   always lists terminal failed calls (or "none"), counts, and the stop status. It is at most
///   `MCPCodeModeLimits.finalResultBytes` UTF-8 bytes, footer included; guest output is limited
///   to `outputBytes` so the footer always fits. Nothing is truncated silently: output overflow
///   ends the run with `limit_exceeded`/`output` and keeps the entries already accepted.
/// - On timeout, cancellation or any limit, `output` holds only what the script already emitted
///   with `text(...)`/`console.log(...)`. Successful child results that were never emitted are
///   not returned, and guest variables are never dumped.
/// - `isError` is true for every status except `success`, including caught or `allowError`
///   child failures; a call that failed once and succeeded on its automatic retry is not a failure.
/// - `structuredContent` carries the same accounting and output as protocol metadata.
struct MCPCodeModeExecutionResult: Equatable {
    enum Status: String {
        case success
        case childFailure = "child_failure"
        case scriptError = "script_error"
        case timeout
        case cancelled
        case limitExceeded = "limit_exceeded"
        case runtimeError = "runtime_error"
    }

    typealias Counts = MCPCodeModeRuntimeOutcome.Counts
    typealias FailedCall = MCPCodeModeRuntimeOutcome.FailedCall

    let status: Status
    /// Stable reason code (`wall_time`, `cpu_time`, `memory`, `output`, `calls`, ...), or nil.
    let reason: String?
    let message: String?
    let output: String
    let counts: Counts
    let failedCalls: [FailedCall]
    let text: String

    var isError: Bool {
        status != .success
    }

    var structuredContent: Value {
        var object: [String: Value] = [
            "status": .string(status.rawValue),
            "output": .string(output),
            "counts": .object([
                "calls": .int(counts.calls),
                "attempts": .int(counts.attempts),
                "completed": .int(counts.completed),
                "failed": .int(counts.failed),
                "queued_at_stop": .int(counts.queuedAtStop),
                "in_flight_at_stop": .int(counts.inFlightAtStop),
                "retries": .int(counts.retries)
            ]),
            "failed_calls": .array(failedCalls.map { call in
                .object([
                    "call_id": .int(call.callID),
                    "tool": .string(call.tool.rawValue),
                    "attempts": .int(call.attempts),
                    "code": .string(call.code)
                ])
            })
        ]
        if let reason { object["reason"] = .string(reason) }
        if let message { object["message"] = .string(message) }
        return .object(object)
    }
}

/// Runs one script in a fresh embedded runtime and bridges its child calls through an injected
/// re-entry closure (normally the connection's registered `tools/call` handler with a
/// `code_mode` child origin). Exactly one `invokeChild` call per dispatched attempt; at most
/// `maxInFlight` at once; at most `maxAttempts` attempts per script, automatic retries included.
struct MCPCodeModeExecutor {
    /// Invokes one child tool call. Must re-enter the full policy/admission/contract path; the
    /// returned `CallTool.Result.isError` (or a thrown error) is authoritative over any value.
    typealias ChildInvoker = @Sendable (_ toolName: String, _ arguments: [String: Value]) async throws -> MCPInProcessToolResult

    /// Contract text for the tool description: limits and the partial-result rule.
    static let descriptionNotes = """
    Limits: 60 s wall, 2 s CPU, 64 MiB heap, 32 KiB script, 32 tool calls per script (automatic \
    retries included), 2 calls in flight, 64 KiB arguments and 2 MiB result per call, 28 KiB of \
    output. Exceeding a limit ends the script with an error and call counts; nothing is truncated \
    silently. On timeout, cancellation or a limit, only output already emitted with text() or \
    console.log() is returned: emit small aggregate checkpoints after completed batches if partial \
    results matter.
    """

    static let maxErrorMessageBytes = 1024
    private static let footerMessageBytes = 512

    let limits: MCPCodeModeLimits
    let cleanupAllowance: DispatchTimeInterval
    let invokeChild: ChildInvoker
    /// Test seam only (see `MCPCodeModeRuntime.init`); production callers leave it nil.
    let ownerExitGate: (@Sendable () -> Void)?

    init(
        limits: MCPCodeModeLimits = .production,
        cleanupAllowance: DispatchTimeInterval = .seconds(2),
        ownerExitGate: (@Sendable () -> Void)? = nil,
        invokeChild: @escaping ChildInvoker
    ) {
        self.limits = limits
        self.cleanupAllowance = cleanupAllowance
        self.ownerExitGate = ownerExitGate
        self.invokeChild = invokeChild
    }

    /// Runs `script` (an async function body). Cancelling the calling task stops the script,
    /// cancels its outstanding children, and returns the output accepted so far with counts.
    /// Children are unstructured tasks inheriting the caller's task-local values; they are
    /// cancelled, not awaited, once the runtime has stopped.
    ///
    /// `onOwnerExit` is called exactly once, when no engine thread remains for this script: before
    /// `execute` returns if the runtime could not be created or started, or once the owner thread
    /// has exited and been joined and its host destroyed. That is before `execute` returns for
    /// every result except `runtime_error`/`cleanup_timeout`, and later (possibly much later)
    /// for that one. Hold a script slot or permit until it runs; it must not block.
    func execute(
        script: String,
        onOwnerExit: (@Sendable () -> Void)? = nil
    ) async -> MCPCodeModeExecutionResult {
        let runtime: MCPCodeModeRuntime
        do {
            runtime = try MCPCodeModeRuntime(
                script: script,
                limits: limits,
                cleanupAllowance: cleanupAllowance,
                ownerExitGate: ownerExitGate
            )
        } catch {
            onOwnerExit?()
            return Self.result(forCreationError: error)
        }
        let (requests, requestSink) = AsyncStream.makeStream(of: MCPCodeModeChildRequest.self)
        let children = MCPCodeModeChildTasks()
        let invoke = invokeChild
        let consumer = Task {
            for await request in requests {
                children.spawn {
                    await Self.runChild(request, runtime: runtime, invoke: invoke)
                }
            }
        }
        defer {
            requestSink.finish()
            consumer.cancel()
            children.closeAndCancelAll()
        }
        do {
            try runtime.start(
                onChildRequest: { request in requestSink.yield(request) },
                onOwnerExit: onOwnerExit
            )
        } catch {
            onOwnerExit?()
            return Self.runtimeFailure(reason: "engine_start_failure", message: "The code_mode runtime could not start.")
        }
        let completion = await withTaskCancellationHandler {
            await runtime.awaitCompletion()
        } onCancel: {
            runtime.requestStop()
            children.cancelAll()
        }
        switch completion {
        case let .finished(outcome):
            return Self.result(from: outcome)
        case let .cleanupTimedOut(progress):
            // Committed checkpoints and counts survive; nothing uncommitted is reported.
            return Self.makeResult(
                status: .runtimeError,
                reason: "cleanup_timeout",
                message: "The code_mode runtime did not stop within its cleanup allowance.",
                output: progress.output,
                counts: progress.counts,
                failedCalls: progress.failedCalls
            )
        }
    }

    // MARK: - Children

    private static func runChild(
        _ request: MCPCodeModeChildRequest,
        runtime: MCPCodeModeRuntime,
        invoke: ChildInvoker
    ) async {
        // A request queued before a stop never starts a child afterwards.
        guard !runtime.isStopRequested, !Task.isCancelled else { return }
        let reply: MCPCodeModeReply
        if let arguments = try? JSONDecoder().decode([String: Value].self, from: request.argumentsJSON) {
            do {
                let result = try await invoke(request.tool.rawValue, arguments)
                reply = childReply(from: result)
            } catch {
                reply = childReply(fromThrown: error)
            }
        } else {
            reply = failureReply(code: "invalid_arguments", message: "The tool arguments could not be decoded.", text: nil)
        }
        runtime.submitReply(callID: request.callID, attempt: request.attempt, reply: reply)
    }

    /// Data-first conversion of one child result. A failed result never exposes captured data.
    static func childReply(from result: MCPInProcessToolResult) -> MCPCodeModeReply {
        let texts = textContents(of: result.result)
        if result.result.isError == true {
            let text = texts?.joined(separator: "\n") ?? ""
            let message = text.isEmpty ? "tool call failed" : bounded(text, bytes: maxErrorMessageBytes)
            // Only the handler's typed EINTR/EAGAIN disposition retries; error text never does.
            if result.transientPOSIXCode != nil {
                return MCPCodeModeReply(
                    disposition: .retryableFailure,
                    payloadJSON: encode(["isError": .bool(true), "error": .string(message), "code": .string("transient_io_error")]),
                    failureCode: "transient_io_error"
                )
            }
            return failureReply(
                code: failureCode(fromErrorText: text) ?? "tool_error",
                message: message,
                text: message == text ? nil : text
            )
        }
        if let value = result.value {
            return successReply(["data": value, "isError": .bool(false)])
        }
        guard let texts, !texts.isEmpty else {
            return failureReply(
                code: "bridge_unsupported_content",
                message: "The tool returned content code_mode cannot represent.",
                text: nil
            )
        }
        return successReply(["text": .string(texts.joined(separator: "\n")), "isError": .bool(false)])
    }

    /// Thrown child errors. Only bridged POSIX `EINTR`/`EAGAIN` are retryable; cancellation,
    /// denials and every other error are final.
    static func childReply(fromThrown error: Error) -> MCPCodeModeReply {
        if error is CancellationError {
            return failureReply(code: "cancelled", message: "The tool call was cancelled.", text: nil)
        }
        let message = bounded(String(describing: error), bytes: maxErrorMessageBytes)
        if MCPInProcessToolResult.transientPOSIXCode(of: error) != nil {
            return MCPCodeModeReply(
                disposition: .retryableFailure,
                payloadJSON: encode(["isError": .bool(true), "error": .string(message), "code": .string("transient_io_error")]),
                failureCode: "transient_io_error"
            )
        }
        return failureReply(code: "tool_threw", message: message, text: nil)
    }

    private static func textContents(of result: CallTool.Result) -> [String]? {
        var texts: [String] = []
        for content in result.content {
            guard case let .text(text, _, _) = content else { return nil }
            texts.append(text)
        }
        return texts
    }

    /// The stable code of an execution-contract error text (`code: message`), if present.
    private static func failureCode(fromErrorText text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[..<colon]
        guard (1 ... 63).contains(candidate.count),
              candidate.first.map({ $0 >= "a" && $0 <= "z" }) == true,
              candidate.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" })
        else {
            return nil
        }
        return String(candidate)
    }

    private static func successReply(_ object: [String: Value]) -> MCPCodeModeReply {
        let payload = encode(object)
        guard !payload.isEmpty else {
            return failureReply(code: "bridge_encoding_failed", message: "The tool result could not be encoded.", text: nil)
        }
        return MCPCodeModeReply(disposition: .success, payloadJSON: payload, failureCode: nil)
    }

    private static func failureReply(code: String, message: String, text: String?) -> MCPCodeModeReply {
        var object: [String: Value] = ["isError": .bool(true), "error": .string(message), "code": .string(code)]
        if let text { object["text"] = .string(text) }
        return MCPCodeModeReply(disposition: .failure, payloadJSON: encode(object), failureCode: code)
    }

    private static func encode(_ object: [String: Value]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(object)) ?? Data()
    }

    /// Longest prefix of `string` within `bytes` UTF-8 bytes, never splitting a character.
    static func bounded(_ string: String, bytes: Int) -> String {
        guard string.utf8.count > bytes else { return string }
        var used = 0
        var end = string.startIndex
        for index in string.indices {
            let next = string.index(after: index)
            let size = string[index ..< next].utf8.count
            if used + size > bytes { break }
            used += size
            end = next
        }
        return String(string[..<end])
    }

    // MARK: - Result formatting

    static func result(from outcome: MCPCodeModeRuntimeOutcome) -> MCPCodeModeExecutionResult {
        let status: MCPCodeModeExecutionResult.Status = switch outcome.status {
        case .success: outcome.counts.failed > 0 ? .childFailure : .success
        case .scriptError: .scriptError
        case .timeout: .timeout
        case .cancelled: .cancelled
        case .limitExceeded: .limitExceeded
        case .runtimeError: .runtimeError
        }
        return makeResult(
            status: status,
            reason: outcome.reason?.rawValue,
            message: outcome.message,
            output: outcome.output,
            counts: outcome.counts,
            failedCalls: outcome.failedCalls
        )
    }

    private static func result(forCreationError error: Error) -> MCPCodeModeExecutionResult {
        if case let MCPCodeModeRuntimeError.scriptTooLarge(limit) = error {
            return makeResult(
                status: .limitExceeded,
                reason: "script_too_large",
                message: "The script exceeds \(limit) UTF-8 bytes.",
                output: "",
                counts: .init(),
                failedCalls: []
            )
        }
        return runtimeFailure(reason: "engine_init_failure", message: "The code_mode runtime could not be created.")
    }

    private static func runtimeFailure(reason: String, message: String) -> MCPCodeModeExecutionResult {
        makeResult(status: .runtimeError, reason: reason, message: message, output: "", counts: .init(), failedCalls: [])
    }

    private static func makeResult(
        status: MCPCodeModeExecutionResult.Status,
        reason: String?,
        message: String?,
        output: String,
        counts: MCPCodeModeExecutionResult.Counts,
        failedCalls: [MCPCodeModeExecutionResult.FailedCall]
    ) -> MCPCodeModeExecutionResult {
        let footer = footer(status: status, reason: reason, message: message, counts: counts, failedCalls: failedCalls, afterOutput: !output.isEmpty)
        let text = output + footer
        assert(text.utf8.count <= MCPCodeModeLimits.finalResultBytes, "code_mode result exceeds its final cap")
        return MCPCodeModeExecutionResult(
            status: status,
            reason: reason,
            message: message,
            output: output,
            counts: counts,
            failedCalls: failedCalls,
            text: text
        )
    }

    /// Deterministic footer, at most `metadataReserveBytes`. It never contains child arguments
    /// or child payloads; failed calls beyond the budget are summarized by count.
    static func footer(
        status: MCPCodeModeExecutionResult.Status,
        reason: String?,
        message: String?,
        counts: MCPCodeModeExecutionResult.Counts,
        failedCalls: [MCPCodeModeExecutionResult.FailedCall],
        afterOutput: Bool
    ) -> String {
        let budget = MCPCodeModeLimits.metadataReserveBytes
        var lines: [String] = []
        lines.append("[code_mode] status: \(status.rawValue)" + (reason.map { " (\($0))" } ?? ""))
        if let message, !message.isEmpty {
            let singleLine = message.replacingOccurrences(of: "\n", with: " ")
            lines.append("error: " + bounded(singleLine, bytes: footerMessageBytes))
        }
        lines.append(
            "calls: \(counts.calls) (completed \(counts.completed), failed \(counts.failed), "
                + "queued at stop \(counts.queuedAtStop), in flight at stop \(counts.inFlightAtStop)); "
                + "attempts \(counts.attempts), retries \(counts.retries)"
        )
        let prefix = afterOutput ? "\n\n" : ""
        var text = prefix + lines.joined(separator: "\n")
        if failedCalls.isEmpty {
            return text + "\nfailed calls: none"
        }
        text += "\nfailed calls:"
        // Room for the summary line that may follow.
        let summaryReserve = 80
        for (index, call) in failedCalls.enumerated() {
            let line = "\n- #\(call.callID) \(call.tool.rawValue): \(call.code) (attempts \(call.attempts))"
            if text.utf8.count + line.utf8.count + summaryReserve > budget {
                let remaining = failedCalls.count - index
                return text + "\n- … \(remaining) more (see structured failed_calls)"
            }
            text += line
        }
        return text
    }
}

/// Unstructured child tasks of one script: cancelled together, never awaited by the parent.
final class MCPCodeModeChildTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    func spawn(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            self?.remove(id)
        }
    }

    func cancelAll() {
        lock.lock()
        let running = Array(tasks.values)
        lock.unlock()
        running.forEach { $0.cancel() }
    }

    func closeAndCancelAll() {
        lock.lock()
        isClosed = true
        let running = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        running.forEach { $0.cancel() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        tasks.removeValue(forKey: id)
        lock.unlock()
    }
}
