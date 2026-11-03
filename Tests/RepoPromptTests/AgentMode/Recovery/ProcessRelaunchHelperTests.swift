import Darwin
import Foundation
@testable import RepoPromptPlatform
import XCTest

/// Lossless restart Phase 4 §G: the closed v1 relaunch protocol and both state machines, driven only
/// through injected inspection, exit watch, open, clock and channel. Nothing is spawned or opened.
final class ProcessRelaunchHelperTests: XCTestCase {
    // MARK: Invocation

    func testClassifyKeepsOrdinaryMCPAndRejectsEveryOtherReservedForm() {
        XCTAssertEqual(ProcessRelaunchInvocation.classify([]), .ordinary)
        XCTAssertEqual(ProcessRelaunchInvocation.classify(["--stdio", "--verbose"]), .ordinary)
        XCTAssertEqual(ProcessRelaunchInvocation.classify(["--rpce-private-relaunch-v1"]), .relaunchV1)
        for invalid in [
            ["--rpce-private-relaunch-v2"],
            ["--rpce-private-relaunch-"],
            ["--rpce-private-relaunch"],
            ["--rpce-private-relaunchv1"],
            ["--rpce-private-relaunch-v1=1"],
            ["--rpce-private-relaunch-v1", "--stdio"],
            ["--stdio", "--rpce-private-relaunch-v1"],
            ["--rpce-private-relaunch-v1", "--rpce-private-relaunch-v1"]
        ] {
            guard case .invalid = ProcessRelaunchInvocation.classify(invalid) else {
                return XCTFail("expected invalid for \(invalid)")
            }
        }
    }

    // MARK: Codec

    func testCodecRoundTripsEveryMessage() throws {
        let id = UUID()
        let messages: [ProcessRelaunchMessage] = [
            .prepare(correlationID: id, parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle),
            .ready(correlationID: id),
            .arm(correlationID: id),
            .armed(correlationID: id),
            .abort(correlationID: id),
            .aborted(correlationID: id),
            .failed(correlationID: id, reason: "nope"),
            .failed(correlationID: nil, reason: "no id")
        ]
        for message in messages {
            let frame = try ProcessRelaunchCodec.encode(message)
            XCTAssertEqual(frame.last, UInt8(ascii: "\n"))
            XCTAssertEqual(try ProcessRelaunchCodec.decode(frame.dropLast()), message)
        }
    }

    func testCodecTruncatesLongFailureReasonsOnEncode() throws {
        let frame = try ProcessRelaunchCodec.encode(.failed(correlationID: nil, reason: String(repeating: "x", count: 2000)))
        guard case let .failed(_, reason) = try ProcessRelaunchCodec.decode(frame.dropLast()) else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(reason.count, ProcessRelaunchCodec.maximumReasonCharacters)
    }

