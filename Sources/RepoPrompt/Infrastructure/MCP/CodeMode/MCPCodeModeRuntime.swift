import CRepoPromptCodeMode
import Foundation

/// Resource limits for one `code_mode` script (plan §6 D3). `production` is the only value used
/// outside tests; the C host rejects any field that is zero or above its production value.
struct MCPCodeModeLimits: Equatable {
    var wallMilliseconds: UInt32
    var cpuMilliseconds: UInt32
    var heapBytes: UInt32
    var stackBytes: UInt32
    var scriptBytes: UInt32
    var argumentBytes: UInt32
    var resultBytes: UInt32
    /// Guest output (`text`/`console.log`/return value): the final cap minus the footer reserve.
    var outputBytes: UInt32
    /// Child attempts, automatic retries included.
    var maxAttempts: UInt32
    /// Children dispatched at once, all four tools together.
    var maxInFlight: UInt32

    static let production = MCPCodeModeLimits(rpcm_production_limits())
    /// Final human-readable result cap, footer included.
    static let finalResultBytes = Int(RPCM_FINAL_RESULT_BYTES)
    /// Part of `finalResultBytes` reserved for the executor footer.
    static let metadataReserveBytes = Int(RPCM_RESULT_METADATA_RESERVE_BYTES)

    init(_ limits: rpcm_limits) {
        wallMilliseconds = limits.wall_ms
        cpuMilliseconds = limits.cpu_ms
        heapBytes = limits.heap_bytes
        stackBytes = limits.stack_bytes
        scriptBytes = limits.script_bytes
        argumentBytes = limits.args_bytes
        resultBytes = limits.result_bytes
        outputBytes = limits.output_bytes
        maxAttempts = limits.max_attempts
        maxInFlight = limits.max_in_flight
    }

    var cValue: rpcm_limits {
        rpcm_limits(
            wall_ms: wallMilliseconds,
            cpu_ms: cpuMilliseconds,
            heap_bytes: heapBytes,
            stack_bytes: stackBytes,
            script_bytes: scriptBytes,
            args_bytes: argumentBytes,
            result_bytes: resultBytes,
            output_bytes: outputBytes,
            max_attempts: maxAttempts,
            max_in_flight: maxInFlight
        )
    }
}

/// The closed set of tools a script may call; raw values are the canonical MCP tool names.
enum MCPCodeModeTool: String, CaseIterable {
    case readFile = "read_file"
    case fileSearch = "file_search"
    case getCodeStructure = "get_code_structure"
    case getFileTree = "get_file_tree"

    init?(_ tool: rpcm_tool) {
        switch tool {
        case RPCM_TOOL_READ_FILE: self = .readFile
        case RPCM_TOOL_FILE_SEARCH: self = .fileSearch
        case RPCM_TOOL_GET_CODE_STRUCTURE: self = .getCodeStructure
        case RPCM_TOOL_GET_FILE_TREE: self = .getFileTree
        default: return nil
        }
    }
}

/// One dispatched child attempt. `argumentsJSON` is the host's own serialization of the guest
/// argument object (at most `argumentBytes`); the same logical call keeps its `callID` on retry.
struct MCPCodeModeChildRequest: Equatable {
    let callID: UInt32
    let attempt: UInt32
    let tool: MCPCodeModeTool
    let argumentsJSON: Data
}

/// The bridge's reply for one child attempt. `payloadJSON` is the guest-visible object:
/// `{data|text, isError:false}` on success, `{isError:true, error, code, text?}` on failure.
struct MCPCodeModeReply: Equatable {
    enum Disposition: Equatable {
        case success
        case failure
        /// Typed transient failure; the host retries the call once if its attempt budget allows.
        case retryableFailure
    }

    let disposition: Disposition
    let payloadJSON: Data
    let failureCode: String?
}

/// Plain copy of the C host's final snapshot.
/// Invariant: `calls == completed + queuedAtStop + inFlightAtStop`; `failed <= completed`.
struct MCPCodeModeRuntimeOutcome: Equatable {
    enum Status: String {
        case success
        case scriptError = "script_error"
        case timeout
        case cancelled
        case limitExceeded = "limit_exceeded"
        case runtimeError = "runtime_error"
    }

