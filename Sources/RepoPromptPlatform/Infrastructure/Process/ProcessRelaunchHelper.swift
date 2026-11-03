import AppKit
import Darwin
import Foundation

// Restart safely relaunch helper (lossless restart Phase 4 §G, FINAL existing-helper amendment).
//
// The helper is the EXISTING bundled `repoprompt-mcp` executable started in a private mode
// (`--rpce-private-relaunch-v1`), dispatched before any MCP code runs. It is not a provider family
// and is never registered as one. This file owns the closed v1 protocol and both state machines; OS
// effects (inspection, exit watch, opening the bundle, I/O, clocks) are injected.
//
// Protocol: newline-delimited JSON, one object per frame, at most 16 KiB per frame, exact key sets.
//   parent → helper: prepare, arm, abort
//   helper → parent: ready, armed, aborted, failed
//
// Helper rules:
// - Before `ready`: the prepared parent is our actual parent (PPID), its UID and birth identity match
//   a fresh inspection under our UID, the helper executable lives in the EXACT prepared bundle
//   (`<bundle>/Contents/MacOS/`), and an exit watch on the parent is established and re-verified.
//   The correlation ID correlates frames; it authenticates nothing.
// - Only `armed` plus a verified exit of that exact parent opens the exact bundle, ONCE. EOF is not
//   parent-exit proof. Anything uncertain (inspection unavailable, deadline, abort, violation)
//   ends with zero opens.
// - Limits: 8 s to ready, 8 s from ready to arm, 15 s from arm to the parent's exit, 10 s for the
//   open. The parent stops an unarmed helper within its cleanup reserve (abort acknowledgement, then
//   SIGKILL of the exact unreaped child), which R4 keeps inside its single deadline.

// MARK: - Invocation

package enum ProcessRelaunchInvocation: Equatable {
    /// No reserved argument: the ordinary MCP invocation, unchanged.
    case ordinary
    /// Exactly the v1 private mode.
    case relaunchV1
    /// A reserved argument in any other form (malformed, extra arguments, another version). Exits
    /// with an error; never falls back to MCP.
    case invalid(String)

    /// Any argument starting with this prefix is reserved (`--rpce-private-relaunch` itself and
    /// every suffix of it), so a near-miss never falls back to the ordinary MCP mode.
    package static let reservedPrefix = "--rpce-private-relaunch"
    package static let v1Argument = "--rpce-private-relaunch-v1"

    /// Classifies process arguments (excluding the executable path).
    package static func classify(_ arguments: [String]) -> ProcessRelaunchInvocation {
        guard arguments.contains(where: { $0.hasPrefix(reservedPrefix) }) else { return .ordinary }
        guard arguments == [v1Argument] else {
            return .invalid("The private relaunch mode accepts exactly one argument: \(v1Argument).")
        }
        return .relaunchV1
    }
}

// MARK: - Messages and codec

package struct ProcessRelaunchParentIdentity: Equatable {
    package let pid: pid_t
    package let bootSessionID: UUID
    package let startSeconds: UInt64
    package let startMicroseconds: UInt64
    package let uid: uid_t

    package init(pid: pid_t, bootSessionID: UUID, startSeconds: UInt64, startMicroseconds: UInt64, uid: uid_t) {
        self.pid = pid
        self.bootSessionID = bootSessionID
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.uid = uid
    }

    package init(_ identity: ProcessBirthIdentity) {
        self.init(
            pid: identity.pid,
            bootSessionID: identity.bootSessionID,
            startSeconds: identity.startSeconds,
            startMicroseconds: identity.startMicroseconds,
            uid: identity.uid
        )
    }

    package func matches(_ identity: ProcessBirthIdentity) -> Bool {
        identity.pid == pid && identity.bootSessionID == bootSessionID && identity.startSeconds == startSeconds
            && identity.startMicroseconds == startMicroseconds && identity.uid == uid
    }
}

package enum ProcessRelaunchMessage: Equatable {
    case prepare(correlationID: UUID, parent: ProcessRelaunchParentIdentity, bundlePath: String)
    case ready(correlationID: UUID)
    case arm(correlationID: UUID)
    case armed(correlationID: UUID)
    case abort(correlationID: UUID)
    case aborted(correlationID: UUID)
    case failed(correlationID: UUID?, reason: String)

    package var correlationID: UUID? {
        switch self {
        case let .prepare(id, _, _), let .ready(id), let .arm(id), let .armed(id), let .abort(id), let .aborted(id):
            id
        case let .failed(id, _):
            id
        }
    }
}

package enum ProcessRelaunchCodecError: Error, Equatable {
    case frameTooLarge
    case malformed(String)
}