    func testCodecRejectsVersionsMembersTypesAndValues() {
        let id = UUID().uuidString
        let parent = #"{"boot":"\#(RelaunchFixture.boot.uuidString)","pid":100,"startMicroseconds":5,"startSeconds":7,"uid":501}"#
        let zeroPID = parent.replacingOccurrences(of: #""pid":100"#, with: #""pid":0"#)
        let negativeUID = parent.replacingOccurrences(of: #""uid":501"#, with: #""uid":-1"#)
        let fractionalStart = parent.replacingOccurrences(of: #""startSeconds":7"#, with: #""startSeconds":7.5"#)
        let extraMember = parent.replacingOccurrences(of: "}", with: #","x":1}"#)
        let longReason = String(repeating: "r", count: 513)
        let rejected = [
            #"[]"#,
            #"not json"#,
            #"{"type":"ready","id":"\#(id)"}"#,
            #"{"v":2,"type":"ready","id":"\#(id)"}"#,
            #"{"v":1.5,"type":"ready","id":"\#(id)"}"#,
            #"{"v":true,"type":"ready","id":"\#(id)"}"#,
            #"{"v":1,"type":"ready"}"#,
            #"{"v":1,"type":"ready","id":"not-a-uuid"}"#,
            #"{"v":1,"type":"ready","id":"\#(id)","extra":1}"#,
            #"{"v":1,"type":"launch","id":"\#(id)"}"#,
            #"{"v":1,"type":"failed","id":"\#(id)"}"#,
            #"{"v":1,"type":"failed","reason":"\#(longReason)"}"#,
            #"{"v":1,"type":"prepare","id":"\#(id)","parent":\#(parent)}"#,
            #"{"v":1,"type":"prepare","id":"\#(id)","parent":\#(parent),"bundle":""}"#,
            #"{"v":1,"type":"prepare","id":"\#(id)","parent":{"pid":100},"bundle":"/A.app"}"#,
            #"{"v":1,"type":"prepare","id":"\#(id)","parent":\#(zeroPID),"bundle":"/A.app"}"#,
            #"{"v":1,"type":"prepare","id":"\#(id)","parent":\#(negativeUID),"bundle":"/A.app"}"#,
            #"{"v":1,"type":"prepare","id":"\#(id)","parent":\#(fractionalStart),"bundle":"/A.app"}"#,
            #"{"v":1,"type":"prepare","id":"\#(id)","parent":\#(extraMember),"bundle":"/A.app"}"#
        ]
        for text in rejected {
            XCTAssertThrowsError(try ProcessRelaunchCodec.decode(Data(text.utf8)), text)
        }
        XCTAssertNoThrow(try ProcessRelaunchCodec.decode(Data(#"{"v":1,"type":"prepare","id":"\#(id)","parent":\#(parent),"bundle":"/A.app"}"#.utf8)))
        XCTAssertEqual(
            try? ProcessRelaunchCodec.decode(Data(repeating: UInt8(ascii: " "), count: ProcessRelaunchCodec.maximumFrameBytes + 1)),
            nil
        )
        XCTAssertThrowsError(
            try ProcessRelaunchCodec.encode(.prepare(
                correlationID: UUID(),
                parent: RelaunchFixture.parent,
                bundlePath: "/" + String(repeating: "a", count: ProcessRelaunchCodec.maximumFrameBytes) + ".app"
            ))
        ) { XCTAssertEqual($0 as? ProcessRelaunchCodecError, .frameTooLarge) }
    }

    // MARK: Frame decoder

    func testFrameDecoderSplitsFramesAcrossChunksAndReportsCleanEOF() throws {
        let id = UUID()
        let bytes = try ProcessRelaunchCodec.encode(.ready(correlationID: id)) + ProcessRelaunchCodec.encode(.armed(correlationID: id))
        var decoder = ProcessRelaunchFrameDecoder()
        var events: [ProcessRelaunchInbound] = []
        for byte in bytes {
            events += decoder.append(Data([byte]))
        }
        XCTAssertEqual(events, [.message(.ready(correlationID: id)), .message(.armed(correlationID: id))])
        XCTAssertEqual(decoder.finish(), .endOfInput)
    }

    func testFrameDecoderPoisonsOnMalformedOversizedOrIncompleteInput() throws {
        var malformed = ProcessRelaunchFrameDecoder()
        let events = try malformed.append(Data("garbage\n".utf8) + ProcessRelaunchCodec.encode(.ready(correlationID: UUID())))
        XCTAssertEqual(events.count, 1)
        guard case .violation = events.first else { return XCTFail("expected violation") }
        XCTAssertTrue(malformed.isPoisoned)
        XCTAssertEqual(try malformed.append(ProcessRelaunchCodec.encode(.ready(correlationID: UUID()))), [])

        var oversized = ProcessRelaunchFrameDecoder()
        let tail = oversized.append(Data(repeating: UInt8(ascii: "a"), count: ProcessRelaunchCodec.maximumFrameBytes + 1))
        XCTAssertEqual(tail, [.violation("frame too large")])

        var incomplete = ProcessRelaunchFrameDecoder()
        XCTAssertEqual(incomplete.append(Data(#"{"v":1"#.utf8)), [])
        guard case .violation = incomplete.finish() else { return XCTFail("expected violation") }
    }

    // MARK: Helper session

    func testArmedHelperIgnoresEOFAndOpensTheExactBundleOnceAfterVerifiedParentExit() async throws {
        let harness = HelperHarness()
        let run = harness.start()
        let id = UUID()
        harness.yield(.message(.prepare(correlationID: id, parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle)))
        await harness.waitForSent(.ready(correlationID: id))
        XCTAssertEqual(harness.watch.watchedPIDs, [RelaunchFixture.parent.pid])
        harness.yield(.message(.arm(correlationID: id)))
        await harness.waitForSent(.armed(correlationID: id))
        harness.yield(.endOfInput)
        harness.finishInput()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(harness.opener.urls, [], "EOF is never parent-exit proof")

        harness.inspection.set(.notFound)
        harness.watch.fire()
        harness.watch.fire()
        let outcome = await run.value
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(harness.opener.urls.map(\.path), [RelaunchFixture.bundle])
        let opens = await harness.session.openCount
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(harness.watch.isCancelled)
    }

    func testAbortBeforeOrAfterArmEndsWithZeroOpens() async {
        for armFirst in [false, true] {
            let harness = HelperHarness()
            let run = harness.start()
            let id = UUID()
            harness.yield(.message(.prepare(correlationID: id, parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle)))
            await harness.waitForSent(.ready(correlationID: id))
            if armFirst {
                harness.yield(.message(.arm(correlationID: id)))
                await harness.waitForSent(.armed(correlationID: id))
            }
            harness.yield(.message(.abort(correlationID: id)))
            let outcome = await run.value
            XCTAssertEqual(outcome, .aborted)
            XCTAssertTrue(harness.sent.contains(.aborted(correlationID: id)))
            harness.inspection.set(.notFound)
            harness.watch.fire()
            try? await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(harness.opener.urls, [])
        }
    }

    func testUnverifiableParentExitOpensNothing() async {
        let harness = HelperHarness()
        let run = harness.start()
        let id = await harness.prepareAndArm()
        harness.inspection.set(.unavailable(ProcessInspectionFailure(operation: .basicInfo, reason: .accessDenied)))
        harness.watch.fire()
        let outcome = await run.value
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(harness.opener.urls, [])
        XCTAssertTrue(harness.sent.contains(.armed(correlationID: id)))
    }

    func testReusedPIDOrSameLifetimeZombieCountsAsExactParentExit() {
        let parent = RelaunchFixture.parent
        XCTAssertTrue(ProcessRelaunchHelperSession.isVerifiedExit(of: parent, inspection: .notFound))
        XCTAssertTrue(ProcessRelaunchHelperSession.isVerifiedExit(of: parent, inspection: .observed(RelaunchFixture.observation(startSeconds: 99))))
        XCTAssertTrue(ProcessRelaunchHelperSession.isVerifiedExit(of: parent, inspection: .observed(RelaunchFixture.observation(isZombie: true))))
        XCTAssertFalse(ProcessRelaunchHelperSession.isVerifiedExit(of: parent, inspection: .observed(RelaunchFixture.observation())))
        XCTAssertFalse(ProcessRelaunchHelperSession.isVerifiedExit(
            of: parent,
            inspection: .unavailable(ProcessInspectionFailure(operation: .basicInfo, reason: .malformedResponse))
        ))
    }

    func testParentExitDeadlineAndReadyDeadlineOpenNothing() async {
        let armed = HelperHarness()
        let armedRun = armed.start()
        _ = await armed.prepareAndArm()
        await armed.sleeper.waitForPending(.seconds(15))
        armed.sleeper.fire(.seconds(15))
        guard case .failed = await armedRun.value else { return XCTFail("expected failed") }
        XCTAssertEqual(armed.opener.urls, [])

        let idle = HelperHarness()
        let idleRun = idle.start()
        await idle.sleeper.waitForPending(.seconds(8))
        idle.sleeper.fire(.seconds(8))
        guard case .failed = await idleRun.value else { return XCTFail("expected failed") }
        guard let last = idle.sent.last, case let .failed(failedID, _) = last else { return XCTFail("expected failed frame") }
        XCTAssertNil(failedID, "no prepare arrived, so the failure is uncorrelated")

        // A ready helper that is never armed expires (review A P2-01) and opens nothing.
        let ready = HelperHarness()
        let readyRun = ready.start()
        let id = UUID()
        ready.yield(.message(.prepare(correlationID: id, parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle)))
        await ready.waitForSent(.ready(correlationID: id))
        await ready.sleeper.waitForPending(.seconds(8))
        ready.sleeper.fire(.seconds(8))
        guard case .failed = await readyRun.value else { return XCTFail("expected an expired ready helper to fail") }
        XCTAssertEqual(ready.opener.urls, [])
    }

    func testPrepareRejectsWrongParentUserLifetimeZombieOrBundle() async {
        let cases: [(String, (HelperHarness) -> ProcessRelaunchParentIdentity, String)] = [
            ("not our parent", { _ in RelaunchFixture.identity(pid: 999) }, RelaunchFixture.bundle),
            ("other user", { _ in RelaunchFixture.identity(uid: 0) }, RelaunchFixture.bundle),
            ("other lifetime", { _ in RelaunchFixture.identity(startSeconds: 1) }, RelaunchFixture.bundle),
            ("zombie", { harness in
                harness.inspection.set(.observed(RelaunchFixture.observation(isZombie: true)))
                return RelaunchFixture.parent
            }, RelaunchFixture.bundle),
            ("relative bundle", { _ in RelaunchFixture.parent }, "Apps/RepoPrompt CE.app"),
            ("not an app", { _ in RelaunchFixture.parent }, "/Apps/RepoPrompt CE"),
            ("other bundle", { _ in RelaunchFixture.parent }, "/Apps/Other.app")
        ]
        for (label, identity, bundle) in cases {
            let harness = HelperHarness()
            let run = harness.start()
            let id = UUID()
            harness.yield(.message(.prepare(correlationID: id, parent: identity(harness), bundlePath: bundle)))
            guard case .failed = await run.value else { return XCTFail("expected failed for \(label)") }
            guard let last = harness.sent.last, case let .failed(failedID, _) = last else {
                return XCTFail("expected failed frame for \(label)")
            }
            XCTAssertEqual(failedID, id, label)
            XCTAssertFalse(harness.sent.contains(.ready(correlationID: id)), label)
            XCTAssertEqual(harness.watch.watchedPIDs, [], label)
            XCTAssertEqual(harness.opener.urls, [], label)
        }
    }

    func testParentGoneAfterWatchInstallFailsBeforeReady() async {
        let harness = HelperHarness()
        harness.watch.onInstall = { harness.inspection.set(.notFound) }
        let run = harness.start()
        let id = UUID()
        harness.yield(.message(.prepare(correlationID: id, parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle)))
        guard case .failed = await run.value else { return XCTFail("expected failed") }
        XCTAssertFalse(harness.sent.contains(.ready(correlationID: id)))
        XCTAssertTrue(harness.watch.isCancelled)
    }

    func testParentExitBeforeArmMismatchedIDAndViolationsOpenNothing() async {
        let early = HelperHarness()
        let earlyRun = early.start()
        let id = UUID()
        early.yield(.message(.prepare(correlationID: id, parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle)))
        await early.waitForSent(.ready(correlationID: id))
        early.inspection.set(.notFound)
        early.watch.fire()
        guard case .failed = await earlyRun.value else { return XCTFail("expected failed") }
        XCTAssertEqual(early.opener.urls, [])

        let mismatched = HelperHarness()
        let mismatchedRun = mismatched.start()
        let preparedID = UUID()
        mismatched.yield(.message(.prepare(correlationID: preparedID, parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle)))
        await mismatched.waitForSent(.ready(correlationID: preparedID))
        mismatched.yield(.message(.arm(correlationID: UUID())))
        guard case .failed = await mismatchedRun.value else { return XCTFail("expected failed") }
        XCTAssertFalse(mismatched.sent.contains(.armed(correlationID: preparedID)))

        let violated = HelperHarness()
        let violatedRun = violated.start()
        _ = await violated.prepareAndArm()
        violated.yield(.violation("frame too large"))
        guard case .failed = await violatedRun.value else { return XCTFail("expected failed") }
        violated.inspection.set(.notFound)
        violated.watch.fire()
        XCTAssertEqual(violated.opener.urls, [])
    }

    func testFailedOpenIsReportedAndNeverRetried() async {
        let harness = HelperHarness()
        harness.opener.result = false
        let run = harness.start()
        _ = await harness.prepareAndArm()
        harness.inspection.set(.notFound)
        harness.watch.fire()
        let outcome = await run.value
        guard case .openFailed = outcome else { return XCTFail("expected openFailed, got \(outcome)") }
        XCTAssertEqual(outcome.exitCode, 3)
        XCTAssertEqual(harness.opener.urls.count, 1)
    }

    // MARK: Parent session

    func testParentPrepareAndArmSucceedWithMatchingReplies() async {
        let helper = FakeHelperChannel { message, reply in
            switch message {
            case let .prepare(id, _, _): reply(.ready(correlationID: id))
            case let .arm(id): reply(.armed(correlationID: id))
            default: break
            }
        }
        let session = helper.session()
        let prepared = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        XCTAssertEqual(prepared, .ready)
        let armed = await session.arm(acknowledgementTimeout: .seconds(1))
        XCTAssertEqual(armed, .armed)
        let state = await session.state
        XCTAssertEqual(state, .armed)
        XCTAssertEqual(helper.terminateCount, 0)
    }

    func testLostArmedAcknowledgementIsResolvedByAbortedBeforeChoices() async {
        let helper = FakeHelperChannel { message, reply in
            switch message {
            case let .prepare(id, _, _): reply(.ready(correlationID: id))
            case let .abort(id): reply(.aborted(correlationID: id))
            default: break
            }
        }
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        let armTask = Task { await session.arm(acknowledgementTimeout: .seconds(1)) }
        await helper.sleeper.waitForPending(.seconds(1))
        helper.sleeper.fire(.seconds(1))
        guard case .notArmed = await armTask.value else { return XCTFail("expected notArmed") }
        XCTAssertEqual(helper.receivedTypes, ["prepare", "arm", "abort"])
        XCTAssertEqual(helper.terminateCount, 0)
        let finished = await session.isFinished
        XCTAssertTrue(finished)
    }

    func testLostArmedAcknowledgementWithoutAbortedTerminatesAndAwaitsExactHelperExit() async {
        let helper = FakeHelperChannel { message, reply in
            if case let .prepare(id, _, _) = message { reply(.ready(correlationID: id)) }
        }
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        let armTask = Task { await session.arm(acknowledgementTimeout: .seconds(1)) }
        await helper.sleeper.waitForPending(.seconds(1))
        helper.sleeper.fire(.seconds(1))
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        XCTAssertEqual(helper.sleeper.pending(.seconds(16)), 0, "no 16 s cleanup bonus (review A P1-07)")
        helper.sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        guard case .notArmed = await armTask.value else { return XCTFail("expected notArmed") }
        XCTAssertEqual(helper.terminateCount, 1)
        XCTAssertTrue(helper.hasExited)
    }

    /// Review A P1-07: a delivered SIGKILL is not exit proof. Without a correlated `aborted` or the
    /// observed exact-child exit, the bounded stop is unresolved: never `.notArmed`, never finished,
    /// and ownership stays with the session. Waits stay inside the one cleanup reserve.
    func testSignalSentWithoutObservedExitIsUnresolvedWithinTheCleanupReserve() async {
        XCTAssertEqual(
            ProcessRelaunchLimits.v1.cleanupReserve,
            ProcessRelaunchLimits.v1.abortAcknowledgement + ProcessRelaunchLimits.v1.terminateGrace
        )
        XCTAssertEqual(ProcessRelaunchLimits.v1.cleanupReserve, .seconds(1))
        let helper = FakeHelperChannel(exitsOnTerminate: false) { message, reply in
            if case let .prepare(id, _, _) = message { reply(.ready(correlationID: id)) }
        }
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        let armTask = Task { await session.arm(acknowledgementTimeout: .seconds(1)) }
        await helper.sleeper.waitForPending(.seconds(1))
        helper.sleeper.fire(.seconds(1))
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        XCTAssertEqual(helper.sleeper.pending(.seconds(16)), 0, "no cleanup bonus beyond the reserve")
        helper.sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        guard case .unresolved = await armTask.value else { return XCTFail("a delivered signal is not proof") }
        XCTAssertEqual(helper.terminateCount, 1, "the exact child's kill is requested once")
        XCTAssertFalse(helper.hasExited)
        let finished = await session.isFinished
        XCTAssertFalse(finished, "never reported finished without proof")
        let state = await session.state
        XCTAssertEqual(state, .stopUnresolved)
        let signals = await session.terminateResults
        XCTAssertEqual(signals, [.signalSent])
        let rearm = await session.arm(acknowledgementTimeout: .seconds(1))
        guard case .unresolved = rearm else { return XCTFail("an unresolved session never claims notArmed") }
    }

    func testSignalFailureIsUnresolvedAndRetainsOwnership() async {
        let helper = FakeHelperChannel(exitsOnTerminate: false, terminateResult: .failed("Operation not permitted")) { message, reply in
            if case let .prepare(id, _, _) = message { reply(.ready(correlationID: id)) }
        }
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        let abortTask = Task { await session.abort() }
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        guard case let .unresolved(reason) = await abortTask.value else { return XCTFail("expected unresolved") }
        XCTAssertTrue(reason.contains("Operation not permitted"), reason)
        let finished = await session.isFinished
        XCTAssertFalse(finished)
        let signals = await session.terminateResults
        XCTAssertEqual(signals, [.failed("Operation not permitted")])
    }

    func testAbortedAcknowledgementForAnotherCorrelationIsNotProof() async {
        let helper = FakeHelperChannel(exitsOnTerminate: false) { message, reply in
            switch message {
            case let .prepare(id, _, _): reply(.ready(correlationID: id))
            case .abort: reply(.aborted(correlationID: UUID()))
            default: break
            }
        }
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        let abortTask = Task { await session.abort() }
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        guard case .unresolved = await abortTask.value else { return XCTFail("a wrong-identity acknowledgement is ignored") }
        XCTAssertEqual(helper.terminateCount, 1)
    }

    /// Repeated stops share one absolute cleanup deadline: a later abort only drains proof that is
    /// already there (zero budget left), and a later observed exit still proves the stop.
    func testRepeatedAbortCannotRenewTheCleanupBudget() async {
        let helper = FakeHelperChannel(exitsOnTerminate: false) { message, reply in
            if case let .prepare(id, _, _) = message { reply(.ready(correlationID: id)) }
        }
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        let first = Task { await session.abort() }
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        guard case .unresolved = await first.value else { return XCTFail("expected unresolved") }

        let second = Task { await session.abort() }
        await helper.sleeper.waitForPending(.zero)
        XCTAssertEqual(helper.sleeper.pending(ProcessRelaunchLimits.v1.abortAcknowledgement), 0, "no renewed acknowledgement wait")
        XCTAssertEqual(helper.sleeper.pending(ProcessRelaunchLimits.v1.terminateGrace), 0, "no renewed kill wait")
        helper.sleeper.fire(.zero)
        await relaunchEventually { helper.terminateCount == 2 }
        await helper.sleeper.waitForPending(.zero)
        helper.sleeper.fire(.zero)
        guard case .unresolved = await second.value else { return XCTFail("still unresolved without proof") }

        helper.exit()
        let third = await session.abort()
        XCTAssertEqual(third, .safe(.exitObserved), "the observed exact-child exit is proof")
        let finished = await session.isFinished
        XCTAssertTrue(finished)
    }

    // MARK: Step 4b: stop proof after an unresolved stop

    /// Drives a prepared, armed-sent helper whose lost `armed` acknowledgement ends unresolved
    /// (no `aborted`, kill signalled, exit not observed).
    private func unresolvedArmedSession(_ helper: FakeHelperChannel) async -> ProcessRelaunchParentSession {
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        let armTask = Task { await session.arm(acknowledgementTimeout: .seconds(1)) }
        await helper.sleeper.waitForPending(.seconds(1))
        helper.sleeper.fire(.seconds(1))
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        guard case .unresolved = await armTask.value else {
            XCTFail("expected an unresolved lost arm")
            return session
        }
        return session
    }

    private func yieldBriefly() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    /// The exact child's exit observed after the stop gave up is proof: the pending observation
    /// resolves, a later observation replays it, and the next stop is `.safe` without another
    /// frame, kill, or timer. The delivered signal alone never resolved it.
    func testExactExitAfterAnUnresolvedStopIsObservedReplayedAndMakesTheNextStopSafe() async {
        let helper = FakeHelperChannel(exitsOnTerminate: false) { message, reply in
            if case let .prepare(id, _, _) = message { reply(.ready(correlationID: id)) }
        }
        let session = await unresolvedArmedSession(helper)
        let done = RelaunchLocked(false)
        let observation = Task {
            let proof = await session.stopProof()
            done.set(true)
            return proof
        }
        await yieldBriefly()
        XCTAssertFalse(done.current, "a delivered signal is not proof")

        helper.exit()
        let proof = await observation.value
        XCTAssertEqual(proof, .exitObserved)
        let replayed = await session.stopProof()
        XCTAssertEqual(replayed, .exitObserved, "proof that arrived earlier is replayed")

        let timersBefore = helper.sleeper.pendingDurations
        let stop = await session.abort()
        XCTAssertEqual(stop, .safe(.exitObserved))
        let repeatedStop = await session.abort()
        XCTAssertEqual(repeatedStop, .safe(.exitObserved), "repeated calls keep the actual proof")
        XCTAssertEqual(helper.terminateCount, 1, "no second kill")
        XCTAssertEqual(helper.sleeper.pendingDurations, timersBefore, "no new timer")
        let finished = await session.isFinished
        XCTAssertTrue(finished)
    }

    /// A late `aborted` correlated with this helper (after the `abort` it answers) is proof; one for
    /// another correlation, and end of input, are not.
    func testLateCorrelatedAbortedIsProofButAForeignAbortedAndEndOfInputAreNot() async {
        let helper = FakeHelperChannel(exitsOnTerminate: false) { message, reply in
            if case let .prepare(id, _, _) = message { reply(.ready(correlationID: id)) }
        }
        let session = await unresolvedArmedSession(helper)
        guard case let .prepare(correlationID, _, _) = helper.received.first else { return XCTFail("expected prepare") }
        let done = RelaunchLocked(false)
        let observation = Task {
            let proof = await session.stopProof()
            done.set(true)
            return proof
        }
        helper.deliver(.aborted(correlationID: UUID()))
        await yieldBriefly()
        XCTAssertFalse(done.current, "another correlation's acknowledgement is not proof")

        helper.deliver(.aborted(correlationID: correlationID))
        let proof = await observation.value
        XCTAssertEqual(proof, .abortAcknowledged)
        let stop = await session.abort()
        XCTAssertEqual(stop, .safe(.abortAcknowledged))
        XCTAssertEqual(helper.receivedTypes, ["prepare", "arm", "abort"], "nothing more is sent")
        XCTAssertEqual(helper.terminateCount, 1, "no second kill")

        let eof = FakeHelperChannel(exitsOnTerminate: false) { message, reply in
            if case let .prepare(id, _, _) = message { reply(.ready(correlationID: id)) }
        }
        let eofSession = await unresolvedArmedSession(eof)
        let eofDone = RelaunchLocked(false)
        let eofObservation = Task {
            let proof = await eofSession.stopProof()
            eofDone.set(true)
            return proof
        }
        eof.finishInput()
        await yieldBriefly()
        XCTAssertFalse(eofDone.current, "end of input is not proof")
        eofObservation.cancel()
        let cancelled = await eofObservation.value
        XCTAssertNil(cancelled, "a cancelled observation reports nothing")
        let state = await eofSession.state
        XCTAssertEqual(state, .stopUnresolved, "still retained")
    }

    /// An `aborted` that answers no `abort` the parent sent is not stop proof; a cancelled
    /// observation ends without proof.
    func testUnsolicitedAbortedIsNotProofAndObservationIsCancellable() async {
        let helper = FakeHelperChannel(exitsOnTerminate: false) { message, reply in
            if case let .prepare(id, _, _) = message { reply(.ready(correlationID: id)) }
        }
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        guard case let .prepare(correlationID, _, _) = helper.received.first else { return XCTFail("expected prepare") }
        let observation = Task { await session.stopProof() }
        helper.deliver(.aborted(correlationID: correlationID))
        await yieldBriefly()
        observation.cancel()
        let proof = await observation.value
        XCTAssertNil(proof)
        let state = await session.state
        XCTAssertEqual(state, .ready)
    }

    func testPrepareFailureWithUnresolvedStopIsTyped() async {
        let helper = FakeHelperChannel(exitsOnTerminate: false) { message, reply in
            if case let .prepare(id, _, _) = message { reply(.failed(correlationID: id, reason: "wrong bundle")) }
        }
        let session = helper.session()
        let prepareTask = Task {
            await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        }
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.abortAcknowledgement)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.abortAcknowledgement)
        await helper.sleeper.waitForPending(ProcessRelaunchLimits.v1.terminateGrace)
        helper.sleeper.fire(ProcessRelaunchLimits.v1.terminateGrace)
        guard case .unresolved = await prepareTask.value else { return XCTFail("expected unresolved prepare") }
        let finished = await session.isFinished
        XCTAssertFalse(finished)
    }

    func testParentPrepareFailuresStopTheHelper() async {
        let refused = FakeHelperChannel { message, reply in
            switch message {
            case let .prepare(id, _, _): reply(.failed(correlationID: id, reason: "wrong bundle"))
            case let .abort(id): reply(.aborted(correlationID: id))
            default: break
            }
        }
        let refusedResult = await refused.session().prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        XCTAssertEqual(refusedResult, .failed("wrong bundle"))
        XCTAssertEqual(refused.receivedTypes, ["prepare", "abort"])

        let silent = FakeHelperChannel { message, reply in
            if case let .abort(id) = message { reply(.aborted(correlationID: id)) }
        }
        let session = silent.session()
        let prepareTask = Task { await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(20)) }
        await silent.sleeper.waitForPending(.seconds(8))
        silent.sleeper.fire(.seconds(8))
        guard case .failed = await prepareTask.value else { return XCTFail("expected failed") }
        XCTAssertEqual(silent.receivedTypes, ["prepare", "abort"])

        let exited = FakeHelperChannel { _, _ in }
        let exitedSession = exited.session()
        let exitedTask = Task { await exitedSession.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5)) }
        await exited.waitForReceived(1)
        exited.exit()
        guard case .failed = await exitedTask.value else { return XCTFail("expected failed") }
        let finished = await exitedSession.isFinished
        XCTAssertTrue(finished)
    }

    func testParentAbortAfterArmWaitsForAbortedAndIsIdempotent() async {
        let helper = FakeHelperChannel { message, reply in
            switch message {
            case let .prepare(id, _, _): reply(.ready(correlationID: id))
            case let .arm(id): reply(.armed(correlationID: id))
            case let .abort(id): reply(.aborted(correlationID: id))
            default: break
            }
        }
        let session = helper.session()
        _ = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(5))
        _ = await session.arm(acknowledgementTimeout: .seconds(1))
        await session.abort()
        await session.abort()
        XCTAssertEqual(helper.receivedTypes, ["prepare", "arm", "abort"])
        let rearm = await session.arm(acknowledgementTimeout: .seconds(1))
        guard case .notArmed = rearm else { return XCTFail("a finished session never re-arms") }
    }

    // MARK: End to end (in memory)

    func testParentAndHelperSessionsInteroperateOverFramedBytes() async {
        let harness = HelperHarness()
        let (parentInbound, parentContinuation) = AsyncStream<ProcessRelaunchInbound>.makeStream()
        let parentDecoder = RelaunchLocked(ProcessRelaunchFrameDecoder())
        harness.forward = { data in
            for event in parentDecoder.mutate({ $0.append(data) }) {
                parentContinuation.yield(event)
            }
        }
        let helperDecoder = RelaunchLocked(ProcessRelaunchFrameDecoder())
        let helperExit = RelaunchGate()
        let channel = ProcessRelaunchHelperChannel(
            send: { data in
                for event in helperDecoder.mutate({ $0.append(data) }) {
                    harness.yield(event)
                }
                return true
            },
            inbound: parentInbound,
            waitForExit: { await helperExit.wait() },
            terminate: { .signalSent }
        )
        let run = harness.start()
        let session = ProcessRelaunchParentSession(channel: channel, sleep: harness.sleeper.sleep)
        let prepared = await session.prepare(parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle, deadline: .seconds(8))
        XCTAssertEqual(prepared, .ready)
        let armed = await session.arm(acknowledgementTimeout: .seconds(2))
        XCTAssertEqual(armed, .armed)
        harness.inspection.set(.notFound)
        harness.watch.fire()
        let outcome = await run.value
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(harness.opener.urls.map(\.path), [RelaunchFixture.bundle])
        helperExit.open()
        parentContinuation.finish()
    }
}

// MARK: - Fixtures

private enum RelaunchFixture {
    static let boot = UUID(uuidString: "6F1C2A4E-1111-4222-8333-944455556666")!
    static let bundle = "/Apps/RepoPrompt CE.app"
    static let helperExecutable = bundle + "/Contents/MacOS/repoprompt-mcp"
    static let parent = identity()

    static func identity(pid: pid_t = 100, startSeconds: UInt64 = 7, uid: uid_t = 501) -> ProcessRelaunchParentIdentity {
        ProcessRelaunchParentIdentity(pid: pid, bootSessionID: boot, startSeconds: startSeconds, startMicroseconds: 5, uid: uid)
    }

    static func observation(startSeconds: UInt64 = 7, isZombie: Bool = false) -> ProcessObservation {
        ProcessObservation(
            identity: ProcessBirthIdentity(bootSessionID: boot, pid: 100, startSeconds: startSeconds, startMicroseconds: 5, uid: 501),
            parentPID: 1,
            isZombie: isZombie,
            executablePath: .available("/Apps/RepoPrompt CE.app/Contents/MacOS/RepoPrompt CE"),
            processGroupID: .available(100),
            environment: .available(ProcessEnvironmentIdentity(runtimeID: nil, claudeConfigDirectory: nil))
        )
    }
}

private final class RelaunchLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// A one-shot gate: `wait` suspends until `open`.
private final class RelaunchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var opened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        guard !isOpen else { return lock.unlock() }
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// Injected clock: every `sleep(duration)` suspends until the test fires that duration or the
/// sleeping task is cancelled.
private final class RelaunchManualSleeper: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private let origin = ContinuousClock.now
    private var elapsed: Duration = .zero

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in await self.suspend(duration) }
    }

    /// Injected monotonic clock: advances only when the test fires a sleep (by that duration).
    var now: @Sendable () -> ContinuousClock.Instant {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return origin + elapsed
        }
    }

