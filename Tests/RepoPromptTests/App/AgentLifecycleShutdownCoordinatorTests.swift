import AppKit
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import XCTest

/// R4 two-stage quit / window close (lossless-restart spec): the app-scoped lifecycle coordinator
/// with fake participants, a manual absolute-deadline clock, and a scripted failure presenter.
/// Launch marks go through the real recovery coordinator and store into a temporary directory whose
/// launch-file writes can be held or failed; assertions read what was durably committed. No window,
/// provider, or app lifecycle is touched.
@MainActor
final class AgentLifecycleShutdownCoordinatorTests: XCTestCase {
    // MARK: Fakes

    /// Virtual monotonic time: a sleep resumes when the test advances past its absolute deadline
    /// (or fires every pending one); `jump` moves time without waking anything; cancellation throws.
    private final class ManualDeadlineClock: @unchecked Sendable {
        private let lock = NSLock()
        private let origin = ContinuousClock.now
        private var offset: Duration = .zero
        private var waiters: [(UUID, ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = []
        private var requested: [ContinuousClock.Instant] = []

        var now: ContinuousClock.Instant {
            lock.withLock { origin + offset }
        }

        func instant(at offset: Duration) -> ContinuousClock.Instant {
            origin + offset
        }

        func sleep(until deadline: ContinuousClock.Instant) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    requested.append(deadline)
                    if deadline <= origin + offset {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiters.append((id, deadline, continuation))
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                let index = waiters.firstIndex { $0.0 == id }
                let continuation = index.map { waiters.remove(at: $0).2 }
                lock.unlock()
                continuation?.resume(throwing: CancellationError())
            }
        }

        var pendingCount: Int {
            lock.withLock { waiters.count }
        }

        /// The earliest absolute deadline a sleep is currently waiting for.
        var nextPendingDeadline: ContinuousClock.Instant? {
            lock.withLock { waiters.map(\.1).min() }
        }

        /// Deadline sleeps requested so far, in order.
        var requestedDeadlines: [ContinuousClock.Instant] {
            lock.withLock { requested }
        }

        var requestedCount: Int {
            requestedDeadlines.count
        }

        /// Expires every pending sleep (time does not move).
        func fire() {
            lock.lock()
            let pending = waiters
            waiters = []
            lock.unlock()
            for (_, _, continuation) in pending {
                continuation.resume()
            }
        }

        /// Advances time, expiring the sleeps it reaches.
        func advance(by duration: Duration) {
            lock.lock()
            offset += duration
            let current = origin + offset
            let due = waiters.filter { $0.1 <= current }
            waiters.removeAll { $0.1 <= current }
            lock.unlock()
            for (_, _, continuation) in due {
                continuation.resume()
            }
        }

        /// Advances time without resuming any sleep (an executor that never ran the deadline task).
        func jump(by duration: Duration) {
            lock.withLock { offset += duration }
        }
    }

    /// The temporary launch file's write seam: records each durably committed launch mark, and can
    /// hold (block) or fail the next write of a given state.
    private final class LaunchMarkDisk: @unchecked Sendable {
        private let lock = NSLock()
        private var committedStates: [AgentRecoveryLaunchMark.State] = []
        private var failing: Set<AgentRecoveryLaunchMark.State> = []
        private var holds: [AgentRecoveryLaunchMark.State: DispatchSemaphore] = [:]
        private var holding: Set<AgentRecoveryLaunchMark.State> = []
        private var released: [DispatchSemaphore] = []

        var committed: [AgentRecoveryLaunchMark.State] {
            lock.withLock { committedStates }
        }

        func resetLog() {
            lock.withLock { committedStates = [] }
        }

        func fail(_ state: AgentRecoveryLaunchMark.State, _ enabled: Bool = true) {
            lock.withLock {
                if enabled { failing.insert(state) } else { failing.remove(state) }
            }
        }

        /// The next write of `state` blocks (inside the store) until `release(state)`.
        func hold(_ state: AgentRecoveryLaunchMark.State) {
            lock.withLock { holds[state] = DispatchSemaphore(value: 0) }
        }

        func isHolding(_ state: AgentRecoveryLaunchMark.State) -> Bool {
            lock.withLock { holding.contains(state) }
        }

        func release(_ state: AgentRecoveryLaunchMark.State) {
            let semaphore = lock.withLock { holds.removeValue(forKey: state) }
            semaphore?.signal()
        }

        func releaseAll() {
            let pending = lock.withLock {
                let values = Array(holds.values)
                holds = [:]
                return values
            }
            pending.forEach { $0.signal() }
        }

        func fileOperations() -> AgentRecoveryStore.FileOperations {
            AgentRecoveryStore.FileOperations(
                writeAtomically: { [self] data, url in
                    guard url.lastPathComponent == "launch-state.json", let state = Self.state(of: data) else {
                        try data.write(to: url, options: .atomic)
                        return
                    }
                    let semaphore = lock.withLock {
                        let held = holds[state]
                        if held != nil { holding.insert(state) }
                        return held
                    }
                    if let semaphore {
                        semaphore.wait()
                        lock.withLock { _ = holding.remove(state) }
                    }
                    if lock.withLock({ failing.contains(state) }) {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: url, options: .atomic)
                    lock.withLock { committedStates.append(state) }
                },
                removeItem: { url in try FileManager.default.removeItem(at: url) }
            )
        }

        private static func state(of data: Data) -> AgentRecoveryLaunchMark.State? {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["state"] as? String
            else { return nil }
            return AgentRecoveryLaunchMark.State(rawValue: raw)
        }
    }

    /// A suspension point that ignores cancellation (a non-cooperative task).
    @MainActor
    private final class Hang {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0

        func wait() async {
            entered += 1
            await withCheckedContinuation { continuations.append($0) }
        }

        func release() {
            let pending = continuations
            continuations = []
            pending.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class FakeParticipant: AgentLifecycleShutdownParticipant {
        private(set) var activeFreezes: Set<UUID> = []
        private(set) var ownedRecoveryFreezes = 0
        private(set) var prepareCalls = 0
        private(set) var finalizeCalls = 0
        /// Teardown executions (joined calls are not counted, as in the real view model).
        private(set) var teardownExecutions = 0
        private var teardownTask: Task<Void, Never>?
        var prepareResults: [AgentModeShutdownReport] = []
        var finalizeResults: [AgentModeShutdownReport] = []
        var prepareHang: Hang?
        var teardownHang: Hang?

        var isFrozen: Bool {
            !activeFreezes.isEmpty
        }

        func beginShutdownFreeze(requestID: UUID, ownsRecoveryFreeze: Bool) {
            activeFreezes.insert(requestID)
            if ownsRecoveryFreeze { ownedRecoveryFreezes += 1 }
        }

        func endShutdownFreeze(requestID: UUID) {
            activeFreezes.remove(requestID)
        }

        func shutdownPrepare(reason _: AgentRecoveryShutdownReason) async -> AgentModeShutdownReport {
            prepareCalls += 1
            if let hang = prepareHang {
                prepareHang = nil
                await hang.wait()
            }
            return prepareResults.isEmpty ? AgentModeShutdownReport() : prepareResults.removeFirst()
        }

        func shutdownTearDown(reason _: AgentRecoveryShutdownReason) async {
            if let teardownTask {
                await teardownTask.value
                return
            }
            teardownExecutions += 1
            let hang = teardownHang
            let task = Task { @MainActor in
                if let hang { await hang.wait() }
            }
            teardownTask = task
            await task.value
        }

        func shutdownFinalize() async -> AgentModeShutdownReport {
            finalizeCalls += 1
            return finalizeResults.isEmpty ? AgentModeShutdownReport() : finalizeResults.removeFirst()
        }
    }

    /// Records every non-mark environment effect and scripts the failure prompt.
    @MainActor
    private final class Recorder {
        var appFreezeBegins = 0
        var appFreezeEnds = 0
        var layoutResult = true
        var layoutHang: Hang?
        var layoutCalls = 0
        var releasedBlockers: [String] = []
        var irreversible: [AgentLifecycleShutdownScope] = []
        var scopeTeardowns: [AgentLifecycleShutdownScope] = []
        var dismissed: [AgentLifecycleShutdownScope] = []
        var presented: [AgentLifecycleShutdownFailure] = []
        /// The answer a dismissed prompt returns (AppKit returns no real choice; a test may inject a
        /// late answer that races the dismissal).
        var answerOnDismiss: AgentLifecycleShutdownChoice = .cancel
        private var pendingChoice: CheckedContinuation<AgentLifecycleShutdownChoice, Never>?

        func present(_ failure: AgentLifecycleShutdownFailure) async -> AgentLifecycleShutdownChoice {
            presented.append(failure)
            return await withCheckedContinuation { pendingChoice = $0 }
        }

        var isPresenting: Bool {
            pendingChoice != nil
        }

        func choose(_ choice: AgentLifecycleShutdownChoice) {
            let continuation = pendingChoice
            pendingChoice = nil
            continuation?.resume(returning: choice)
        }

        /// Like AppKit ending a dismissed sheet: the pending prompt returns without a real choice.
        func dismiss(_ scope: AgentLifecycleShutdownScope) {
            dismissed.append(scope)
            choose(answerOnDismiss)
        }
    }

    private var recorder: Recorder!
    private var clock: ManualDeadlineClock!
    private var disk: LaunchMarkDisk!
    private var fixture: RecoveryLaneFixture!
    private var appParticipants: [FakeParticipant] = []
    private var windowParticipants: [Int: FakeParticipant] = [:]
    private var hangs: [Hang] = []

    override func setUp() async throws {
        recorder = Recorder()
        clock = ManualDeadlineClock()
        disk = LaunchMarkDisk()
        fixture = try await RecoveryLaneFixture.make(
            "AgentLifecycleShutdownCoordinatorTests",
            fileOperations: disk.fileOperations()
        )
        // Startup wrote this launch's `running` mark; tests observe only what shutdown commits.
        disk.resetLog()
        appParticipants = []
        windowParticipants = [:]
        hangs = []
    }

    override func tearDown() async throws {
        // Never leave a suspended fake or a blocked write behind.
        hangs.forEach { $0.release() }
        disk?.releaseAll()
        recorder?.choose(.proceedAnyway)
        clock?.fire()
        await settle()
        fixture?.tearDown()
        fixture = nil
    }

    private func makeHang() -> Hang {
        let hang = Hang()
        hangs.append(hang)
        return hang
    }

    private func makeCoordinator(relaunch: AgentLifecycleRelaunchHooks? = nil) -> AgentLifecycleShutdownCoordinator {
        let recorder = recorder!
        let clock = clock!
        let recovery = fixture.coordinator
        var environment = AgentLifecycleShutdownEnvironment(
            participants: { [unowned self] scope in
                switch scope {
                case .application:
                    appParticipants
                case let .window(id):
                    windowParticipants[id].map { [$0] } ?? []
                }
            },
            beginApplicationRecoveryFreeze: {
                recorder.appFreezeBegins += 1
                return { recorder.appFreezeEnds += 1 }
            },
            preserveLayout: {
                recorder.layoutCalls += 1
                if let hang = recorder.layoutHang {
                    recorder.layoutHang = nil
                    await hang.wait()
                }
                return recorder.layoutResult
            },
            settleReleasedRecoveryInput: { recorder.releasedBlockers },
            recordLaunchState: { recovery.recordLaunchState($0) },
            authorizeCleanExit: { recovery.authorizeCleanExit() },
            recordCleanExit: { recovery.recordCleanExit(authorization: $0) },
            beginIrreversible: { recorder.irreversible.append($0) },
            tearDownScope: { recorder.scopeTeardowns.append($0) },
            presentFailure: { await recorder.present($0) },
            dismissFailure: { recorder.dismiss($0) },
            now: { clock.now },
            sleepUntil: { try await clock.sleep(until: $0) }
        )
        environment.relaunch = relaunch
        return AgentLifecycleShutdownCoordinator(environment: environment)
    }

    private func settle() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    /// Joins every launch-mark write enqueued so far: an unauthorized clean write is ordered behind
    /// them and writes nothing.
    private func drainLaunchMarks() async {
        _ = await fixture.coordinator.recordCleanExit(authorization: UUID()).value
    }

    private func diskMark() async -> AgentRecoveryLaunchMark.State? {
        guard case let .mark(mark) = await fixture.store.readLaunchMark() else { return nil }
        return mark.state
    }

    /// Waits (bounded, real time) for asynchronous effects, including store writes off the main actor.
    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if condition() { return }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: Stage A

    func testStageAFailureCancelKeepsTheAppUsableAndASecondAttemptQuitsCleanly() async {
        let participant = FakeParticipant()
        participant.prepareResults = [AgentModeShutdownReport(blockers: ["Session A: a secret answer would be lost."])]
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []

        XCTAssertTrue(coordinator.requestApplicationQuit { replies.append($0) })
        XCTAssertTrue(participant.isFrozen, "frozen synchronously, before the first await")
        XCTAssertEqual(recorder.appFreezeBegins, 1)
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.messages, ["Session A: a secret answer would be lost."])
        XCTAssertEqual(coordinator.applicationRequest?.phase, .preparationFailed)
        XCTAssertTrue(recorder.irreversible.isEmpty, "Stage A never crosses the point of no return")

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(participant.isFrozen, "Cancel reopens the owners")
        XCTAssertEqual(recorder.appFreezeEnds, 1)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .running], "the app keeps running")
        XCTAssertEqual(participant.teardownExecutions, 0)
        XCTAssertFalse(coordinator.isApplicationRequestActive, "interaction continues")

