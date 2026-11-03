import Foundation
import RepoPromptWorkspace

package struct WorktreeMergeReviewScope: Hashable {
    let windowID: Int
    let tabID: UUID

    package init(
        windowID: Int,
        tabID: UUID
    ) {
        self.windowID = windowID
        self.tabID = tabID
    }
}

package struct PendingWorktreeMergeReview: Identifiable, Equatable {
    package let id: UUID
    let scope: WorktreeMergeReviewScope
    package let operationID: String
    package let sourceLabel: String
    package let sourceBranch: String?
    package let sourcePath: String
    package let sourceHead: String
    package let targetLabel: String
    package let targetBranch: String?
    package let targetPath: String
    package let targetHead: String
    package let mergeBase: String
    package let visualization: String
    package let summary: GitWorktreeMergeSummary?
    package let artifacts: GitWorktreeMergePreviewArtifacts?
    package let conflictPrediction: GitWorktreeMergeConflictPrediction
    let createdAt: Date

    package init(
        id: UUID = UUID(),
        scope: WorktreeMergeReviewScope,
        preview: GitWorktreeMergePreview,
        createdAt: Date = Date()
    ) {
        let inspection = preview.inspection
        self.id = id
        self.scope = scope
        operationID = preview.operationID
        sourceLabel = inspection.source.displayName
        sourceBranch = inspection.source.branch
        sourcePath = inspection.source.path
        sourceHead = inspection.sourceHead
        targetLabel = inspection.target.displayName
        targetBranch = inspection.target.branch
        targetPath = inspection.target.path
        targetHead = inspection.targetHead
        mergeBase = inspection.mergeBase
        visualization = inspection.visualization
        summary = inspection.summary
        artifacts = preview.artifacts
        conflictPrediction = inspection.conflictPrediction
        self.createdAt = createdAt
    }
}

/// `reject` and `cancelled` are explicit withdrawals by the reviewer (card or MCP decision).
/// `timeout` and `preserved` end the request without a decision (Step 5c): the review is kept as
/// read-only history. `preserved` is issued only by lifecycle ends (run end, reset, replacement).
package enum WorktreeMergeReviewDecision: Equatable {
    case accept
    case reject(reason: String)
    case timeout
    case cancelled(reason: String)
    case preserved(reason: String)

    package var cancelledReason: String? {
        switch self {
        case .accept:
            nil
        case let .reject(reason):
            reason
        case .timeout:
            "Timed out while waiting for worktree merge approval."
        case let .cancelled(reason):
            reason
        case let .preserved(reason):
            reason
        }
    }
}