    private func suspend(_ duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            resume { $0.id == id }
        }
    }

    func pending(_ duration: Duration) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count { $0.duration == duration }
    }

    func waitForPending(_ duration: Duration, file: StaticString = #filePath, line: UInt = #line) async {
        await relaunchEventually(file: file, line: line) { self.pending(duration) > 0 }
    }

    func fire(_ duration: Duration) {
        lock.lock()
        elapsed += duration
        lock.unlock()
        resume { $0.duration == duration }
    }

    /// Every pending sleep duration (test observability).
    var pendingDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return waiters.map(\.duration)
    }

    private func resume(where predicate: (Waiter) -> Bool) {
        lock.lock()
        let matched = waiters.filter(predicate)
        waiters.removeAll(where: predicate)
        lock.unlock()
        matched.forEach { $0.continuation.resume() }
    }
}

private func relaunchEventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    for _ in 0 ..< 2000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("condition not reached", file: file, line: line)
}

private final class RelaunchWatch: @unchecked Sendable {
    private let state = RelaunchLocked<(pids: [pid_t], handler: (@Sendable () -> Void)?, cancelled: Bool)>(([], nil, false))
    var onInstall: (@Sendable () -> Void)?

    var watchedPIDs: [pid_t] {
        state.current.pids
    }

