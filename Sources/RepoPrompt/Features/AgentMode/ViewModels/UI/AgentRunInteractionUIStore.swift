import Foundation
import RepoPromptAgentCore

struct AgentRunInteractionUISnapshot: Equatable {
    var currentTabID: UUID?
    var runState: AgentSessionRunState
    var runningStatusText: String?
    var activeAgentRunStartedAt: Date?
    var waitingPrompt: String?
    var pendingAskUser: AgentAskUserPendingState?
    var pendingUserInputRequest: AgentRequestUserInputRequest?
    var pendingApproval: AgentApprovalRequest?
    var pendingPermissionsRequest: AgentPermissionsRequest?
    var pendingMCPElicitationRequest: AgentMCPElicitationRequest?
    var pendingApplyEditsReview: PendingApplyEditsReview?
    var pendingWorktreeMergeReview: PendingWorktreeMergeReview?
    /// Active worktree merge operation in `.conflicted` or `.awaitingCommit`
    /// state for the current tab, surfaced as a persistent blocker so the
    /// merge conflict card can be shown when no higher-priority blocker is
    /// active. `nil` when no such operation exists for the current tab.
    var activeWorktreeMergeConflict: AgentSessionWorktreeMergeOperation?
    /// Step 5c: most recent ended, read-only merge review of the current tab (View/Copy/Discard
    /// only), shown when no higher-priority card is active.
    var historicalWorktreeMergeReview: AgentSessionWorktreeMergeOperation?
    /// Session-owned Discard progress/failure of `historicalWorktreeMergeReview`.
    var historicalWorktreeMergeReviewDiscard: AgentWorktreeMergeReviewDiscardState?
    var activeRunID: UUID?
    var activeAgentSessionID: UUID?
    var activeRunAttemptID: UUID?
    var latestUserSequenceIndex: Int?
    var canForkCurrentSession: Bool
    var selectedAgent: AgentProviderKind
    var selectedModelRaw: String
    var selectedReasoningEffortRaw: String?
    /// R4 edit freeze of this window: answer cards are disabled (answers are also refused by the
    /// view model before any mutation).
    var isShutdownFrozen = false

    var isAgentBusy: Bool {
        runState == .running
    }

    var isWaitingForInstruction: Bool {
        runState == .waitingForUser
    }

    var pendingUserInputCancelTarget: AgentRunCancelTarget? {
        guard let currentTabID,
              let activeRunID,
              let pendingUserInputRequest
        else { return nil }
        return AgentRunCancelTarget(
            tabID: currentTabID,
            expectedRunID: activeRunID,
            expectedActiveAgentSessionID: activeAgentSessionID,
            expectedRunAttemptID: activeRunAttemptID,
            expectedPendingUserInputRequestID: pendingUserInputRequest.requestID
        )
    }

    static let empty = AgentRunInteractionUISnapshot(
        currentTabID: nil,
        runState: .idle,
        runningStatusText: nil,
        activeAgentRunStartedAt: nil,
        waitingPrompt: nil,
        pendingAskUser: nil,
        pendingUserInputRequest: nil,
        pendingApproval: nil,
        pendingPermissionsRequest: nil,
        pendingMCPElicitationRequest: nil,
        pendingApplyEditsReview: nil,
        pendingWorktreeMergeReview: nil,
        activeWorktreeMergeConflict: nil,
        historicalWorktreeMergeReview: nil,
        activeRunID: nil,
        activeAgentSessionID: nil,
        activeRunAttemptID: nil,
        latestUserSequenceIndex: nil,
        canForkCurrentSession: false,
        selectedAgent: .codexExec,
        selectedModelRaw: AgentModel.defaultModel.rawValue,
        selectedReasoningEffortRaw: nil
    )
}

@MainActor
final class AgentRunInteractionUIStore: ObservableObject {
    @Published private(set) var snapshot: AgentRunInteractionUISnapshot = .empty

    func update(_ snapshot: AgentRunInteractionUISnapshot) {
        guard self.snapshot != snapshot else {
            #if DEBUG
                AgentModePerfDiagnostics.recordStoreUpdate("runInteraction", published: false)
            #endif
            return
        }
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                "runInteraction",
                published: true,
                details: [
                    "tabID": AgentModePerfDiagnostics.shortID(snapshot.currentTabID),
                    "runState": String(describing: snapshot.runState),
                    "hasPendingAskUser": String(snapshot.pendingAskUser != nil),
                    "askUserTimeoutStartedAt": snapshot.pendingAskUser?.timeoutStartedAt?.description ?? "nil",
                    "hasPendingInput": String(snapshot.pendingUserInputRequest != nil),
                    "hasPendingApproval": String(snapshot.pendingApproval != nil),
                    "hasPendingPermissions": String(snapshot.pendingPermissionsRequest != nil),
                    "hasPendingMCPElicitation": String(snapshot.pendingMCPElicitationRequest != nil),
                    "hasApplyReview": String(snapshot.pendingApplyEditsReview != nil),
                    "hasWorktreeMergeReview": String(snapshot.pendingWorktreeMergeReview != nil),
                    "hasWorktreeMergeConflict": String(snapshot.activeWorktreeMergeConflict != nil),
                    "activeRunID": AgentModePerfDiagnostics.shortID(snapshot.activeRunID)
                ]
            )
        #endif
        self.snapshot = snapshot
    }
}
