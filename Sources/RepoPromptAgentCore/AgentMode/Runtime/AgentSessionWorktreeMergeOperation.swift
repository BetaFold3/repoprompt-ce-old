import Foundation
import RepoPromptWorkspace

/// Persisted, compact Agent-session metadata for a worktree merge workflow.
///
/// The operation intentionally stores identifiers, endpoints, fingerprints, artifact references,
/// and resume state only. Full patch text remains in the published preview artifacts.
package struct AgentSessionWorktreeMergeOperation: Codable, Equatable, Identifiable {
    package enum Status: String, Codable, Equatable {
        case previewed
        case awaitingApproval = "awaiting_approval"
        case applying
        case conflicted
        case awaitingCommit = "awaiting_commit"
        case stale
        case completed
        case failed
        case cancelled
        case aborted

        package var isTerminal: Bool {
            switch self {
            case .stale, .completed, .failed, .cancelled, .aborted:
                true
            case .previewed, .awaitingApproval, .applying, .conflicted, .awaitingCommit:
                false
            }
        }

        package var isActive: Bool {
            !isTerminal
        }
    }

    package let id: String
    package var source: GitWorktreeMergeEndpoint
    package var target: GitWorktreeMergeEndpoint
    package var mergeBase: String
    package var sourceHead: String
    package var targetHeadBefore: String
    package var sourceFingerprint: GitDiffFingerprint?
    package var targetFingerprint: GitDiffFingerprint?
    package var previewArtifacts: GitWorktreeMergePreviewArtifacts?
    package var summary: GitWorktreeMergeSummary?
    package var visualization: String?
    package var status: Status
    package var conflictFiles: [String]
    package var resultCommit: String?
    var createdAt: Date
    package var updatedAt: Date
    package var completedAt: Date?
    package var lastError: String?
    /// Step 5c: set only on an `.awaitingApproval` review whose retained preview bundle and refs
    /// were installed and covered by a written session save before the review was shown. `nil` for
    /// every other operation (including reviews recorded before this field existed).
    package var reviewPreservation: AgentSessionWorktreeMergeReviewPreservation?

    package init(
        id: String,
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        mergeBase: String,
        sourceHead: String,
        targetHeadBefore: String,
        sourceFingerprint: GitDiffFingerprint? = nil,
        targetFingerprint: GitDiffFingerprint? = nil,
        previewArtifacts: GitWorktreeMergePreviewArtifacts? = nil,
        summary: GitWorktreeMergeSummary? = nil,
        visualization: String? = nil,
        status: Status = .previewed,
        conflictFiles: [String] = [],
        resultCommit: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        lastError: String? = nil,
        reviewPreservation: AgentSessionWorktreeMergeReviewPreservation? = nil
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.mergeBase = mergeBase
        self.sourceHead = sourceHead
        self.targetHeadBefore = targetHeadBefore
        self.sourceFingerprint = sourceFingerprint
        self.targetFingerprint = targetFingerprint
        self.previewArtifacts = previewArtifacts
        self.summary = summary
        self.visualization = visualization
        self.status = status
        self.conflictFiles = conflictFiles.sorted()
        self.resultCommit = resultCommit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastError = lastError
        self.reviewPreservation = reviewPreservation
    }

    var activeSummary: AgentSessionWorktreeMergeSummary? {
        guard status.isActive else { return nil }
        return AgentSessionWorktreeMergeSummary(operation: self)
    }

    /// A preserved review whose request ended (lifecycle, timeout, replacement, or relaunch)
    /// without an explicit decision: read-only history. It can never be applied or resumed.
    package var isHistoricalReview: Bool {
        status == .awaitingApproval && reviewPreservation?.state == .historical
    }
}

/// Step 5c: preservation marker of a worktree merge review. `live` means the retained proposal is
/// shown (or about to be shown) to a waiting request in this process; `historical` means that
/// request ended without an explicit Merge, Reject, or Discard. The operation's
/// `previewArtifacts` are the retained refs; nothing else records the proposal.
package struct AgentSessionWorktreeMergeReviewPreservation: Codable, Equatable {
    package enum State: String, Codable, Equatable {
        case live
        case historical
    }

    package var state: State
    package var endedReason: String?
    package var endedAt: Date?

    package init(state: State, endedReason: String? = nil, endedAt: Date? = nil) {
        self.state = state
        self.endedReason = endedReason
        self.endedAt = endedAt
    }

    package static let live = AgentSessionWorktreeMergeReviewPreservation(state: .live)

    package static func historical(reason: String, at date: Date) -> AgentSessionWorktreeMergeReviewPreservation {
        AgentSessionWorktreeMergeReviewPreservation(state: .historical, endedReason: reason, endedAt: date)
    }
}

