import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import XCTest

/// Lossless restart Phase 4 §G: the App relaunch driver over injected spawn, identity, proof and
/// helper channels. No process is spawned and nothing is opened.
@MainActor
final class AppRelaunchCoordinatorTests: XCTestCase {
    private var sleeper: AppRelaunchTestSleeper!
    private var channels: [ScriptedRelaunchChannel] = []

    override func setUp() async throws {
        sleeper = AppRelaunchTestSleeper()
        channels = []
    }

    override func tearDown() async throws {
        channels.forEach { $0.exit() }
        sleeper?.releaseAll()
        channels = []
    }

    private static let identity = ProcessRelaunchParentIdentity(
        pid: 4242,
        bootSessionID: UUID(uuidString: "0A0B0C0D-1111-4222-8333-944455556666")!,
        startSeconds: 10,
        startMicroseconds: 20,
        uid: 501
    )

    private static let cooperative: @Sendable (ProcessRelaunchMessage) -> ProcessRelaunchMessage? = { message in
        switch message {
        case let .prepare(id, _, _): .ready(correlationID: id)
        case let .arm(id): .armed(correlationID: id)
        case let .abort(id): .aborted(correlationID: id)
        default: nil
        }
    }

    private func makeCoordinator(
        identity: ProcessRelaunchParentIdentity? = AppRelaunchCoordinatorTests.identity,
        spawnFails: Bool = false,
        exitsOnTerminate: Bool = true,
        proof: @escaping @MainActor () -> AgentRuntimeAllStoppedProof = { .allStopped },
        respond: @escaping @Sendable (ProcessRelaunchMessage) -> ProcessRelaunchMessage? = AppRelaunchCoordinatorTests.cooperative
    ) -> AppRelaunchCoordinator {
        AppRelaunchCoordinator(dependencies: AppRelaunchCoordinator.Dependencies(
            spawnHelper: { [unowned self] in
                if spawnFails { throw CocoaError(.executableNotLoadable) }
                let channel = ScriptedRelaunchChannel(exitsOnTerminate: exitsOnTerminate, respond: respond)
                channels.append(channel)
                return channel.channel
            },
            parentIdentity: { identity },
            bundlePath: "/Apps/RepoPrompt CE.app",
            verifyAllStopped: { proof() },
            sleep: sleeper.sleep,
            now: sleeper.now
        ))
    }

    /// An R4 attempt's absolute budget: `work` from now, every stop by the cleanup reserve after it.
    private func budget(_ work: Duration) -> AgentLifecycleRelaunchBudget {
        let now = sleeper.now()
        return AgentLifecycleRelaunchBudget(
            workExpiry: now + work,
            cleanupExpiry: now + work + ProcessRelaunchLimits.v1.cleanupReserve
        )
    }

    func testEachPrepareSpawnsAFreshHelperAndAbandonsThePreviousOne() async {
        let coordinator = makeCoordinator()
        let hooks = coordinator.hooks
        let first = await hooks.prepare(budget(.seconds(8)))
        XCTAssertNil(first)
        let second = await hooks.prepare(budget(.seconds(8)))
        XCTAssertNil(second)
        XCTAssertEqual(coordinator.spawnCount, 2)
        XCTAssertEqual(channels.map(\.receivedTypes), [["prepare", "abort"], ["prepare"]])
        guard case let .prepare(_, parent, bundle) = channels.first?.received.first else { return XCTFail("expected prepare") }
        XCTAssertEqual(parent, Self.identity)
        XCTAssertEqual(bundle, "/Apps/RepoPrompt CE.app")
    }

    func testMissingIdentityOrSpawnFailureNeverPrepares() async {
        let anonymousCoordinator = makeCoordinator(identity: nil)
        let anonymous = await anonymousCoordinator.hooks.prepare(budget(.seconds(8)))
        XCTAssertEqual(anonymous, AppRelaunchCoordinator.identityUnavailableMessage)
        XCTAssertEqual(anonymousCoordinator.spawnCount, 0)
        let unspawnable = makeCoordinator(spawnFails: true)
        let failed = await unspawnable.hooks.prepare(budget(.seconds(8)))
        XCTAssertEqual(failed, AppRelaunchCoordinator.helperUnavailableMessage)
        XCTAssertEqual(unspawnable.spawnCount, 0)
        XCTAssertTrue(channels.isEmpty)
    }

