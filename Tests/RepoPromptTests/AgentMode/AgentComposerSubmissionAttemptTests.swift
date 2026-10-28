import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

@MainActor
final class AgentComposerSubmissionAttemptTests: XCTestCase {
    func testComposerProductionEqualityRejectsLiveTabChangeBeforePropsCatchUp() {
        let sourceTabID = UUID()
        let destinationTabID = UUID()
        let focusToken = UUID()

        XCTAssertTrue(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                lhsComposerFocusToken: focusToken,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: sourceTabID,
                rhsComposerFocusToken: focusToken
            )
        )
        XCTAssertFalse(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                lhsComposerFocusToken: focusToken,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: destinationTabID,
                rhsComposerFocusToken: focusToken
            )
        )
        XCTAssertFalse(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                lhsComposerFocusToken: focusToken,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: sourceTabID,
                rhsComposerFocusToken: UUID()
            )
        )
    }

    func testLatchSuppressesRapidSameTabCallbacksButAllowsAnotherTab() throws {
        var latch = AgentComposerSubmissionLatch()
        let firstSession = AgentTabSession(tabID: UUID())
        let secondSession = AgentTabSession(tabID: UUID())
        let firstTarget = makeTarget(session: firstSession)
        let secondTarget = makeTarget(session: secondSession)

        let firstAttempt = try XCTUnwrap(latch.begin(target: firstTarget, rawDraftSnapshot: "first"))

        XCTAssertTrue(latch.isLatched(for: firstSession.tabID))
        XCTAssertEqual(latch.activeAttemptID(for: firstSession.tabID), firstAttempt.id)
        XCTAssertNil(latch.begin(target: firstTarget, rawDraftSnapshot: "duplicate"))
        XCTAssertNotNil(latch.begin(target: secondTarget, rawDraftSnapshot: "second"))
    }

    func testMatchingCompletionClearsOnlyUnchangedInput() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentTabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "submitted draft")
        )

        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "submitted draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertTrue(effects.shouldClearInput)
        XCTAssertNil(effects.blockedMessage)
        XCTAssertFalse(latch.isLatched(for: session.tabID))
    }

    func testScheduledCompletionClearsOnlyUnchangedInput() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentTabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "scheduled draft")
        )

        let scheduleID = UUID()
        let effects = latch.complete(
            attempt,
            result: .scheduled(id: scheduleID),
            currentTabID: session.tabID,
            currentRawDraft: "scheduled draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertTrue(effects.shouldClearInput)
        XCTAssertNil(effects.blockedMessage)
        XCTAssertFalse(latch.isLatched(for: session.tabID))
    }

    func testNewerTypingAndDraftRestorationSurviveCompletion() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentTabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "submitted draft")
        )

        // A programmatic restoration must advance the same revision even when the
        // resulting text happens to match the submitted text.
        latch.advanceInputRevision()
        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "submitted draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertFalse(effects.shouldClearInput)
    }

    func testTabSwitchPreventsOldCompletionFromClearingCurrentDraft() throws {
        var latch = AgentComposerSubmissionLatch()
        let sourceSession = AgentTabSession(tabID: UUID())
        let currentSession = AgentTabSession(tabID: UUID())
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: sourceSession), rawDraftSnapshot: "same text")
        )

        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: currentSession.tabID,
            currentRawDraft: "same text"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertFalse(effects.shouldClearInput)
    }

    func testStaleCompletionCannotReleaseNewerAttempt() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentTabSession(tabID: UUID())
        let target = makeTarget(session: session)
        let oldAttempt = try XCTUnwrap(
            latch.begin(target: target, rawDraftSnapshot: "old", attemptID: UUID())
        )
        XCTAssertTrue(latch.cancel(oldAttempt))
        let newAttempt = try XCTUnwrap(
            latch.begin(target: target, rawDraftSnapshot: "new", attemptID: UUID())
        )

        let staleEffects = latch.complete(
            oldAttempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "new"
        )

        XCTAssertEqual(staleEffects, .stale)
        XCTAssertEqual(latch.activeAttemptID(for: session.tabID), newAttempt.id)
    }

    func testBlockedCompletionCannotOverwriteNewerNotice() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentTabSession(tabID: UUID())
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "draft")
        )
        latch.advanceNoticeRevision()

        let effects = latch.complete(
            attempt,
            result: .blocked(message: "older notice"),
            currentTabID: session.tabID,
            currentRawDraft: "draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertNil(effects.blockedMessage)
    }

    /// Review B L5: an admission refusal reaches the composer's completion as `effects.blockedMessage`
    /// unchanged, so the input bar's classifier makes it persistent; an unrelated block stays timed.
    func testAdmissionRefusalBlockedMessageIsClassifiedAsPersistent() throws {
        let refusals: [AgentRecoveryAdmissionRefusal] = [
            .startupNotReady,
            .restricted("A process from before the restart may still be writing this conversation."),
            .untrackedInput
        ]
        for refusal in refusals {
            var latch = AgentComposerSubmissionLatch()
            let session = AgentTabSession(tabID: UUID())
            let attempt = try XCTUnwrap(latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "draft"))
            let effects = latch.complete(
                attempt,
                result: .blocked(message: AgentModeViewModel.recoveryAdmissionRefusalMessage(refusal)),
                currentTabID: session.tabID,
                currentRawDraft: "draft"
            )
            XCTAssertFalse(effects.shouldClearInput, "\(refusal)")
            let message = try XCTUnwrap(effects.blockedMessage, "\(refusal)")
            XCTAssertTrue(AgentModeViewModel.isRecoveryAdmissionRefusalNotice(message), "\(refusal): \(message)")
        }
        var latch = AgentComposerSubmissionLatch()
        let session = AgentTabSession(tabID: UUID())
        let attempt = try XCTUnwrap(latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "draft"))
        let effects = latch.complete(
            attempt,
            result: .blocked(message: AgentModeViewModel.staleComposerSubmitTargetMessage),
            currentTabID: session.tabID,
            currentRawDraft: "draft"
        )
        let message = try XCTUnwrap(effects.blockedMessage)
        XCTAssertFalse(AgentModeViewModel.isRecoveryAdmissionRefusalNotice(message))

        // Review B P3: a refusal completing after a switch to another tab publishes no notice, so
        // it can't be pinned on the new tab.
        var switched = AgentComposerSubmissionLatch()
        let sourceSession = AgentTabSession(tabID: UUID())
        let switchedAttempt = try XCTUnwrap(switched.begin(target: makeTarget(session: sourceSession), rawDraftSnapshot: "draft"))
        let switchedEffects = switched.complete(
            switchedAttempt,
            result: .blocked(message: AgentModeViewModel.recoveryAdmissionRefusalMessage(.startupNotReady)),
            currentTabID: UUID(),
            currentRawDraft: "draft"
        )
        XCTAssertNil(switchedEffects.blockedMessage)
    }

    /// 9-live V1: a persistent notice (a recovery admission refusal) survives the transient
    /// dismiss timer and clears on the next submit attempt or composer text change.
    func testPersistentNoticeSurvivesTheTimerAndClearsOnTheNextEditOrAttempt() {
        var notice = AgentComposerSubmitNotice()
        let refusal = AgentModeViewModel.recoveryAdmissionRefusalMessage(.startupNotReady)
        XCTAssertFalse(notice.show(refusal, persistent: true), "no dismiss timer for a persistent notice")
        XCTAssertFalse(notice.transientTimerFired(for: refusal), "a timer never clears a persistent notice")
        XCTAssertEqual(notice.message, refusal)
        XCTAssertTrue(notice.isPersistent)

        XCTAssertTrue(notice.clearPersistent(), "the next text change or submit attempt clears it")
        XCTAssertNil(notice.message)
        XCTAssertFalse(notice.isPersistent)
        XCTAssertFalse(notice.clearPersistent(), "nothing left to clear")

        // A transient notice that replaces a persistent one is timed again.
        XCTAssertFalse(notice.show(refusal, persistent: true))
        XCTAssertTrue(notice.show("Steering isn't supported here.", persistent: false))
        XCTAssertFalse(notice.isPersistent)
        XCTAssertTrue(notice.transientTimerFired(for: "Steering isn't supported here."))
        XCTAssertNil(notice.message)
    }

    /// The 3-second behaviour stays for every other notice: an edit doesn't clear it, its own timer
    /// does, and an older timer never clears a newer notice. An empty message shows nothing.
    func testTransientNoticeClearsOnlyOnItsOwnTimer() {
        var notice = AgentComposerSubmitNotice()
        XCTAssertEqual(AgentComposerSubmitNotice.transientDurationNanoseconds, 3_000_000_000)
        XCTAssertTrue(notice.show("first", persistent: false))
        XCTAssertFalse(notice.clearPersistent(), "an edit leaves a transient notice to its timer")
        XCTAssertEqual(notice.message, "first")
        XCTAssertTrue(notice.show("second", persistent: false))
        XCTAssertFalse(notice.transientTimerFired(for: "first"), "an older timer never clears a newer notice")
        XCTAssertEqual(notice.message, "second")
        XCTAssertTrue(notice.transientTimerFired(for: "second"))
        XCTAssertNil(notice.message)
        XCTAssertFalse(notice.show("", persistent: true))
        XCTAssertNil(notice.message)
    }

    private func makeTarget(session: AgentTabSession) -> AgentComposerSubmitTarget {
        AgentComposerSubmitTarget(
            tabID: session.tabID,
            route: .createAgentSessionFromSourceTab,
            expectedSourceTabSessionIdentity: ObjectIdentifier(session),
            expectedSourceAgentSessionID: nil,
            expectedPersistentBindingIdentity: nil,
            expectedBindingTransitionGeneration: session.bindingTransitionGeneration,
            expectedRunState: .idle,
            expectedRunID: nil,
            expectedRunAttemptID: nil,
            expectedSubmissionToken: session.composerSubmissionToken,
            expectedInitialStartLocation: .local
        )
    }
}