/// Step 5c: in-memory presentation of a Discard of an ended merge review, owned by the session so
/// it survives the card being removed and recreated. While `isDiscarding`, `review` (the value
/// Discard started from) stays the visible, read-only historical review; afterwards `message`
/// explains a Discard that wasn't acknowledged. Never persisted.
package struct AgentWorktreeMergeReviewDiscardState: Equatable {
    package let review: AgentSessionWorktreeMergeOperation
    package var isDiscarding: Bool
    package var message: String?

    package init(review: AgentSessionWorktreeMergeOperation, isDiscarding: Bool, message: String?) {
        self.review = review
        self.isDiscarding = isDiscarding
        self.message = message
    }
}

/// Lightweight merge state copied into session-list/header/index data so restored sessions can
/// surface active merge attention without decoding transcripts or embedding patch contents.
package struct AgentSessionWorktreeMergeSummary: Codable, Equatable, Identifiable {
    package let id: String
    package let status: AgentSessionWorktreeMergeOperation.Status
    let sourceWorktreeID: String
    package let sourceLabel: String
    package let sourceBranch: String?
    package let sourcePath: String
    let targetWorktreeID: String
    package let targetLabel: String
    package let targetBranch: String?
    package let targetPath: String
    package let repositoryID: String
    let repoKey: String
    package let conflictFileCount: Int
    package let updatedAt: Date
    /// Step 5c: `true` for an ended, read-only preserved review (status stays awaiting approval);
    /// absent otherwise.
    package let isHistoricalReview: Bool?

    package init(
        id: String,
        status: AgentSessionWorktreeMergeOperation.Status,
        sourceWorktreeID: String,
        sourceLabel: String,
        sourceBranch: String?,
        sourcePath: String,
        targetWorktreeID: String,
        targetLabel: String,
        targetBranch: String?,
        targetPath: String,
        repositoryID: String,
        repoKey: String,
        conflictFileCount: Int,
        updatedAt: Date,
        isHistoricalReview: Bool? = nil
    ) {
        self.id = id
        self.status = status
        self.sourceWorktreeID = sourceWorktreeID
        self.sourceLabel = sourceLabel
        self.sourceBranch = sourceBranch
        self.sourcePath = sourcePath
        self.targetWorktreeID = targetWorktreeID
        self.targetLabel = targetLabel
        self.targetBranch = targetBranch
        self.targetPath = targetPath
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.conflictFileCount = max(0, conflictFileCount)
        self.updatedAt = updatedAt
        self.isHistoricalReview = isHistoricalReview == true ? true : nil
    }

    init(operation: AgentSessionWorktreeMergeOperation) {
        self.init(
            id: operation.id,
            status: operation.status,
            sourceWorktreeID: operation.source.worktreeID,
            sourceLabel: operation.source.displayName,
            sourceBranch: operation.source.branch,
            sourcePath: operation.source.path,
            targetWorktreeID: operation.target.worktreeID,
            targetLabel: operation.target.displayName,
            targetBranch: operation.target.branch,
            targetPath: operation.target.path,
            repositoryID: operation.source.repositoryID,
            repoKey: operation.source.repoKey,
            conflictFileCount: operation.conflictFiles.count,
            updatedAt: operation.updatedAt,
            isHistoricalReview: operation.isHistoricalReview
        )
    }
}

struct AgentSessionWorktreeMergeReconciliationInspection: Equatable {
    var targetMergeInProgress: Bool
    var targetHead: String?
    var conflictFiles: [String]
    var previewArtifactsAvailable: Bool?
    var previewFingerprintsMatch: Bool?

    init(
        targetMergeInProgress: Bool,
        targetHead: String?,
        conflictFiles: [String] = [],
        previewArtifactsAvailable: Bool? = nil,
        previewFingerprintsMatch: Bool? = nil
    ) {
        self.targetMergeInProgress = targetMergeInProgress
        self.targetHead = targetHead
        self.conflictFiles = conflictFiles.sorted()
        self.previewArtifactsAvailable = previewArtifactsAvailable
        self.previewFingerprintsMatch = previewFingerprintsMatch
    }
}

struct AgentSessionWorktreeMergeReconciliationHooks {
    var inspect: @Sendable (AgentSessionWorktreeMergeOperation) async throws -> AgentSessionWorktreeMergeReconciliationInspection

    static func live(
        vcsService: VCSService = .shared,
        fileManager: FileManager = .default
    ) -> AgentSessionWorktreeMergeReconciliationHooks {
        AgentSessionWorktreeMergeReconciliationHooks { operation in
            let git = await vcsService.gitBackend()
            async let targetMergeState = git.inspectMergeState(at: operation.target.url)
            async let targetHead = git.getHeadID(at: operation.target.url)
            let previewValidity = try await Self.previewValidity(
                for: operation,
                vcsService: vcsService,
                fileManager: fileManager
            )
            let state = try await targetMergeState
            return try await AgentSessionWorktreeMergeReconciliationInspection(
                targetMergeInProgress: state.inProgress,
                targetHead: targetHead,
                conflictFiles: state.conflictFiles,
                previewArtifactsAvailable: previewValidity.artifactsAvailable,
                previewFingerprintsMatch: previewValidity.fingerprintsMatch
            )
        }
    }