    var isCancelled: Bool {
        state.current.cancelled
    }

    func install(pid: pid_t, handler: @escaping @Sendable () -> Void) -> ProcessRelaunchWatchToken {
        state.mutate { watch in
            watch.pids.append(pid)
            watch.handler = handler
        }
        onInstall?()
        return ProcessRelaunchWatchToken { [state] in state.mutate { $0.cancelled = true } }
    }

    func fire() {
        state.current.handler?()
    }
}

private final class RelaunchOpener: @unchecked Sendable {
    private let recorded = RelaunchLocked<[URL]>([])
    private let outcome = RelaunchLocked(true)

    var urls: [URL] {
        recorded.current
    }

    var result: Bool {
        get {
            outcome.current
        }
        set {
            outcome.set(newValue)
        }
    }

    func open(_ url: URL) async -> Bool {
        recorded.mutate { $0.append(url) }
        return outcome.current
    }
}

private final class HelperHarness: @unchecked Sendable {
    let inspection = RelaunchLocked<ProcessInspectionResult>(.observed(RelaunchFixture.observation()))
    let watch = RelaunchWatch()
    let opener = RelaunchOpener()
    let sleeper = RelaunchManualSleeper()
    private let sentFrames = RelaunchLocked<[ProcessRelaunchMessage]>([])
    private let input: AsyncStream<ProcessRelaunchInbound>
    private let inputContinuation: AsyncStream<ProcessRelaunchInbound>.Continuation
    /// Optional byte forwarder (end-to-end test) for frames the helper sends.
    var forward: (@Sendable (Data) -> Void)?
    private(set) lazy var session = ProcessRelaunchHelperSession(environment: environment())