    func testVerifyAllStoppedMapsTheRegistryProof() async {
        var proof = AgentRuntimeAllStoppedProof.notProven("A Claude runtime is still running.")
        let coordinator = makeCoordinator(proof: { proof })
        let blocked = await coordinator.hooks.verifyAllStopped()
        XCTAssertEqual(blocked, "A Claude runtime is still running.")
        proof = .allStopped
        let proven = await coordinator.hooks.verifyAllStopped()
        XCTAssertNil(proven)
    }

    func testArmRequiresAReadyHelperAndAbandonLeavesNothingArmed() async {
        let coordinator = makeCoordinator()
        let hooks = coordinator.hooks
        let unprepared = await hooks.arm(budget(.seconds(2)))
        XCTAssertEqual(unprepared, "The restart helper is not ready.")
        let prepared = await hooks.prepare(budget(.seconds(8)))
        XCTAssertNil(prepared)
        let armed = await hooks.arm(budget(.seconds(2)))
        XCTAssertNil(armed)
        let abandoned = await hooks.abandon()
        XCTAssertEqual(abandoned, .safe, "a correlated aborted is proof")
        XCTAssertEqual(channels.map(\.receivedTypes), [["prepare", "arm", "abort"]])
        let rearmed = await hooks.arm(budget(.seconds(2)))
        XCTAssertEqual(rearmed, "The restart helper is not ready.", "an abandoned helper is never reused")
        let empty = await hooks.abandon()
        XCTAssertEqual(empty, .safe)
        XCTAssertEqual(channels.first?.receivedTypes.count, 3, "abandon without a helper does nothing")
    }

    func testRefusedPrepareDropsTheHelperAndRetryUsesAFreshOne() async {
        let refusing = AppRelaunchRefusals(count: 1)
        let coordinator = makeCoordinator { message in
            switch message {
            case let .prepare(id, _, _) where refusing.consume():
                .failed(correlationID: id, reason: "The helper is not inside the prepared application bundle.")
            default:
                AppRelaunchCoordinatorTests.cooperative(message)
            }
        }
        let hooks = coordinator.hooks
        let refused = await hooks.prepare(budget(.seconds(8)))
        XCTAssertEqual(refused, "The helper is not inside the prepared application bundle.")
        let notReady = await hooks.arm(budget(.seconds(2)))
        XCTAssertEqual(notReady, "The restart helper is not ready.")
        let retried = await hooks.prepare(budget(.seconds(8)))
        XCTAssertNil(retried)
        XCTAssertEqual(coordinator.spawnCount, 2)
        XCTAssertEqual(channels.map(\.receivedTypes), [["prepare", "abort"], ["prepare"]])
    }

    func testLostArmAcknowledgementIsResolvedBeforeTheHookReturns() async {
        let coordinator = makeCoordinator { message in
            switch message {
            case .arm: nil
            default: AppRelaunchCoordinatorTests.cooperative(message)
            }
        }
        let hooks = coordinator.hooks
        _ = await hooks.prepare(budget(.seconds(8)))
        let arm = Task { await hooks.arm(budget(.seconds(2))) }
        await sleeper.waitForPending(.seconds(2))
        sleeper.fire(.seconds(2))
        let result = await arm.value
        XCTAssertEqual(result, "The relaunch helper did not confirm it was armed.")
        XCTAssertEqual(channels.first?.receivedTypes, ["prepare", "arm", "abort"], "aborted before any choice")
    }

    /// Review A P1-07: a lost arm acknowledgement whose stop is not proven (no `aborted`, kill
    /// signalled but the exact child's exit not observed) leaves the helper retained. `abandon`
    /// reports it unresolved within what is left of the budget, and no fresh helper is spawned.
    func testUnresolvedLostArmRetainsTheHelperAndRefusesAFreshOne() async {
        let coordinator = makeCoordinator(exitsOnTerminate: false) { message in
            switch message {
            case let .prepare(id, _, _): .ready(correlationID: id)
            default: nil
            }
        }
        let hooks = coordinator.hooks
        let prepared = await hooks.prepare(budget(.seconds(8)))
        XCTAssertNil(prepared)
        let arm = Task { await hooks.arm(budget(.seconds(2))) }
        await sleeper.waitForPending(.seconds(2))
        sleeper.fire(.seconds(2))
        await sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        let armResult = await arm.value
        XCTAssertNotNil(armResult)
        XCTAssertTrue(coordinator.retainsHelper, "ownership retained while the helper may be armed")

        let abandon = Task { await hooks.abandon() }
        await sleeper.waitForPending(.zero)
        XCTAssertEqual(sleeper.pending(ProcessRelaunchLimits.v1.abortAcknowledgement), 0, "no renewed budget")
        sleeper.fire(.zero)
        await sleeper.waitForPending(.zero)
        sleeper.fire(.zero)
        guard case .unresolved = await abandon.value else { return XCTFail("expected unresolved abandon") }
        XCTAssertTrue(coordinator.retainsHelper)

        let retry = Task { await hooks.prepare(budget(.seconds(8))) }
        await sleeper.waitForPending(.zero)
        sleeper.fire(.zero)
        await sleeper.waitForPending(.zero)
        sleeper.fire(.zero)
        let retried = await retry.value
        XCTAssertNotNil(retried, "no fresh helper while the earlier one is unresolved")
        XCTAssertEqual(coordinator.spawnCount, 1)
        XCTAssertEqual(channels.count, 1)

        // The exact child's exit observed later is proof: ownership is released.
        channels.first?.exit()
        let released = await hooks.abandon()
        XCTAssertEqual(released, .safe)
        XCTAssertFalse(coordinator.retainsHelper)
    }

