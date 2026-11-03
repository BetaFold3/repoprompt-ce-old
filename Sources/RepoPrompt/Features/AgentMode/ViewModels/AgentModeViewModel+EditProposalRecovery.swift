import AppKit
import Foundation
import MCP
import RepoPromptAgentCore
import RepoPromptWorkspace

// Lossless-restart Step 5a (docs/context/plans/completed/2026-10-18-lossless-app-restart-spec.md, Phase 5):
// ordinary pending `apply_edits` reviews of a recovery-tracked Agent Mode session.
//
// - The owner (the reviewing tab's session, its exact recovery lane, the lane's binding, and the
//   session's existing ownership identity), and whether recovery is required, are frozen
//   synchronously before the review's first new await (target resolution, preview, ticket). The
//   review's identity then comes from the approval store's ticket; admission validates the frozen
//   owner and never adopts a replacement or falls back to untracked after an await.
// - The persisted target is the canonical absolute file the preview read and the reviewed write
//   uses (resolved once by the provider's workspace host), never a relative or alias string.
// - The exact proposal (proposed text, displayed diff, physical and display paths, owner, and the
//   preview's decoded-text base evidence) is committed `pending` before the live review is shown.
//   A refused or failed commit shows nothing and writes nothing.
// - On accept, `applicationStarted` is committed before the existing live host write begins; a
//   refusal there writes nothing (the proposal reverts to `pending`, best effort).
// - The fence (same session object in the tab with the same existing ownership identity: binding,
//   binding transition generation, persistence state, lane, parent; no binding transition in
//   progress; the same lane and lifecycle binding, valid for handoff, owned; not shutdown-frozen)
//   and Task cancellation are re-checked after every new await. After `applicationStarted`, the
//   exact review ticket is re-checked at the approval store, then the fence again synchronously
//   before the write. A replacement session is never silently bound; no lock is held while the
//   user decides.
// - A completed write removes the proposal (`applied`); if that record write fails the caller
//   reports partial success, never "nothing changed". An explicit reject withdraws it. Timeout and
//   every lifecycle cancellation keep it as history: the recovery list then offers only View,
//   Copy, and Discard. Nothing is ever applied from history.
// - An independent caller (no Agent Mode tab) or a session without durable recovery admission is
//   unchanged (no record is written).

/// What one previewed proposal stores for recovery.
struct ApplyEditsReviewProposalInput {
    let physicalPath: String
    let displayPath: String
    let unifiedDiff: String
    let proposedText: String
    /// The preview's decoded original text; `nil` when the target did not exist.
    let baseText: String?
}

#if DEBUG
    /// The new edit-review awaits a test may hold (`test_editProposalRecoveryAwaitHook`).
    enum EditProposalRecoveryAwaitPoint: Equatable {
        case pendingCommit
        case applicationStartedCommit
        case reviewTicketCheck
    }
#endif

/// The recovery-tracked owner of one `apply_edits` review, frozen before its first new await.
@MainActor
final class ApplyEditsReviewRecoveryOwner {
    let tabID: UUID
    let sessionID: UUID
    /// The lane's lifecycle binding (session, incarnation, reset generation) at capture.
    let binding: AgentRecoveryLifecycleBinding
    /// The session's existing ownership facts at capture (no new generation).
    let ownerIdentity: MCPDelegatedChildIdentity
    private(set) weak var session: AgentTabSession?
    private(set) weak var lane: AgentRecoverySessionLane?

    fileprivate init(tabID: UUID, sessionID: UUID, session: AgentTabSession, lane: AgentRecoverySessionLane) {
        self.tabID = tabID
        self.sessionID = sessionID
        binding = lane.binding
        ownerIdentity = MCPDelegatedChildIdentity(session)
        self.session = session
        self.lane = lane
    }
}

/// One reviewed proposal admitted under its frozen recovery-tracked owner.
@MainActor
final class ApplyEditsReviewRecoveryAdmission {
    let reviewID: UUID
    let owner: ApplyEditsReviewRecoveryOwner
    /// `applicationStarted` was acknowledged (the write may have begun after this).
    fileprivate(set) var isApplicationStarted = false
    /// The live phase ended (the proposal, if still stored, is historical).
    fileprivate(set) var isFinished = false

    var session: AgentTabSession? {
        owner.session
    }

    var lane: AgentRecoverySessionLane? {
        owner.lane
    }