    enum Reason: String {
        case scriptException = "script_exception"
        case unsettleablePromise = "unsettleable_promise"
        case wallTime = "wall_time"
        case cancelled
        case cpuTime = "cpu_time"
        case memory
        case stack
        case output
        case calls
        case hostAllocation = "host_allocation_failure"
        case engineInit = "engine_init_failure"
    }

    struct FailedCall: Equatable {
        let callID: Int
        let tool: MCPCodeModeTool
        let attempts: Int
        let code: String
    }

    struct Counts: Equatable {
        var calls = 0
        var attempts = 0
        var completed = 0
        var failed = 0
        var queuedAtStop = 0
        var inFlightAtStop = 0
        var retries = 0
        var maxInFlightObserved = 0
    }

    let status: Status
    let reason: Reason?
    /// Accepted guest output, valid UTF-8, at most `outputBytes`.
    let output: String
    /// Script error text (bounded), or nil.
    let message: String?
    let counts: Counts
    let failedCalls: [FailedCall]
    let guestCPUMilliseconds: Double
    let wallMilliseconds: Double

    init(
        status: Status,
        reason: Reason?,
        output: String,
        message: String?,
        counts: Counts,
        failedCalls: [FailedCall],
        guestCPUMilliseconds: Double = 0,
        wallMilliseconds: Double = 0
    ) {
        self.status = status
        self.reason = reason
        self.output = output
        self.message = message
        self.counts = counts
        self.failedCalls = failedCalls
        self.guestCPUMilliseconds = guestCPUMilliseconds
        self.wallMilliseconds = wallMilliseconds
    }

    init(_ outcome: rpcm_outcome) {
        switch outcome.status {
        case RPCM_STATUS_SUCCESS: status = .success
        case RPCM_STATUS_SCRIPT_ERROR: status = .scriptError
        case RPCM_STATUS_TIMEOUT: status = .timeout
        case RPCM_STATUS_CANCELLED: status = .cancelled
        case RPCM_STATUS_LIMIT_EXCEEDED: status = .limitExceeded
        default: status = .runtimeError
        }
        reason = Self.reason(outcome.reason)
        output = Self.string(outcome.output, count: outcome.output_len)
        let messageText = Self.string(outcome.message, count: outcome.message_len)
        message = messageText.isEmpty ? nil : messageText
        counts = Counts(
            calls: Int(outcome.calls),
            attempts: Int(outcome.attempts),
            completed: Int(outcome.completed),
            failed: Int(outcome.failed),
            queuedAtStop: Int(outcome.queued_at_stop),
            inFlightAtStop: Int(outcome.in_flight_at_stop),
            retries: Int(outcome.retries),
            maxInFlightObserved: Int(outcome.max_in_flight_observed)
        )
        failedCalls = Self.failedCalls(outcome.failed_calls, count: outcome.failed_call_count)
        guestCPUMilliseconds = outcome.guest_cpu_ms
        wallMilliseconds = outcome.wall_ms
    }

    private static func reason(_ reason: rpcm_reason) -> Reason? {
        switch reason {
        case RPCM_REASON_SCRIPT_EXCEPTION: .scriptException
        case RPCM_REASON_UNSETTLEABLE_PROMISE: .unsettleablePromise
        case RPCM_REASON_WALL_TIME: .wallTime
        case RPCM_REASON_CANCELLED: .cancelled
        case RPCM_REASON_CPU_TIME: .cpuTime
        case RPCM_REASON_MEMORY: .memory
        case RPCM_REASON_STACK: .stack
        case RPCM_REASON_OUTPUT: .output
        case RPCM_REASON_CALLS: .calls
        case RPCM_REASON_HOST_ALLOCATION: .hostAllocation
        case RPCM_REASON_ENGINE_INIT: .engineInit
        default: nil
        }
    }