    /// A prepared helper whose `arm` was sent, its acknowledgement lost, and its stop unresolved
    /// (kill signalled, exit not observed): retained by the driver.
    private func unresolvedArmedHelper() async -> (AppRelaunchCoordinator, AgentLifecycleRelaunchHooks) {
        let coordinator = makeCoordinator(exitsOnTerminate: false, respond: { message in
            switch message {
            case let .prepare(id, _, _): .ready(correlationID: id)
            default: nil
            }
        })
        let hooks = coordinator.hooks
        _ = await hooks.prepare(budget(.seconds(8)))
        let arm = Task { await hooks.arm(budget(.seconds(2))) }
        await sleeper.waitForPending(.seconds(2))
        sleeper.fire(.seconds(2))
        await sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        _ = await arm.value
        XCTAssertTrue(coordinator.retainsHelper)
        return (coordinator, hooks)
    }

    /// Step 4b: the retained (arm-sent) helper's exact exit observed later releases exactly that
    /// helper through the observation: no frame, kill, fresh helper, or arm follows. A duplicate
    /// observation finds nothing; only a later explicit prepare (Retry) spawns a fresh helper.
    func testObservedExitOfTheRetainedArmedHelperReleasesOnlyThatHelperWithoutSpawning() async {
        let (coordinator, hooks) = await unresolvedArmedHelper()
        let framesBefore = channels.first?.receivedTypes
        XCTAssertEqual(framesBefore, ["prepare", "arm", "abort"])
        let observation = Task { await hooks.awaitRetainedHelperStop() }
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        XCTAssertTrue(coordinator.retainsHelper, "a delivered signal is not proof")

        channels.first?.exit()
        let released = await observation.value
        XCTAssertTrue(released)
        XCTAssertFalse(coordinator.retainsHelper, "the exact retained helper is released")
        XCTAssertEqual(channels.first?.receivedTypes, framesBefore, "nothing is sent to the stopped helper")
        XCTAssertEqual(coordinator.spawnCount, 1, "the notification never spawns a helper")

        let duplicate = await hooks.awaitRetainedHelperStop()
        XCTAssertFalse(duplicate, "a duplicate observation has nothing to release")

        let retried = await hooks.prepare(budget(.seconds(8)))
        XCTAssertNil(retried, "an explicit prepare after the proof may use a fresh helper")
        XCTAssertEqual(coordinator.spawnCount, 2)
    }

    /// Step 4b: a cancelled observation reports nothing and keeps the helper retained; with no
    /// retained helper there is nothing to observe.
    func testCancelledObservationKeepsTheRetainedHelper() async {
        let idle = makeCoordinator()
        let none = await idle.hooks.awaitRetainedHelperStop()
        XCTAssertFalse(none)

        let (coordinator, hooks) = await unresolvedArmedHelper()
        let observation = Task { await hooks.awaitRetainedHelperStop() }
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        observation.cancel()
        let released = await observation.value
        XCTAssertFalse(released)
        XCTAssertTrue(coordinator.retainsHelper, "cancellation never releases an unproven helper")
        let retry = Task { await hooks.prepare(budget(.seconds(8))) }
        await sleeper.waitForPending(.zero)
        sleeper.fire(.zero)
        await sleeper.waitForPending(.zero)
        sleeper.fire(.zero)
        let refused = await retry.value
        XCTAssertNotNil(refused, "still no fresh helper")
        XCTAssertEqual(coordinator.spawnCount, 1)
    }