    init() {
        (input, inputContinuation) = AsyncStream<ProcessRelaunchInbound>.makeStream()
    }

    var sent: [ProcessRelaunchMessage] {
        sentFrames.current
    }

    func start() -> Task<ProcessRelaunchHelperOutcome, Never> {
        let session = session
        let input = input
        return Task { await session.run(inbound: input) }
    }

    func yield(_ event: ProcessRelaunchInbound) {
        inputContinuation.yield(event)
    }

    func finishInput() {
        inputContinuation.finish()
    }

    func waitForSent(_ message: ProcessRelaunchMessage, file: StaticString = #filePath, line: UInt = #line) async {
        await relaunchEventually(file: file, line: line) { self.sent.contains(message) }
    }

    func prepareAndArm() async -> UUID {
        let id = UUID()
        yield(.message(.prepare(correlationID: id, parent: RelaunchFixture.parent, bundlePath: RelaunchFixture.bundle)))
        await waitForSent(.ready(correlationID: id))
        yield(.message(.arm(correlationID: id)))
        await waitForSent(.armed(correlationID: id))
        return id
    }

    private func environment() -> ProcessRelaunchHelperEnvironment {
        ProcessRelaunchHelperEnvironment(
            parentPID: { RelaunchFixture.parent.pid },
            currentUID: { RelaunchFixture.parent.uid },
            inspect: { [inspection] _ in inspection.current },
            ownExecutablePath: { RelaunchFixture.helperExecutable },
            realPath: { $0 },
            watchExit: { [watch] pid, handler in watch.install(pid: pid, handler: handler) },
            openBundle: { [opener] url in await opener.open(url) },
            sleep: sleeper.sleep,
            send: { [sentFrames, weak self] data in
                if let message = try? ProcessRelaunchCodec.decode(data.dropLast()) {
                    sentFrames.mutate { $0.append(message) }
                }
                self?.forward?(data)
            }
        )
    }
}

