@testable import RepoPromptAgentCore
import XCTest

extension AgentRecoveryActionRunner {
    /// Tests: `qualification`'s actions over the Claude Code + Codex runtime qualification
    /// (`AgentRecoveryActivation.claudeAndCodex.runtime`), so the O32 provider gate admits the
    /// fixtures' Claude Code and Codex targets and refuses every other provider.
    convenience init(qualification: AgentRecoveryActionQualification, registrationActive: @escaping @MainActor () -> Bool) {
        self.init(
            activation: AgentRecoveryActivation(runtime: AgentRecoveryActivation.claudeAndCodex.runtime, actions: qualification),
            registrationActive: registrationActive
        )
    }
}

/// Fixture lifecycle authority for controller-unit tests. It serializes transactions per instance
/// and validates incarnation, reset generation, and deletion before running the body. Real
/// `AgentSessionDataService` gate races are covered by `AgentSessionRecoveryIntegrationTests`.
actor RecoveryFixtureLifecycle {
    enum Rejection: Error, Equatable {
        case sessionDeleted
        case staleAuthority
    }

    private(set) var incarnationID: UUID
    private(set) var generation: UInt64 = 0
    private var deleted = false
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pauseArmed = false
    private var pausedContinuation: CheckedContinuation<Void, Never>?
    private var pauseObserver: CheckedContinuation<Void, Never>?

    init(incarnationID: UUID) {
        self.incarnationID = incarnationID
    }

    func markDeleted() {
        deleted = true
    }

    func advanceReset() {
        generation += 1
    }

    /// The next transaction pauses (holding the gate) before validation until `releasePause()`.
    func armPause() {
        pauseArmed = true
    }

    func waitUntilPaused() async {
        if pausedContinuation != nil { return }
        await withCheckedContinuation { pauseObserver = $0 }
    }

    func releasePause() {
        pausedContinuation?.resume()
        pausedContinuation = nil
    }

    func transaction<T: Sendable>(
        binding: AgentRecoveryLifecycleBinding,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        defer { release() }
        if pauseArmed {
            pauseArmed = false
            await withCheckedContinuation { continuation in
                pausedContinuation = continuation
                pauseObserver?.resume()
                pauseObserver = nil
            }
        }
        guard !deleted else { throw Rejection.sessionDeleted }
        guard binding.incarnationID == incarnationID, binding.transcriptResetGeneration == generation else {
            throw Rejection.staleAuthority
        }
        return try await body()
    }

    private func acquire() async {
        guard locked else {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct RecoveryFixtureGate: AgentRecoveryLifecycleGate {
    let binding: AgentRecoveryLifecycleBinding
    let lifecycle: RecoveryFixtureLifecycle

    func performRecoveryTransaction<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await lifecycle.transaction(binding: binding, body)
    }
}

/// Thread-safe switch for injected file-operation failures.
final class RecoveryStoreWriteFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failWrites = false
    private var failRemovals = false
    private var failWritePathFragment: String?

    var shouldFailWrites: Bool {
        get { lock.withLock { failWrites } }
        set { lock.withLock { failWrites = newValue } }
    }

    var shouldFailRemovals: Bool {
        get { lock.withLock { failRemovals } }
        set { lock.withLock { failRemovals = newValue } }
    }

    /// Writes whose path contains this fragment fail (for example one session's record).
    var failingWritePathFragment: String? {
        get { lock.withLock { failWritePathFragment } }
        set { lock.withLock { failWritePathFragment = newValue } }
    }

    func fileOperations() -> AgentRecoveryStore.FileOperations {
        AgentRecoveryStore.FileOperations(
            writeAtomically: { [self] data, url in
                if shouldFailWrites {
                    throw CocoaError(.fileWriteUnknown)
                }
                if let fragment = failingWritePathFragment, url.path.contains(fragment) {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            },
            removeItem: { [self] url in
                if shouldFailRemovals {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            }
        )
    }
}

/// One-shot latch: `pause()` suspends until `open()`; `waitUntilPaused()` observes arrival.
actor RecoveryGateLatch {
    private var isOpen = false
    private var paused: CheckedContinuation<Void, Never>?
    private var arrivalObserver: CheckedContinuation<Void, Never>?
    private var arrived = false

    func pause() async {
        arrived = true
        arrivalObserver?.resume()
        arrivalObserver = nil
        guard !isOpen else { return }
        await withCheckedContinuation { paused = $0 }
    }

    func waitUntilPaused() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalObserver = $0 }
    }

    func open() {
        isOpen = true
        paused?.resume()
        paused = nil
    }
}

/// Controllable monotonic clock for deadline arithmetic.
final class RecoveryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant + duration }
    }
}