    /// Review R1 B N3: a ready helper whose stop is unproven but that was never sent `arm` (so it
    /// can never open anything) is `.unresolvedUnarmed`. It stays retained: Retry spawns no fresh
    /// helper and the retained one is never armed.
    func testUnresolvedStopOfANeverArmedHelperIsUnarmedAndStillRetained() async {
        let coordinator = makeCoordinator(exitsOnTerminate: false) { message in
            switch message {
            case let .prepare(id, _, _): .ready(correlationID: id)
            default: nil
            }
        }
        let hooks = coordinator.hooks
        let prepared = await hooks.prepare(budget(.seconds(8)))
        XCTAssertNil(prepared)
        let abandon = Task { await hooks.abandon() }
        await sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        guard case .unresolvedUnarmed = await abandon.value else { return XCTFail("expected an unresolved, never-armed stop") }
        XCTAssertTrue(coordinator.retainsHelper)

        let retry = Task { await hooks.prepare(budget(.seconds(8))) }
        await sleeper.waitForPending(.zero)
        sleeper.fire(.zero)
        await sleeper.waitForPending(.zero)
        sleeper.fire(.zero)
        let retried = await retry.value
        XCTAssertNotNil(retried, "no fresh helper while the earlier one is unresolved")
        XCTAssertEqual(coordinator.spawnCount, 1)
        let armed = await hooks.arm(budget(.seconds(2)))
        XCTAssertNotNil(armed, "an unresolved helper is never armed")
        XCTAssertEqual(channels.first?.receivedTypes, ["prepare", "abort", "abort"], "no arm frame was ever sent")
    }

    func testProductionCompositionStaysOff() {
        XCTAssertFalse(AgentRecoveryActivation.production.actions.safeRestart)
        XCTAssertFalse(AgentRecoveryActivation.claudeAndCodex.actions.safeRestart, "subset registration can't prove unregistered families stopped")
        XCTAssertNil(AppRelaunchCoordinator.production())
        XCTAssertNil(AppRelaunchCoordinator.production(qualification: AgentRecoveryActionQualification(safeRestart: true), registry: nil))
    }
}

// MARK: - Fixtures

private final class AppRelaunchRefusals: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(count: Int) {
        remaining = count
    }

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// Injected clock for the parent session's timers: suspends until fired or released.
private final class AppRelaunchTestSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(Duration, CheckedContinuation<Void, Never>)] = []
    private let origin = ContinuousClock.now
    private var elapsed: Duration = .zero

    /// Monotonic clock that advances only when a sleep is fired (by that duration).
    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return origin + elapsed
        }
    }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in
            await withCheckedContinuation { continuation in
                lock.lock()
                waiters.append((duration, continuation))
                lock.unlock()
            }
        }
    }

    func pending(_ duration: Duration) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count { $0.0 == duration }
    }

    func waitForPending(_ duration: Duration, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 2000 {
            if pending(duration) > 0 { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("no pending sleep of \(duration)", file: file, line: line)
    }

    func fire(_ duration: Duration) {
        lock.lock()
        elapsed += duration
        let matched = waiters.filter { $0.0 == duration }
        waiters.removeAll { $0.0 == duration }
        lock.unlock()
        matched.forEach { $0.1.resume() }
    }

    func releaseAll() {
        lock.lock()
        let all = waiters
        waiters = []
        lock.unlock()
        all.forEach { $0.1.resume() }
    }
}

/// A scripted helper behind one channel: `respond` maps each frame the parent sends to a reply.
private final class ScriptedRelaunchChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ProcessRelaunchMessage] = []
    private var exited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private let continuation: AsyncStream<ProcessRelaunchInbound>.Continuation
    private(set) var channel: ProcessRelaunchHelperChannel!

    init(
        exitsOnTerminate: Bool = true,
        respond: @escaping @Sendable (ProcessRelaunchMessage) -> ProcessRelaunchMessage?
    ) {
        let (inbound, continuation) = AsyncStream<ProcessRelaunchInbound>.makeStream()
        self.continuation = continuation
        channel = ProcessRelaunchHelperChannel(
            send: { [self] data in
                guard let message = try? ProcessRelaunchCodec.decode(data.dropLast()) else { return false }
                lock.lock()
                messages.append(message)
                lock.unlock()
                if let reply = respond(message) { continuation.yield(.message(reply)) }
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
                if exitsOnTerminate { exit() }
                return .signalSent
            }
        )
    }

    var received: [ProcessRelaunchMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    var receivedTypes: [String] {
        received.map { message in
            switch message {
            case .prepare: "prepare"
            case .ready: "ready"
            case .arm: "arm"
            case .armed: "armed"
            case .abort: "abort"
            case .aborted: "aborted"
            case .failed: "failed"
            }
        }
    }

    func exit() {
        lock.lock()
        exited = true
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
        continuation.finish()
    }
}