package enum ProcessRelaunchCodec {
    package static let protocolVersion = 1
    package static let maximumFrameBytes = 16 * 1024
    package static let maximumReasonCharacters = 512

    /// One frame including its trailing newline.
    package static func encode(_ message: ProcessRelaunchMessage) throws -> Data {
        var object: [String: Any] = ["v": protocolVersion]
        switch message {
        case let .prepare(id, parent, bundlePath):
            object["type"] = "prepare"
            object["id"] = id.uuidString
            object["parent"] = [
                "pid": Int(parent.pid),
                "boot": parent.bootSessionID.uuidString,
                "startSeconds": parent.startSeconds,
                "startMicroseconds": parent.startMicroseconds,
                "uid": Int(parent.uid)
            ] as [String: Any]
            object["bundle"] = bundlePath
        case let .ready(id):
            object["type"] = "ready"
            object["id"] = id.uuidString
        case let .arm(id):
            object["type"] = "arm"
            object["id"] = id.uuidString
        case let .armed(id):
            object["type"] = "armed"
            object["id"] = id.uuidString
        case let .abort(id):
            object["type"] = "abort"
            object["id"] = id.uuidString
        case let .aborted(id):
            object["type"] = "aborted"
            object["id"] = id.uuidString
        case let .failed(id, reason):
            object["type"] = "failed"
            if let id { object["id"] = id.uuidString }
            object["reason"] = String(reason.prefix(maximumReasonCharacters))
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count < maximumFrameBytes else { throw ProcessRelaunchCodecError.frameTooLarge }
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Decodes one frame (without its newline). Exact key sets; unknown types or members reject.
    // swiftlint:disable:next cyclomatic_complexity
    package static func decode(_ frame: Data) throws -> ProcessRelaunchMessage {
        guard frame.count <= maximumFrameBytes else { throw ProcessRelaunchCodecError.frameTooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            throw ProcessRelaunchCodecError.malformed("not a JSON object")
        }
        guard (object["v"] as? NSNumber)?.intValue == protocolVersion, isInteger(object["v"]) else {
            throw ProcessRelaunchCodecError.malformed("unsupported version")
        }
        guard let type = object["type"] as? String else { throw ProcessRelaunchCodecError.malformed("missing type") }
        func requireKeys(_ keys: Set<String>) throws {
            guard Set(object.keys) == keys else { throw ProcessRelaunchCodecError.malformed("unexpected members for \(type)") }
        }
        func id() throws -> UUID {
            guard let raw = object["id"] as? String, let value = UUID(uuidString: raw) else {
                throw ProcessRelaunchCodecError.malformed("invalid id")
            }
            return value
        }
        switch type {
        case "prepare":
            try requireKeys(["v", "type", "id", "parent", "bundle"])
            guard let parent = object["parent"] as? [String: Any],
                  Set(parent.keys) == ["pid", "boot", "startSeconds", "startMicroseconds", "uid"],
                  let pid = integer(parent["pid"]), pid > 0, pid <= Int64(Int32.max),
                  let bootRaw = parent["boot"] as? String, let boot = UUID(uuidString: bootRaw),
                  let start = integer(parent["startSeconds"]), start >= 0,
                  let micros = integer(parent["startMicroseconds"]), micros >= 0,
                  let uid = integer(parent["uid"]), uid >= 0, uid <= Int64(UInt32.max)
            else { throw ProcessRelaunchCodecError.malformed("invalid parent") }
            guard let bundle = object["bundle"] as? String, !bundle.isEmpty else {
                throw ProcessRelaunchCodecError.malformed("invalid bundle")
            }
            return try .prepare(
                correlationID: id(),
                parent: ProcessRelaunchParentIdentity(
                    pid: pid_t(pid),
                    bootSessionID: boot,
                    startSeconds: UInt64(start),
                    startMicroseconds: UInt64(micros),
                    uid: uid_t(uid)
                ),
                bundlePath: bundle
            )
        case "ready":
            try requireKeys(["v", "type", "id"])
            return try .ready(correlationID: id())
        case "arm":
            try requireKeys(["v", "type", "id"])
            return try .arm(correlationID: id())
        case "armed":
            try requireKeys(["v", "type", "id"])
            return try .armed(correlationID: id())
        case "abort":
            try requireKeys(["v", "type", "id"])
            return try .abort(correlationID: id())
        case "aborted":
            try requireKeys(["v", "type", "id"])
            return try .aborted(correlationID: id())
        case "failed":
            let keys = Set(object.keys)
            guard keys == ["v", "type", "reason"] || keys == ["v", "type", "id", "reason"] else {
                throw ProcessRelaunchCodecError.malformed("unexpected members for failed")
            }
            guard let reason = object["reason"] as? String, reason.count <= maximumReasonCharacters else {
                throw ProcessRelaunchCodecError.malformed("invalid reason")
            }
            return try .failed(correlationID: keys.contains("id") ? id() : nil, reason: reason)
        default:
            throw ProcessRelaunchCodecError.malformed("unknown type")
        }
    }

    private static func isInteger(_ value: Any?) -> Bool {
        integer(value) != nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9.0e15 else { return nil }
        return number.int64Value
    }
}

/// Inbound channel events after framing.
package enum ProcessRelaunchInbound: Equatable {
    case message(ProcessRelaunchMessage)
    /// The peer closed its side. Never proof that the peer process exited.
    case endOfInput
    /// Oversized or malformed input. The channel is unusable afterwards.
    case violation(String)
}

/// Splits a byte stream into frames (16 KiB cap, including an unterminated tail).
package struct ProcessRelaunchFrameDecoder {
    private var buffer = Data()
    private(set) var isPoisoned = false

    package init() {}

    package mutating func append(_ data: Data) -> [ProcessRelaunchInbound] {
        guard !isPoisoned else { return [] }
        buffer.append(data)
        var events: [ProcessRelaunchInbound] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let frame = buffer[buffer.startIndex ..< newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            do {
                try events.append(.message(ProcessRelaunchCodec.decode(Data(frame))))
            } catch {
                isPoisoned = true
                events.append(.violation(String(describing: error)))
                return events
            }
        }
        if buffer.count > ProcessRelaunchCodec.maximumFrameBytes {
            isPoisoned = true
            events.append(.violation("frame too large"))
        }
        return events
    }

    /// End of input: an unterminated tail is a violation; otherwise `.endOfInput`.
    package mutating func finish() -> ProcessRelaunchInbound {
        guard !isPoisoned else { return .endOfInput }
        if !buffer.isEmpty {
            isPoisoned = true
            return .violation("incomplete frame at end of input")
        }
        return .endOfInput
    }
}

// MARK: - Limits

package struct ProcessRelaunchLimits: Equatable {
    /// Helper: spawn to `prepare`, and again `ready` to `arm` (a ready helper never waits forever).
    package var ready: Duration
    package var parentExit: Duration
    package var open: Duration
    /// Parent: how long an unarmed helper gets to confirm `aborted` (or exit) before its exact child
    /// is killed.
    package var abortAcknowledgement: Duration
    /// Parent: how long the exit of a killed helper is awaited. A delivered signal is not exit
    /// proof (review A P1-07): without a correlated `aborted` or the exact child's observed exit the
    /// stop is unresolved and the parent keeps ownership of the helper.
    package var terminateGrace: Duration

    package init(
        ready: Duration = .seconds(8),
        parentExit: Duration = .seconds(15),
        open: Duration = .seconds(10),
        abortAcknowledgement: Duration = .milliseconds(750),
        terminateGrace: Duration = .milliseconds(250)
    ) {
        self.ready = ready
        self.parentExit = parentExit
        self.open = open
        self.abortAcknowledgement = abortAcknowledgement
        self.terminateGrace = terminateGrace
    }

    /// The parent's bounded cleanup of one unarmed helper (R4 reserves it inside its deadline).
    package var cleanupReserve: Duration {
        abortAcknowledgement + terminateGrace
    }

    package static let v1 = ProcessRelaunchLimits()
}

// MARK: - Helper side

package final class ProcessRelaunchWatchToken: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var cancelled = false

    package init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    package func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { onCancel() }
    }
}