/// A scripted helper on the far side of a parent channel. `respond` sees each decoded frame the
/// parent sends and may reply with helper messages.
private final class FakeHelperChannel: @unchecked Sendable {
    let sleeper = RelaunchManualSleeper()
    private let receivedFrames = RelaunchLocked<[ProcessRelaunchMessage]>([])
    private let terminations = RelaunchLocked(0)
    private let exitGate = RelaunchGate()
    private let inbound: AsyncStream<ProcessRelaunchInbound>
    private let continuation: AsyncStream<ProcessRelaunchInbound>.Continuation
    private let respond: @Sendable (ProcessRelaunchMessage, @Sendable (ProcessRelaunchMessage) -> Void) -> Void
    private let exitsOnTerminate: Bool
    private let terminateResult: ProcessRelaunchTerminateResult

    init(
        exitsOnTerminate: Bool = true,
        terminateResult: ProcessRelaunchTerminateResult = .signalSent,
        respond: @escaping @Sendable (ProcessRelaunchMessage, @Sendable (ProcessRelaunchMessage) -> Void) -> Void
    ) {
        self.exitsOnTerminate = exitsOnTerminate
        self.terminateResult = terminateResult
        self.respond = respond
        (inbound, continuation) = AsyncStream<ProcessRelaunchInbound>.makeStream()
    }

