import Foundation
import RepoPromptAgentCore

// Lossless-restart Phase 1b composer wiring (spec R2 "Composer writes"). Active once
// `AgentRecoveryAppComposition` installs `recoveryCoordinator` (mandatory admission); while it is
// `nil` (XCTest without explicit injection) every entry point below is a no-op.
//
// Ownership: the coordinator holds exactly one lane (one composer controller) per durable
// session. A session's lane is (re)claimed after each `persistenceState` assignment; a reset
// yields a new binding and retires the old lane without flushing it under the stale generation.
// A reset is preceded by `prepareRecoveryTranscriptReset`, which writes the latest composer under
// the old generation (or vetoes the reset). Input typed before any lane exists (first draft of a
// new tab, images awaiting promotion) is an owner-scoped obligation whose single preparation task
// creates normal foundation authority, promotes images, and forwards with the original deadline.

@MainActor
extension AgentModeViewModel {
    /// Shown when queued input reaches a route whose durable admission is not wired while the
    /// session requires it (fail closed; never queued untracked).
    static let durableQueueAdmissionRequiredMessage =
        "This message could not be queued because durable recovery admission is not available for this route."
    /// Held-input reason for a saved submission that was refused before it was projected.
    static let refusedSubmissionHoldReason = "It was saved but couldn't be sent or put back into the message box."

    // MARK: Outcome classification

    /// A Codex send whose handoff began without proof of its result. Callers keep the bubble and
    /// the durable intent; they never delete, restore a retryable draft, retry, or report "Sent".
    nonisolated static func isDeliveryUnknown(_ outcome: CodexAgentModeCoordinator.NativeSendOutcome?) -> Bool {
        if case .deliveryUnknown = outcome { return true }
        return false
    }

    /// A non-Codex run start that provably handed nothing off (dispatch refused, target changed,
    /// handoff revoked, or blocked before startup). `nil` means a runner was admitted.
    nonisolated static func runStartDidNotHandOff(_ outcome: CodexAgentModeCoordinator.NativeSendOutcome?) -> Bool {
        switch outcome {
        case .stale?, .failed?, .cancelled?:
            true
        case .sent?, .queuedFallback?, .deliveryUnknown?, nil:
            false
        }
    }

    /// Start-tail settlement of staged next-turn input after `runService.startRun` returned.
    /// `nil` = the provider outcome owns it (an admitted runner, or a Codex send/fallback that already
    /// reported its exact stages). A start that provably handed nothing off releases the stages;
    /// an uncertain one holds them.
    nonisolated static func stagedInputStartDisposition(
        for outcome: CodexAgentModeCoordinator.NativeSendOutcome?
    ) -> AgentStagedInputDisposition? {
        switch outcome {
        case .stale?, .failed?, .cancelled?:
            .notSent
        case .deliveryUnknown?:
            .deliveryUnknown
        case .sent?, .queuedFallback?, nil:
            nil
        }
    }

    // MARK: Pending-handoff recovery join

    /// Join of a hydrated pending-handoff payload with the durable delivery evidence of every
    /// recovery intent that captured it (`AgentRecoveryIntent.pendingHandoff.payloadID`) and of
    /// those intents' attempts.
    enum PendingHandoffRecoveryJoin: Equatable {
        /// A carrying intent or attempt was provider-accepted: the payload was delivered.
        case consumed
        /// A carrying intent or attempt may have delivered it (`dispatching`, `deliveryUnknown`, or an
        /// attempt without a recorded outcome): never prepended again automatically.
        case uncertain
        /// A carrying intent still owns the snapshot (`queued` or `failed`, so it can still be sent
        /// explicitly with it): reserved until the carrier is withdrawn or its delivery settles.
        case carriedByIntent
        /// Every carrying intent was withdrawn and none of its attempts may have delivered it, or an
        /// authorized read found no record (no admission ever carried a payload of this session).
        case release
        /// The record is unreadable or the lane unavailable: held (fail closed).
        case authorityUnavailable
    }

    nonisolated static func pendingHandoffRecoveryJoin(
        payloadID: UUID,
        recordState: Result<AgentRecoveryRecordState, AgentRecoveryControllerFailure>
    ) -> PendingHandoffRecoveryJoin {
        let record: AgentRecoveryRecord
        switch recordState {
        case .failure, .success(.preserved):
            return .authorityUnavailable
        case .success(.absent):
            return .release
        case let .success(.supported(supported)):
            record = supported
        }
        let linkedIntents = record.intents.filter { $0.pendingHandoff?.payloadID == payloadID }
        guard !linkedIntents.isEmpty else { return .release }
        let linkedIntentIDs = Set(linkedIntents.map(\.intentID))
        let linkedOutcomes = record.attempts
            .filter { linkedIntentIDs.contains($0.intentID) }
            .map { $0.outcome?.outcome }
        if linkedIntents.contains(where: { $0.deliveryState == .providerAccepted })
            || linkedOutcomes.contains(.providerAccepted)
        {
            return .consumed
        }
        let intentUncertain = linkedIntents.contains {
            $0.deliveryState == .dispatching || $0.deliveryState == .deliveryUnknown
        }
        // Only a recorded failure (pre-handoff or verified rejection) proves an attempt delivered nothing.
        let attemptUncertain = linkedOutcomes.contains { outcome in
            guard let outcome else { return true }
            if case .failed = outcome { return false }
            return true
        }
        if intentUncertain || attemptUncertain { return .uncertain }
        // Only an explicit withdrawal ends a carrier's ownership of the snapshot.
        if linkedIntents.contains(where: { $0.deliveryState != .withdrawn }) { return .carriedByIntent }
        return .release
    }