package struct ProcessRelaunchHelperEnvironment {
    package var parentPID: @Sendable () -> pid_t
    package var currentUID: @Sendable () -> uid_t
    package var inspect: @Sendable (pid_t) -> ProcessInspectionResult
    package var ownExecutablePath: @Sendable () -> String?
    package var realPath: @Sendable (String) -> String?
    package var watchExit: @Sendable (pid_t, @escaping @Sendable () -> Void) -> ProcessRelaunchWatchToken
    /// Opens the exact application bundle once. Returns whether the open request succeeded.
    package var openBundle: @Sendable (URL) async -> Bool
    package var sleep: @Sendable (Duration) async -> Void
    package var send: @Sendable (Data) -> Void

    package init(
        parentPID: @escaping @Sendable () -> pid_t,
        currentUID: @escaping @Sendable () -> uid_t,
        inspect: @escaping @Sendable (pid_t) -> ProcessInspectionResult,
        ownExecutablePath: @escaping @Sendable () -> String?,
        realPath: @escaping @Sendable (String) -> String?,
        watchExit: @escaping @Sendable (pid_t, @escaping @Sendable () -> Void) -> ProcessRelaunchWatchToken,
        openBundle: @escaping @Sendable (URL) async -> Bool,
        sleep: @escaping @Sendable (Duration) async -> Void,
        send: @escaping @Sendable (Data) -> Void
    ) {
        self.parentPID = parentPID
        self.currentUID = currentUID
        self.inspect = inspect
        self.ownExecutablePath = ownExecutablePath
        self.realPath = realPath
        self.watchExit = watchExit
        self.openBundle = openBundle
        self.sleep = sleep
        self.send = send
    }
}

package enum ProcessRelaunchHelperOutcome: Equatable {
    /// The exact bundle was opened once after the exact parent's verified exit.
    case opened
    /// The single open attempt failed or timed out (never retried).
    case openFailed(String)
    /// The parent aborted. Zero opens.
    case aborted
    /// Anything else. Zero opens.
    case failed(String)

    package var exitCode: Int32 {
        switch self {
        case .opened: 0
        case .aborted: 0
        case .openFailed: 3
        case .failed: 2
        }
    }
}