    var receivedTypes: [String] {
        receivedFrames.current.map { message in
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

    var terminateCount: Int {
        terminations.current
    }

    var received: [ProcessRelaunchMessage] {
        receivedFrames.current
    }

    var hasExited: Bool {
        exitGate.opened
    }

    /// A helper frame arriving on its own (not as a reply).
    func deliver(_ message: ProcessRelaunchMessage) {
        continuation.yield(.message(message))
    }

    /// The helper closes its output (never exit proof).
    func finishInput() {
        continuation.finish()
    }

    func waitForReceived(_ count: Int) async {
        await relaunchEventually { self.receivedFrames.current.count >= count }
    }

    func exit() {
        exitGate.open()
    }

    func session() -> ProcessRelaunchParentSession {
        let channel = ProcessRelaunchHelperChannel(
            send: { [self] data in
                guard !exitGate.opened, let message = try? ProcessRelaunchCodec.decode(data.dropLast()) else { return false }
                receivedFrames.mutate { $0.append(message) }
                let continuation = continuation
                respond(message) { reply in continuation.yield(.message(reply)) }
                return true
            },
            inbound: inbound,
            waitForExit: { [exitGate] in await exitGate.wait() },
            terminate: { [terminations, exitGate, exitsOnTerminate, terminateResult] in
                terminations.mutate { $0 += 1 }
                if exitsOnTerminate { exitGate.open() }
                return terminateResult
            }
        )
        return ProcessRelaunchParentSession(channel: channel, sleep: sleeper.sleep, now: sleeper.now)
    }
}
