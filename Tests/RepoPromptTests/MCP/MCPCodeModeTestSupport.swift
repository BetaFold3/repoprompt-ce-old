import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace

extension MCPCodeModeLimits {
    /// Production limits with short wall/CPU budgets so containment tests finish quickly.
    static func testing(
        wallMilliseconds: UInt32 = 4000,
        cpuMilliseconds: UInt32 = 400,
        heapBytes: UInt32? = nil,
        scriptBytes: UInt32? = nil,
        argumentBytes: UInt32? = nil,
        resultBytes: UInt32? = nil,
        outputBytes: UInt32? = nil
    ) -> MCPCodeModeLimits {
        var limits = MCPCodeModeLimits.production
        limits.wallMilliseconds = wallMilliseconds
        limits.cpuMilliseconds = cpuMilliseconds
        if let heapBytes { limits.heapBytes = heapBytes }
        if let scriptBytes { limits.scriptBytes = scriptBytes }
        if let argumentBytes { limits.argumentBytes = argumentBytes }
        if let resultBytes { limits.resultBytes = resultBytes }
        if let outputBytes { limits.outputBytes = outputBytes }
        return limits
    }
}

/// Stub re-entry bridge: records every invocation (one per attempt), tracks concurrency, and
/// publishes invocation events so tests can synchronize without sleeps where possible.
final class MCPCodeModeStubBridge: @unchecked Sendable {
    struct Invocation: Equatable {
        let tool: String
        let arguments: [String: Value]
    }

    typealias Handler = @Sendable (_ tool: String, _ arguments: [String: Value], _ index: Int) async throws -> MCPInProcessToolResult

    private let lock = NSLock()
    private let handler: Handler
    private var recorded: [Invocation] = []
    private var running = 0
    private var maxRunning = 0
    private var cancelled = 0
    private var finished = 0
    private let eventsContinuation: AsyncStream<Invocation>.Continuation
    let events: AsyncStream<Invocation>

    init(handler: @escaping Handler = { tool, arguments, _ in MCPCodeModeStubBridge.success(tool: tool, arguments: arguments) }) {
        self.handler = handler
        (events, eventsContinuation) = AsyncStream.makeStream(of: Invocation.self)
    }

    var invocations: [Invocation] {
        lock.withLock { recorded }
    }

    var maxConcurrent: Int {
        lock.withLock { maxRunning }
    }

    var cancelledCount: Int {
        lock.withLock { cancelled }
    }

    var finishedCount: Int {
        lock.withLock { finished }
    }

    var invoker: MCPCodeModeExecutor.ChildInvoker {
        { [self] tool, arguments in try await invoke(tool: tool, arguments: arguments) }
    }

    private func invoke(tool: String, arguments: [String: Value]) async throws -> MCPInProcessToolResult {
        let invocation = Invocation(tool: tool, arguments: arguments)
        let index: Int = lock.withLock {
            recorded.append(invocation)
            running += 1
            maxRunning = max(maxRunning, running)
            return recorded.count - 1
        }
        eventsContinuation.yield(invocation)
        defer {
            lock.withLock {
                running -= 1
                finished += 1
            }
        }
        do {
            return try await handler(tool, arguments, index)
        } catch is CancellationError {
            lock.withLock { cancelled += 1 }
            throw CancellationError()
        }
    }

    /// Waits for the next invocation whose `path` argument matches.
    func waitForInvocation(path: String) async -> Invocation? {
        for await event in events where event.arguments["path"] == .string(path) {
            return event
        }
        return nil
    }

    static func success(tool: String, arguments: [String: Value]) -> MCPInProcessToolResult {
        MCPInProcessToolResult(
            value: .object(["tool": .string(tool), "arguments": .object(arguments)]),
            result: CallTool.Result(content: [.text(text: "markdown for \(tool)", annotations: nil, _meta: nil)], isError: false)
        )
    }
}

final class MCPCodeModeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

/// Thread-safe ordered record of lifecycle events, for ordering assertions.
final class MCPCodeModeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    var events: [String] {
        lock.withLock { entries }
    }
}

/// Bounded hold for the runtime's test-only owner-exit gate: the owner thread waits at exit until
/// `open()` or `limit` passes, so no test can leave a thread stuck.
final class MCPCodeModeOwnerExitGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let limit: DispatchTimeInterval
    let entered = MCPCodeModeFlag()

    init(limit: DispatchTimeInterval = .seconds(10)) {
        self.limit = limit
    }

    var hold: @Sendable () -> Void {
        { [self] in
            entered.set()
            _ = semaphore.wait(timeout: .now() + limit)
        }
    }

    func open() {
        semaphore.signal()
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func mcpCodeModeEventually(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