    /// Hydration join: with a recovery coordinator installed, a hydrated pending-handoff payload
    /// is held (`recoveryJoinPending`) and never prepended until its lane's record proves it free.
    /// Accepted evidence consumes exactly this payload; uncertain evidence keeps it held
    /// (`recoveryDeliveryUncertain`, no automatic carry-forward); an unreadable record or a missing
    /// lane holds it (`recoveryAuthorityUnavailable`). A payload changed meanwhile, a live stage,
    /// or an in-process delivery hold is never touched. Re-runnable; inactive (legacy behavior)
    /// without a coordinator.
    func resolvePendingHandoffRecoveryJoin(for session: AgentTabSession) {
        guard let begun = beginPendingHandoffRecoveryJoin(for: session) else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            await finishPendingHandoffRecoveryJoin(for: session, lane: begun.lane, payloadID: begun.payloadID)
        }
    }

    /// `resolvePendingHandoffRecoveryJoin`, awaited: the join is applied before returning (R04 Edit
    /// resolves it before the user can send the moved text).
    func awaitPendingHandoffRecoveryJoin(for session: AgentTabSession) async {
        guard let begun = beginPendingHandoffRecoveryJoin(for: session) else { return }
        await finishPendingHandoffRecoveryJoin(for: session, lane: begun.lane, payloadID: begun.payloadID)
    }

    /// Synchronous half: sets the hold before any suspension.
    private func beginPendingHandoffRecoveryJoin(
        for session: AgentTabSession
    ) -> (lane: AgentRecoverySessionLane, payloadID: UUID)? {
        guard recoveryCoordinator != nil,
              session.pendingHandoff.hasPayload,
              let payloadID = session.pendingHandoff.payloadID,
              session.pendingHandoff.stage == nil,
              !session.pendingHandoff.isStagedForSend,
              session.pendingHandoff.deliveryHold == nil || session.pendingHandoff.deliveryHold?.isRecoveryHold == true
        else { return nil }
        guard let lane = session.recoveryLane else {
            session.pendingHandoff.deliveryHold = .recoveryAuthorityUnavailable
            return nil
        }
        session.pendingHandoff.deliveryHold = .recoveryJoinPending
        return (lane, payloadID)
    }

    private func finishPendingHandoffRecoveryJoin(
        for session: AgentTabSession,
        lane: AgentRecoverySessionLane,
        payloadID: UUID
    ) async {
        let recordState = await lane.readRecord()
        guard session.recoveryLane === lane,
              session.pendingHandoff.payloadID == payloadID,
              session.pendingHandoff.stage == nil,
              session.pendingHandoff.deliveryHold?.isRecoveryHold == true
        else { return }
        applyPendingHandoffRecoveryJoin(
            Self.pendingHandoffRecoveryJoin(payloadID: payloadID, recordState: recordState),
            to: session
        )
    }

    private func applyPendingHandoffRecoveryJoin(_ join: PendingHandoffRecoveryJoin, to session: AgentTabSession) {
        switch join {
        case .consumed:
            session.pendingHandoff.clearAfterSend()
            session.isDirty = true
            scheduleSave(for: session.tabID)
        case .uncertain:
            session.pendingHandoff.deliveryHold = .recoveryDeliveryUncertain
        case .carriedByIntent:
            session.pendingHandoff.deliveryHold = .recoveryCarriedByIntent
        case .release:
            session.pendingHandoff.deliveryHold = nil
        case .authorityUnavailable:
            session.pendingHandoff.deliveryHold = .recoveryAuthorityUnavailable
        }
    }

    // MARK: Remote dispatch identities

    /// Dispatch identity of a fresh remote send shown as `userItemID`. Untracked only while the
    /// session's admission is inactive; `nil` (fail closed) when durable admission is mandatory and
    /// the route has no store-issued receipt for it.
    func remoteSendDispatch(for session: AgentTabSession, userItemID: UUID, receipt: AgentRecoveryQueueReceipt? = nil) -> RemoteInputDispatch? {
        if let receipt {
            return RemoteInputDispatch(input: AgentQueuedInputIdentity(receipt: receipt))
        }
        return AgentQueuedInputIdentity.untracked(userItemID: userItemID, in: session).map { RemoteInputDispatch(input: $0) }
    }

    /// Dispatch identity of an explicit user retry (Resend, start-target picker, workspace-open
    /// retry) of the existing item `userItemID`: its committed intent from the lane's record when one
    /// exists (any eligible state, validated again by the store), otherwise an untracked identity
    /// only while admission is inactive. Never a fabricated queue receipt.
    func remoteExplicitRetryDispatch(for session: AgentTabSession, userItemID: UUID) async -> RemoteInputDispatch? {
        if let lane = session.recoveryLane, !lane.isRetired,
           let existing = await lane.existingIntentReference(forUserItemID: userItemID)
        {
            return RemoteInputDispatch(existingIntent: existing)
        }
        return AgentQueuedInputIdentity.untracked(userItemID: userItemID, in: session)
            .map { RemoteInputDispatch(input: $0, authorization: .explicitUserAction) }
    }

    // MARK: Durable input admission (producers)

    /// Shown when a durable commit failed or was refused before anything was projected; the input
    /// stays in the composer (or with the caller) and nothing was sent.
    static let recoveryAdmissionFailedMessage =
        "This message could not be saved for recovery, so it was not sent. Your draft is kept."

    /// F-9: each admission refusal says why the message was not sent; only an actual save or
    /// authority failure claims one. Nothing was written and the draft is kept in every case.
    static func recoveryAdmissionRefusalMessage(_ refusal: AgentRecoveryAdmissionRefusal) -> String {
        switch refusal {
        case .startupNotReady:
            recoveryRefusalStartupNotReadyMessage
        case .startupFailed:
            recoveryRefusalStartupFailedMessage
        case let .restricted(reason):
            "\(recoveryRefusalRestrictedPrefix)\(reason)\(recoveryRefusalRestrictedSuffix)"
        case .crashHeld:
            recoveryRefusalCrashHeldMessage
        case .unsavedPredecessorInput:
            recoveryRefusalUnsavedPredecessorMessage
        case .resetPreparationInProgress:
            recoveryRefusalResetPreparationMessage
        case .shutdownInProgress:
            recoveryRefusalShutdownMessage
        case .recoveryActionInProgress:
            recoveryRefusalActionInProgressMessage
        case .laneRetired, .bindingMismatch:
            recoveryRefusalSessionChangedMessage
        case .composerUnavailable, .untrackedInput:
            recoveryAdmissionFailedMessage
        }
    }

    static let recoveryRefusalStartupNotReadyMessage =
        "RepoPrompt is still checking what was interrupted by the last restart, so this message was not sent yet. Your draft is kept."
    static let recoveryRefusalStartupFailedMessage =
        "RepoPrompt couldn't check what was interrupted by the last restart, so this message was not sent. Retry from the recovery banner. Your draft is kept."
    static let recoveryRefusalRestrictedPrefix = "This message was not sent: "
    static let recoveryRefusalRestrictedSuffix = " Review it in the recovery banner. Your draft is kept."
    static let recoveryRefusalCrashHeldMessage =
        "The previous run in this session may still have been working when RepoPrompt closed. Confirm it stopped from the recovery banner before sending. Your draft is kept."
    static let recoveryRefusalUnsavedPredecessorMessage =
        "Earlier unsaved input in this session needs to be restored or discarded first (recovery banner). Your draft is kept."
    static let recoveryRefusalResetPreparationMessage =
        "The conversation is being cleared, so this message was not sent. Your draft is kept."
    static let recoveryRefusalShutdownMessage =
        "RepoPrompt is saving this session before closing, so this message was not sent. Your draft is kept."
    static let recoveryRefusalActionInProgressMessage =
        "A recovery choice in this workspace is in progress, so this message was not sent. Your draft is kept."
    static let recoveryRefusalSessionChangedMessage =
        "The session changed before this message could be saved, so it was not sent. Your draft is kept."

    /// 9-live V1: whether `message` is a sentence of `recoveryAdmissionRefusalMessage`. The composer
    /// shows those as a persistent notice (until the next submit attempt or text change) instead of
    /// the 3-second one.
    static func isRecoveryAdmissionRefusalNotice(_ message: String) -> Bool {
        if message.hasPrefix(recoveryRefusalRestrictedPrefix), message.hasSuffix(recoveryRefusalRestrictedSuffix) {
            return true
        }
        return [
            recoveryRefusalStartupNotReadyMessage,
            recoveryRefusalStartupFailedMessage,
            recoveryRefusalCrashHeldMessage,
            recoveryRefusalUnsavedPredecessorMessage,
            recoveryRefusalResetPreparationMessage,
            recoveryRefusalShutdownMessage,
            recoveryRefusalActionInProgressMessage,
            recoveryRefusalSessionChangedMessage,
            recoveryAdmissionFailedMessage
        ].contains(message)
    }

    /// Shown when the input was committed but its lane retired during the commit: it is kept as held
    /// input for the next launch's explicit resolution and is never dispatched or retargeted here.
    static let recoveryAdmissionStaleMessage =
        "The session changed while this message was being saved. It was kept and was not sent."

    /// Result of admitting one user input before its optimistic projection.
    enum RecoveryInputAdmission {
        /// The session does not require durable admission (inactive, no live lane): legacy routing.
        case notRequired
        /// A committed `queued` intent; its identity is carried unchanged to every route. `content` is
        /// exactly what was committed and `attachments` the live images it references (managed).
        case admitted(
            AgentQueuedInputIdentity,
            lane: AgentRecoverySessionLane,
            content: AgentRecoveryInputContent,
            attachments: [AgentImageAttachment]
        )
        /// Nothing may be projected or sent. The caller keeps its input.
        case blocked(String)
    }

    /// O11: the transient result of placing one saved input at the conversation's execution end and
    /// proving that placement durable (a covering owner write). It names the action authorization,
    /// intent, user item, and destination turn the synchronous submit must find unchanged. It is not
    /// a reservation authority and is never persisted.
    struct RecoverySavedInputPreparation: Equatable {
        let authorizationToken: UUID
        let intentID: UUID
        let userItemID: UUID
        let executionTurnID: UUID
        let tabID: UUID
    }

    /// R12: the one immutable snapshot of a durably admitted user turn, carried from admission through
    /// projection, workflow wrapping, attachment reservation, and provider preparation. Submission
    /// never re-reads the live composer: later edits belong to a newer composer revision and survive.
    struct AdmittedUserTurnInput {
        let identity: AgentQueuedInputIdentity
        /// What the intent committed (the comparison basis for a refused submission's restore).
        let content: AgentRecoveryInputContent
        let attachments: [AgentImageAttachment]
        let taggedFiles: [AgentTaggedFileAttachment]
        let workflow: AgentWorkflowDefinition?
        let interviewFirst: Bool
        /// A composer submission: exactly the submitted items leave the live composer.
        let consumesComposer: Bool
        /// O11: Send saved's committed placement of its saved input at the execution end. Required
        /// for an authorized saved-input resend (`resendsAuthorizedSavedIntent`); never persisted.
        var savedPreparation: RecoverySavedInputPreparation?

        /// Review A P1-06: Send saved re-dispatches the one saved intent its coordinator-issued
        /// action authorization names. Only that authority may reuse the intent's already shown
        /// deterministic bubble, and a refused submission keeps the saved intent (never withdrawn).
        var resendsAuthorizedSavedIntent: Bool {
            guard let sourceIntentID = identity.actionAuthorization?.sourceIntentID else { return false }
            return sourceIntentID == identity.intentID && !consumesComposer
        }
    }

    /// Durable admission applies when the session requires it, or whenever it owns a live lane.
    func requiresDurableRecoveryAdmission(for session: AgentTabSession) -> Bool {
        if session.recoveryAdmissionMode == .mandatory { return true }
        guard let lane = session.recoveryLane else { return false }
        return !lane.isRetired
    }

    /// Commits `queued` intent for one user input before any optimistic clear, bubble, or handoff:
    /// normal authority for a new tab, managed images (composer images are promoted first), the
    /// composer revision consumed by a composer submission, the immutable target, and the exact
    /// pending-handoff prefix this send will prepend (with its payload ID durably saved first). A
    /// refusal or failed commit writes nothing and returns `.blocked`; a commit whose lane retired
    /// meanwhile stays held (never dispatched or retargeted) and is also `.blocked`.
    func admitRecoveryInput(
        session: AgentTabSession,
        userItemID: UUID,
        origin: AgentRecoveryIntentOrigin,
        text: String,
        attachments: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        workflow: AgentWorkflowDefinition?,
        interviewFirst: Bool,
        consumesComposer: Bool,
        actionAuthorization: AgentRecoveryActionAuthorization? = nil
    ) async -> RecoveryInputAdmission {
        // Scoped shutdown freeze (app quit, or this window's close): refused before any authority,
        // promotion, or write, even for a session that would otherwise need no durable admission.
        if isRecoveryShutdownFrozen(session) {
            return .blocked(Self.recoveryAdmissionRefusalMessage(.shutdownInProgress))
        }
        guard requiresDurableRecoveryAdmission(for: session) else { return .notRequired }
        let tabID = session.tabID
        // A live lane is the session's durable authority; without one, normal authority is
        // established through the composed coordinator (fail closed when there is none).
        if session.recoveryLane == nil || session.recoveryLane?.isRetired == true {
            guard recoveryCoordinator != nil else { return .blocked(Self.recoveryAdmissionFailedMessage) }
            if let failure = await establishRecoveryAuthority(for: session) {
                print("[AgentModeVM][Recovery] input not admitted: no authority (\(failure))")
                return .blocked(Self.recoveryAdmissionFailedMessage)
            }
        }
        guard sessions[tabID] === session, let lane = session.recoveryLane, !lane.isRetired else {
            return .blocked(Self.recoveryAdmissionFailedMessage)
        }
        var images: [AgentRecoveryImageReference] = []
        if consumesComposer {
            if let failure = await promoteRecoveryImages(for: session, lane: lane) {
                print("[AgentModeVM][Recovery] input not admitted: \(failure)")
                return .blocked(Self.recoveryAdmissionFailedMessage)
            }
            guard sessions[tabID] === session, session.recoveryLane === lane, !lane.isRetired else {
                return .blocked(Self.recoveryAdmissionFailedMessage)
            }
        }
        // R12: the snapshot captured by the caller, not the live composer. Promotion swaps a live
        // attachment for its managed copy under the same ID; anything else is the captured value.
        let liveAttachments = consumesComposer
            ? attachments.map { captured in session.pendingImageAttachments.first { $0.id == captured.id } ?? captured }
            : attachments
        for attachment in liveAttachments {
            guard let reference = lane.store.existingImageReference(for: attachment, sessionID: lane.sessionID) else {
                return .blocked("An attached image could not be saved for recovery, so the message was not sent.")
            }
            images.append(reference)
        }
        let pendingHandoff: AgentRecoveryPendingHandoffSnapshot?
        switch await capturePendingHandoffForAdmission(session: session) {
        case let .captured(snapshot):
            pendingHandoff = snapshot
        case let .blocked(message):
            return .blocked(message)
        }
        guard sessions[tabID] === session, session.recoveryLane === lane, !lane.isRetired else {
            return .blocked(Self.recoveryAdmissionFailedMessage)
        }
        let content = AgentRecoveryInputContent(
            text: text,
            images: images,
            taggedFiles: taggedFiles.map(AgentRecoveryTaggedFileReference.init),
            workflow: workflow.map(AgentRecoveryWorkflowSnapshot.init),
            interviewFirst: interviewFirst
        )
        let target: AgentRecoveryIntentTarget = if session.runState.isActive, let runAttemptID = session.activeRunAttemptID {
            .liveRun(AgentRecoveryRunTarget(
                runAttemptID: runAttemptID,
                processRunID: session.runID,
                providerConversationID: session.selectedAgent == .codexExec ? session.codexConversationID : nil
            ))
        } else {
            .session
        }
        let admission = AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: userItemID,
            origin: origin,
            target: target,
            original: content,
            pendingHandoff: pendingHandoff,
            actionAuthorization: actionAuthorization
        )
        // Captured synchronously with the submitted content (no await since it was built). The
        // composer revision is consumed only while the live composer still is exactly the submitted
        // snapshot; typing during the awaits above is a newer revision that must survive (R12).
        let liveComposerIsSubmission = consumesComposer
            && recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID) == content
        let composerToken = liveComposerIsSubmission ? lane.beginComposerSubmission(content) : nil
        switch await lane.admitQueued(admission, composerToken: composerToken) {
        case let .success(admitted):
            return .admitted(
                AgentQueuedInputIdentity(receipt: admitted.receipt, actionAuthorization: actionAuthorization),
                lane: lane,
                content: content,
                attachments: liveAttachments
            )
        case let .failure(.refused(refusal)):
            print("[AgentModeVM][Recovery] input not admitted: refused \(refusal)")
            return .blocked(Self.recoveryAdmissionRefusalMessage(refusal))
        case let .failure(.commitFailed(failure)):
            print("[AgentModeVM][Recovery] input not admitted: commit failed \(failure)")
            return .blocked(Self.recoveryAdmissionFailedMessage)
        case .failure(.staleAfterCommit), .failure(.dispatchStaleAfterCommit):
            // `dispatchStaleAfterCommit` is dispatch-only; admission never reports it.
            return .blocked(Self.recoveryAdmissionStaleMessage)
        }
    }

    /// R01: an admitted intent whose submit was refused (or whose target went stale) before it was
    /// projected. A non-composer caller (MCP) still holds its input, so the intent is withdrawn. A
    /// composer submission may have consumed the durable composer, making the intent the only
    /// recoverable copy: it is withdrawn only after the exact original draft was durably written back
    /// as this lane's composer; otherwise it stays held (`queued`, never dispatched by this caller).
    func releaseRefusedRecoveryAdmission(
        _ admitted: AdmittedUserTurnInput,
        lane: AgentRecoverySessionLane,
        session: AgentTabSession
    ) async {
        guard let intentID = admitted.identity.intentID else { return }
        if admitted.consumesComposer {
            guard await durablyRestoreRefusedComposerSubmission(admitted, lane: lane, session: session) else {
                print("[AgentModeVM][Recovery] refused submission kept held: its draft was not durably restored")
                // Visible now (recovery list), not only after a restart.
                lane.noteProjectionRemoved(intentIDs: [intentID], reason: Self.refusedSubmissionHoldReason)
                return
            }
        }
        if case let .failure(failure) = await lane.withdraw(intentID: intentID) {
            print("[AgentModeVM][Recovery] unprojected intent could not be withdrawn: \(failure)")
            lane.noteProjectionRemoved(intentIDs: [intentID], reason: Self.refusedSubmissionHoldReason)
        }
    }

    /// Writes the refused submission's exact content back as the lane's composer, only while the
    /// live composer still is exactly that content (no newer edit), and reports whether the write of
    /// that very revision committed.
    private func durablyRestoreRefusedComposerSubmission(
        _ admitted: AdmittedUserTurnInput,
        lane: AgentRecoverySessionLane,
        session: AgentTabSession
    ) async -> Bool {
        guard sessions[session.tabID] === session,
              session.recoveryLane === lane,
              !lane.isRetired,
              recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID) == admitted.content,
              let revision = lane.composerDidChange(admitted.content)
        else { return false }
        guard case let .committed(receipt) = await lane.flushComposer() else { return false }
        return receipt.composerRevision == revision
    }

    enum PendingHandoffCapture {
        case captured(AgentRecoveryPendingHandoffSnapshot?)
        case blocked(String)
    }

    /// The exact pending-handoff prefix the next local send prepends (mirrors
    /// `prependPendingHandoffIfNeeded`), captured for the admission carrier before any queue
    /// acknowledgement or handoff can clear it. A legacy payload's newly assigned payload ID is
    /// persisted through a fenced session save first; if that save does not commit, the assignment
    /// is undone and the send is blocked.
    func capturePendingHandoffForAdmission(session: AgentTabSession) async -> PendingHandoffCapture {
        guard session.remoteHost == nil,
              !session.pendingHandoff.isReservedForSend,
              let payload = session.pendingHandoff.payload
        else { return .captured(nil) }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .captured(nil) }
        if session.pendingHandoff.payloadID == nil {
            guard let assigned = session.pendingHandoff.ensurePayloadID() else { return .captured(nil) }
            session.isDirty = true
            guard await flushSaveDetailed(for: session.tabID).didWriteDurably else {
                if session.pendingHandoff.payloadID == assigned {
                    session.pendingHandoff.payloadID = nil
                }
                return .blocked(Self.recoveryAdmissionFailedMessage)
            }
        }
        return .captured(AgentRecoveryPendingHandoffSnapshot(session.pendingHandoff, prependedText: trimmed + "\n\n"))
    }

    /// Stages the pending handoff onto `text` for a durable send whose carrier is still queued
    /// (adopted plan §5): the payload ID is made durable and the exact prefix is captured as a
    /// snapshot. The caller attaches the snapshot to the carrier before the dispatch commit
    /// (`AgentProviderHandoff.commitDispatch`, or `stagePendingHandoff(_:session:carriers:)`).
    /// `.failed` releases the new stage; the caller must block the send and keep its input saved.
    func stagePendingHandoffForDurableDispatch(
        _ text: String,
        session: AgentTabSession
    ) async -> AgentPendingHandoffDispatchStaging {
        let hadPayloadID = session.pendingHandoff.payloadID != nil
        let staged = stagePendingHandoffIfNeeded(text, session: session)
        guard let stage = staged.pendingHandoffStage else { return .none }
        let prefix = String(staged.text.dropLast(text.count))
        guard staged.text.hasSuffix(text),
              let snapshot = AgentRecoveryPendingHandoffSnapshot(session.pendingHandoff, prependedText: prefix),
              snapshot.payloadID == stage.payloadID
        else {
            recordPendingHandoffStageOutcome(for: session, stage: stage, disposition: .notSent)
            return .failed
        }
        if !hadPayloadID {
            guard await flushSaveDetailed(for: session.tabID).didWriteDurably else {
                recordPendingHandoffStageOutcome(for: session, stage: stage, disposition: .notSent)
                return .failed
            }
        }
        return .staged(staged, snapshot)
    }

    /// Presents durable input whose send was blocked before its dispatch commit (its handoff prefix
    /// could not be saved with it) as held input with `reason`. Its intents stay `queued`.
    func holdBlockedDurableInput(_ carriers: [AgentQueuedInputIdentity], session: AgentTabSession, reason: String) {
        let intentIDs = carriers.compactMap(\.intentID)
        guard !intentIDs.isEmpty, let lane = session.recoveryLane else { return }
        lane.noteProjectionRemoved(intentIDs: intentIDs, reason: reason)
    }

    /// Stages the pending handoff onto `text` for a send of `carriers` whose dispatch commit
    /// follows this call (R03, adopted plan §5): the exact snapshot is attached to the queued
    /// carrier intent first, and only then does the prefix ride on the provider text. If the
    /// payload cannot be saved or attached, the stage is released and the send is blocked
    /// (`blockedReason`) with its input still saved — it is never sent without its handoff. That
    /// includes a carrier whose attempt history does not prove non-delivery (`invalidTransition`):
    /// it stays blocked for explicit resolution. The attach and the dispatch that follows use the
    /// same lane; if the session's lane changed meanwhile the send is blocked. Untracked or remote
    /// input keeps legacy staging.
    func stagePendingHandoff(
        _ text: String,
        session: AgentTabSession,
        carriers: [AgentQueuedInputIdentity]
    ) async -> AgentStagedProviderText {
        guard session.remoteHost == nil,
              let carrierID = carriers.first(where: \.isDurable)?.intentID
        else { return stagePendingHandoffIfNeeded(text, session: session) }
        let blocked = AgentStagedProviderText(text: text, blockedReason: AgentPendingHandoffDispatchStaging.blockedReason)
        switch await stagePendingHandoffForDurableDispatch(text, session: session) {
        case .none:
            return AgentStagedProviderText(text: text)
        case .failed:
            return blocked
        case let .staged(staged, snapshot):
            guard let stage = staged.pendingHandoffStage else { return AgentStagedProviderText(text: text) }
            guard let lane = session.recoveryLane, lane.isValidForHandoff else {
                recordPendingHandoffStageOutcome(for: session, stage: stage, disposition: .notSent)
                return blocked
            }
            switch await lane.attachPendingHandoff(intentID: carrierID, snapshot: snapshot) {
            case .success:
                guard session.recoveryLane === lane, lane.isValidForHandoff else {
                    recordPendingHandoffStageOutcome(for: session, stage: stage, disposition: .notSent)
                    return blocked
                }
                // Attached: the durable record says this send prepends exactly this prefix, so it
                // does. The stage rides along only while it is still the session's current stage.
                return AgentStagedProviderText(
                    text: staged.text,
                    pendingHandoffStage: session.pendingHandoff.stage == stage ? stage : nil
                )
            case .failure:
                recordPendingHandoffStageOutcome(for: session, stage: stage, disposition: .notSent)
                return blocked
            }
        }
    }

    /// The refusal thrown when no dispatch identity exists for a remote send (nothing handed off).
    static var remoteDispatchUnavailableError: RemoteInputHandoffError {
        RemoteInputHandoffError(disposition: .notHandedOff, cause: .dispatchRefused(.refused(.untrackedInput)), evidence: nil)
    }

    /// Whether a remote send error proves the input may have reached the host.
    static func isRemoteDeliveryUnknown(_ error: any Error) -> Bool {
        (error as? RemoteInputHandoffError)?.disposition == .deliveryUnknown
    }

    // MARK: Composition

    /// Installs the app-scoped coordinator once, before any hydration (production:
    /// `AgentRecoveryAppComposition`; tests compose it directly). The VM's session writer becomes
    /// the coordinator's DataService, and every live session gains composer observation and, when
    /// it has persistence state, its lane.
    /// `admissionMode` applies to every live and new session (`.mandatory`: every user input is
    /// committed durably before projection or handoff).
    func installRecoveryCoordinator(
        _ coordinator: AgentRecoveryCoordinator,
        admissionMode: AgentRecoveryAdmissionMode = .inactive
    ) {
        guard recoveryCoordinator == nil else {
            assert(recoveryCoordinator === coordinator, "the recovery coordinator is installed once")
            return
        }
        recoveryCoordinator = coordinator
        recoveryAdmissionModeForSessions = admissionMode
        recoveryCompositionFailure = nil
        // Startup results, holds, and restrictions republish the current tab's composer (its
        // recovery list), re-report every open tab's busy state, and force a scheduler re-evaluation.
        recoveryCoordinatorChangeObserver = NotificationCenter.default
            .publisher(for: .agentRecoveryCoordinatorDidChange, object: coordinator)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                refreshRecoveryListUI()
                scheduledSendCoordinator?.recordDidChange()
            }
        // Live records, composer recovery state, and the catalog (questions, schedules awaiting
        // confirmation, shared action states) republish the current tab's composer (its recovery
        // list) and re-report every open tab's scheduler busy state; the scheduler re-evaluates
        // only when a tab's busy state actually changed. Unlike the observer above, this does not
        // force `recordDidChange()`: an ordinary write never changes startup results, holds, or
        // restrictions.
        recoveryLiveStateObserver = NotificationCenter.default
            .publisher(for: .agentRecoveryCatalogDidChange, object: coordinator)
            .merge(with: NotificationCenter.default.publisher(for: .agentRecoveryComposerStateDidChange, object: coordinator))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshRecoveryListUI()
            }
        // A carried or uncertain pending handoff re-joins once its carrier's evidence lands.
        recoveryPendingHandoffEvidenceObserver = NotificationCenter.default
            .publisher(for: .agentRecoveryDeliveryEvidenceDidSettle)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let lane = notification.object as? AgentRecoverySessionLane else { return }
                for session in sessions.values
                    where session.recoveryLane === lane && session.pendingHandoff.deliveryHold?.isRecoveryHold == true
                {
                    resolvePendingHandoffRecoveryJoin(for: session)
                }
            }
        for session in sessions.values {
            session.recoveryAdmissionMode = admissionMode
            recoveryPersistenceStateDidChange(for: session)
        }
    }

    /// Production composition failed: every live and new session stays mandatory without a
    /// coordinator, so every send route and the scheduler fail closed (no permissive fallback).
    func failRecoveryComposition(_ message: String) {
        guard recoveryCoordinator == nil else { return }
        recoveryCompositionFailure = message
        recoveryAdmissionModeForSessions = .mandatory
        for session in sessions.values {
            session.recoveryAdmissionMode = .mandatory
        }
        refreshRecoveryListUI()
    }

    // MARK: Lane ownership

    /// Re-binds `session`'s recovery lane to its current persistence state. Call after every
    /// assignment of `AgentTabSession.persistenceState`.
    func recoveryPersistenceStateDidChange(for session: AgentTabSession) {
        guard let coordinator = recoveryCoordinator else { return }
        let previous = session.recoveryLane
        defer {
            // A recovery-held payload re-joins against the new lane (a pending read bound to the old
            // lane is discarded) or retries once authority may have become available.
            let hold = session.pendingHandoff.deliveryHold
            if hold?.isRecoveryHold == true,
               session.recoveryLane !== previous || hold == .recoveryAuthorityUnavailable
            {
                resolvePendingHandoffRecoveryJoin(for: session)
            }
        }
        installRecoveryComposerObservation(on: session)
        guard let state = session.persistenceState else {
            session.recoveryLane = nil
            if let previous {
                coordinator.releaseLane(previous)
            }
            return
        }
        if let previous, !previous.isRetired, previous.persistenceState == state {
            return
        }
        let lane: AgentRecoverySessionLane
        do {
            lane = try coordinator.claimLane(owner: session, persistenceState: state)
        } catch {
            // No lifecycle authority: no lane. Producers require a lane once activated (fail closed);
            // composer input stays an owner-scoped obligation (observation remains installed).
            session.recoveryLane = nil
            if let previous {
                coordinator.releaseLane(previous)
            }
            return
        }
        if let previous, previous !== lane, previous.sessionID != lane.sessionID {
            coordinator.releaseLane(previous)
        }
        session.recoveryLane = lane
        // A session of a window frozen by its close joins that freeze (app quit freezes every owner).
        if let token = shutdownFreezeState?.recoveryToken {
            coordinator.extendShutdownFreeze(token, owner: session)
        }
        // Eager restore: edits typed meanwhile are buffered by the lane under their original
        // first-unsaved instant.
        Task { [weak self, weak session] in
            let outcome = await lane.restoreComposer()
            guard let self, let session, session.recoveryLane === lane else { return }
            applyRecoveryRestoreOutcome(outcome, lane: lane, to: session)
        }
        // An obligation recorded before this lane existed is handed over with its original instant.
        if let preparation = coordinator.composerPreparation(for: session), !preparation.isPreparing {
            startRecoveryComposerPreparation(for: session, coordinator: coordinator)
        }
    }

    /// Installs composite composer observation whenever recovery is composed, with or without a
    /// lane, so first-draft typing of a new tab is observed from its first mutation. Installed by
    /// `makeSession` (the single tab-session creation path) before any seeded draft, by every
    /// persistence-state (re)binding, and for existing sessions by `installRecoveryCoordinator`.
    func installRecoveryComposerObservation(on session: AgentTabSession) {
        if let recoveryCoordinator, session.recoveryCoordinator == nil {
            session.recoveryCoordinator = recoveryCoordinator
        }
        guard recoveryCoordinator != nil, session.recoveryComposerObserver == nil else { return }
        session.recoveryComposerObserver = { [weak self] session in
            self?.recoveryComposerDidMutate(session: session)
        }
    }

    /// Flushes the outgoing tab's composer (tab switch). Completion never adopts into another tab:
    /// the lane is bound to its own durable session.
    func flushRecoveryComposer(for session: AgentTabSession) {
        guard let lane = session.recoveryLane, !lane.isRetired else { return }
        Task { _ = await lane.flushComposer() }
    }

    // MARK: Composer snapshots

    /// Immutable snapshot of the session's live composer (text, images, tagged files, workflow with
    /// its captured template, interview choice). `nil` when an image is not yet represented in
    /// managed recovery storage.
    func recoveryInputContent(for session: AgentTabSession, store: AgentRecoveryStore, sessionID: UUID) -> AgentRecoveryInputContent? {
        var images: [AgentRecoveryImageReference] = []
        for attachment in session.pendingImageAttachments {
            guard let reference = store.existingImageReference(for: attachment, sessionID: sessionID) else {
                return nil
            }
            images.append(reference)
        }
        return AgentRecoveryInputContent(
            text: session.draftText,
            images: images,
            taggedFiles: session.pendingTaggedFileAttachments.map(AgentRecoveryTaggedFileReference.init),
            workflow: session.selectedWorkflow.map(AgentRecoveryWorkflowSnapshot.init),
            interviewFirst: effectiveInterviewFirst(for: session)
        )
    }

    /// Composite composer observation target. With a live lane the snapshot is forwarded (an
    /// unpromoted image starts promotion under the same timed obligation). Without one, the first
    /// mutation records the owner's obligation at its own instant and starts the single
    /// preparation task; later mutations coalesce into it.
    func recoveryComposerDidMutate(session: AgentTabSession) {
        guard let coordinator = recoveryCoordinator else { return }
        guard let lane = session.recoveryLane, !lane.isRetired else {
            let content = session.pendingImageAttachments.isEmpty
                ? recoveryInputContent(for: session, store: coordinator.store, sessionID: session.activeAgentSessionID ?? UUID())
                : nil
            if let content, content.isEmpty, coordinator.composerPreparation(for: session) == nil {
                return
            }
            coordinator.recordComposerMutationAwaitingPreparation(owner: session, content: content)
            startRecoveryComposerPreparation(for: session, coordinator: coordinator)
            return
        }
        guard let content = recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID) else {
            let preparation = coordinator.recordComposerMutationAwaitingPreparation(owner: session, content: nil)
            lane.composerContentUnrepresentable(firstUnsavedAt: preparation.firstUnsavedAt)
            startRecoveryComposerPreparation(for: session, coordinator: coordinator)
            return
        }
        if let preparation = coordinator.composerPreparation(for: session) {
            guard !preparation.isPreparing else {
                // Coalesced: the running preparation forwards the latest content when it finishes.
                coordinator.recordComposerMutationAwaitingPreparation(owner: session, content: content)
                return
            }
            coordinator.completeComposerPreparation(owner: session, forwardingTo: lane, content: content)
            return
        }
        lane.composerDidChange(content)
    }

    // MARK: Composer preparation (authority, promotion)

    private func startRecoveryComposerPreparation(for session: AgentTabSession, coordinator: AgentRecoveryCoordinator) {
        coordinator.startComposerPreparation(owner: session) { [weak self, weak session] _ in
            guard let self, let session else { return .ownerReplaced }
            return await prepareRecoveryComposer(for: session, coordinator: coordinator)
        }
    }

    /// The single preparation: normal foundation authority (exclusive creation for a genuinely new
    /// tab, adopted only under the existing owner fences), lane claim with eager restore, image
    /// promotion through the existing import path, then hand-over of the latest snapshot with the
    /// obligation's original first-unsaved instant. Every failure keeps the obligation visible.
    private func prepareRecoveryComposer(
        for session: AgentTabSession,
        coordinator: AgentRecoveryCoordinator
    ) async -> AgentRecoveryComposerPreparationFailure? {
        let tabID = session.tabID
        if session.recoveryLane == nil || session.recoveryLane?.isRetired == true {
            if let failure = await establishRecoveryAuthority(for: session) {
                return failure
            }
        }
        guard sessions[tabID] === session, let lane = session.recoveryLane, !lane.isRetired, lane.isOwned(by: session) else {
            return .ownerReplaced
        }
        if let failure = await promoteRecoveryImages(for: session, lane: lane) {
            return failure
        }
        guard sessions[tabID] === session, session.recoveryLane === lane, !lane.isRetired else { return .ownerReplaced }
        guard let content = recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID) else {
            return .imagePromotionFailed("an attachment is not represented in managed recovery storage")
        }
        switch coordinator.completeComposerPreparation(owner: session, forwardingTo: lane, content: content) {
        case let .failure(failure):
            return failure
        case .success:
            return nil
        }
    }

    /// Establishes authority for an owner without a lane. A session with persistence state reclaims
    /// its lane; a genuinely new tab is created through the existing exclusive creation path with
    /// its normal initial session (a creation conflict never adopts another creator's authority;
    /// a late completion keeps its committed authority only for its originating owner).
    private func establishRecoveryAuthority(for session: AgentTabSession) async -> AgentRecoveryComposerPreparationFailure? {
        if session.persistenceState != nil {
            recoveryPersistenceStateDidChange(for: session)
            return session.recoveryLane == nil ? .authorityUnavailable("no lifecycle authority for the session") : nil
        }
        guard !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else {
            return .authorityUnavailable("session persistence is suppressed")
        }
        guard session.staleResetRecovery == nil else { return .authorityUnavailable("stale reset recovery is pending") }
        guard let context = currentSessionPersistenceContext(), sessionPersistenceContextIsCurrent(context) else {
            return .authorityUnavailable("no current persistence context")
        }
        guard sessions[session.tabID] === session, let sessionID = ensureSessionBoundToTab(session) else {
            return .ownerReplaced
        }
        let workspace = context.workspace
        let initialSession = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: session.tabID,
            name: resolvedSessionDisplayName(for: session.tabID),
            agentKind: session.selectedAgent.rawValue,
            agentModel: session.selectedModelRaw,
            ohMyPiThinkingSelections: session.ohMyPiThinkingSelections.nilIfEmpty,
            agentReasoningEffort: session.selectedReasoningEffortRaw,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: session.parentSessionID,
            isMCPOriginated: session.isMCPOriginated,
            origin: session.origin,
            profile: session.profile,
            worktreeBindings: session.worktreeBindings
        )
        let acquisition = await acquirePersistenceState(
            for: session,
            sessionID: sessionID,
            workspace: workspace,
            context: context,
            initialSession: initialSession
        )
        guard acquisition.state != nil else {
            return acquisition.createdDurably
                ? .ownerReplaced
                : .authorityUnavailable("the session could not be created or adopted")
        }
        return session.recoveryLane == nil ? .authorityUnavailable("no lifecycle authority for the session") : nil
    }

    /// Imports unmanaged composer images into the lane's managed recovery storage (existing import
    /// validation) and swaps the live attachments for their managed copies without reporting a new
    /// edit. A failure keeps the live attachment and is reported persistently by the obligation.
    private func promoteRecoveryImages(
        for session: AgentTabSession,
        lane: AgentRecoverySessionLane
    ) async -> AgentRecoveryComposerPreparationFailure? {
        let store = lane.store
        let sessionID = lane.sessionID
        for _ in 0 ..< 3 {
            let unmanaged = session.pendingImageAttachments.filter {
                store.existingImageReference(for: $0, sessionID: sessionID) == nil
            }
            guard !unmanaged.isEmpty else { return nil }
            var promoted: [UUID: AgentImageAttachment] = [:]
            for attachment in unmanaged {
                do {
                    let reference = try await store.importManagedImage(sessionID: sessionID, attachment: attachment)
                    guard let managed = store.attachment(for: reference, sessionID: sessionID) else {
                        return .imagePromotionFailed("the imported image could not be resolved")
                    }
                    promoted[attachment.id] = managed
                } catch {
                    return .imagePromotionFailed(String(describing: error))
                }
            }
            guard session.recoveryLane === lane, !lane.isRetired else { return .ownerReplaced }
            session.withRecoveryComposerObservationSuppressed {
                session.pendingImageAttachments = session.pendingImageAttachments.map { promoted[$0.id] ?? $0 }
            }
            syncComposerUIState(tabID: session.tabID)
        }
        let remaining = session.pendingImageAttachments.contains {
            store.existingImageReference(for: $0, sessionID: sessionID) == nil
        }
        return remaining ? .imagePromotionFailed("attachments kept changing during promotion") : nil
    }

    // MARK: Transcript reset preparation

    /// Pre-reset preserve/veto (spec R2 reset ordering). Joins the owner's preparation and the
    /// lane's restore and admitted submissions, then writes the latest composer under the current
    /// generation. Returns the veto reason when input would remain unrepresentable, unwritten, or
    /// only in memory; the caller must then not reset (nothing was cleared). On `nil` the lane stays
    /// closed to admission until the reset commits (the successor claim retires it) or
    /// `endRecoveryTranscriptResetPreparation` releases it. Inactive (`nil`) when recovery is not
    /// composed.
    func prepareRecoveryTranscriptReset(for session: AgentTabSession) async -> AgentRecoveryResetPreparationFailure? {
        // No binding change while shutdown preparation owns this session (vetoed, nothing cleared).
        if isRecoveryShutdownFrozen(session) { return .alreadyPreparing }
        guard let coordinator = recoveryCoordinator else { return nil }
        if let preparation = coordinator.composerPreparation(for: session) {
            await preparation.preparationTask?.value
            if coordinator.composerPreparation(for: session) != nil {
                return .unrepresentableComposerInput
            }
        }
        guard let lane = session.recoveryLane, !lane.isRetired else { return nil }
        let ownerBinding = session.persistentSessionBindingIdentity
        if case let .failure(failure) = await lane.prepareForTranscriptReset() {
            return failure
        }
        guard sessions[session.tabID] === session,
              session.persistentSessionBindingIdentity == ownerBinding,
              session.recoveryLane === lane
        else {
            lane.endTranscriptResetPreparation()
            return .laneRetired
        }
        return nil
    }

    /// Releases a successful preparation whose reset did not commit.
    func endRecoveryTranscriptResetPreparation(for session: AgentTabSession, lane: AgentRecoverySessionLane?) {
        guard let lane, session.recoveryLane === lane, !lane.isRetired else { return }
        lane.endTranscriptResetPreparation()
    }

    // MARK: Restore

    private func applyRecoveryRestoreOutcome(
        _ outcome: AgentRecoveryComposerRestoreOutcome,
        lane: AgentRecoverySessionLane,
        to session: AgentTabSession
    ) {
        let live = recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID)
        let liveIsEmpty = live?.isEmpty ?? false
        switch outcome {
        case let .restored(snapshot):
            if let snapshot, liveIsEmpty {
                applyRecoveredComposer(snapshot.content, lane: lane, to: session)
            } else if !liveIsEmpty {
                // Live typing that predates the lane is newer than any stored composer.
                recoveryComposerDidMutate(session: session)
            }
        case .heldForOtherGeneration:
            // The held composer is surfaced for explicit resolution; live typing is kept pending.
            if !liveIsEmpty {
                recoveryComposerDidMutate(session: session)
            }
        case .superseded, .failed:
            break
        }
    }

    /// Explicit user resolution of exactly the displayed held composer (recovery list Restore /
    /// Discard). Restored content is placed only while the live composer is still empty; newer
    /// typing keeps the composer (the lane keeps the restored content visible instead).
    func resolveHeldRecoveryComposer(
        _ choice: AgentRecoveryHeldComposerChoice,
        expectedHeldRevision: AgentRecoveryComposerRevision,
        for session: AgentTabSession
    ) async -> Result<Void, AgentRecoveryControllerFailure> {
        guard recoveryCoordinator != nil, let lane = session.recoveryLane, !lane.isRetired else { return .failure(.retired) }
        let live = recoveryInputContent(for: session, store: lane.store, sessionID: lane.sessionID)
        let result = await lane.resolveHeldComposer(
            choice,
            expectedHeldRevision: expectedHeldRevision,
            liveComposerIsEmpty: live?.isEmpty ?? false
        )
        switch result {
        case let .failure(failure):
            return .failure(failure)
        case let .success(snapshot):
            if let snapshot, session.recoveryLane === lane {
                applyRecoveredComposer(snapshot.content, lane: lane, to: session)
            }
            return .success(())
        }
    }

    /// Retries a failed composer restore and applies its outcome (recovery list).
    func retryRecoveryComposerRestore(for session: AgentTabSession) async -> AgentRecoveryComposerRestoreOutcome {
        guard let lane = session.recoveryLane, !lane.isRetired else { return .failed(.retired) }
        let outcome = await lane.restoreComposer()
        if session.recoveryLane === lane {
            applyRecoveryRestoreOutcome(outcome, lane: lane, to: session)
        }
        return outcome
    }

    /// Places recovered content into the live composer without reporting it as a new edit.
    func applyRecoveredComposer(
        _ content: AgentRecoveryInputContent,
        lane: AgentRecoverySessionLane,
        to session: AgentTabSession
    ) {
        // A managed reference whose file is missing still resolves (to its managed path) and is
        // kept, so the reference round-trips through the next composer write instead of being
        // dropped. A reference that cannot resolve at all is never dropped silently: the restore is
        // not applied and the stored composer stays untouched for explicit resolution.
        var images: [AgentImageAttachment] = []
        for reference in content.images {
            guard let attachment = lane.store.attachment(for: reference, sessionID: lane.sessionID) else {
                print("[AgentModeVM][Recovery] recovered composer not applied: an image reference cannot be resolved")
                return
            }
            images.append(attachment)
        }
        session.withRecoveryComposerObservationSuppressed {
            if session.tabID == currentTabID {
                restoreComposerDraft(
                    tabID: session.tabID,
                    text: content.text,
                    message: "Restored unsent draft",
                    strategy: .replaceIfEmpty
                )
            } else {
                session.draftText = content.text
            }
            session.pendingImageAttachments = images
            session.pendingTaggedFileAttachments = content.taggedFiles.map(\.attachment)
            session.selectedWorkflow = content.workflow?.definition
            session.interviewFirst = content.interviewFirst
            if session === activeSession {
                selectedWorkflow = session.selectedWorkflow
                interviewFirst = session.interviewFirst
            }
        }
        syncComposerUIState(tabID: session.tabID)
        syncStatusPillsUIState()
    }
}