    fileprivate init(reviewID: UUID, owner: ApplyEditsReviewRecoveryOwner) {
        self.reviewID = reviewID
        self.owner = owner
    }
}

/// The final record write of a reviewed proposal.
enum ApplyEditsReviewRecoveryFinish {
    /// The accepted write completed: remove the proposal.
    case applied
    /// Explicit user rejection: withdraw the proposal.
    case withdrawn
    /// Timeout, lifecycle cancellation, or a failed write: keep whatever is stored as history.
    case preserved
}

extension AgentModeViewModel {
    /// Freezes the review's owner synchronously, before any new await. Returns nil (unchanged
    /// legacy behavior) only when the owner is established untracked here: the tab's session has no
    /// durable recovery admission, or the tab has no session while admission is not mandatory.
    /// Throws (fail closed) for a missing session under mandatory admission or an unavailable or
    /// inconsistent recovery owner.
    func mcpCaptureApplyEditsReviewOwner(tabID: UUID) throws -> ApplyEditsReviewRecoveryOwner? {
        guard let session = sessions[tabID] else {
            guard recoveryAdmissionModeForSessions != .mandatory else {
                throw Self.editReviewRefusal("this tab's Agent session is not available")
            }
            return nil
        }
        guard requiresDurableRecoveryAdmission(for: session) else { return nil }
        guard !isRecoveryShutdownFrozen(session) else {
            throw Self.editReviewRefusal("RepoPrompt is closing this session")
        }
        guard let sessionID = session.activeAgentSessionID,
              !session.bindingTransitionInProgress,
              let lane = session.recoveryLane,
              lane.isValidForHandoff,
              lane.isOwned(by: session),
              lane.sessionID == sessionID,
              Self.editReviewPersistenceMatches(session, lane.binding)
        else {
            throw Self.editReviewRefusal("this session's recovery state is not available")
        }
        return ApplyEditsReviewRecoveryOwner(tabID: tabID, sessionID: sessionID, session: session, lane: lane)
    }

    /// Admits and commits `input` as review `reviewID`'s pending proposal before the review is shown,
    /// under the owner frozen by `mcpCaptureApplyEditsReviewOwner`. Nil owner is the unchanged legacy
    /// path. Throws, having shown and written nothing, when the frozen owner is no longer current
    /// (reset, rebound, replaced, removed), the request was cancelled, or the commit failed.
    func mcpAdmitApplyEditsReviewProposal(
        owner: ApplyEditsReviewRecoveryOwner?,
        reviewID: UUID,
        input: ApplyEditsReviewProposalInput
    ) async throws -> ApplyEditsReviewRecoveryAdmission? {
        guard let owner else { return nil }
        guard !Task.isCancelled, editReviewOwnerIsCurrent(owner), let session = owner.session, let lane = owner.lane else {
            throw Self.editReviewRefusal("the session changed or the request was cancelled before the review was shown")
        }
        let admission = ApplyEditsReviewRecoveryAdmission(reviewID: reviewID, owner: owner)
        let proposal = AgentRecoveryEditProposal(
            reviewID: reviewID,
            runAttemptID: session.activeRunOwnership?.attemptID,
            transcriptResetGeneration: lane.binding.transcriptResetGeneration,
            appInstanceID: lane.store.appInstanceID,
            proposedAt: AgentRecoveryTimestamp(Date()),
            physicalPath: input.physicalPath,
            displayPath: input.displayPath,
            unifiedDiff: input.unifiedDiff,
            proposedText: input.proposedText,
            base: .preview(originalText: input.baseText)
        )
        // Live before the commit, so the stored proposal never flashes as historical.
        lane.noteEditProposalLive(reviewID)
        #if DEBUG
            if let hook = test_editProposalRecoveryAwaitHook {
                await hook(session, .pendingCommit)
            }
        #endif
        if case .failure = await lane.commitEditProposal(proposal) {
            admission.isFinished = true
            lane.endEditProposalLive(reviewID)
            throw Self.editReviewRefusal("the proposed edit could not be saved for crash recovery, so it was not shown")
        }
        guard !Task.isCancelled, editReviewRecoveryIsCurrent(admission) else {
            // Committed, never shown: kept as history (the request ended).
            finishLive(admission)
            throw Self.editReviewRefusal("the session changed or the request was cancelled before the review was shown")
        }
        return admission
    }