        XCTAssertTrue(coordinator.requestApplicationQuit { replies.append($0) }, "a second attempt starts fresh")
        await waitUntil("the second reply") { replies.count == 2 }
        XCTAssertEqual(replies, [false, true])
        XCTAssertEqual(participant.prepareCalls, 2)
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(participant.finalizeCalls, 1)
        XCTAssertEqual(recorder.irreversible, [.application])
        XCTAssertEqual(recorder.scopeTeardowns, [.application])
        XCTAssertEqual(disk.committed.last, .cleanExit, "the clean mark was committed before the reply")
        XCTAssertEqual(disk.committed.count { $0 == .cleanExit }, 1)
        let mark = await diskMark()
        XCTAssertEqual(mark, .cleanExit)
    }

    func testStageALayoutAndReleasedInputFailuresBlockAndRetryRunsAFreshAttempt() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        recorder.layoutResult = false
        recorder.releasedBlockers = ["A closed tab's draft is not saved yet."]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(
            recorder.presented.last?.messages,
            [AgentLifecycleShutdownCoordinator.layoutFailureMessage, "A closed tab's draft is not saved yet."]
        )
        recorder.layoutResult = true
        recorder.releasedBlockers = []
        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(coordinator.applicationRequest?.preparationAttempts, 2)
        XCTAssertEqual(participant.teardownExecutions, 1)
    }

    /// One absolute deadline per attempt: a non-cooperative preparation never delays the prompt,
    /// and its late completion is fenced (no teardown, no reply, no clean mark).
    func testStageADeadlineDoesNotJoinANonCooperativeTaskAndItsLateCompletionIsFenced() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.prepareHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the stuck preparation") { hang.entered == 1 && clock.pendingCount == 1 }

        clock.fire()
        await waitUntil("the timeout prompt") { recorder.isPresenting }
        let failure = recorder.presented.last
        XCTAssertEqual(failure?.stage, .preparation)
        XCTAssertEqual(failure?.timedOut, true)
        XCTAssertEqual(failure?.messages, [AgentLifecycleShutdownCoordinator.timeoutMessage])

        hang.release()
        await settle()
        XCTAssertEqual(coordinator.applicationRequest?.phase, .preparationFailed, "late success is fenced")
        XCTAssertTrue(recorder.irreversible.isEmpty)
        XCTAssertEqual(participant.teardownExecutions, 0)
        XCTAssertTrue(replies.isEmpty)
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit))

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(participant.isFrozen)
    }

    /// Cancel fences the attempt's remaining Stage A side effects: a late step never writes
    /// `shutdownInProgress` after Cancel's `running`, nor prepares participants.
    func testCancelFencesLateStageASideEffects() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let hang = makeHang()
        recorder.layoutHang = hang
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the stuck layout step") { hang.entered == 1 && clock.pendingCount == 1 }
        clock.fire()
        await waitUntil("the timeout prompt") { recorder.isPresenting }
        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.running])

        hang.release()
        await settle()
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.running], "no late shutdownInProgress lands after Cancel")
        XCTAssertEqual(participant.prepareCalls, 0, "no participant is prepared for a cancelled attempt")
        XCTAssertEqual(replies, [false])
    }

    // MARK: Absolute expiry (R4-05)

    /// The expiry is captured when the user attempt starts: a deadline task that runs late (a busy
    /// main actor) still expires at the captured instant, never 8 seconds after it started.
    func testDelayedDeadlineTaskNeverExtendsTheCapturedExpiry() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.prepareHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        // Five seconds pass before the deadline task first runs.
        clock.jump(by: .seconds(5))
        await waitUntil("the deadline sleep") { clock.requestedCount == 1 && hang.entered == 1 }
        XCTAssertEqual(clock.requestedDeadlines, [clock.instant(at: .seconds(8))], "captured at the request")

        clock.advance(by: .milliseconds(2900))
        await settle()
        XCTAssertFalse(recorder.isPresenting, "7.9 of 8 seconds since the request")
        clock.advance(by: .milliseconds(100))
        await waitUntil("the timeout at the captured expiry") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)
        XCTAssertTrue(recorder.irreversible.isEmpty)
        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
    }

    /// Success transitions check the captured expiry themselves: work that finishes after it (while
    /// the deadline task never got to run) neither crosses the point of no return nor marks clean.
    func testWorkFinishingAfterTheExpiryNeverCrossesTheBoundaryOrMarksClean() async {
        let participant = FakeParticipant()
        let prepareHang = makeHang()
        participant.prepareHang = prepareHang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the slow preparation") { prepareHang.entered == 1 && clock.pendingCount == 1 }

        clock.jump(by: .seconds(9))
        prepareHang.release()
        await waitUntil("the Stage A timeout") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)
        XCTAssertTrue(recorder.irreversible.isEmpty, "a late Stage A never crosses the boundary")
        XCTAssertEqual(participant.teardownExecutions, 0)

        // Retry: a fresh deadline; Stage B's final flush then finishes after that expiry.
        let teardownHang = makeHang()
        participant.teardownHang = teardownHang
        recorder.choose(.retry)
        await waitUntil("the stuck teardown") { teardownHang.entered == 1 }
        clock.jump(by: .seconds(9))
        teardownHang.release()
        await waitUntil("the Stage B timeout") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)
        XCTAssertEqual(participant.finalizeCalls, 1)
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit), "no clean mark after the expiry")

        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(participant.teardownExecutions, 1)
        let mark = await diskMark()
        XCTAssertEqual(mark, .cleanExit, "a retry within its own deadline marks clean")
    }

    // MARK: Stage B

    /// One absolute deadline per user attempt: Stage B receives only what Stage A left of it (no
    /// second deadline is armed at the point of no return); an explicit Retry gets a fresh one.
    func testOneAbsoluteDeadlineSpansStageAAndStageBAndOnlyRetryRearmsIt() async {
        let participant = FakeParticipant()
        let prepareHang = makeHang()
        let teardownHang = makeHang()
        participant.prepareHang = prepareHang
        participant.teardownHang = teardownHang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the slow preparation") { prepareHang.entered == 1 && clock.pendingCount == 1 }

        clock.advance(by: .seconds(7))
        await settle()
        XCTAssertFalse(recorder.isPresenting, "7 of 8 seconds used in Stage A")
        prepareHang.release()
        await waitUntil("the stuck teardown") { teardownHang.entered == 1 }
        XCTAssertEqual(clock.requestedCount, 1, "the point of no return arms no second deadline")
        XCTAssertEqual(coordinator.applicationRequest?.phase, .tearingDown)

        clock.advance(by: .milliseconds(1500))
        await waitUntil("the Stage B timeout on the remainder") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)

        recorder.choose(.retry)
        await waitUntil("the retry deadline") { clock.requestedCount == 2 && clock.pendingCount == 1 }
        XCTAssertEqual(clock.requestedDeadlines.last, clock.instant(at: .milliseconds(16500)), "Retry: now + 8 s")
        clock.advance(by: .milliseconds(7900))
        await settle()
        XCTAssertFalse(recorder.isPresenting, "Retry gets a fresh 8 seconds")
        clock.advance(by: .milliseconds(200))
        await waitUntil("the retry timeout") { recorder.presented.count == 2 && recorder.isPresenting }
        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit))
        XCTAssertEqual(participant.teardownExecutions, 1)
    }

    func testStageBOffersNoCancelAndRetryFlushesAgainWithoutRepeatingTeardown() async {
        let participant = FakeParticipant()
        participant.finalizeResults = [AgentModeShutdownReport(blockers: ["Session A: the conversation could not be saved."])]
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(coordinator.applicationRequest?.phase, .finalizationFailed)
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit), "no clean mark after a failed final flush")

        recorder.choose(.cancel)
        await waitUntil("the prompt again") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization, "Stage B has no Cancel")
        XCTAssertEqual(
            recorder.presented.last?.messages,
            ["Session A: the conversation could not be saved."],
            "the dismissed prompt is shown again with its own reasons"
        )
        XCTAssertEqual(recorder.presented.last?.timedOut, false)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(participant.isFrozen, "past the point of no return nothing reopens")

        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(participant.finalizeCalls, 2, "Retry flushes again")
        XCTAssertEqual(participant.teardownExecutions, 1, "teardown never runs twice")
        XCTAssertEqual(recorder.irreversible, [.application])
        XCTAssertEqual(recorder.scopeTeardowns, [.application])
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit])
    }

    /// The Stage B deadline does not join a stuck teardown; Quit Anyway completes without a clean
    /// mark, and the teardown's late completion never finalizes or marks clean.
    func testStageBDeadlineWithAStuckTeardownQuitsAnywayWithoutACleanMark() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.teardownHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the stuck teardown") { hang.entered == 1 && clock.pendingCount == 1 }
        clock.fire()
        await waitUntil("the timeout prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)

        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        hang.release()
        await settle()
        await drainLaunchMarks()
        XCTAssertEqual(participant.finalizeCalls, 0, "late teardown completion is fenced")
        XCTAssertEqual(disk.committed, [.shutdownInProgress])
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(replies, [true], "replied exactly once")
    }

    // MARK: F5 observability (repeated requests, prompt identity at the single deadline)

    /// Repeated quit requests (a second Quit click, another terminate) join the request in progress:
    /// no new attempt, no new or later deadline, no second prompt, and no reply of their own. The
    /// prompt appears at the first request's 8-second expiry and carries that request's identity.
    func testRepeatedQuitRequestsNeverExtendTheSingleDeadline() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.prepareHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit { replies.append($0) })
        let requestID = coordinator.applicationRequest?.id
        await waitUntil("the stuck preparation") { hang.entered == 1 && clock.pendingCount == 1 }
        XCTAssertEqual(clock.requestedDeadlines, [clock.instant(at: .seconds(8))])

        clock.advance(by: .seconds(5))
        for _ in 0 ..< 3 {
            XCTAssertFalse(coordinator.requestApplicationQuit { replies.append($0) }, "a repeated quit joins")
        }
        await settle()
        XCTAssertEqual(coordinator.applicationRequest?.id, requestID, "the same request")
        XCTAssertEqual(clock.requestedDeadlines, [clock.instant(at: .seconds(8))], "no new or later deadline")
        XCTAssertEqual(participant.prepareCalls, 1, "no new attempt")

        clock.advance(by: .milliseconds(2900))
        await settle()
        XCTAssertFalse(recorder.isPresenting, "7.9 of 8 seconds since the first request")
        clock.advance(by: .milliseconds(100))
        await waitUntil("the timeout at the first request's expiry") { recorder.isPresenting }
        let failure = recorder.presented.last
        XCTAssertEqual(failure?.requestID, requestID)
        XCTAssertEqual(failure?.stage, .preparation)
        XCTAssertEqual(failure?.timedOut, true)
        XCTAssertEqual(failure.map(AgentLifecycleShutdownDiagnostics.dialogStage), "preparation.deadline_expired")

        // While the prompt waits for the user, a repeated quit neither re-presents nor re-arms.
        XCTAssertFalse(coordinator.requestApplicationQuit { replies.append($0) })
        await settle()
        XCTAssertEqual(recorder.presented.count, 1)
        XCTAssertEqual(clock.requestedCount, 1)
        XCTAssertTrue(replies.isEmpty, "a repeated request never gets a reply of its own")

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false], "replied exactly once, to the first request")
        XCTAssertEqual(coordinator.applicationRequest?.id, requestID)
        XCTAssertNil(coordinator.activeApplicationRequestID, "a finished request is never logged as the current one")
    }

    /// A teardown that never finishes: the Stage B prompt appears exactly at the single deadline the
    /// request armed (none is armed at the point of no return), carries the request's identity, and
    /// the teardown's late completion never finalizes, marks clean, or replies.
    func testStalledTeardownPresentsTheStageBPromptForItsRequestAtTheSingleDeadline() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.teardownHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        let requestID = coordinator.applicationRequest?.id
        await waitUntil("the stuck teardown") { hang.entered == 1 && clock.pendingCount == 1 }
        XCTAssertEqual(clock.requestedDeadlines, [clock.instant(at: .seconds(8))], "one deadline, armed at the request")

        clock.advance(by: .milliseconds(7900))
        await settle()
        XCTAssertFalse(recorder.isPresenting)
        clock.advance(by: .milliseconds(100))
        await waitUntil("the Stage B timeout") { recorder.isPresenting }
        let failure = recorder.presented.last
        XCTAssertEqual(failure?.requestID, requestID)
        XCTAssertEqual(failure?.stage, .finalization)
        XCTAssertEqual(failure?.timedOut, true)
        XCTAssertEqual(failure.map(AgentLifecycleShutdownDiagnostics.dialogStage), "finalization.deadline_expired")

        hang.release()
        await settle()
        XCTAssertEqual(coordinator.applicationRequest?.phase, .finalizationFailed, "the late teardown is fenced")
        XCTAssertEqual(participant.finalizeCalls, 0)
        XCTAssertTrue(replies.isEmpty, "the prompt keeps waiting for the user")
        await drainLaunchMarks()
        XCTAssertFalse(disk.committed.contains(.cleanExit))

        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
    }

    /// The persisted token and the dialog actually built for the same failure stay paired: each
    /// failure kind's `dialogStage` is checked together with its alert's title.
    func testDialogStageTokenPairsWithTheAlertTitleForEachFailureKind() {
        func failure(
            scope: AgentLifecycleShutdownScope = .application,
            _ stage: AgentLifecycleShutdownStage,
            timedOut: Bool = false,
            awaitsAck: Bool = false,
            unresolved: Bool = false,
            allowsExit: Bool = false
        ) -> AgentLifecycleShutdownFailure {
            var failure = AgentLifecycleShutdownFailure(
                requestID: UUID(),
                scope: scope,
                stage: stage,
                messages: [AgentLifecycleShutdownCoordinator.timeoutMessage],
                timedOut: timedOut,
                awaitsCleanExitAcknowledgement: awaitsAck
            )
            failure.relaunchHelperUnresolved = unresolved
            failure.allowsUncertainRelaunchExit = allowsExit
            return failure
        }
        let cases: [(AgentLifecycleShutdownFailure, String, String)] = [
            (failure(.preparation, timedOut: true), "preparation.deadline_expired", "RepoPrompt couldn't save everything before quitting"),
            (failure(.preparation), "preparation.failure", "RepoPrompt couldn't save everything before quitting"),
            (
                failure(scope: .window(1), .preparation, timedOut: true),
                "preparation.deadline_expired",
                "RepoPrompt couldn't save everything before closing this window"
            ),
            (failure(.finalization, timedOut: true), "finalization.deadline_expired", "Some work could not be saved"),
            (failure(.finalization), "finalization.failure", "Some work could not be saved"),
            (failure(scope: .window(1), .finalization), "finalization.failure", "Some work could not be saved"),
            (
                failure(.finalization, timedOut: true, awaitsAck: true),
                "finalization.clean_exit_unacknowledged",
                "RepoPrompt is still finishing its quit"
            ),
            (
                failure(.finalization, unresolved: true),
                "finalization.relaunch_unresolved",
                "RepoPrompt can't continue restarting safely"
            ),
            (
                failure(.preparation, unresolved: true),
                "preparation.relaunch_unresolved",
                "RepoPrompt can't continue restarting safely"
            ),
            (
                failure(.finalization, unresolved: true, allowsExit: true),
                "finalization.relaunch_unresolved_exit_offered",
                "RepoPrompt can exit, but may reopen"
            )
        ]
        for (failure, token, title) in cases {
            XCTAssertEqual(AgentLifecycleShutdownDiagnostics.dialogStage(failure), token, title)
            XCTAssertEqual(WindowStatesManager.makeLifecycleShutdownFailureAlert(failure).messageText, title, token)
        }
    }

    // MARK: Clean mark at the persistence boundary (R4-02)

    /// A clean write that failed committed nothing: no correction is needed, the launch file keeps
    /// the unclean mark, and Quit Anyway replies at once.
    func testFailedCleanWriteLeavesTheUncleanMarkWithoutACorrection() async {
        appParticipants = [FakeParticipant()]
        disk.fail(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.messages, [AgentLifecycleShutdownCoordinator.cleanMarkFailureMessage])
        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress], "nothing clean was committed, nothing corrected")
        let mark = await diskMark()
        XCTAssertEqual(mark, .shutdownInProgress)
    }

    /// Stage A awaits its `shutdownInProgress` mark: an unconfirmed write is held by the attempt's
    /// deadline (a Stage A timeout), never crossed. Nothing is prepared or torn down behind it.
    func testUnconfirmedStageALaunchMarkTimesOutBeforeAnythingIsTornDown() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.shutdownInProgress)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("Stage A's mark write held in the store") {
            disk.isHolding(.shutdownInProgress) && clock.pendingCount == 1
        }
        await settle()
        XCTAssertEqual(participant.prepareCalls, 0, "preparation waits for the confirmed mark")

        clock.fire()
        await waitUntil("the Stage A timeout prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.timedOut, true)
        XCTAssertTrue(recorder.irreversible.isEmpty, "never crossed the point of no return")
        XCTAssertFalse(coordinator.isApplicationAdmissionSealed)
        XCTAssertEqual(participant.teardownExecutions, 0)

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        disk.release(.shutdownInProgress)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .running], "Cancel's mark is ordered last")
        XCTAssertEqual(participant.prepareCalls, 0, "the late mark never resumes the cancelled attempt")
    }

    /// A failed Stage A launch mark blocks the point of no return (Retry / Cancel); Retry writes it
    /// again and, once confirmed, quits cleanly.
    func testFailedStageALaunchMarkPreventsTeardownUntilRetryConfirmsIt() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.fail(.shutdownInProgress)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.messages, [AgentLifecycleShutdownCoordinator.launchMarkFailureMessage])
        XCTAssertTrue(recorder.irreversible.isEmpty)
        XCTAssertEqual(participant.teardownExecutions, 0)

        disk.fail(.shutdownInProgress, false)
        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit])
        XCTAssertEqual(participant.teardownExecutions, 1)
    }

    // MARK: Delayed clean-write acknowledgement

    /// Every participant was prepared and finalized and the clean write was enqueued under a valid
    /// authorization; only its acknowledgement is late. That is not uncertainty about saved input:
    /// no correction is written, the prompt says so, and Quit Anyway replies at once.
    func testDelayedCleanAcknowledgementIsNeverCorrectedAndQuitAnywayRepliesAtOnce() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the clean write held in the store") { disk.isHolding(.cleanExit) }

        clock.fire()
        await waitUntil("the acknowledgement prompt") { recorder.isPresenting }
        let failure = recorder.presented.last
        XCTAssertEqual(failure?.stage, .finalization)
        XCTAssertEqual(failure?.timedOut, true)
        XCTAssertEqual(failure?.awaitsCleanExitAcknowledgement, true)
        XCTAssertEqual(failure?.messages, [AgentLifecycleShutdownCoordinator.cleanExitAcknowledgementMessage])
        recorder.choose(.proceedAnyway)
        await waitUntil("the immediate reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true], "Quit Anyway does not wait for the write")

        disk.release(.cleanExit)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit], "no corrective write")
        XCTAssertEqual(participant.finalizeCalls, 1)
        XCTAssertEqual(replies, [true], "replied exactly once")
    }

    /// Retry joins the pending clean write (bounded by its own fresh deadline, never a second
    /// write or finalization); the write's late completion never terminates the app by itself.
    func testRetryJoinsADelayedCleanWriteWhoseLateCompletionNeverTerminates() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the clean write held in the store") { disk.isHolding(.cleanExit) }
        clock.fire()
        await waitUntil("the acknowledgement prompt") { recorder.isPresenting }

        recorder.choose(.retry)
        await waitUntil("the retry deadline") { clock.pendingCount == 1 }
        clock.fire()
        await waitUntil("the bounded retry prompt") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.messages, [AgentLifecycleShutdownCoordinator.cleanExitAcknowledgementMessage])
        XCTAssertTrue(replies.isEmpty)

        disk.release(.cleanExit)
        await drainLaunchMarks()
        await settle()
        XCTAssertTrue(replies.isEmpty, "a late acknowledgement never terminates by itself")
        XCTAssertEqual(coordinator.applicationRequest?.phase, .finalizationFailed)

        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit], "one clean write")
        XCTAssertEqual(participant.finalizeCalls, 1, "no duplicate finalization")
        XCTAssertEqual(participant.teardownExecutions, 1)
    }

    /// A delayed clean write that finally wrote nothing is released: Retry finalizes and
    /// authorizes afresh.
    func testRetryAfterADelayedCleanWriteThatWroteNothingAuthorizesAfresh() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        disk.fail(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the clean write held in the store") { disk.isHolding(.cleanExit) }
        clock.fire()
        await waitUntil("the acknowledgement prompt") { recorder.isPresenting }
        disk.release(.cleanExit)
        await drainLaunchMarks()
        await settle()
        XCTAssertNil(coordinator.applicationRequest?.cleanWrite, "a write that wrote nothing is released")

        disk.fail(.cleanExit, false)
        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit])
        XCTAssertEqual(participant.finalizeCalls, 2)
    }

    // MARK: Window close

    func testWindowCloseNeverWritesALaunchMarkAndHonorsTheForwardedVeto() async {
        let participant = FakeParticipant()
        windowParticipants = [7: participant]
        let coordinator = makeCoordinator()
        var finishes: [Bool] = []
        var allowClose = false

        XCTAssertTrue(coordinator.requestWindowClose(windowID: 7, forwardedVeto: { allowClose }, finish: { finishes.append($0) }))
        XCTAssertTrue(participant.isFrozen)
        XCTAssertEqual(participant.ownedRecoveryFreezes, 1, "a window close owns its scoped recovery freeze")
        XCTAssertFalse(
            coordinator.requestWindowClose(windowID: 7, forwardedVeto: { true }, finish: { finishes.append($0) }),
            "a duplicate close joins the request in progress"
        )
        await waitUntil("the vetoed finish") { !finishes.isEmpty }
        XCTAssertEqual(finishes, [false], "the forwarded veto is honored before the point of no return")
        XCTAssertTrue(recorder.irreversible.isEmpty)
        XCTAssertEqual(participant.teardownExecutions, 0)
        XCTAssertFalse(participant.isFrozen)

        allowClose = true
        coordinator.requestWindowClose(windowID: 7, forwardedVeto: { allowClose }, finish: { finishes.append($0) })
        await waitUntil("the authorized finish") { finishes.count == 2 }
        XCTAssertEqual(finishes, [false, true])
        XCTAssertEqual(recorder.irreversible, [.window(7)])
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(participant.finalizeCalls, 1)
        await drainLaunchMarks()
        XCTAssertTrue(disk.committed.isEmpty, "a window close never writes a global launch mark")
        XCTAssertEqual(recorder.appFreezeBegins, 0)
        XCTAssertFalse(coordinator.hasUnfinalizedWindowClose)
        XCTAssertFalse(coordinator.isApplicationAdmissionSealed, "a window close never seals admission")
        XCTAssertTrue(coordinator.admitApplicationWindow(FakeParticipant()))
    }

    /// R4-2 (B): Close Anyway after a failed window final flush keeps every later app quit of this
    /// launch from proving a clean exit.
    func testCloseAnywayKeepsALaterQuitFromMarkingClean() async {
        let window = FakeParticipant()
        window.finalizeResults = [AgentModeShutdownReport(blockers: ["Session W: the conversation could not be saved."])]
        let other = FakeParticipant()
        windowParticipants = [5: window]
        let coordinator = makeCoordinator()
        var finishes: [Bool] = []
        coordinator.requestWindowClose(windowID: 5, forwardedVeto: { true }, finish: { finishes.append($0) })
        await waitUntil("the window Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        recorder.choose(.proceedAnyway)
        await waitUntil("the window finish") { !finishes.isEmpty }
        XCTAssertEqual(finishes, [true])
        XCTAssertTrue(coordinator.hasUnfinalizedWindowClose)

        windowParticipants = [:]
        appParticipants = [other]
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(other.finalizeCalls, 1)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress], "the quit never marks clean")
        let mark = await diskMark()
        XCTAssertEqual(mark, .shutdownInProgress)
    }

    func testAppQuitSupersedesAWindowCloseInStageAAndRefusesNewCloses() async {
        let window = FakeParticipant()
        let hang = makeHang()
        window.prepareHang = hang
        let other = FakeParticipant()
        windowParticipants = [1: window]
        appParticipants = [window, other]
        let coordinator = makeCoordinator()
        var finishes: [Bool] = []
        var replies: [Bool] = []
        coordinator.requestWindowClose(windowID: 1, forwardedVeto: { true }, finish: { finishes.append($0) })
        await waitUntil("the stuck window preparation") { hang.entered == 1 }

        XCTAssertTrue(coordinator.requestApplicationQuit { replies.append($0) })
        XCTAssertFalse(coordinator.requestApplicationQuit { replies.append($0) }, "a duplicate quit joins")
        XCTAssertEqual(finishes, [false], "the window stays open; the quit owns it now")
        XCTAssertEqual(recorder.dismissed, [.window(1)])
        XCTAssertTrue(window.isFrozen, "still frozen by the app quit")
        XCTAssertFalse(
            coordinator.requestWindowClose(windowID: 2, forwardedVeto: { true }, finish: { finishes.append($0) }),
            "no window close starts during an app quit"
        )
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(window.teardownExecutions, 1)
        XCTAssertEqual(other.teardownExecutions, 1)
        hang.release()
        await settle()
        XCTAssertEqual(finishes, [false], "the superseded close never finishes later")
    }

    func testAppQuitJoinsAWindowPastItsPointOfNoReturnWithoutPreparingOrTearingItDownAgain() async {
        let window = FakeParticipant()
        let hang = makeHang()
        window.teardownHang = hang
        let other = FakeParticipant()
        windowParticipants = [3: window]
        appParticipants = [window, other]
        let coordinator = makeCoordinator()
        var finishes: [Bool] = []
        var replies: [Bool] = []
        coordinator.requestWindowClose(windowID: 3, forwardedVeto: { true }, finish: { finishes.append($0) })
        await waitUntil("the window teardown") { hang.entered == 1 }

        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the other window's preparation") { other.prepareCalls == 1 }
        XCTAssertEqual(window.prepareCalls, 1, "a window past its point of no return is not prepared again")
        hang.release()
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(window.teardownExecutions, 1, "its single teardown is joined, never repeated")
        XCTAssertEqual(disk.committed.last, .cleanExit)
    }

    // MARK: Window admission during an app quit (R4-3)

    /// Registers a window the way `WindowStatesManager.registerWindowState` does: admission is
    /// decided first; only an admitted window becomes an app participant.
    @discardableResult
    private func register(_ participant: FakeParticipant, with coordinator: AgentLifecycleShutdownCoordinator) -> Bool {
        guard coordinator.admitApplicationWindow(participant) else { return false }
        appParticipants.append(participant)
        return true
    }

    /// A window registered while Stage A runs is frozen at registration and invalidates the
    /// attempt: Stage A fails instead of crossing the point of no return without it. Retry
    /// preserves the layout again (now including it) and prepares it before the boundary.
    func testWindowRegisteredDuringStageAFailsTheAttemptAndRetryPreservesLayoutAndPreparesIt() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.prepareHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the slow preparation") { hang.entered == 1 }

        let newcomer = FakeParticipant()
        XCTAssertTrue(register(newcomer, with: coordinator), "Stage A admits")
        XCTAssertTrue(newcomer.isFrozen, "frozen synchronously at registration")
        hang.release()
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(recorder.presented.last?.messages, [AgentLifecycleShutdownCoordinator.newWindowMessage])
        XCTAssertTrue(recorder.irreversible.isEmpty, "never crossed the point of no return without it")
        XCTAssertEqual(newcomer.prepareCalls, 0)
        XCTAssertEqual(recorder.layoutCalls, 1)

        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(recorder.layoutCalls, 2, "the layout is preserved again with the new window")
        XCTAssertEqual(newcomer.prepareCalls, 1, "prepared before the point of no return")
        XCTAssertEqual(newcomer.teardownExecutions, 1)
        XCTAssertEqual(newcomer.finalizeCalls, 1)
        XCTAssertEqual(disk.committed.last, .cleanExit)
        XCTAssertFalse(disk.committed.dropLast().contains(.cleanExit))
    }

    /// A window registered while the Stage A prompt is shown joins the request; Cancel unfreezes it
    /// with the others. A registration after the request finished is ignored.
    func testWindowRegisteredDuringAStageAPromptIsUnfrozenByCancel() async {
        let participant = FakeParticipant()
        participant.prepareResults = [AgentModeShutdownReport(blockers: ["Session A: a draft could not be saved."])]
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the Stage A prompt") { recorder.isPresenting }

        let newcomer = FakeParticipant()
        register(newcomer, with: coordinator)
        XCTAssertTrue(newcomer.isFrozen)
        recorder.choose(.cancel)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(newcomer.isFrozen, "Cancel reopens the window that joined")
        XCTAssertFalse(participant.isFrozen)

        let afterwards = FakeParticipant()
        XCTAssertTrue(register(afterwards, with: coordinator), "a cancelled quit never sealed admission")
        XCTAssertFalse(afterwards.isFrozen, "no quit in progress")
        XCTAssertFalse(coordinator.isApplicationAdmissionSealed)
    }

    /// Admission is sealed synchronously at the point of no return, before anything irreversible:
    /// a window arriving during teardown is refused and never frozen, prepared, torn down, or
    /// finalized, so it cannot invalidate the clean proof of the windows this quit prepared.
    func testAdmissionIsSealedAtThePointOfNoReturnAndARefusedWindowIsUntouched() async {
        let participant = FakeParticipant()
        let hang = makeHang()
        participant.teardownHang = hang
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        XCTAssertFalse(coordinator.isApplicationAdmissionSealed, "Stage A admits")
        await waitUntil("the teardown") { hang.entered == 1 }
        XCTAssertTrue(coordinator.isApplicationAdmissionSealed)
        XCTAssertEqual(recorder.irreversible, [.application])

        let newcomer = FakeParticipant()
        XCTAssertFalse(register(newcomer, with: coordinator), "refused past the point of no return")
        XCTAssertFalse(newcomer.isFrozen)
        hang.release()
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(newcomer.prepareCalls, 0)
        XCTAssertEqual(newcomer.teardownExecutions, 0)
        XCTAssertEqual(newcomer.finalizeCalls, 0)
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit], "the proof covers every admitted window")
    }

    /// The concrete late-window race: a window arrives while the clean write is gated in the store.
    /// It is refused before registration, nothing it would own is touched, and the clean claim
    /// stays justified (no correction). The seal persists after completion: no window, close, or
    /// second quit is admitted until the process exits.
    func testWindowArrivingWhileTheCleanWriteIsGatedIsRefusedAndTheCleanClaimHolds() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        coordinator.requestApplicationQuit { replies.append($0) }
        await waitUntil("the clean write held in the store") { disk.isHolding(.cleanExit) }

        let newcomer = FakeParticipant()
        XCTAssertFalse(register(newcomer, with: coordinator))
        XCTAssertFalse(newcomer.isFrozen)
        XCTAssertEqual(appParticipants.count, 1, "the refused window is never a participant")
        disk.release(.cleanExit)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertTrue(recorder.presented.isEmpty)
        XCTAssertEqual(recorder.layoutCalls, 1)
        XCTAssertEqual(newcomer.prepareCalls + newcomer.teardownExecutions + newcomer.finalizeCalls, 0)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .cleanExit], "no correction")

        XCTAssertTrue(coordinator.isApplicationAdmissionSealed, "sealed until the process exits")
        XCTAssertFalse(register(FakeParticipant(), with: coordinator))
        XCTAssertFalse(coordinator.requestApplicationQuit { replies.append($0) })
        windowParticipants = [9: participant]
        XCTAssertFalse(coordinator.requestWindowClose(windowID: 9, forwardedVeto: { true }, finish: { _ in }))
        XCTAssertEqual(replies, [true])
    }

    // MARK: Restart safely (lossless restart Phase 4 §G)

    /// Scripted relaunch hooks with a model of the helper's state (ready / armed).
    @MainActor
    private final class FakeRelaunch {
        var calls: [String] = []
        var prepareResults: [String?] = []
        var verifyResults: [String?] = []
        var armResults: [String?] = []
        /// Scripted `abandon` outcomes (`.safe` once exhausted).
        var abandonResults: [AgentLifecycleRelaunchAbandonment] = []
        var budgets: [AgentLifecycleRelaunchBudget] = []
        /// One-shot suspensions of the next `verifyAllStopped` / `prepare` / `arm` (consumed when
        /// entered; ignore cancellation like a hook bounded only by its own budget).
        var verifyGate: Hang?
        var prepareGate: Hang?
        var armGate: Hang?
        /// Disk marks committed when `verifyAllStopped` ran.
        var marksAtVerify: [[AgentRecoveryLaunchMark.State]] = []
        var disk: LaunchMarkDisk?
        private(set) var helperReady = false
        private(set) var helperArmed = false
        /// Step 4b: a recorded stop proof of the retained helper, released once (replayed to a
        /// later observation when it arrived first).
        private var retainedStopProven = false
        private var stopWaiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
        private(set) var cancelledStopWaits = 0

        /// The retained helper's exact exit or correlated `aborted` arrived.
        func proveRetainedHelperStop() {
            if let waiter = stopWaiter {
                stopWaiter = nil
                waiter.continuation.resume(returning: true)
            } else {
                retainedStopProven = true
            }
        }

        var isAwaitingStop: Bool {
            stopWaiter != nil
        }

        /// Test cleanup: ends a still-pending observation without proof.
        func endStopWait() {
            guard let waiter = stopWaiter else { return }
            stopWaiter = nil
            waiter.continuation.resume(returning: false)
        }

        private func cancelStopWait(_ id: UUID) {
            guard let waiter = stopWaiter, waiter.id == id else { return }
            stopWaiter = nil
            cancelledStopWaits += 1
            waiter.continuation.resume(returning: false)
        }

        var hooks: AgentLifecycleRelaunchHooks {
            AgentLifecycleRelaunchHooks(
                prepare: { [self] budget in
                    calls.append("prepare")
                    budgets.append(budget)
                    if let gate = prepareGate {
                        prepareGate = nil
                        await gate.wait()
                    }
                    let result = prepareResults.isEmpty ? nil : prepareResults.removeFirst()
                    helperReady = result == nil
                    helperArmed = false
                    return result
                },
                verifyAllStopped: { [self] in
                    calls.append("verify")
                    marksAtVerify.append(disk?.committed ?? [])
                    if let gate = verifyGate {
                        verifyGate = nil
                        await gate.wait()
                    }
                    return verifyResults.isEmpty ? nil : verifyResults.removeFirst()
                },
                arm: { [self] budget in
                    calls.append("arm")
                    budgets.append(budget)
                    if let gate = armGate {
                        armGate = nil
                        await gate.wait()
                    }
                    let result = armResults.isEmpty ? nil : armResults.removeFirst()
                    helperArmed = result == nil && helperReady
                    helperReady = false
                    return result
                },
                abandon: { [self] in
                    calls.append("abandon")
                    let result = abandonResults.isEmpty ? .safe : abandonResults.removeFirst()
                    if result == .safe {
                        helperReady = false
                        helperArmed = false
                    }
                    return result
                },
                awaitRetainedHelperStop: { [self] in
                    calls.append("awaitStop")
                    let id = UUID()
                    return await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            if retainedStopProven {
                                retainedStopProven = false
                                continuation.resume(returning: true)
                            } else if Task.isCancelled {
                                continuation.resume(returning: false)
                            } else {
                                stopWaiter = (id, continuation)
                            }
                        }
                    } onCancel: {
                        Task { @MainActor in self.cancelStopWait(id) }
                    }
                }
            )
        }
    }

    func testSafeRestartIsRefusedWithoutComposedHooksBeforeAnythingFreezes() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let coordinator = makeCoordinator()
        var replies: [Bool] = []
        XCTAssertFalse(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(participant.isFrozen)
        XCTAssertEqual(recorder.appFreezeBegins, 0)
        XCTAssertNil(coordinator.applicationRequest)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [], "nothing was recorded")
    }

    func testSafeRestartPreparesInStageAProvesAllStoppedAfterTheCleanWriteThenArmsOnce() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.disk = disk
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the restart reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "arm"])
        XCTAssertEqual(relaunch.marksAtVerify.first?.last, .cleanExit, "Stage B proves all stopped only after final persistence")
        XCTAssertEqual(participant.finalizeCalls, 1)
        XCTAssertTrue(relaunch.helperArmed)
        XCTAssertEqual(coordinator.applicationRequest?.relaunchArmed, true)
        // Review A P1-07 / R1 A P1-07: every hook gets the same absolute budget of the one 8 s
        // deadline: helper work ends before the cleanup reserve, every helper stop by 8 s itself.
        let reserve = ProcessRelaunchLimits.v1.cleanupReserve
        XCTAssertEqual(reserve, .seconds(1))
        let expected = AgentLifecycleRelaunchBudget(
            workExpiry: clock.instant(at: .seconds(8) - reserve),
            cleanupExpiry: clock.instant(at: .seconds(8))
        )
        XCTAssertEqual(relaunch.budgets, [expected, expected], "absolute, never renewed: \(relaunch.budgets)")
    }

    func testSafeRestartStageBVerifyFailureLeavesNoHelperAndQuitAnywayNeverRelaunches() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.verifyResults = ["A Codex runtime is still running."]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .finalization)
        XCTAssertEqual(recorder.presented.last?.messages, ["A Codex runtime is still running."])
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "abandon"], "never armed; abandoned before the prompt")
        XCTAssertFalse(relaunch.helperReady)
        XCTAssertFalse(relaunch.helperArmed)

        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(relaunch.calls.contains("arm"))
        XCTAssertEqual(coordinator.applicationRequest?.relaunchArmed, false)
    }

    func testSafeRestartStageBRetryUsesAFreshHelperAfterProvingAllStopped() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.verifyResults = ["A tool is still running."]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        recorder.choose(.retry)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "abandon", "verify", "prepare", "arm"])
        XCTAssertTrue(relaunch.helperArmed)
        XCTAssertEqual(participant.teardownExecutions, 1, "Retry never repeats teardown")
    }

    func testSafeRestartLostArmAcknowledgementIsAbandonedBeforeChoices() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.armResults = ["The relaunch helper did not confirm it was armed."]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "arm", "abandon"])
        XCTAssertFalse(relaunch.helperArmed)
        XCTAssertEqual(coordinator.applicationRequest?.relaunchArmed, false)
        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(relaunch.calls.count { $0 == "arm" }, 1)
    }

    func testSafeRestartStageAHelperFailureCancelUnfreezesAndAbandons() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.prepareResults = ["RepoPrompt could not start its restart helper."]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.stage, .preparation)
        XCTAssertEqual(relaunch.calls, ["prepare", "abandon"])
        XCTAssertTrue(recorder.irreversible.isEmpty)

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(participant.isFrozen, "Cancel unfreezes Stage A")
        await waitUntil("the cancel abandon") { relaunch.calls.count == 3 }
        XCTAssertEqual(relaunch.calls, ["prepare", "abandon", "abandon"])
        XCTAssertFalse(relaunch.helperReady)
        XCTAssertEqual(participant.teardownExecutions, 0)
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, [.shutdownInProgress, .running])
    }

    private static let lostArmText = "The relaunch helper did not confirm it was armed."
    private static let unresolvedStopText = "RepoPrompt could not confirm that its restart helper stopped."

    /// Review A P1-07 + Step 4c: when abandoning a helper whose `arm` this attempt sent cannot prove
    /// its stop, the prompt offers only the explicit uncertain exit (no Retry, Cancel, or Quit
    /// Anyway). Keep Waiting (the ignored sentinel) and every ordinary choice show the SAME prompt
    /// again without repeating `abandon`, the stop observation, a deadline, or any helper hook, so
    /// waiting never removes the only way out. A later stop proof restores the ordinary choices, and
    /// the ordinary Quit Anyway then quits without relaunching.
    func testSafeRestartUnresolvedArmedHelperOffersOnlyTheUncertainExitAndWaitingShowsTheSamePromptAgain() async throws {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.armResults = [Self.lostArmText]
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the unresolved prompt and its stop observation") { recorder.isPresenting && relaunch.isAwaitingStop }
        let request = try XCTUnwrap(coordinator.applicationRequest)
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "arm", "abandon", "awaitStop"])
        let failure = try XCTUnwrap(recorder.presented.last)
        XCTAssertTrue(failure.relaunchHelperUnresolved)
        XCTAssertEqual(failure.offeredChoices, [.exitMayReopen], "no Retry, Cancel, or Quit Anyway")
        XCTAssertEqual(failure.messages.last, Self.unresolvedStopText)

        for (index, choice) in [AgentLifecycleShutdownChoice.cancel, .retry, .proceedAnyway, .cancel].enumerated() {
            recorder.choose(choice)
            await waitUntil("the same prompt after \(choice)") { recorder.presented.count == index + 2 && recorder.isPresenting }
            XCTAssertEqual(request.relaunchHelperUnresolvedPrompts, index + 1)
        }
        XCTAssertTrue(recorder.presented.allSatisfy { $0 == failure }, "the same prompt is shown again")
        XCTAssertEqual(replies, [], "never reported finished")
        XCTAssertFalse(request.isFinished)
        XCTAssertEqual(request.phase, .finalizationFailed)
        XCTAssertEqual(
            relaunch.calls,
            ["prepare", "verify", "arm", "abandon", "awaitStop"],
            "no repeated abandon or observation, fresh helper, retry, or second arm"
        )
        XCTAssertTrue(relaunch.isAwaitingStop, "waiting keeps observing the stop proof")
        XCTAssertEqual(relaunch.cancelledStopWaits, 0)
        XCTAssertEqual(recorder.dismissed, [])
        XCTAssertEqual(request.finalizationAttempts, 1)
        XCTAssertEqual(participant.finalizeCalls, 1)
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(request.expiry, clock.instant(at: .seconds(7)), "no renewed deadline")
        XCTAssertNotNil(request.relaunchArmSafetyProof)

        relaunch.proveRetainedHelperStop()
        await waitUntil("choices restored") { recorder.presented.count == 6 && recorder.isPresenting }
        let restored = recorder.presented.last
        XCTAssertEqual(restored?.offeredChoices, [.retry, .proceedAnyway])
        XCTAssertEqual(restored?.offersUncertainRelaunchExit, false)
        XCTAssertNil(request.relaunchArmSafetyProof, "the proven stop ends the uncertainty")
        XCTAssertEqual(request.relaunchHelperUnresolvedPrompts, 4, "the dismissed prompt's answer is not counted")
        XCTAssertEqual(replies, [], "late proof does not quit automatically")
        recorder.choose(.proceedAnyway)
        await waitUntil("explicit Quit Anyway completes") { replies == [true] }
        XCTAssertEqual(relaunch.calls.count { $0 == "arm" }, 1, "Quit Anyway never relaunches")
        XCTAssertEqual(relaunch.calls.last, "abandon")
        XCTAssertFalse(request.relaunchArmed)
        XCTAssertEqual(request.relaunchUncertainExits, 0, "the ordinary Quit Anyway is not the uncertain exit")
    }

    /// Step 4b: once the retained (arm-sent) helper's stop is proven, the no-choice prompt is
    /// dismissed and the same Stage B failure is presented again with its normal choices. The
    /// notification itself retries nothing, prepares or arms no helper, saves or marks nothing, and
    /// renews no deadline; the dismissed prompt's answer and a duplicate proof do nothing. Only the
    /// user's explicit Retry then runs the normal pipeline with a fresh deadline and helper.
    func testSafeRestartProvenRetainedHelperStopRestoresTheChoicesAndOnlyAnExplicitRetryRearms() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.armResults = ["The relaunch helper did not confirm it was armed."]
        relaunch.abandonResults = [.unresolved("RepoPrompt could not confirm that its restart helper stopped.")]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the no-choice prompt and its stop observation") { recorder.isPresenting && relaunch.isAwaitingStop }
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "arm", "abandon", "awaitStop"])
        let informational = recorder.presented.last
        XCTAssertEqual(informational?.offeredChoices, [.exitMayReopen], "only the explicit uncertain exit (Step 4c)")
        let request = coordinator.applicationRequest
        XCTAssertEqual(request?.expiry, clock.instant(at: .seconds(7)))
        await drainLaunchMarks()
        let marksBefore = disk.committed
        XCTAssertEqual(marksBefore.last, .cleanExit)
        // Time passes while the prompt informs: a renewed deadline would be visible.
        clock.advance(by: .seconds(3))

        relaunch.proveRetainedHelperStop()
        await waitUntil("the restored prompt") { recorder.presented.count == 2 && recorder.isPresenting }
        await settle()
        XCTAssertEqual(recorder.dismissed, [.application], "the informational prompt is dismissed")
        XCTAssertEqual(recorder.presented.count, 2, "the dismissed prompt's answer is ignored")
        let restored = recorder.presented.last
        XCTAssertEqual(restored?.stage, .finalization)
        XCTAssertEqual(restored?.relaunchHelperUnresolved, false)
        XCTAssertEqual(restored?.offeredChoices, [.retry, .proceedAnyway])
        XCTAssertEqual(restored?.messages, informational.map { Array($0.messages.dropLast()) })
        XCTAssertEqual(request?.relaunchHelperStopRecoveries, 1)
        XCTAssertEqual(request?.relaunchHelperUnresolvedPrompts, 0)
        XCTAssertEqual(
            relaunch.calls,
            ["prepare", "verify", "arm", "abandon", "awaitStop", "abandon"],
            "no automatic Retry, fresh helper, or arm"
        )
        XCTAssertEqual(replies, [], "no automatic quit")
        XCTAssertEqual(request?.isFinished, false)
        XCTAssertEqual(request?.finalizationAttempts, 1)
        XCTAssertEqual(participant.finalizeCalls, 1, "nothing is saved again")
        XCTAssertEqual(request?.expiry, clock.instant(at: .seconds(7)), "no renewed deadline")
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, marksBefore, "no further launch mark")

        relaunch.proveRetainedHelperStop()
        await settle()
        XCTAssertEqual(recorder.presented.count, 2, "a duplicate proof does nothing")
        XCTAssertEqual(recorder.dismissed, [.application])
        XCTAssertEqual(request?.relaunchHelperStopRecoveries, 1)

        recorder.choose(.retry)
        await waitUntil("the restart reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(Array(relaunch.calls.dropFirst(6)), ["verify", "prepare", "arm"], "the explicit Retry uses a fresh helper")
        XCTAssertEqual(request?.finalizationAttempts, 2)
        XCTAssertEqual(request?.expiry, clock.instant(at: .seconds(10)), "the explicit Retry starts a fresh deadline")
        XCTAssertEqual(request?.relaunchArmed, true)
        XCTAssertEqual(participant.teardownExecutions, 1, "Retry never repeats teardown")
        XCTAssertEqual(participant.finalizeCalls, 1, "Retry joins the acknowledged clean write")
    }

    /// Step 4b: proof that arrived before the observation was registered is not missed; the
    /// restored Quit Anyway quits without relaunching.
    func testSafeRestartStopProofArrivingBeforeTheObservationRestoresChoicesAndQuitAnywayNeverRelaunches() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.armResults = ["The relaunch helper did not confirm it was armed."]
        relaunch.abandonResults = [.unresolved("RepoPrompt could not confirm that its restart helper stopped.")]
        relaunch.proveRetainedHelperStop()
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the restored prompt") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(recorder.presented.first?.relaunchHelperUnresolved, true)
        XCTAssertEqual(recorder.presented.first?.offersUncertainRelaunchExit, true)
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [.retry, .proceedAnyway])
        XCTAssertNil(coordinator.applicationRequest?.relaunchArmSafetyProof)
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "arm", "abandon", "awaitStop", "abandon"])

        recorder.choose(.proceedAnyway)
        await waitUntil("the reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(relaunch.calls.count { $0 == "arm" }, 1, "Quit Anyway never relaunches")
        XCTAssertEqual(coordinator.applicationRequest?.relaunchArmed, false)
        XCTAssertEqual(relaunch.cancelledStopWaits, 0)
    }

    /// Review R1 B N3: an unresolved stop of a helper the protocol proves was never sent `arm` (it
    /// can never open anything) keeps the normal Stage A choices with the reason shown. The driver
    /// keeps the helper (its Retry prepare reports the refusal instead of spawning a fresh one),
    /// and Cancel unfreezes as usual.
    func testSafeRestartStageAUnresolvedUnarmedHelperKeepsTheNormalChoices() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        let unresolved = "RepoPrompt could not confirm that its restart helper stopped."
        relaunch.prepareResults = ["The relaunch helper did not become ready in time.", unresolved]
        relaunch.abandonResults = [.unresolvedUnarmed(unresolved), .unresolvedUnarmed(unresolved)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the Stage A prompt") { recorder.isPresenting }
        let first = recorder.presented.last
        XCTAssertEqual(first?.stage, .preparation)
        XCTAssertEqual(first?.relaunchHelperUnresolved, false, "never armed: not the no-choice prompt")
        XCTAssertEqual(first?.offeredChoices, [.retry, .cancel])
        XCTAssertEqual(first?.messages.last, unresolved, "the unresolved stop is reported")

        recorder.choose(.retry)
        await waitUntil("the retried prompt") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(relaunch.calls, ["prepare", "abandon", "prepare", "abandon"])
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [.retry, .cancel])
        XCTAssertEqual(coordinator.applicationRequest?.relaunchHelperUnresolvedPrompts, 0)
        XCTAssertTrue(recorder.irreversible.isEmpty)

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(participant.isFrozen, "Cancel unfreezes Stage A")
        await waitUntil("the cancel abandon") { relaunch.calls.count == 5 }
        XCTAssertEqual(relaunch.calls.last, "abandon")
    }

    // MARK: Restart safely, explicit uncertain exit (Step 4c)

    /// The explicit uncertain exit completes the request exactly once without claiming the helper
    /// stopped: the observation is cancelled, and no helper hook, launch mark, finalization,
    /// teardown, or deadline follows. A later proof or answer does nothing.
    func testSafeRestartUncertainExitCompletesOnceWithoutHooksMarksOrDeadline() async throws {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.armResults = [Self.lostArmText]
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the unresolved prompt and its stop observation") { recorder.isPresenting && relaunch.isAwaitingStop }
        let request = try XCTUnwrap(coordinator.applicationRequest)
        let failure = try XCTUnwrap(recorder.presented.last)
        XCTAssertEqual(failure.stage, .finalization)
        XCTAssertTrue(failure.offersUncertainRelaunchExit)
        XCTAssertEqual(failure.offeredChoices, [.exitMayReopen])
        XCTAssertEqual(
            request.relaunchArmSafetyProof,
            AgentLifecycleShutdownCoordinator.RelaunchArmSafetyProof(requestID: request.id, attemptID: request.attemptID),
            "the witness of exactly this request's current attempt"
        )
        await drainLaunchMarks()
        let marksBefore = disk.committed
        XCTAssertEqual(marksBefore.last, .cleanExit)
        clock.advance(by: .seconds(3))

        recorder.choose(.exitMayReopen)
        await waitUntil("the exit reply") { replies == [true] }
        await waitUntil("the observation is cancelled") { relaunch.cancelledStopWaits == 1 }
        XCTAssertEqual(request.phase, .completed)
        XCTAssertTrue(request.isFinished)
        XCTAssertEqual(request.relaunchUncertainExits, 1)
        XCTAssertFalse(request.relaunchArmed, "never claimed armed")
        XCTAssertNil(request.relaunchArmSafetyProof)
        XCTAssertEqual(request.relaunchHelperStopRecoveries, 0, "not a stop recovery")
        XCTAssertEqual(request.relaunchHelperUnresolvedPrompts, 0)
        XCTAssertEqual(request.finalizationAttempts, 1)
        XCTAssertEqual(request.expiry, clock.instant(at: .seconds(7)), "no renewed deadline")
        XCTAssertFalse(relaunch.isAwaitingStop)
        XCTAssertEqual(
            relaunch.calls,
            ["prepare", "verify", "arm", "abandon", "awaitStop"],
            "no abandon, prepare, arm, or verify follows the exit"
        )
        XCTAssertEqual(participant.finalizeCalls, 1)
        XCTAssertEqual(participant.teardownExecutions, 1)
        XCTAssertEqual(recorder.scopeTeardowns, [.application])
        await drainLaunchMarks()
        XCTAssertEqual(disk.committed, marksBefore, "no further launch mark")
        assertHonestUncertainExitAlert(failure)

        relaunch.proveRetainedHelperStop()
        recorder.choose(.exitMayReopen)
        await settle()
        XCTAssertEqual(replies, [true], "completed exactly once")
        XCTAssertEqual(recorder.presented.count, 1, "no replacement prompt")
        XCTAssertEqual(recorder.dismissed, [])
        XCTAssertEqual(request.relaunchHelperStopRecoveries, 0)
    }

    /// Proof before answer: the stop proof invalidates the exit prompt before dismissing it, so an
    /// exit answer resumed by that dismissal is stale and ignored. On the restored ordinary prompt
    /// the exit is rejected (shown again), never reinterpreted as Cancel or Quit Anyway.
    func testSafeRestartExitAnswerResumedByTheProofDismissalLosesToTheProof() async throws {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.armResults = [Self.lostArmText]
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the unresolved prompt and its stop observation") { recorder.isPresenting && relaunch.isAwaitingStop }
        let request = try XCTUnwrap(coordinator.applicationRequest)
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [.exitMayReopen])

        recorder.answerOnDismiss = .exitMayReopen
        relaunch.proveRetainedHelperStop()
        await waitUntil("the restored prompt") { recorder.presented.count == 2 && recorder.isPresenting }
        recorder.answerOnDismiss = .cancel
        await settle()
        XCTAssertEqual(recorder.dismissed, [.application])
        XCTAssertEqual(replies, [], "the dismissed prompt's exit answer loses to the proof")
        XCTAssertEqual(request.relaunchUncertainExits, 0)
        XCTAssertFalse(request.isFinished)
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [.retry, .proceedAnyway])

        recorder.choose(.exitMayReopen)
        await waitUntil("the ordinary prompt shown again") { recorder.presented.count == 3 && recorder.isPresenting }
        XCTAssertEqual(request.rejectedUncertainExitAnswers, 1)
        XCTAssertEqual(recorder.presented[2], recorder.presented[1], "the same ordinary prompt")
        XCTAssertEqual(replies, [], "never a Quit Anyway")
        XCTAssertEqual(request.phase, .finalizationFailed, "never a Cancel")
        XCTAssertEqual(
            relaunch.calls,
            ["prepare", "verify", "arm", "abandon", "awaitStop", "abandon"],
            "a rejected answer repeats no hook"
        )

        recorder.choose(.proceedAnyway)
        await waitUntil("the ordinary Quit Anyway") { replies == [true] }
        XCTAssertEqual(relaunch.calls.count { $0 == "arm" }, 1)
        XCTAssertEqual(request.relaunchUncertainExits, 0)
    }

    /// A deadline firing while `arm` is in flight keeps the attempt's pre-arm witness, so the
    /// unresolved prompt offers the exit; the timed-out attempt's late `armed` never mutates the
    /// request or completes it.
    func testSafeRestartTimeoutWhileArmIsInFlightKeepsTheWitnessAndFencesTheLateArm() async throws {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        let armHang = makeHang()
        relaunch.armGate = armHang
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("arm in flight") { armHang.entered == 1 }
        let request = try XCTUnwrap(coordinator.applicationRequest)
        let attempt = request.attemptID
        XCTAssertEqual(
            request.relaunchArmSafetyProof,
            AgentLifecycleShutdownCoordinator.RelaunchArmSafetyProof(requestID: request.id, attemptID: attempt),
            "recorded before arm was entered"
        )

        clock.advance(by: .seconds(7))
        await waitUntil("the unresolved prompt and its stop observation") { recorder.isPresenting && relaunch.isAwaitingStop }
        let failure = try XCTUnwrap(recorder.presented.last)
        XCTAssertTrue(failure.timedOut)
        XCTAssertEqual(failure.offeredChoices, [.exitMayReopen])
        XCTAssertEqual(request.attemptID, attempt)
        // Review A F1 / B P2-1: the coordinator's own timeout prompt, through the real builder.
        XCTAssertEqual(
            failure.messages,
            [AgentLifecycleShutdownCoordinator.restartArmUnconfirmedMessage, Self.unresolvedStopText],
            "the restart-timeout text is replaced; the stop diagnostic stays"
        )
        XCTAssertFalse(failure.awaitsCleanExitAcknowledgement, "the witness proves the clean write")
        assertHonestUncertainExitAlert(failure)

        armHang.release()
        await settle()
        XCTAssertFalse(request.relaunchArmed, "a stale attempt's late armed is fenced")
        XCTAssertEqual(replies, [], "a stale arm never completes the request")
        XCTAssertFalse(request.isFinished)
        XCTAssertEqual(recorder.presented.count, 1)
        XCTAssertTrue(recorder.isPresenting)

        recorder.choose(.exitMayReopen)
        await waitUntil("the exit reply") { replies == [true] }
        XCTAssertEqual(request.relaunchUncertainExits, 1)
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "arm", "abandon", "awaitStop"])
    }

    /// Verification or helper preparation still suspended when the deadline fires never lets the
    /// late continuation record the witness or arm, and a witness never survives into a new
    /// attempt: both unresolved prompts only inform (no exit; an exit answer is ignored, not shown
    /// again).
    func testSafeRestartLateVerifyOrPrepareAfterATimeoutNeverRecordsTheWitnessOrArms() async throws {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        let verifyHang = makeHang()
        relaunch.verifyGate = verifyHang
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("verification in flight") { verifyHang.entered == 1 }
        let request = try XCTUnwrap(coordinator.applicationRequest)
        clock.advance(by: .seconds(7))
        await waitUntil("the unresolved prompt") { recorder.isPresenting && relaunch.isAwaitingStop }
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [])
        XCTAssertEqual(recorder.presented.last?.relaunchHelperUnresolved, true)
        XCTAssertEqual(
            recorder.presented.last?.messages.first,
            AgentLifecycleShutdownCoordinator.restartTimeoutMessage,
            "an unadmitted prompt keeps its timeout text"
        )
        verifyHang.release()
        await settle()
        XCTAssertNil(request.relaunchArmSafetyProof)
        XCTAssertFalse(relaunch.calls.contains("arm"), "the late verification never arms")
        recorder.choose(.exitMayReopen)
        await waitUntil("the ignored answer") { request.relaunchHelperUnresolvedPrompts == 1 }
        await settle()
        XCTAssertEqual(recorder.presented.count, 1, "not offered: ignored, not shown again")
        XCTAssertEqual(replies, [])
        XCTAssertEqual(request.relaunchUncertainExits, 0)

        // The stop proof restores the choices; the explicit Retry's preparation outlives its fresh
        // deadline.
        relaunch.proveRetainedHelperStop()
        await waitUntil("the restored prompt") { recorder.presented.count == 2 && recorder.isPresenting }
        let restored = try XCTUnwrap(recorder.presented.last)
        XCTAssertEqual(restored.offeredChoices, [.retry, .proceedAnyway])
        // Resolved timeout: "won't restart automatically. Try again, or quit" is true again.
        XCTAssertEqual(restored.messages, [AgentLifecycleShutdownCoordinator.restartTimeoutMessage])
        let restoredAlert = WindowStatesManager.makeLifecycleShutdownFailureAlert(restored)
        XCTAssertEqual(restoredAlert.buttons.map(\.title), ["Retry", "Quit Anyway"])
        XCTAssertTrue(restoredAlert.informativeText.hasPrefix(AgentLifecycleShutdownCoordinator.restartTimeoutMessage))
        let prepareHang = makeHang()
        relaunch.prepareGate = prepareHang
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        recorder.choose(.retry)
        await waitUntil("the retry's preparation in flight") { prepareHang.entered == 1 }
        XCTAssertNil(request.relaunchArmSafetyProof)
        clock.advance(by: .seconds(7))
        await waitUntil("the retry's unresolved prompt") {
            recorder.presented.count == 3 && recorder.isPresenting && relaunch.isAwaitingStop
        }
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [], "no witness from the earlier attempt")
        prepareHang.release()
        await settle()
        XCTAssertNil(request.relaunchArmSafetyProof)
        XCTAssertFalse(relaunch.calls.contains("arm"), "the late preparation never arms")
        XCTAssertEqual(
            relaunch.calls,
            ["prepare", "verify", "abandon", "awaitStop", "abandon", "verify", "prepare", "abandon", "awaitStop"]
        )

        relaunch.proveRetainedHelperStop()
        await waitUntil("the restored prompt") { recorder.presented.count == 4 && recorder.isPresenting }
        recorder.choose(.proceedAnyway)
        await waitUntil("the ordinary Quit Anyway") { replies == [true] }
        XCTAssertEqual(request.relaunchUncertainExits, 0)
    }

    /// The real alert for an admitted uncertain exit never contradicts it: no promise that the app
    /// won't restart, no unconfirmed clean write, no Try again / quit-without-restarting advice.
    private func assertHonestUncertainExitAlert(
        _ failure: AgentLifecycleShutdownFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(failure.offersUncertainRelaunchExit, file: file, line: line)
        let alert = WindowStatesManager.makeLifecycleShutdownFailureAlert(failure)
        XCTAssertEqual(alert.buttons.map(\.title), ["Keep Waiting", "Exit \u{2014} may reopen"], file: file, line: line)
        let text = alert.informativeText
        for contradiction in [
            "won't restart automatically",
            "Try again",
            "quit without restarting",
            "that it recorded a clean exit",
            "could not record"
        ] {
            XCTAssertFalse(text.contains(contradiction), "contradicts the exit: \(contradiction)\n\(text)", file: file, line: line)
        }
        XCTAssertTrue(text.contains("may reopen automatically, or it may not"), text, file: file, line: line)
    }

    /// Unresolved prompts without this attempt's pre-arm witness only inform, as before Step 4c.
    private func assertUnresolvedPromptOffersNoExit(
        _ coordinator: AgentLifecycleShutdownCoordinator,
        _ relaunch: FakeRelaunch,
        stage: AgentLifecycleShutdownStage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitUntil("the unresolved prompt", file: file, line: line) { recorder.isPresenting && relaunch.isAwaitingStop }
        let failure = recorder.presented.last
        XCTAssertEqual(failure?.stage, stage, file: file, line: line)
        XCTAssertEqual(failure?.relaunchHelperUnresolved, true, file: file, line: line)
        XCTAssertEqual(failure?.offeredChoices, [], file: file, line: line)
        XCTAssertEqual(failure?.offersUncertainRelaunchExit, false, file: file, line: line)
        XCTAssertNil(coordinator.applicationRequest?.relaunchArmSafetyProof, file: file, line: line)
        XCTAssertFalse(relaunch.calls.contains("arm"), file: file, line: line)
        let shown = recorder.presented.count
        recorder.choose(.exitMayReopen)
        await waitUntil("the ignored answer", file: file, line: line) {
            coordinator.applicationRequest?.relaunchHelperUnresolvedPrompts == 1
        }
        await settle()
        XCTAssertEqual(recorder.presented.count, shown, "ignored, not shown again", file: file, line: line)
        XCTAssertEqual(coordinator.applicationRequest?.isFinished, false, file: file, line: line)
        XCTAssertEqual(coordinator.applicationRequest?.relaunchUncertainExits, 0, file: file, line: line)
        // Cleanup through the existing path: proof restores the ordinary choices.
        relaunch.proveRetainedHelperStop()
        await waitUntil("the restored prompt", file: file, line: line) { recorder.presented.count == shown + 1 && recorder.isPresenting }
    }

    func testSafeRestartFailedCleanWriteNeverAdmitsTheUncertainExit() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.fail(.cleanExit)
        let relaunch = FakeRelaunch()
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await assertUnresolvedPromptOffersNoExit(coordinator, relaunch, stage: .finalization)
        XCTAssertEqual(recorder.presented.first?.messages.first, AgentLifecycleShutdownCoordinator.cleanMarkFailureMessage)
        XCTAssertFalse(relaunch.calls.contains("verify"))
        recorder.choose(.proceedAnyway)
        await waitUntil("the ordinary Quit Anyway") { replies == [true] }
    }

    func testSafeRestartPendingCleanWriteNeverAdmitsTheUncertainExit() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        disk.hold(.cleanExit)
        let relaunch = FakeRelaunch()
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the held clean write") { disk.isHolding(.cleanExit) }
        clock.advance(by: .seconds(7))
        await assertUnresolvedPromptOffersNoExit(coordinator, relaunch, stage: .finalization)
        XCTAssertEqual(recorder.presented.first?.messages.first, AgentLifecycleShutdownCoordinator.restartTimeoutMessage)
        disk.release(.cleanExit)
        await drainLaunchMarks()
        await settle()
        XCTAssertFalse(relaunch.calls.contains("verify"), "a late acknowledgement never continues the timed-out attempt")
        XCTAssertNil(coordinator.applicationRequest?.relaunchArmSafetyProof)
        recorder.choose(.proceedAnyway)
        await waitUntil("the ordinary Quit Anyway") { replies == [true] }
    }

    func testSafeRestartFailedStopVerificationNeverAdmitsTheUncertainExit() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.verifyResults = ["A tool is still running."]
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await assertUnresolvedPromptOffersNoExit(coordinator, relaunch, stage: .finalization)
        XCTAssertEqual(recorder.presented.first?.messages.first, "A tool is still running.")
        recorder.choose(.proceedAnyway)
        await waitUntil("the ordinary Quit Anyway") { replies == [true] }
    }

    func testSafeRestartStageAUnresolvedHelperNeverAdmitsTheUncertainExit() async {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.prepareResults = ["RepoPrompt could not start its restart helper."]
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await assertUnresolvedPromptOffersNoExit(coordinator, relaunch, stage: .preparation)
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [.retry, .cancel])
        XCTAssertTrue(recorder.irreversible.isEmpty)
        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { replies == [false] }
    }

    /// An `.unresolvedUnarmed` stop after the arm attempt clears the witness (the helper can never
    /// open anything): the ordinary choices stay, and an exit answer is rejected, never a quit.
    func testSafeRestartUnresolvedUnarmedStageBKeepsTheOrdinaryChoicesAndRejectsTheExit() async throws {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.armResults = [Self.lostArmText]
        relaunch.abandonResults = [.unresolvedUnarmed(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        let request = try XCTUnwrap(coordinator.applicationRequest)
        XCTAssertEqual(recorder.presented.last?.relaunchHelperUnresolved, false)
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [.retry, .proceedAnyway])
        XCTAssertNil(request.relaunchArmSafetyProof)

        recorder.choose(.exitMayReopen)
        await waitUntil("the same prompt") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(request.rejectedUncertainExitAnswers, 1)
        XCTAssertEqual(replies, [])
        XCTAssertEqual(relaunch.calls, ["prepare", "verify", "arm", "abandon"], "no repeated abandon")

        recorder.choose(.proceedAnyway)
        await waitUntil("the ordinary Quit Anyway") { replies == [true] }
        XCTAssertEqual(request.relaunchUncertainExits, 0)
        XCTAssertFalse(request.relaunchArmed)
    }

    private func makeFailure(
        scope: AgentLifecycleShutdownScope = .application,
        stage: AgentLifecycleShutdownStage,
        unresolved: Bool = false,
        allowsExit: Bool = false
    ) -> AgentLifecycleShutdownFailure {
        var failure = AgentLifecycleShutdownFailure(
            requestID: UUID(),
            scope: scope,
            stage: stage,
            messages: ["Something went wrong."],
            timedOut: false
        )
        failure.relaunchHelperUnresolved = unresolved
        failure.allowsUncertainRelaunchExit = allowsExit
        return failure
    }

    /// Only an admitted unresolved app Stage B prompt offers the exit (window close, Stage A, and an
    /// unadmitted prompt never do); `appending` carries the admission forward.
    func testUncertainExitIsOfferedOnlyOnAnAdmittedUnresolvedApplicationStageBPrompt() {
        XCTAssertEqual(makeFailure(stage: .finalization, unresolved: true, allowsExit: true).offeredChoices, [.exitMayReopen])
        XCTAssertEqual(makeFailure(stage: .finalization, unresolved: true).offeredChoices, [])
        XCTAssertEqual(makeFailure(stage: .preparation, unresolved: true, allowsExit: true).offeredChoices, [])
        XCTAssertEqual(makeFailure(scope: .window(1), stage: .finalization, unresolved: true, allowsExit: true).offeredChoices, [])
        XCTAssertEqual(makeFailure(stage: .finalization, allowsExit: true).offeredChoices, [.retry, .proceedAnyway])
        XCTAssertEqual(makeFailure(stage: .preparation).offeredChoices, [.retry, .cancel])
        XCTAssertEqual(makeFailure(scope: .window(1), stage: .finalization).offeredChoices, [.retry, .proceedAnyway])

        let base = makeFailure(stage: .finalization)
        let admitted = base.appending("unresolved", relaunchHelperUnresolved: true, allowsUncertainRelaunchExit: true)
        XCTAssertTrue(admitted.offersUncertainRelaunchExit)
        let carried = admitted.appending("more", relaunchHelperUnresolved: false)
        XCTAssertTrue(carried.relaunchHelperUnresolved)
        XCTAssertTrue(carried.offersUncertainRelaunchExit, "carried forward")
        XCTAssertEqual(carried.messages, ["Something went wrong.", "unresolved", "more"])
        XCTAssertFalse(
            base.appending("unarmed", relaunchHelperUnresolved: false, allowsUncertainRelaunchExit: true).allowsUncertainRelaunchExit,
            "never admitted without an unresolved helper"
        )
    }

    /// The AppKit adapter's builder and mapper, without showing anything: Keep Waiting first and
    /// default (Return), the exit second with no key equivalent; the unresolved branch is decided
    /// before the stage mapping, so no dismissal (sheet `.cancel`, app-modal `.abort`) or first
    /// button ever becomes an exit or a Retry there. Ordinary prompts keep their mapping.
    func testLifecycleShutdownAlertButtonsKeysAndResponseMapping() {
        let eligible = makeFailure(stage: .finalization, unresolved: true, allowsExit: true)
        let alert = WindowStatesManager.makeLifecycleShutdownFailureAlert(eligible)
        XCTAssertEqual(alert.buttons.map(\.title), ["Keep Waiting", "Exit \u{2014} may reopen"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", ""])
        XCTAssertEqual(alert.messageText, "RepoPrompt can exit, but may reopen")
        XCTAssertTrue(alert.informativeText.hasPrefix("Something went wrong."))
        XCTAssertTrue(alert.informativeText.contains("Before RepoPrompt asked its restart helper to arm"), alert.informativeText)
        XCTAssertTrue(alert.informativeText.contains("may reopen automatically, or it may not"), alert.informativeText)
        XCTAssertFalse(alert.informativeText.contains("second"), "no bound is promised")

        let informative = makeFailure(stage: .finalization, unresolved: true)
        XCTAssertEqual(WindowStatesManager.makeLifecycleShutdownFailureAlert(informative).buttons.map(\.title), ["OK"])
        XCTAssertEqual(
            WindowStatesManager.makeLifecycleShutdownFailureAlert(makeFailure(stage: .finalization)).buttons.map(\.title),
            ["Retry", "Quit Anyway"]
        )
        XCTAssertEqual(
            WindowStatesManager.makeLifecycleShutdownFailureAlert(makeFailure(scope: .window(1), stage: .finalization)).buttons.map(\.title),
            ["Retry", "Close Anyway"]
        )
        XCTAssertEqual(
            WindowStatesManager.makeLifecycleShutdownFailureAlert(makeFailure(stage: .preparation)).buttons.map(\.title),
            ["Retry", "Cancel"]
        )

        let responses: [NSApplication.ModalResponse] = [
            .alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn, .cancel, .abort, .stop
        ]
        func mapped(_ failure: AgentLifecycleShutdownFailure) -> [AgentLifecycleShutdownChoice] {
            responses.map { WindowStatesManager.lifecycleShutdownChoice(for: failure, response: $0) }
        }
        XCTAssertEqual(mapped(eligible), [.cancel, .exitMayReopen, .cancel, .cancel, .cancel, .cancel])
        XCTAssertEqual(mapped(informative), Array(repeating: .cancel, count: responses.count))
        XCTAssertEqual(
            mapped(makeFailure(scope: .window(1), stage: .finalization, unresolved: true, allowsExit: true)),
            Array(repeating: .cancel, count: responses.count),
            "never an exit outside the app's Stage B"
        )
        XCTAssertEqual(
            mapped(makeFailure(stage: .finalization)),
            [.retry, .proceedAnyway, .cancel, .cancel, .cancel, .cancel]
        )
        XCTAssertEqual(mapped(makeFailure(stage: .preparation)), [.retry, .cancel, .cancel, .cancel, .cancel, .cancel])
    }

    /// A helper channel that never exits on its own and replies only as `respond` scripts (by
    /// default never); it records frames and kill requests (a delivered signal is never exit proof).
    private final class SilentRelaunchChannel: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        private var terminates = 0
        private var exited = false
        private var exitWaiters: [CheckedContinuation<Void, Never>] = []
        private let continuation: AsyncStream<ProcessRelaunchInbound>.Continuation
        private(set) var channel: ProcessRelaunchHelperChannel!

        init(respond: @escaping @Sendable (ProcessRelaunchMessage) -> ProcessRelaunchMessage? = { _ in nil }) {
            let (inbound, continuation) = AsyncStream<ProcessRelaunchInbound>.makeStream()
            self.continuation = continuation
            channel = ProcessRelaunchHelperChannel(
                send: { [self] data in
                    lock.withLock { frames += 1 }
                    if let message = try? ProcessRelaunchCodec.decode(data.dropLast()), let reply = respond(message) {
                        continuation.yield(.message(reply))
                    }
                    return true
                },
                inbound: inbound,
                waitForExit: { [self] in
                    await withCheckedContinuation { waiter in
                        lock.lock()
                        if exited {
                            lock.unlock()
                            waiter.resume()
                        } else {
                            exitWaiters.append(waiter)
                            lock.unlock()
                        }
                    }
                },
                terminate: { [self] in
                    lock.withLock { terminates += 1 }
                    return .signalSent
                }
            )
        }

        var terminateCount: Int {
            lock.withLock { terminates }
        }

        var frameCount: Int {
            lock.withLock { frames }
        }

        func exit() {
            let waiters = lock.withLock {
                exited = true
                let pending = exitWaiters
                exitWaiters = []
                return pending
            }
            waiters.forEach { $0.resume() }
            continuation.finish()
        }
    }

    /// Review R1 A P1-07: R4 and the real relaunch driver share ONE injected clock. Identity
    /// inspection and spawn consume 2 s inside the prepare hook before the helper's ready timer
    /// starts; the helper never answers and never exits. The ready wait still ends at the attempt's
    /// work expiry (7 s, not 2 s + 7 s), the stop ends at the final expiry (8 s, never renewed to
    /// 9–10 s), and by 8 s the prompt shows the unresolved ownership (the helper is retained and
    /// was never armed, so the normal Stage A choices stay — review R1 B N3).
    func testSafeRestartComposedHelperBudgetIsAbsoluteAcrossTimeSpentBeforeItsTimerStarts() async throws {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let clock = try XCTUnwrap(clock)
        let silent = SilentRelaunchChannel()
        defer { silent.exit() }
        let bootSessionID = try XCTUnwrap(UUID(uuidString: "0A0B0C0D-1111-4222-8333-944455556666"))
        let identity = ProcessRelaunchParentIdentity(
            pid: 4242,
            bootSessionID: bootSessionID,
            startSeconds: 10,
            startMicroseconds: 20,
            uid: 501
        )
        let driver = AppRelaunchCoordinator(dependencies: AppRelaunchCoordinator.Dependencies(
            spawnHelper: { silent.channel },
            parentIdentity: {
                // Spent inside the hook, after R4 handed over its budget.
                clock.advance(by: .seconds(2))
                return identity
            },
            bundlePath: "/Apps/RepoPrompt CE.app",
            verifyAllStopped: { .allStopped },
            sleep: { duration in try? await clock.sleep(until: clock.now + duration) },
            now: { clock.now }
        ))
        let coordinator = makeCoordinator(relaunch: driver.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })

        let workExpiry = clock.instant(at: .seconds(7))
        let finalExpiry = clock.instant(at: .seconds(8))
        await waitUntil("R4's deadline and the helper's ready timer, both at the work expiry") {
            clock.requestedDeadlines.count { $0 == workExpiry } == 2
        }
        XCTAssertEqual(clock.now, clock.instant(at: .seconds(2)), "2 s were consumed before the timer started")
        XCTAssertEqual(driver.spawnCount, 1)
        clock.advance(by: .seconds(5))

        let acknowledgementDeadline = finalExpiry - ProcessRelaunchLimits.v1.terminateGrace
        await waitUntil("the abort acknowledgement wait") { clock.requestedDeadlines.contains(acknowledgementDeadline) }
        clock.advance(by: acknowledgementDeadline - clock.now)
        await waitUntil("the kill request and its exit wait") {
            silent.terminateCount == 1 && clock.requestedDeadlines.contains(finalExpiry)
        }
        clock.advance(by: finalExpiry - clock.now)
        await waitUntil("the prompt") { recorder.isPresenting }

        XCTAssertEqual(clock.now, finalExpiry, "the prompt appears by the final expiry")
        XCTAssertTrue(
            clock.requestedDeadlines.allSatisfy { $0 <= finalExpiry },
            "no helper wait is renewed past 8 s: \(clock.requestedDeadlines.map { $0 - clock.instant(at: .zero) })"
        )
        let failure = recorder.presented.last
        XCTAssertEqual(failure?.stage, .preparation)
        XCTAssertEqual(failure?.timedOut, true)
        XCTAssertEqual(failure?.relaunchHelperUnresolved, false, "arm was never sent")
        XCTAssertEqual(failure?.offeredChoices, [.retry, .cancel])
        XCTAssertTrue(
            failure?.messages.last?.hasPrefix(ProcessRelaunchParentSession.stopUnresolvedText) == true,
            String(describing: failure?.messages)
        )
        XCTAssertTrue(driver.retainsHelper, "signal delivery is not exit proof: ownership retained")
        XCTAssertGreaterThanOrEqual(silent.terminateCount, 1)
        XCTAssertEqual(driver.spawnCount, 1)
        XCTAssertEqual(replies, [])

        recorder.choose(.cancel)
        await waitUntil("the cancelled reply") { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(participant.isFrozen)
        XCTAssertTrue(driver.retainsHelper, "still retained until its stop is proven")
        XCTAssertEqual(driver.spawnCount, 1, "no fresh helper")
    }

    /// Review B P2-2: the real relaunch driver over a helper channel that answers `ready` but never
    /// `armed` and never exits (no process). R4's deadline and the driver's `armed` wait share the
    /// work expiry, so the Stage B timeout lands while `arm` is in flight; the driver's `abandon`
    /// reports `.unresolved` (arm sent), so the admitted prompt is honest, and the explicit exit
    /// completes once while the driver keeps owning the helper (no fresh helper, frame, or kill).
    func testSafeRestartComposedLostArmAcknowledgementOffersAnHonestExitAndTheDriverKeepsTheHelper() async throws {
        let participant = FakeParticipant()
        appParticipants = [participant]
        let clock = try XCTUnwrap(clock)
        let readyOnly = SilentRelaunchChannel { message in
            if case let .prepare(id, _, _) = message { return .ready(correlationID: id) }
            return nil
        }
        defer { readyOnly.exit() }
        let bootSessionID = try XCTUnwrap(UUID(uuidString: "0A0B0C0D-1111-4222-8333-944455556666"))
        let identity = ProcessRelaunchParentIdentity(
            pid: 4242,
            bootSessionID: bootSessionID,
            startSeconds: 10,
            startMicroseconds: 20,
            uid: 501
        )
        let driver = AppRelaunchCoordinator(dependencies: AppRelaunchCoordinator.Dependencies(
            spawnHelper: { readyOnly.channel },
            parentIdentity: { identity },
            bundlePath: "/Apps/RepoPrompt CE.app",
            verifyAllStopped: { .allStopped },
            sleep: { duration in try? await clock.sleep(until: clock.now + duration) },
            now: { clock.now }
        ))
        let coordinator = makeCoordinator(relaunch: driver.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .safeRestart) { replies.append($0) })
        await waitUntil("prepare and arm sent") { readyOnly.frameCount == 2 }
        let request = try XCTUnwrap(coordinator.applicationRequest)
        XCTAssertNotNil(request.relaunchArmSafetyProof, "recorded before arm")

        // Advance only to deadlines that are actually awaited, never past the attempt's 8 s.
        let finalExpiry = clock.instant(at: .seconds(8))
        for _ in 0 ..< 20 {
            await settle()
            if recorder.isPresenting { break }
            if let next = clock.nextPendingDeadline, next <= finalExpiry {
                clock.advance(by: next - clock.now)
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        await waitUntil("the admitted prompt") { recorder.isPresenting }
        XCTAssertLessThanOrEqual(clock.now, finalExpiry, "the prompt appears by the final expiry")
        let failure = try XCTUnwrap(recorder.presented.last)
        XCTAssertEqual(failure.stage, .finalization)
        XCTAssertTrue(failure.timedOut)
        XCTAssertEqual(failure.offeredChoices, [.exitMayReopen])
        XCTAssertEqual(failure.messages.first, AgentLifecycleShutdownCoordinator.restartArmUnconfirmedMessage)
        XCTAssertFalse(failure.messages.contains(AgentLifecycleShutdownCoordinator.restartTimeoutMessage))
        assertHonestUncertainExitAlert(failure)
        XCTAssertTrue(driver.retainsHelper, "arm sent, stop unproven: ownership retained")
        XCTAssertEqual(driver.spawnCount, 1)
        let frames = readyOnly.frameCount
        let kills = readyOnly.terminateCount

        recorder.choose(.exitMayReopen)
        await waitUntil("the exit reply") { replies == [true] }
        await settle()
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(request.relaunchUncertainExits, 1)
        XCTAssertFalse(request.relaunchArmed)
        XCTAssertTrue(driver.retainsHelper, "the exit never claims or forces the helper's stop")
        XCTAssertEqual(driver.spawnCount, 1, "no fresh helper")
        XCTAssertEqual(readyOnly.frameCount, frames, "no further frame")
        XCTAssertEqual(readyOnly.terminateCount, kills, "no further kill request")
        XCTAssertEqual(participant.finalizeCalls, 1)
    }

    /// A plain app quit never consults the relaunch hooks, even when they are composed: its Stage B
    /// prompt keeps Retry / Quit Anyway and never offers or records the uncertain exit.
    func testPlainQuitWithComposedRelaunchHooksNeverOffersTheUncertainExit() async {
        let participant = FakeParticipant()
        participant.finalizeResults = [AgentModeShutdownReport(blockers: ["Session A could not be saved."])]
        appParticipants = [participant]
        let relaunch = FakeRelaunch()
        relaunch.abandonResults = [.unresolved(Self.unresolvedStopText)]
        let coordinator = makeCoordinator(relaunch: relaunch.hooks)
        var replies: [Bool] = []
        XCTAssertTrue(coordinator.requestApplicationQuit(reason: .appQuit) { replies.append($0) })
        await waitUntil("the Stage B prompt") { recorder.isPresenting }
        XCTAssertEqual(recorder.presented.last?.offeredChoices, [.retry, .proceedAnyway])
        XCTAssertEqual(recorder.presented.last?.offersUncertainRelaunchExit, false)
        XCTAssertNil(coordinator.applicationRequest?.relaunchArmSafetyProof)
        XCTAssertEqual(relaunch.calls, [], "no hook, abandon included")
        recorder.choose(.exitMayReopen)
        await waitUntil("the rejected exit shows the prompt again") { recorder.presented.count == 2 && recorder.isPresenting }
        XCTAssertEqual(coordinator.applicationRequest?.rejectedUncertainExitAnswers, 1)
        recorder.choose(.proceedAnyway)
        await waitUntil("the ordinary Quit Anyway") { replies == [true] }
        XCTAssertEqual(coordinator.applicationRequest?.relaunchUncertainExits, 0)
    }

    // MARK: Close authorization

    func testFinalizedCloseAuthorizationIsOneShot() {
        let closeCoordinator = WindowCloseCoordinator()
        XCTAssertFalse(closeCoordinator.consumeFinalizedCloseAuthorization())
        closeCoordinator.authorizeFinalizedClose()
        XCTAssertTrue(closeCoordinator.consumeFinalizedCloseAuthorization())
        XCTAssertFalse(closeCoordinator.consumeFinalizedCloseAuthorization(), "a later close asks again")
    }
}