/// The helper state machine. One event loop; every decision happens on it.
package actor ProcessRelaunchHelperSession {
    private enum Phase: Equatable {
        case awaitingPrepare
        case ready
        case armed
        case opening
    }

    private enum Event {
        case inbound(ProcessRelaunchInbound)
        case parentExitObserved
        case deadline(Phase)
        case openFinished(Bool)
    }

    private let environment: ProcessRelaunchHelperEnvironment
    private let limits: ProcessRelaunchLimits
    private var opens = 0

    package init(environment: ProcessRelaunchHelperEnvironment, limits: ProcessRelaunchLimits = .v1) {
        self.environment = environment
        self.limits = limits
    }

    /// Number of open requests issued (0 or 1).
    package var openCount: Int {
        opens
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    package func run(inbound: AsyncStream<ProcessRelaunchInbound>) async -> ProcessRelaunchHelperOutcome {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let pump = Task {
            for await event in inbound {
                continuation.yield(.inbound(event))
            }
            continuation.yield(.inbound(.endOfInput))
        }
        var timers: [Task<Void, Never>] = []
        var watch: ProcessRelaunchWatchToken?
        defer {
            pump.cancel()
            timers.forEach { $0.cancel() }
            watch?.cancel()
            continuation.finish()
        }
        func startDeadline(_ phase: Phase, _ duration: Duration) {
            let sleep = environment.sleep
            timers.append(Task {
                await sleep(duration)
                guard !Task.isCancelled else { return }
                continuation.yield(.deadline(phase))
            })
        }
        func send(_ message: ProcessRelaunchMessage) {
            if let data = try? ProcessRelaunchCodec.encode(message) { environment.send(data) }
        }

        var phase = Phase.awaitingPrepare
        var correlationID: UUID?
        var parent: ProcessRelaunchParentIdentity?
        var bundleURL: URL?
        startDeadline(.awaitingPrepare, limits.ready)

        for await event in events {
            switch (phase, event) {
            case let (.awaitingPrepare, .inbound(.message(.prepare(id, identity, bundlePath)))):
                switch validatePrepare(identity: identity, bundlePath: bundlePath) {
                case let .failure(rejection):
                    send(.failed(correlationID: id, reason: rejection.reason))
                    return .failed(rejection.reason)
                case let .success(url):
                    correlationID = id
                    parent = identity
                    bundleURL = url
                }
                watch = environment.watchExit(identity.pid) { continuation.yield(.parentExitObserved) }
                // A watch installed on an already-exited process may never fire: re-verify.
                guard case let .observed(observation) = environment.inspect(identity.pid),
                      identity.matches(observation.identity), !observation.isZombie
                else {
                    let reason = "The parent could not be verified after the exit watch was installed."
                    send(.failed(correlationID: id, reason: reason))
                    return .failed(reason)
                }
                phase = .ready
                startDeadline(.ready, limits.ready)
                send(.ready(correlationID: id))
            case (.awaitingPrepare, .deadline(.awaitingPrepare)):
                let reason = "No valid prepare arrived before the ready deadline."
                send(.failed(correlationID: nil, reason: reason))
                return .failed(reason)
            case (.awaitingPrepare, .inbound(.endOfInput)):
                return .failed("Input ended before prepare.")
            case let (.ready, .inbound(.message(.arm(id)))) where id == correlationID:
                phase = .armed
                startDeadline(.armed, limits.parentExit)
                send(.armed(correlationID: id))
            case let (.ready, .inbound(.message(.abort(id)))) where id == correlationID,
                 let (.armed, .inbound(.message(.abort(id)))) where id == correlationID:
                send(.aborted(correlationID: id))
                return .aborted
            case (.ready, .deadline(.ready)):
                let reason = "No arm arrived before the ready deadline."
                send(.failed(correlationID: correlationID, reason: reason))
                return .failed(reason)
            case (.ready, .inbound(.endOfInput)):
                return .failed("Input ended before arm.")
            case (.ready, .parentExitObserved):
                return .failed("The parent exited before arming.")
            case (.armed, .inbound(.endOfInput)):
                // EOF is not proof that the parent exited: keep waiting for the exit watch.
                continue
            case (.armed, .parentExitObserved):
                guard let parent, let bundleURL else { return .failed("Missing prepared state.") }
                guard Self.isVerifiedExit(of: parent, inspection: environment.inspect(parent.pid)) else {
                    return .failed("The parent's exit could not be verified.")
                }
                phase = .opening
                opens += 1
                startDeadline(.opening, limits.open)
                let open = environment.openBundle
                timers.append(Task {
                    let succeeded = await open(bundleURL)
                    continuation.yield(.openFinished(succeeded))
                })
            case (.armed, .deadline(.armed)):
                return .failed("The parent did not exit before the deadline.")
            case let (.opening, .openFinished(succeeded)):
                return succeeded ? .opened : .openFailed("The application could not be opened.")
            case (.opening, .deadline(.opening)):
                return .openFailed("Opening the application timed out.")
            case (.opening, _):
                continue
            case (_, .deadline), (_, .parentExitObserved), (_, .openFinished):
                // Stale timer or event of an earlier phase.
                continue
            case let (_, .inbound(.violation(reason))):
                send(.failed(correlationID: correlationID, reason: "Protocol violation: \(reason)"))
                return .failed("Protocol violation: \(reason)")
            case (_, .inbound(.message)):
                let reason = "Unexpected message for the current state."
                send(.failed(correlationID: correlationID, reason: reason))
                return .failed(reason)
            case (_, .inbound(.endOfInput)):
                return .failed("Input ended.")
            }
        }
        return .failed("The helper stopped unexpectedly.")
    }

    private struct Rejection: Error {
        let reason: String
    }

    private func validatePrepare(identity: ProcessRelaunchParentIdentity, bundlePath: String) -> Result<URL, Rejection> {
        guard identity.pid == environment.parentPID() else {
            return .failure(Rejection(reason: "The prepared process is not this helper's parent."))
        }
        guard identity.uid == environment.currentUID() else {
            return .failure(Rejection(reason: "The parent belongs to another user."))
        }
        guard case let .observed(observation) = environment.inspect(identity.pid),
              identity.matches(observation.identity), !observation.isZombie
        else {
            return .failure(Rejection(reason: "The parent's identity could not be verified."))
        }
        guard bundlePath.hasPrefix("/"), bundlePath.hasSuffix(".app"),
              let bundle = environment.realPath(bundlePath), bundle.hasSuffix(".app")
        else {
            return .failure(Rejection(reason: "The application bundle path is invalid."))
        }
        guard let own = environment.ownExecutablePath().flatMap(environment.realPath),
              (own as NSString).deletingLastPathComponent == bundle + "/Contents/MacOS"
        else {
            return .failure(Rejection(reason: "The helper is not inside the prepared application bundle."))
        }
        return .success(URL(fileURLWithPath: bundle, isDirectory: true))
    }

    /// Exact-parent exit: the PID is gone, reused by another lifetime, or a zombie of the same
    /// lifetime. Unavailable inspection is never proof.
    package static func isVerifiedExit(of parent: ProcessRelaunchParentIdentity, inspection: ProcessInspectionResult) -> Bool {
        switch inspection {
        case .notFound:
            true
        case let .observed(observation):
            !parent.matches(observation.identity) || observation.isZombie
        case .unavailable:
            false
        }
    }
}

// MARK: - Parent side

/// The parent's view of one spawned helper (injected; the App adapter owns the real process).
package struct ProcessRelaunchHelperChannel {
    /// Writes one frame. Returns false when the helper's input is closed.
    package var send: @Sendable (Data) -> Bool
    package var inbound: AsyncStream<ProcessRelaunchInbound>
    /// Resolves once the exact helper child has exited and been reaped by this process.
    package var waitForExit: @Sendable () async -> Void
    /// Requests SIGKILL of the exact, not-yet-reaped helper child: the bounded last resort after a
    /// lost acknowledgement. Its result is never exit proof (review A P1-07): only an observed exit
    /// (`waitForExit`) or a correlated `aborted` proves the helper can no longer open anything.
    package var terminate: @Sendable () -> ProcessRelaunchTerminateResult

    package init(
        send: @escaping @Sendable (Data) -> Bool,
        inbound: AsyncStream<ProcessRelaunchInbound>,
        waitForExit: @escaping @Sendable () async -> Void,
        terminate: @escaping @Sendable () -> ProcessRelaunchTerminateResult
    ) {
        self.send = send
        self.inbound = inbound
        self.waitForExit = waitForExit
        self.terminate = terminate
    }
}

/// What a terminate request did. None of these is exit proof.
package enum ProcessRelaunchTerminateResult: Equatable {
    /// SIGKILL was delivered to the exact child (accepted by the kernel; its exit is not yet observed).
    case signalSent
    /// The exact child is no longer running as far as its owner knows; nothing was signalled.
    case notRunning
    /// The signal could not be delivered, or the exact child's identity could not be established.
    case failed(String)
}

/// How the parent's bounded stop of one helper ended (review A P1-07).
package enum ProcessRelaunchStopProof: Equatable {
    /// The helper confirmed `aborted` for this exact correlation (irreversible on the helper side).
    case abortAcknowledged
    /// The exact helper child's exit was observed.
    case exitObserved
}

package enum ProcessRelaunchStopResult: Equatable {
    /// Proven: the helper can no longer arm or open anything.
    case safe(ProcessRelaunchStopProof)
    /// Not proven within the session's one absolute cleanup budget: the helper may still be alive
    /// (and, after a lost `armed` acknowledgement, armed). Ownership stays with this session.
    case unresolved(String)

    package var isSafe: Bool {
        if case .safe = self { return true }
        return false
    }
}

package enum ProcessRelaunchPrepareResult: Equatable {
    case ready
    /// The helper was not made ready; its stop was proven (`aborted` or its exact exit).
    case failed(String)
    /// The helper was not made ready and its stop could not be proven: ownership is retained.
    case unresolved(String)
}

package enum ProcessRelaunchArmResult: Equatable {
    case armed
    /// Not armed: the helper confirmed `aborted` or its exact exit was observed. Safe to show choices.
    case notArmed(String)
    /// The arm was not confirmed and the helper's stop could not be proven: it may be armed.
    /// Ownership is retained; no choice, fresh helper, or Quit Anyway may follow.
    case unresolved(String)
}

/// The first stop proof one helper gave (lossless restart Step 4b), recorded by the session's pumps
/// as it arrives, independent of whichever call is consuming events. Lock-protected so a waiter that
/// registers while the proof lands never misses it.
private final class ProcessRelaunchStopProofLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var proof: ProcessRelaunchStopProof?
    private var abortSent = false
    private var waiters: [UUID: CheckedContinuation<ProcessRelaunchStopProof?, Never>] = [:]

    var recorded: ProcessRelaunchStopProof? {
        lock.withLock { proof }
    }

    /// Set before an `abort` frame is written: only then is a correlated `aborted` a reply to it.
    func noteAbortSent() {
        lock.withLock { abortSent = true }
    }

    func recordAborted() {
        guard lock.withLock({ abortSent }) else { return }
        record(.abortAcknowledged)
    }

    /// The first proof wins; later ones are ignored.
    func record(_ newProof: ProcessRelaunchStopProof) {
        let pending: [CheckedContinuation<ProcessRelaunchStopProof?, Never>] = lock.withLock {
            guard proof == nil else { return [] }
            proof = newProof
            let waiting = Array(waiters.values)
            waiters = [:]
            return waiting
        }
        pending.forEach { $0.resume(returning: newProof) }
    }

    /// The recorded proof (at once when it is already there), or `nil` once the waiting task is
    /// cancelled.
    func wait() async -> ProcessRelaunchStopProof? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let proof {
                    lock.unlock()
                    continuation.resume(returning: proof)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(returning: nil)
        }
    }
}