    /// Decodes the fixed C `failed_calls` array (a tuple in Swift) up to `count` records.
    static func failedCalls(_ records: some Any, count: UInt32) -> [FailedCall] {
        let failedCount = min(Int(count), Int(RPCM_MAX_ATTEMPTS))
        return withUnsafeBytes(of: records) { raw in
            let records = raw.bindMemory(to: rpcm_failed_call.self)
            return (0 ..< min(failedCount, records.count)).map { index in
                let record = records[index]
                let code = withUnsafeBytes(of: record.code) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                return FailedCall(
                    callID: Int(record.call_id),
                    tool: MCPCodeModeTool(record.tool) ?? .readFile,
                    attempts: Int(record.attempts),
                    code: code
                )
            }
        }
    }

    private static func string(_ pointer: UnsafePointer<CChar>?, count: Int) -> String {
        guard let pointer, count > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
    }
}

/// Committed progress copied from a host whose owner thread may still run (`rpcm_host_snapshot`):
/// the output accepted so far, counts (`queuedAtStop`/`inFlightAtStop` as last published) and
/// terminal failed calls. Never contains unemitted child data.
struct MCPCodeModeRuntimeProgress: Equatable {
    let output: String
    let counts: MCPCodeModeRuntimeOutcome.Counts
    let failedCalls: [MCPCodeModeRuntimeOutcome.FailedCall]

    init(output: String = "", counts: MCPCodeModeRuntimeOutcome.Counts = .init(), failedCalls: [MCPCodeModeRuntimeOutcome.FailedCall] = []) {
        self.output = output
        self.counts = counts
        self.failedCalls = failedCalls
    }

    init(_ progress: rpcm_progress, output: String) {
        self.output = output
        counts = MCPCodeModeRuntimeOutcome.Counts(
            calls: Int(progress.calls),
            attempts: Int(progress.attempts),
            completed: Int(progress.completed),
            failed: Int(progress.failed),
            queuedAtStop: Int(progress.queued),
            inFlightAtStop: Int(progress.in_flight),
            retries: Int(progress.retries)
        )
        failedCalls = MCPCodeModeRuntimeOutcome.failedCalls(progress.failed_calls, count: progress.failed_call_count)
    }
}

enum MCPCodeModeRuntimeError: Error, Equatable {
    case invalidLimits
    case scriptTooLarge(limit: Int)
    case scriptNotUTF8
    case allocationFailed
    case alreadyStarted
    case startFailed(errno: Int32)
}

/// Swift owner of one opaque C host (one script, one run). The C owner thread runs every QuickJS
/// operation and frees the runtime itself; this object joins that thread and only then destroys
/// the host. While the thread runs, the host retains this object, so neither can be freed early.
///
/// Reply submission and host destruction are serialized by `lock`: once the owner has exited,
/// `submitReply` is a no-op returning `.notAccepted`, so late child completions never touch freed
/// memory. The bounded cleanup path never frees a host whose thread may still run.
final class MCPCodeModeRuntime: @unchecked Sendable {
    enum Completion: Equatable {
        case finished(MCPCodeModeRuntimeOutcome)
        /// The owner thread did not exit within the cleanup allowance. Carries the progress it
        /// had committed by then. The host stays retained and is joined and destroyed whenever the
        /// thread does exit; `onOwnerExit` runs only then.
        case cleanupTimedOut(MCPCodeModeRuntimeProgress)
    }

    enum SubmitResult: Equatable {
        case accepted
        case notAccepted
        case invalid
    }

    private enum Phase {
        case created
        case running
        case finished
    }

    let limits: MCPCodeModeLimits
    private let cleanupAllowance: DispatchTimeInterval
    private let lock = NSLock()
    private var host: OpaquePointer?
    private var phase: Phase = .created
    private var stopRequested = false
    private var onChildRequest: (@Sendable (MCPCodeModeChildRequest) -> Void)?
    private var onOwnerExit: (@Sendable () -> Void)?
    private let ownerExitGate: (@Sendable () -> Void)?
    private var retainedByOwner: Unmanaged<MCPCodeModeRuntime>?
    private var completion: Completion?
    private var waiter: CheckedContinuation<Completion, Never>?