    private static func previewValidity(
        for operation: AgentSessionWorktreeMergeOperation,
        vcsService: VCSService,
        fileManager: FileManager
    ) async throws -> (artifactsAvailable: Bool, fingerprintsMatch: Bool) {
        let artifactsAvailable = operation.previewArtifacts.map { artifacts in
            let requiredPaths = [artifacts.manifestPath, artifacts.mapPath, artifacts.sidecarPath]
            let optionalPaths = [artifacts.allPatchPath].compactMap(\.self)
            return (requiredPaths + optionalPaths).allSatisfy { fileManager.fileExists(atPath: $0) }
        } ?? false

        guard operation.sourceFingerprint != nil || operation.targetFingerprint != nil else {
            return (artifactsAvailable, true)
        }

        let inspection = try await vcsService.inspectGitWorktreeMerge(.init(
            source: operation.source,
            target: operation.target
        ))
        let sourceMatches = operation.sourceFingerprint.map { $0 == inspection.sourceFingerprint } ?? true
        let targetMatches = operation.targetFingerprint.map { $0 == inspection.targetFingerprint } ?? true
        return (artifactsAvailable, sourceMatches && targetMatches)
    }
}

enum AgentSessionWorktreeMergeReconciler {
    static let relaunchEndedReviewReason = "RepoPrompt closed before this merge review was answered."

    static func reconcile(
        _ operations: [AgentSessionWorktreeMergeOperation],
        now: Date = Date(),
        hooks: AgentSessionWorktreeMergeReconciliationHooks = .live()
    ) async -> [AgentSessionWorktreeMergeOperation] {
        var reconciled: [AgentSessionWorktreeMergeOperation] = []
        reconciled.reserveCapacity(operations.count)
        for operation in operations {
            await reconciled.append(reconcile(operation, now: now, hooks: hooks))
        }
        return reconciled
    }

    static func reconcile(
        _ operation: AgentSessionWorktreeMergeOperation,
        now: Date = Date(),
        hooks: AgentSessionWorktreeMergeReconciliationHooks
    ) async -> AgentSessionWorktreeMergeOperation {
        guard !operation.status.isTerminal else { return operation }

        var updated = operation
        switch operation.status {
        case .awaitingApproval:
            // Step 5c: a preserved review becomes read-only history; no continuation is resumed.
            if let preservation = operation.reviewPreservation {
                guard preservation.state == .live else { return operation }
                updated.reviewPreservation = .historical(reason: Self.relaunchEndedReviewReason, at: now)
                updated.updatedAt = now
                return updated
            }
            updated.status = .cancelled
            updated.updatedAt = now
            updated.completedAt = now
            updated.lastError = "Merge approval was cancelled because pending approval continuations do not survive relaunch."
            return updated
        case .previewed:
            do {
                let inspection = try await hooks.inspect(operation)
                if inspection.previewArtifactsAvailable == false || inspection.previewFingerprintsMatch == false {
                    updated.status = .stale
                    updated.updatedAt = now
                    updated.completedAt = now
                    updated.lastError = inspection.previewArtifactsAvailable == false
                        ? "Merge preview artifacts are no longer available."
                        : "Merge preview fingerprints are no longer current."
                }
                return updated
            } catch {
                updated.status = .stale
                updated.updatedAt = now
                updated.completedAt = now
                updated.lastError = "Merge preview could not be revalidated: \(error.localizedDescription)"
                return updated
            }
        case .applying, .conflicted, .awaitingCommit:
            do {
                let inspection = try await hooks.inspect(operation)
                return reconcileInFlight(updated, inspection: inspection, now: now)
            } catch {
                updated.status = .failed
                updated.updatedAt = now
                updated.completedAt = now
                updated.lastError = "Merge state could not be inspected: \(error.localizedDescription)"
                return updated
            }
        case .stale, .completed, .failed, .cancelled, .aborted:
            return operation
        }
    }

    private static func reconcileInFlight(
        _ operation: AgentSessionWorktreeMergeOperation,
        inspection: AgentSessionWorktreeMergeReconciliationInspection,
        now: Date
    ) -> AgentSessionWorktreeMergeOperation {
        var updated = operation
        updated.conflictFiles = inspection.conflictFiles
        updated.updatedAt = now

        if inspection.targetMergeInProgress {
            updated.resultCommit = nil
            updated.completedAt = nil
            updated.lastError = nil
            updated.status = inspection.conflictFiles.isEmpty ? .awaitingCommit : .conflicted
            return updated
        }

        if let targetHead = inspection.targetHead, targetHead != operation.targetHeadBefore {
            updated.status = .completed
            updated.resultCommit = targetHead
            updated.completedAt = now
            updated.lastError = nil
            updated.conflictFiles = []
            return updated
        }

        updated.status = .failed
        updated.completedAt = now
        updated.lastError = "No Git merge is in progress for the target worktree and no merge commit was detected."
        return updated
    }
}

package extension Sequence<AgentSessionWorktreeMergeOperation> {
    var activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary] {
        compactMap(\.activeSummary)
    }
}