    /// The accepted review's write: for an admitted proposal, `applicationStarted` is acknowledged
    /// and the exact ticket and owner re-checked before `write` runs, then the outcome is
    /// recorded. Returns false only when the write completed but its `applied` record failed
    /// (partial success). A refusal before the write throws, having written nothing. Without an
    /// admission (legacy) `write` runs unchanged.
    func mcpPerformAcceptedApplyEditsReview(
        _ admission: ApplyEditsReviewRecoveryAdmission?,
        ticketIsCurrent: () async -> Bool,
        write: () async throws -> Void
    ) async throws -> Bool {
        guard admission != nil else {
            try await write()
            return true
        }
        try await mcpBeginApplyEditsReviewApplication(admission, ticketIsCurrent: ticketIsCurrent)
        do {
            try await write()
        } catch {
            // Whether the file changed is unknown: the proposal stays marked possibly applied
            // in recovery (never reverted to pending).
            await mcpFinishApplyEditsReview(admission, .preserved)
            throw error
        }
        return await mcpFinishApplyEditsReview(admission, .applied)
    }

    /// The accepted proposal's `applicationStarted` commit, acknowledged before the live write
    /// begins; then the exact review ticket (`ticketIsCurrent`, the approval store's check) and,
    /// synchronously after that await, the owner fence and cancellation. Throws, having written
    /// nothing, when the owner changed, the review was replaced or closed, or the commit failed.
    private func mcpBeginApplyEditsReviewApplication(
        _ admission: ApplyEditsReviewRecoveryAdmission?,
        ticketIsCurrent: () async -> Bool
    ) async throws {
        guard let admission else { return }
        guard !admission.isFinished, !Task.isCancelled, editReviewRecoveryIsCurrent(admission),
              let session = admission.session, let lane = admission.lane
        else {
            finishLive(admission)
            throw Self.editReviewRefusal("the session changed or the request was cancelled before the accepted edit was written")
        }
        #if DEBUG
            if let hook = test_editProposalRecoveryAwaitHook {
                await hook(session, .applicationStartedCommit)
            }
        #endif
        if case .failure = await lane.transitionEditProposal(reviewID: admission.reviewID, .applicationStarted) {
            // Known not written; the failed commit's state is unknown, so return it to pending
            // (best effort; a retired lane leaves whatever was stored, never applied).
            await revertApplicationNotStarted(admission, lane: lane)
            throw Self.editReviewRefusal("RepoPrompt could not record that the accepted edit was starting")
        }
        guard !Task.isCancelled, editReviewRecoveryIsCurrent(admission) else {
            await revertApplicationNotStarted(admission, lane: lane)
            throw Self.editReviewRefusal("the session changed or the request was cancelled before the accepted edit was written")
        }
        #if DEBUG
            if let hook = test_editProposalRecoveryAwaitHook {
                await hook(session, .reviewTicketCheck)
            }
        #endif
        guard await ticketIsCurrent() else {
            await revertApplicationNotStarted(admission, lane: lane)
            throw Self.editReviewRefusal("the review was replaced or closed before the accepted edit was written")
        }
        // Synchronous after the ticket's actor hop: nothing can retarget before the write begins.
        guard !Task.isCancelled, editReviewRecoveryIsCurrent(admission) else {
            await revertApplicationNotStarted(admission, lane: lane)
            throw Self.editReviewRefusal("the session changed or the request was cancelled before the accepted edit was written")
        }
        admission.isApplicationStarted = true
    }

    /// Known not written: best effort returns the stored proposal to pending (if that fails it stays
    /// possibly applied, never applied), then always ends the live phase so it is listed as history.
    private func revertApplicationNotStarted(
        _ admission: ApplyEditsReviewRecoveryAdmission,
        lane: AgentRecoverySessionLane
    ) async {
        defer { finishLive(admission) }
        admission.isFinished = true
        _ = await lane.transitionEditProposal(reviewID: admission.reviewID, .applicationNotStarted)
    }