/// Parent-side protocol driver for one helper. Retry always uses a fresh session and helper.
package actor ProcessRelaunchParentSession {
    private enum Event {
        case inbound(ProcessRelaunchInbound)
        case helperExited
        case timeout(UInt64)
    }

    private let channel: ProcessRelaunchHelperChannel
    private let correlationID: UUID
    private let sleep: @Sendable (Duration) async -> Void
    private let limits: ProcessRelaunchLimits
    private var events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var helperExited = false
    private var timerGeneration: UInt64 = 0
    private var pumps: [Task<Void, Never>] = []
    private let stopProofLatch = ProcessRelaunchStopProofLatch()
    private let now: @Sendable () -> ContinuousClock.Instant
    /// The one absolute cleanup budget, captured when the first stop began (review A P1-07): later
    /// stops only get what is left of it, so repeated calls never renew it.
    private var stopAcknowledgementDeadline: ContinuousClock.Instant?
    private var stopDeadline: ContinuousClock.Instant?
    /// The driver's absolute final cleanup expiry (review R1 A P1-07): captured from the first
    /// budget passed in (the R4 attempt's deadline) and only ever lowered. Every stop ends by it,
    /// whatever was awaited before the stop began.
    private var cleanupCap: ContinuousClock.Instant?
    /// Whether an `arm` frame was ever attempted (review R1 B N3). While `false`, the helper was
    /// never armed, so even a ready helper whose stop is unproven can never open anything.
    package private(set) var armWasSent = false
    /// Every terminate request's result (diagnostics; never exit proof).
    private(set) var terminateResults: [ProcessRelaunchTerminateResult] = []
    private(set) var state: State = .spawned

    package enum State: Equatable {
        case spawned
        case ready
        case armed
        /// A stop was not proven within the cleanup budget: the helper may be alive (possibly
        /// armed). Never reported as finished; ownership stays here.
        case stopUnresolved
        case finished
    }

    package init(
        channel: ProcessRelaunchHelperChannel,
        correlationID: UUID = UUID(),
        limits: ProcessRelaunchLimits = .v1,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.channel = channel
        self.correlationID = correlationID
        self.limits = limits
        self.sleep = sleep
        self.now = now
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    private func startPumpsIfNeeded() {
        guard pumps.isEmpty else { return }
        let channel = channel
        let continuation = continuation
        let latch = stopProofLatch
        let correlationID = correlationID
        pumps.append(Task {
            for await event in channel.inbound {
                if case let .message(.aborted(id)) = event, id == correlationID {
                    latch.recordAborted()
                }
                continuation.yield(.inbound(event))
            }
            // End of input is never stop proof.
            continuation.yield(.inbound(.endOfInput))
        })
        pumps.append(Task {
            await channel.waitForExit()
            latch.record(.exitObserved)
            continuation.yield(.helperExited)
        })
    }

    private func startTimer(_ duration: Duration) -> UInt64 {
        timerGeneration += 1
        let generation = timerGeneration
        let sleep = sleep
        let continuation = continuation
        Task {
            await sleep(duration)
            continuation.yield(.timeout(generation))
        }
        return generation
    }

    private func send(_ message: ProcessRelaunchMessage) -> Bool {
        guard let data = try? ProcessRelaunchCodec.encode(message) else { return false }
        return channel.send(data)
    }

    /// Lowers the session's absolute cleanup cap (never raises or renews it).
    private func capCleanup(at expiry: ContinuousClock.Instant?) {
        guard let expiry else { return }
        cleanupCap = min(cleanupCap ?? expiry, expiry)
    }

    /// Stage A relative to now: `deadline` from this call, cleanup capped `cleanupReserve` after it.
    package func prepare(
        parent: ProcessRelaunchParentIdentity,
        bundlePath: String,
        deadline: Duration
    ) async -> ProcessRelaunchPrepareResult {
        let start = now()
        return await prepare(
            parent: parent,
            bundlePath: bundlePath,
            workExpiry: start + deadline,
            cleanupExpiry: start + deadline + limits.cleanupReserve
        )
    }

    /// Stage A: sends `prepare` and waits for `ready` until the absolute `workExpiry` (never longer
    /// than the helper's own ready limit), recomputed when the timer starts, so time the driver spent
    /// before this call (serialization, a prior helper's cleanup, identity, spawn) is never renewed.
    /// On failure the helper is stopped before returning, by `cleanupExpiry` at the latest.
    package func prepare(
        parent: ProcessRelaunchParentIdentity,
        bundlePath: String,
        workExpiry: ContinuousClock.Instant,
        cleanupExpiry: ContinuousClock.Instant
    ) async -> ProcessRelaunchPrepareResult {
        guard state == .spawned else { return .failed("The helper was already prepared.") }
        capCleanup(at: cleanupExpiry)
        startPumpsIfNeeded()
        guard now() < workExpiry else {
            return await failPrepare("The relaunch helper did not become ready in time.")
        }
        guard send(.prepare(correlationID: correlationID, parent: parent, bundlePath: bundlePath)) else {
            return await failPrepare("The relaunch helper did not accept input.")
        }
        let left = workExpiry - now()
        let timer = startTimer(min(left > .zero ? left : .zero, limits.ready))
        for await event in events {
            switch event {
            case let .inbound(.message(.ready(id))) where id == correlationID:
                state = .ready
                return .ready
            case let .inbound(.message(.failed(_, reason))):
                return await failPrepare(reason)
            case let .timeout(generation) where generation == timer:
                return await failPrepare("The relaunch helper did not become ready in time.")
            case .timeout:
                continue
            case .helperExited:
                helperExited = true
                state = .finished
                return .failed("The relaunch helper exited before it was ready.")
            case .inbound:
                return await failPrepare("The relaunch helper sent an unexpected reply.")
            }
        }
        return await failPrepare("The relaunch helper channel closed.")
    }

    private func failPrepare(_ reason: String) async -> ProcessRelaunchPrepareResult {
        switch await stopUnarmed() {
        case .safe:
            .failed(reason)
        case let .unresolved(stopReason):
            .unresolved("\(reason) \(stopReason)")
        }
    }

    /// Cancel, any prompt, or Quit Anyway: abort a live helper (spawned, ready, armed, or an earlier
    /// unresolved stop) and wait for `aborted` or its exact exit within what is left of the one
    /// absolute cleanup budget. Only `.safe` proves no helper of this session can open anything.
    @discardableResult
    package func abort() async -> ProcessRelaunchStopResult {
        guard state != .finished else { return .safe(helperExited ? .exitObserved : .abortAcknowledged) }
        return await stopUnarmed()
    }

    /// Stage B relative to now: the acknowledgement is awaited for `acknowledgementTimeout`.
    package func arm(acknowledgementTimeout: Duration) async -> ProcessRelaunchArmResult {
        await arm(workExpiry: now() + acknowledgementTimeout, cleanupExpiry: nil)
    }

    /// Stage B: arms the ready helper, awaiting `armed` until the absolute `workExpiry` (recomputed
    /// when sent). A lost or late `armed` acknowledgement is resolved before returning: `aborted` or
    /// the helper's verified exit proves it is not armed; otherwise the exact child is terminated
    /// and its exit awaited, by the session's cleanup cap at the latest. No `arm` is sent once the
    /// work budget is spent. Only `.armed` leaves an armed helper.
    package func arm(
        workExpiry: ContinuousClock.Instant,
        cleanupExpiry: ContinuousClock.Instant?
    ) async -> ProcessRelaunchArmResult {
        if state == .stopUnresolved { return .unresolved(Self.stopUnresolvedText) }
        guard state == .ready else { return .notArmed("The relaunch helper is not ready.") }
        capCleanup(at: cleanupExpiry)
        let left = workExpiry - now()
        guard left > .zero else {
            return await resolveLostArm(reason: "The relaunch helper could not be armed in time.")
        }
        // Set before the write: a partially written frame is treated as possibly armed.
        armWasSent = true
        guard send(.arm(correlationID: correlationID)) else {
            return await resolveLostArm(reason: "The relaunch helper did not accept the arm request.")
        }
        let timer = startTimer(left)
        for await event in events {
            switch event {
            case let .inbound(.message(.armed(id))) where id == correlationID:
                state = .armed
                return .armed
            case let .timeout(generation) where generation == timer:
                return await resolveLostArm(reason: "The relaunch helper did not confirm it was armed.")
            case .timeout:
                continue
            case .helperExited:
                helperExited = true
                state = .finished
                return .notArmed("The relaunch helper exited.")
            case let .inbound(.message(.failed(_, reason))):
                return await resolveLostArm(reason: reason)
            case .inbound:
                return await resolveLostArm(reason: "The relaunch helper sent an unexpected reply.")
            }
        }
        return await resolveLostArm(reason: "The relaunch helper channel closed.")
    }

    private func resolveLostArm(reason: String) async -> ProcessRelaunchArmResult {
        switch await stopUnarmed() {
        case .safe:
            .notArmed(reason)
        case let .unresolved(stopReason):
            .unresolved("\(reason) \(stopReason)")
        }
    }

    static let stopUnresolvedText =
        "RepoPrompt could not confirm that its restart helper stopped."

    /// Sends `abort` and waits for a correlated `aborted` or the helper's observed exit until the
    /// acknowledgement deadline; otherwise requests SIGKILL of the exact child and keeps waiting for
    /// that proof until the cleanup deadline. Both deadlines are absolute, captured by the first
    /// stop (`abortAcknowledgement`, then `cleanupReserve` in total) and capped by the driver's final
    /// cleanup expiry (leaving `terminateGrace` for the kill when it can): a repeated stop only gets
    /// what is left, never a renewed budget, and never waits past the request's final expiry. A
    /// delivered signal is not proof: without `aborted` or an observed exit the stop is
    /// `.unresolved` and the session keeps ownership (never `.finished`).
    private func stopUnarmed() async -> ProcessRelaunchStopResult {
        guard !helperExited else {
            state = .finished
            return .safe(.exitObserved)
        }
        if let proof = stopProofLatch.recorded {
            // Proof that arrived after an earlier unresolved stop: nothing is sent or awaited.
            helperExited = proof == .exitObserved
            state = .finished
            return .safe(proof)
        }
        startPumpsIfNeeded()
        let start = now()
        var acknowledgementDeadline = stopAcknowledgementDeadline ?? start + limits.abortAcknowledgement
        var cleanupDeadline = stopDeadline ?? start + limits.cleanupReserve
        if let cleanupCap {
            acknowledgementDeadline = min(acknowledgementDeadline, cleanupCap - limits.terminateGrace)
            cleanupDeadline = min(cleanupDeadline, cleanupCap)
        }
        stopAcknowledgementDeadline = acknowledgementDeadline
        stopDeadline = cleanupDeadline
        stopProofLatch.noteAbortSent()
        _ = send(.abort(correlationID: correlationID))
        if let proof = await awaitStop(until: acknowledgementDeadline) {
            state = .finished
            return .safe(proof)
        }
        let signal = channel.terminate()
        terminateResults.append(signal)
        if let proof = await awaitStop(until: cleanupDeadline) {
            state = .finished
            return .safe(proof)
        }
        state = .stopUnresolved
        let detail = switch signal {
        case .signalSent: "It was told to stop, but its exit was not observed in time."
        case .notRunning: "Its exit was not observed."
        case let .failed(reason): "It could not be stopped (\(reason))."
        }
        return .unresolved("\(Self.stopUnresolvedText) \(detail)")
    }

    /// The proof the helper gave before the absolute `deadline` (an already passed deadline still
    /// drains proof that arrived earlier): a correlated `aborted`, or its observed exit.
    private func awaitStop(until deadline: ContinuousClock.Instant) async -> ProcessRelaunchStopProof? {
        let left = deadline - now()
        let timer = startTimer(left > .zero ? left : .zero)
        for await event in events {
            switch event {
            case let .inbound(.message(.aborted(id))) where id == correlationID:
                return .abortAcknowledged
            case .helperExited:
                helperExited = true
                return .exitObserved
            case let .timeout(generation) where generation == timer:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    package var isFinished: Bool {
        state == .finished
    }

    /// Waits for proof that this exact helper stopped (lossless restart Step 4b): its exact child's
    /// observed exit, or a correlated `aborted` after an `abort` was sent. Replay-safe (proof that
    /// arrived earlier, even while an unresolved stop gave up, returns at once) and cancellable
    /// (`nil`). Never inferred from end of input, a delivered signal, or a timeout. Sends nothing
    /// and changes no state; a later `abort()` then reports the stop `.safe` without waiting.
    package nonisolated func stopProof() async -> ProcessRelaunchStopProof? {
        await stopProofLatch.wait()
    }
}

// MARK: - Live helper (runs only inside the private mode of `repoprompt-mcp`)

package enum ProcessRelaunchHelperMain {
    /// Runs the helper over stdin/stdout and returns the process exit code. Never prints to stdout
    /// outside the protocol.
    package static func run() async -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let (inbound, continuation) = AsyncStream<ProcessRelaunchInbound>.makeStream()
        let reader = Thread {
            var decoder = ProcessRelaunchFrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                for event in decoder.append(Data(buffer.prefix(count))) {
                    continuation.yield(event)
                }
                if decoder.isPoisoned { break }
            }
            continuation.yield(decoder.finish())
            continuation.finish()
        }
        reader.start()
        let session = ProcessRelaunchHelperSession(environment: .live)
        let outcome = await session.run(inbound: inbound)
        return outcome.exitCode
    }
}

package extension ProcessRelaunchHelperEnvironment {
    static let live = ProcessRelaunchHelperEnvironment(
        parentPID: { getppid() },
        currentUID: { getuid() },
        inspect: { ProcessInspection.inspect(pid: $0) },
        // The running image's actual path (never `Bundle.main`, which resolves to the enclosing
        // application's main executable for an auxiliary tool).
        ownExecutablePath: {
            guard case let .observed(observation) = ProcessInspection.inspect(pid: getpid()),
                  case let .available(path) = observation.executablePath
            else { return nil }
            return path
        },
        realPath: { path in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        },
        watchExit: { pid, handler in
            let watch = ProcessExitWatch(pid: pid, handler: handler)
            return ProcessRelaunchWatchToken { watch.cancel() }
        },
        openBundle: { url in
            await withCheckedContinuation { continuation in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                    continuation.resume(returning: application != nil && error == nil)
                }
            }
        },
        sleep: { try? await Task.sleep(for: $0) },
        send: { data in
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(STDOUT_FILENO, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return }
                    offset += written
                }
            }
        }
    )
}