    /// `ownerExitGate` is a test seam only: it runs on the owner thread after QuickJS is freed and
    /// before the thread can be joined, so a test can hold the exit (bounded) to exercise the
    /// cleanup-deadline path without a genuinely stuck engine.
    init(
        script: String,
        limits: MCPCodeModeLimits = .production,
        cleanupAllowance: DispatchTimeInterval = .seconds(2),
        ownerExitGate: (@Sendable () -> Void)? = nil
    ) throws {
        self.limits = limits
        self.cleanupAllowance = cleanupAllowance
        self.ownerExitGate = ownerExitGate
        var cLimits = limits.cValue
        var created: OpaquePointer?
        let utf8 = Array(script.utf8)
        let status = utf8.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { chars in
                rpcm_host_create(chars.baseAddress, chars.count, &cLimits, &created)
            }
        }
        switch status {
        case RPCM_CREATE_OK:
            host = created
        case RPCM_CREATE_INVALID_LIMITS:
            throw MCPCodeModeRuntimeError.invalidLimits
        case RPCM_CREATE_SCRIPT_TOO_LARGE:
            throw MCPCodeModeRuntimeError.scriptTooLarge(limit: Int(limits.scriptBytes))
        case RPCM_CREATE_SCRIPT_NOT_UTF8:
            throw MCPCodeModeRuntimeError.scriptNotUTF8
        default:
            throw MCPCodeModeRuntimeError.allocationFailed
        }
    }

    deinit {
        // Only a never-started host can remain here: a started host retains this object until
        // its owner thread has been joined and the host destroyed.
        if let host, phase == .created {
            _ = rpcm_host_destroy(host)
        }
    }

    /// True once a stop was requested or the run finished; children must not start afterwards.
    var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested || phase == .finished
    }

    /// Starts the owner thread. `onChildRequest` runs on the owner thread for each dispatched
    /// attempt and must return promptly without blocking. `onOwnerExit` runs exactly once, on a
    /// utility queue, after the owner thread has exited and the host has been joined and
    /// destroyed, and before a `.finished` completion is delivered; after `.cleanupTimedOut` it
    /// runs whenever the thread finally exits. It is never called if `start` throws.
    func start(
        onChildRequest: @escaping @Sendable (MCPCodeModeChildRequest) -> Void,
        onOwnerExit: (@Sendable () -> Void)? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .created, let host else { throw MCPCodeModeRuntimeError.alreadyStarted }
        self.onChildRequest = onChildRequest
        self.onOwnerExit = onOwnerExit
        let retained = Unmanaged.passRetained(self)
        let rc = rpcm_host_start(
            host,
            { context, callID, attempt, tool, arguments, length in
                guard let context, let tool = MCPCodeModeTool(tool) else { return }
                let runtime = Unmanaged<MCPCodeModeRuntime>.fromOpaque(context).takeUnretainedValue()
                let data = arguments.map { Data(bytes: $0, count: length) } ?? Data()
                runtime.deliver(MCPCodeModeChildRequest(callID: callID, attempt: attempt, tool: tool, argumentsJSON: data))
            },
            { context in
                guard let context else { return }
                Unmanaged<MCPCodeModeRuntime>.fromOpaque(context).takeUnretainedValue().ownerDidExit()
            },
            retained.toOpaque()
        )
        guard rc == 0 else {
            retained.release()
            self.onChildRequest = nil
            self.onOwnerExit = nil
            throw MCPCodeModeRuntimeError.startFailed(errno: rc)
        }
        retainedByOwner = retained
        phase = .running
        if stopRequested {
            rpcm_host_request_stop(host)
            scheduleCleanupDeadline(after: .seconds(0), plus: cleanupAllowance)
        }
        let wall = DispatchTimeInterval.milliseconds(Int(limits.wallMilliseconds))
        scheduleCleanupDeadline(after: wall, plus: cleanupAllowance)
    }

    /// Thread-safe and nonblocking. A reply after a stop or after the run finished is ignored.
    @discardableResult
    func submitReply(callID: UInt32, attempt: UInt32, reply: MCPCodeModeReply) -> SubmitResult {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .running, let host else { return .notAccepted }
        let disposition = switch reply.disposition {
        case .success: RPCM_REPLY_SUCCESS
        case .failure: RPCM_REPLY_FAILURE
        case .retryableFailure: RPCM_REPLY_RETRYABLE_FAILURE
        }
        let status = reply.payloadJSON.withUnsafeBytes { raw in
            let payload = raw.bindMemory(to: CChar.self)
            return Self.withOptionalCString(reply.failureCode) { code in
                rpcm_host_submit_reply(host, callID, attempt, disposition, payload.baseAddress, payload.count, code)
            }
        }
        switch status {
        case RPCM_SUBMIT_ACCEPTED: return .accepted
        case RPCM_SUBMIT_NOT_ACCEPTED: return .notAccepted
        default: return .invalid
        }
    }

    /// Thread-safe and idempotent: stops admission and dispatch, interrupts guest code, and arms
    /// the cleanup allowance.
    func requestStop() {
        lock.lock()
        let firstRequest = !stopRequested
        stopRequested = true
        let running = phase == .running
        if running, let host {
            rpcm_host_request_stop(host)
        }
        lock.unlock()
        if firstRequest, running {
            scheduleCleanupDeadline(after: .seconds(0), plus: cleanupAllowance)
        }
    }

    /// Suspends until the owner thread has exited and been joined (`.finished`), or until the
    /// cleanup allowance after the wall limit or a stop request passes (`.cleanupTimedOut`).
    /// Single waiter.
    func awaitCompletion() async -> Completion {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completion {
                lock.unlock()
                continuation.resume(returning: completion)
                return
            }
            precondition(waiter == nil, "MCPCodeModeRuntime supports a single completion waiter")
            waiter = continuation
            lock.unlock()
        }
    }

    // MARK: - Owner-thread callbacks

    private func deliver(_ request: MCPCodeModeChildRequest) {
        lock.lock()
        let handler = onChildRequest
        lock.unlock()
        handler?(request)
    }

    /// Runs on the owner thread after QuickJS is fully torn down; the thread returns right after,
    /// so the join below completes promptly.
    private func ownerDidExit() {
        ownerExitGate?()
        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock()
            guard let host else {
                lock.unlock()
                return
            }
            let snapshot = rpcm_host_join(host).map { MCPCodeModeRuntimeOutcome($0.pointee) }
            _ = rpcm_host_destroy(host)
            self.host = nil
            phase = .finished
            onChildRequest = nil
            let exitHandler = onOwnerExit
            onOwnerExit = nil
            let retained = retainedByOwner
            retainedByOwner = nil
            lock.unlock()
            // No engine thread remains for this script: release its slot before reporting.
            exitHandler?()
            let outcome = snapshot ?? MCPCodeModeRuntimeOutcome(
                status: .runtimeError,
                reason: .engineInit,
                output: "",
                message: nil,
                counts: .init(),
                failedCalls: []
            )
            complete(.finished(outcome))
            retained?.release()
        }
    }

    // MARK: - Completion

    private func complete(_ value: Completion) {
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        completion = value
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    private func scheduleCleanupDeadline(after interval: DispatchTimeInterval, plus allowance: DispatchTimeInterval) {
        let deadline = DispatchTime.now() + interval + allowance
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self] in
            self?.cleanupDeadlinePassed()
        }
    }

    private func cleanupDeadlinePassed() {
        lock.lock()
        guard phase == .running, let host else {
            lock.unlock()
            return
        }
        // The host cannot be destroyed while `lock` is held, and the snapshot never waits for
        // the owner thread or guest code.
        let progress = Self.snapshot(host, outputCapacity: Int(limits.outputBytes))
        lock.unlock()
        requestStop()
        complete(.cleanupTimedOut(progress))
    }

    private static func snapshot(_ host: OpaquePointer, outputCapacity: Int) -> MCPCodeModeRuntimeProgress {
        var progress = rpcm_progress()
        var buffer = [CChar](repeating: 0, count: max(outputCapacity, 1))
        let copied = buffer.withUnsafeMutableBufferPointer { chars in
            rpcm_host_snapshot(host, &progress, chars.baseAddress, chars.count)
        }
        let output = buffer.withUnsafeBufferPointer { chars in
            String(decoding: UnsafeRawBufferPointer(start: chars.baseAddress, count: copied), as: UTF8.self)
        }
        return MCPCodeModeRuntimeProgress(progress, output: output)
    }

    private static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }
}