    /// Ends the review's live phase with its final record write. Returns false only when a
    /// required record write (`applied` / `withdrawn`) failed; the stored proposal then stays
    /// historical (an accepted, written edit then remains marked possibly applied).
    @discardableResult
    func mcpFinishApplyEditsReview(
        _ admission: ApplyEditsReviewRecoveryAdmission?,
        _ finish: ApplyEditsReviewRecoveryFinish
    ) async -> Bool {
        guard let admission, !admission.isFinished else { return true }
        defer { finishLive(admission) }
        let transition: AgentRecoveryEditProposalTransition
        switch finish {
        case .preserved:
            return true
        case .applied:
            transition = .applied
        case .withdrawn:
            transition = .withdrawn
        }
        guard let lane = admission.lane else { return false }
        if case .failure = await lane.transitionEditProposal(reviewID: admission.reviewID, transition) {
            return false
        }
        return true
    }

    private func finishLive(_ admission: ApplyEditsReviewRecoveryAdmission) {
        admission.isFinished = true
        admission.lane?.endEditProposalLive(admission.reviewID)
    }

    private func editReviewRecoveryIsCurrent(_ admission: ApplyEditsReviewRecoveryAdmission) -> Bool {
        editReviewOwnerIsCurrent(admission.owner)
    }

    /// The frozen owner still holds the tab with exactly its captured identity and lane.
    private func editReviewOwnerIsCurrent(_ owner: ApplyEditsReviewRecoveryOwner) -> Bool {
        guard let session = owner.session,
              sessions[owner.tabID] === session,
              !session.bindingTransitionInProgress,
              session.activeAgentSessionID == owner.sessionID,
              MCPDelegatedChildIdentity(session) == owner.ownerIdentity,
              let lane = owner.lane,
              session.recoveryLane === lane,
              lane.binding == owner.binding,
              lane.sessionID == owner.sessionID,
              lane.isValidForHandoff,
              lane.isOwned(by: session),
              Self.editReviewPersistenceMatches(session, owner.binding),
              !isRecoveryShutdownFrozen(session)
        else {
            return false
        }
        return true
    }

    /// The session's persistence state is the lane binding's incarnation and reset generation.
    private static func editReviewPersistenceMatches(
        _ session: AgentTabSession,
        _ binding: AgentRecoveryLifecycleBinding
    ) -> Bool {
        guard let state = session.persistenceState else { return false }
        return state.stamp.incarnationID == binding.incarnationID
            && state.transcriptResetGeneration == binding.transcriptResetGeneration
    }

    // MARK: Recovery list (historical proposals)

    /// Viewer text is capped; Copy always copies the full stored proposal.
    static let recoveryListEditProposalDisplayLimit = 20000

    static func recoveryListEditProposalDetail(_ proposal: AgentRecoveryEditProposal, isCurrentLaunch: Bool) -> String {
        let ended = isCurrentLaunch
            ? "The agent's edit request ended (its review timed out or was replaced by a newer one, or its tab, window, or run ended)."
            : "The agent proposed this edit before RepoPrompt closed. That request has ended."
        let outcome = proposal.state == .applicationStarted
            ? "It was accepted and writing had started, so whether the file changed is uncertain, even if the file now matches it."
            : "It was not written, nothing was applied automatically, and the agent can't receive a result for it."
        return "\(ended) \(outcome) Target: \(proposal.displayPath)."
    }

    static func recoveryListEditProposalText(_ proposal: AgentRecoveryEditProposal) -> String {
        let full = """
        Target: \(proposal.displayPath)
        File: \(proposal.physicalPath)

        Proposed change:
        \(proposal.unifiedDiff)

        Proposed file content:
        \(proposal.proposedText)
        """
        guard full.count > recoveryListEditProposalDisplayLimit else { return full }
        return String(full.prefix(recoveryListEditProposalDisplayLimit))
            + "\n\n[Shortened for display. Copy proposal copies the full proposed content.]"
    }

    /// The stored proposal a recovery row shows (nil once it left the catalog).
    private func recoveryListEditProposal(_ rowID: String) -> AgentRecoveryEditProposal? {
        guard let item = recoveryListCatalogItem(rowID), case let .editProposal(proposal, _) = item.payload else { return nil }
        return proposal
    }