/// Deterministic absolute-deadline sleep seam: sleeps suspend until the test fires through their deadline.
actor RecoveryManualSleeper {
    private struct Waiter {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private(set) var requestedDeadlines: [ContinuousClock.Instant] = []

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                requestedDeadlines.append(deadline)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    var pendingDeadlines: [ContinuousClock.Instant] {
        waiters.map(\.deadline).sorted()
    }

    /// Resumes every sleep whose deadline is at or before `instant`.
    @discardableResult
    func fire(through instant: ContinuousClock.Instant) -> Int {
        let matching = waiters.filter { $0.deadline <= instant }
        waiters.removeAll { $0.deadline <= instant }
        for waiter in matching {
            waiter.continuation.resume()
        }
        return matching.count
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

enum RecoveryTestSupport {
    static func makeTemporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptCE-XCTest", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func makeImageSource(in directory: URL, name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent("\(name).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: url)
        return url
    }

    static func content(
        _ text: String,
        images: [AgentRecoveryImageReference] = [],
        interviewFirst: Bool = false
    ) -> AgentRecoveryInputContent {
        AgentRecoveryInputContent(text: text, images: images, interviewFirst: interviewFirst)
    }

    static func snapshot(
        _ text: String,
        images: [AgentRecoveryImageReference] = [],
        revision: AgentRecoveryComposerRevision = .make(),
        generation: UInt64 = 0
    ) -> AgentRecoveryComposerSnapshot {
        AgentRecoveryComposerSnapshot(
            revision: revision,
            capturedAt: AgentRecoveryTimestamp(millisecondsSince1970: 1000),
            transcriptResetGeneration: generation,
            content: content(text, images: images)
        )
    }

    static func submission(
        _ text: String,
        intentID: UUID = UUID(),
        userItemID: UUID = UUID(),
        origin: AgentRecoveryIntentOrigin = .composer,
        target: AgentRecoveryIntentTarget = .session,
        images: [AgentRecoveryImageReference] = [],
        scheduleReference: AgentRecoveryScheduleReference? = nil
    ) -> AgentRecoveryIntentSubmission {
        AgentRecoveryIntentSubmission(
            intentID: intentID,
            userItemID: userItemID,
            origin: origin,
            target: target,
            payload: content(text, images: images),
            scheduleReference: scheduleReference
        )
    }

    static func liveRunTarget(runAttemptID: UUID = UUID()) -> AgentRecoveryIntentTarget {
        .liveRun(AgentRecoveryRunTarget(runAttemptID: runAttemptID, processRunID: UUID(), providerConversationID: "thread-1"))
    }

    static func ownership(sessionID: UUID, attemptID: UUID = UUID()) -> AgentRunOwnership {
        AgentRunOwnership(
            attemptID: attemptID,
            binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: sessionID)
        )
    }

    /// A terminal commit revision as the barrier creates it, without an MCP publication envelope.
    static func terminalCommit(
        ownership: AgentRunOwnership,
        commitID: UUID = UUID(),
        state: AgentSessionRunState = .completed,
        expectedRunID: UUID? = nil,
        cause: AgentRunTerminalCause = .ordinary
    ) -> AgentRunTerminalCommitRevision {
        AgentRunTerminalCommitRevision(
            commitID: commitID,
            ownership: ownership,
            terminalState: state,
            expectedRunID: expectedRunID,
            cause: cause,
            sourceItemsRevision: 0,
            assistantDeltaFlushGeneration: 0,
            providerDrainGeneration: 0,
            mcpPublicationEnvelope: nil,
            successorKind: nil,
            providerSuccessorID: nil
        )
    }

    /// Polls `condition` (real time, bounded) for asynchronous timer effects.
    static func eventually(
        timeoutSeconds: Double = 5,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    // MARK: JSON editing

    enum PathComponent {
        case key(String)
        case index(Int)
    }

    /// Sets `key` = `value` on the object found at `path` inside `json`.
    static func setMember(
        _ json: inout AgentRecoveryJSONValue,
        at path: [PathComponent],
        key: String,
        value: AgentRecoveryJSONValue
    ) {
        guard let first = path.first else {
            guard case var .object(object) = json else { return XCTFail("not an object") }
            object[key] = value
            json = .object(object)
            return
        }
        let rest = Array(path.dropFirst())
        switch (first, json) {
        case let (.key(name), .object(original)):
            var object = original
            guard var child = object[name] else { return XCTFail("missing \(name)") }
            setMember(&child, at: rest, key: key, value: value)
            object[name] = child
            json = .object(object)
        case let (.index(index), .array(original)):
            var array = original
            guard array.indices.contains(index) else { return XCTFail("missing index \(index)") }
            setMember(&array[index], at: rest, key: key, value: value)
            json = .array(array)
        default:
            XCTFail("path mismatch")
        }
    }

    static func member(
        _ json: AgentRecoveryJSONValue,
        at path: [PathComponent],
        key: String
    ) -> AgentRecoveryJSONValue? {
        var current = json
        for component in path {
            switch (component, current) {
            case let (.key(name), .object(object)):
                guard let child = object[name] else { return nil }
                current = child
            case let (.index(index), .array(array)):
                guard array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        guard case let .object(object) = current else { return nil }
        return object[key]
    }

    static func readJSON(_ url: URL) throws -> AgentRecoveryJSONValue {
        try JSONDecoder().decode(AgentRecoveryJSONValue.self, from: Data(contentsOf: url))
    }

    static func writeJSON(_ json: AgentRecoveryJSONValue, to url: URL) throws {
        try JSONEncoder().encode(json).write(to: url, options: .atomic)
    }
}