    /// Copy: the exact stored proposed text. Never writes the target file.
    func copyRecoveryEditProposal(rowID: String) -> String? {
        guard let proposal = recoveryListEditProposal(rowID) else { return "This proposal is no longer available." }
        #if DEBUG
            if let writer = test_recoveryListPasteboardWriter {
                writer(proposal.proposedText)
                return nil
            }
        #endif
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proposal.proposedText, forType: .string)
        return nil
    }

    /// Discard: durably withdraws exactly the displayed proposal of the open session. The target
    /// file is never read or written.
    func discardRecoveryEditProposal(rowID: String) async -> String? {
        guard let item = recoveryListCatalogItem(rowID),
              case let .editProposal(proposal, _) = item.payload,
              let sessionID = item.sessionID
        else { return "This proposal is no longer available." }
        let reviewID = proposal.reviewID
        guard let (_, lane) = recoveryListLane(sessionID: sessionID) else {
            return "Open this session to discard this proposal."
        }
        guard !lane.liveEditProposalIDs.contains(reviewID) else {
            return "This proposal is still being reviewed."
        }
        if case let .failure(failure) = await lane.transitionEditProposal(reviewID: reviewID, .withdrawn) {
            return "The proposal couldn't be discarded (\(Self.recoveryListDescription(of: failure))). Nothing was changed."
        }
        return nil
    }

    /// View: a transient, read-only comparison of the target file (decoded by the same workspace
    /// host as the preview) with the stored proposal. A missing or unreadable file never blocks
    /// View or Copy; a match never proves the proposal was applied.
    func inspectRecoveryEditProposal(rowID: String) async -> String? {
        guard let item = recoveryListCatalogItem(rowID), case let .editProposal(proposal, _) = item.payload else {
            return nil
        }
        if item.workspaceID != nil, item.workspaceID != persistenceWorkspace?.id {
            return "This proposal belongs to another workspace. Open that workspace to compare it with the current file."
        }
        guard let store = promptManager?.workspaceFileContextStore else {
            return "The current file couldn't be checked."
        }
        let description = await Self.recoveryListEditProposalInspection(proposal, store: store)
        // Identity fence: only the proposal that was displayed is described.
        guard let current = recoveryListEditProposal(rowID), current.hasSameProposal(as: proposal) else {
            return "This proposal changed. Open View again."
        }
        return description
    }

    /// View's transient comparison of the stored canonical absolute target, read through the same
    /// workspace host decoding as the preview, against `store`'s visible workspace roots. The stored
    /// path is never re-resolved as a relative or alias string, so a changed selection or added root
    /// can't retarget it. A target outside every visible root (for example a session worktree) is
    /// reported neutrally, never as missing or deleted.
    static func recoveryListEditProposalInspection(
        _ proposal: AgentRecoveryEditProposal,
        store: WorkspaceFileContextStore
    ) async -> String {
        let path = StandardizedPath.absolute(proposal.physicalPath)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        guard path.hasPrefix("/"),
              roots.contains(where: { path == $0.standardizedFullPath || path.hasPrefix($0.standardizedFullPath + "/") })
        else {
            return "The target isn't inside this window's loaded workspace roots (for example, it was in a session worktree), so it can't be compared here."
        }
        let host = WorkspaceFileEditHost(store: store, lookupRootScope: .visibleWorkspace)
        guard await host.fileExists(path: path) else {
            return recoveryListEditProposalComparison(proposal, currentText: nil)
        }
        guard let currentText = try? await host.readText(path: path) else {
            return "The current file couldn't be read, so it can't be compared."
        }
        return recoveryListEditProposalComparison(proposal, currentText: currentText)
    }

    static func recoveryListEditProposalComparison(_ proposal: AgentRecoveryEditProposal, currentText: String?) -> String {
        let uncertain = proposal.state == .applicationStarted
            ? " Whether this edit was applied stays uncertain."
            : ""
        guard let currentText else {
            return proposal.base.exists
                ? "The target file wasn't found in this workspace (it may have been deleted or moved).\(uncertain)"
                : "The target file still doesn't exist; the proposal would have created it.\(uncertain)"
        }
        if currentText == proposal.proposedText {
            return "The file currently matches the proposed content. That doesn't prove this proposal was applied.\(uncertain)"
        }
        switch proposal.base.matches(decodedText: currentText) {
        case true?:
            return "The file still matches the version this edit was proposed against.\(uncertain)"
        case false?:
            return "The file has changed since this edit was proposed, and doesn't match the proposal.\(uncertain)"
        case nil:
            return "The file doesn't match the proposal; its original version can't be compared.\(uncertain)"
        }
    }

    private static func editReviewRefusal(_ reason: String) -> MCPError {
        MCPError.invalidParams(
            "apply_edits: \(reason). Nothing was changed. If the proposal was saved, it is listed in Needs Attention; it is never applied automatically."
        )
    }
}
