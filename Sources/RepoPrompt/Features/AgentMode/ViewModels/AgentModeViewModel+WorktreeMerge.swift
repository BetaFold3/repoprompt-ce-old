import AppKit
import Foundation
import MCP
import RepoPromptAgentCore
import RepoPromptShared
import RepoPromptWorkspace

enum WorktreeMergeSourceBindingResolver {
    enum ResolverError: LocalizedError, Equatable {
        case noBindings
        case ambiguous([String])
        case notFound(String)
        case missingHead(String)

        var errorDescription: String? {
            switch self {
            case .noBindings:
                "This agent session is not bound to a source worktree. Bind a worktree before merging."
            case let .ambiguous(labels):
                "Multiple worktree bindings match this session (\(labels.joined(separator: ", "))). Pass repo_root to choose the source binding."
            case let .notFound(selector):
                "No worktree binding matches repo_root '\(selector)'."
            case let .missingHead(label):
                "Worktree binding '\(label)' does not have a recorded HEAD. Refresh or recreate the binding before merging."
            }
        }
    }

    static func resolve(
        bindings: [AgentSessionWorktreeBinding],
        repoRoot: String?
    ) throws -> AgentSessionWorktreeBinding {
        let available = bindings.filter { !$0.worktreeRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !available.isEmpty else { throw ResolverError.noBindings }
        guard let repoRoot, !repoRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if available.count == 1 { return available[0] }
            throw ResolverError.ambiguous(available.map(displayLabel(for:)))
        }

        let selector = repoRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedBindings = available.filter { matchesBinding($0, selector: selector) }
        if matchedBindings.count == 1 { return matchedBindings[0] }
        if matchedBindings.count > 1 { throw ResolverError.ambiguous(matchedBindings.map(displayLabel(for:))) }
        throw ResolverError.notFound(selector)
    }

    static func endpoint(from binding: AgentSessionWorktreeBinding) throws -> GitWorktreeMergeEndpoint {
        guard let head = binding.head?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else {
            throw ResolverError.missingHead(displayLabel(for: binding))
        }
        return GitWorktreeMergeEndpoint(
            worktreeID: binding.worktreeID,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            path: binding.worktreeRootPath,
            name: binding.worktreeName ?? binding.visualLabel,
            branch: binding.branch,
            head: head,
            isMain: false
        )
    }

    private static func matchesBinding(_ binding: AgentSessionWorktreeBinding, selector: String) -> Bool {
        let lower = selector.lowercased()
        let canonicalSelector = standardizedPath(selector)
        let candidates = [
            binding.id,
            binding.repositoryID,
            binding.repoKey,
            binding.logicalRootName,
            binding.logicalRootPath,
            binding.worktreeID,
            binding.worktreeName,
            binding.worktreeRootPath,
            binding.branch,
            binding.visualLabel
        ].compactMap(\.self)
        return candidates.contains { candidate in
            candidate.lowercased() == lower || standardizedPath(candidate) == canonicalSelector
        }
    }

    private static func displayLabel(for binding: AgentSessionWorktreeBinding) -> String {
        binding.logicalRootName
            ?? binding.visualLabel
            ?? binding.worktreeName
            ?? binding.branch
            ?? binding.repoKey
    }

    private static func standardizedPath(_ raw: String) -> String {
        guard raw.contains("/") || raw.hasPrefix("~") || raw.hasPrefix(".") else { return raw }
        return ((raw as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}

/// Pure, MainActor-independent selectors that decide which worktree merge
/// state should drive Agent Mode attention surfaces (blocker stack, session
/// row badges, and root capsules). Kept side-effect-free so view-model and
/// view tests can pin behavior deterministically.
enum AgentWorktreeMergeBlockerSelector {
    /// Active conflict/awaiting-commit operation for a session. When the
    /// session has multiple non-terminal operations, the most recently updated
    /// one wins so the blocker tracks live activity.
    static func activeConflictOperation(
        in operations: [AgentSessionWorktreeMergeOperation]
    ) -> AgentSessionWorktreeMergeOperation? {
        operations
            .filter { $0.status == .conflicted || $0.status == .awaitingCommit }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
    }

    /// Attention summary for sidebar/session-row markers. Returns `nil` when no
    /// active merge operation needs attention. An ended, read-only review never outranks a
    /// conflict, awaiting-commit, or live review, however recent it is.
    static func sidebarAttention(
        in operations: [AgentSessionWorktreeMergeOperation]
    ) -> AgentWorktreeMergeAttention? {
        let candidates = operations.filter { operation in
            operation.status == .conflicted
                || operation.status == .awaitingCommit
                || operation.status == .awaitingApproval
        }
        guard let primary = candidates.max(by: { attentionRanksBelow(
            ($0.isHistoricalReview, $0.updatedAt),
            ($1.isHistoricalReview, $1.updatedAt)
        ) }) else {
            return nil
        }
        return AgentWorktreeMergeAttention(operation: primary)
    }

    /// Same ranking for persisted summaries (closed or restored sessions).
    static func sidebarAttention(
        inSummaries summaries: [AgentSessionWorktreeMergeSummary]
    ) -> AgentWorktreeMergeAttention? {
        primarySummary(in: summaries).map(AgentWorktreeMergeAttention.init(summary:))
    }

    /// The summary that represents a session's merge attention: non-historical first, then newest.
    static func primarySummary(
        in summaries: [AgentSessionWorktreeMergeSummary]
    ) -> AgentSessionWorktreeMergeSummary? {
        summaries
            .filter { $0.status == .conflicted || $0.status == .awaitingCommit || $0.status == .awaitingApproval }
            .max(by: { attentionRanksBelow(
                ($0.isHistoricalReview == true, $0.updatedAt),
                ($1.isHistoricalReview == true, $1.updatedAt)
            ) })
    }

    private static func attentionRanksBelow(_ lhs: (historical: Bool, updatedAt: Date), _ rhs: (historical: Bool, updatedAt: Date)) -> Bool {
        if lhs.historical != rhs.historical { return lhs.historical }
        return lhs.updatedAt < rhs.updatedAt
    }

    /// Step 5c: most recent ended, read-only preserved review of a session.
    static func historicalReviewOperation(
        in operations: [AgentSessionWorktreeMergeOperation]
    ) -> AgentSessionWorktreeMergeOperation? {
        operations
            .filter(\.isHistoricalReview)
            .max(by: { $0.updatedAt < $1.updatedAt })
    }
}

/// Lightweight, presentation-only summary of an active worktree merge
/// operation. Surfaces just enough for session row badges, workspace-root
/// `MERGE → <target>` capsules, and conflict tooltips without forcing
/// downstream views to depend on the full persistence record.
struct AgentWorktreeMergeAttention: Equatable {
    enum Kind: Equatable {
        case awaitingApproval
        /// Step 5c: an ended, read-only merge review kept for View/Copy/Discard.
        case historicalReview
        case conflicted
        case awaitingCommit
    }

    let operationID: String
    let kind: Kind
    let sourceLabel: String
    let targetLabel: String
    let targetPath: String
    let conflictFileCount: Int

    init(operation: AgentSessionWorktreeMergeOperation) {
        operationID = operation.id
        sourceLabel = operation.source.displayName
        targetLabel = operation.target.displayName
        targetPath = operation.target.path
        conflictFileCount = operation.conflictFiles.count
        switch operation.status {
        case .awaitingApproval:
            kind = operation.isHistoricalReview ? .historicalReview : .awaitingApproval
        case .awaitingCommit:
            kind = .awaitingCommit
        default:
            kind = .conflicted
        }
    }

    init(summary: AgentSessionWorktreeMergeSummary) {
        operationID = summary.id
        sourceLabel = summary.sourceLabel
        targetLabel = summary.targetLabel
        targetPath = summary.targetPath
        conflictFileCount = summary.conflictFileCount
        switch summary.status {
        case .awaitingApproval:
            kind = summary.isHistoricalReview == true ? .historicalReview : .awaitingApproval
        case .awaitingCommit:
            kind = .awaitingCommit
        default:
            kind = .conflicted
        }
    }

    var capsuleText: String {
        "MERGE → \(targetLabel)"
    }

    var tooltipText: String {
        let stateText: String = switch kind {
        case .awaitingApproval: "awaiting approval"
        case .historicalReview: "ended review (read-only)"
        case .conflicted: conflictFileCount > 0
            ? "\(conflictFileCount) conflict\(conflictFileCount == 1 ? "" : "s")"
            : "conflicts"
        case .awaitingCommit: "awaiting commit"
        }
        return "Merge \(sourceLabel) → \(targetLabel) · \(stateText) (operation \(operationID))"
    }
}

enum AgentWorktreeMergeCoordinator {
    static func makeOperation(
        preview: GitWorktreeMergePreview,
        status: AgentSessionWorktreeMergeOperation.Status = .previewed,
        now: Date = Date()
    ) -> AgentSessionWorktreeMergeOperation {
        let inspection = preview.inspection
        return AgentSessionWorktreeMergeOperation(
            id: preview.operationID,
            source: inspection.source,
            target: inspection.target,
            mergeBase: inspection.mergeBase,
            sourceHead: inspection.sourceHead,
            targetHeadBefore: inspection.targetHead,
            sourceFingerprint: inspection.sourceFingerprint,
            targetFingerprint: inspection.targetFingerprint,
            previewArtifacts: preview.artifacts,
            summary: inspection.summary,
            visualization: inspection.visualization,
            status: status,
            createdAt: now,
            updatedAt: now
        )
    }

    static func upsert(
        _ operation: AgentSessionWorktreeMergeOperation,
        in operations: inout [AgentSessionWorktreeMergeOperation]
    ) {
        if let index = operations.firstIndex(where: { $0.id == operation.id }) {
            operations[index] = operation
        } else {
            operations.append(operation)
        }
    }

    static func update(
        operationID: String,
        in operations: inout [AgentSessionWorktreeMergeOperation],
        now: Date = Date(),
        mutate: (inout AgentSessionWorktreeMergeOperation) -> Void
    ) throws {
        guard let index = operations.firstIndex(where: { $0.id == operationID }) else {
            throw MCPError.invalidParams("Unknown worktree merge operation_id: \(operationID)")
        }
        mutate(&operations[index])
        operations[index].updatedAt = now
    }

    static func apply(
        result: GitWorktreeMergeApplyResult,
        to operation: inout AgentSessionWorktreeMergeOperation,
        now: Date = Date()
    ) {
        operation.conflictFiles = result.conflictFiles.sorted()
        operation.resultCommit = result.mergeCommit ?? result.targetHeadAfter
        operation.lastError = result.errorMessage ?? result.staleReason
        operation.updatedAt = now
        switch result.status {
        case .completed, .noOp:
            operation.status = .completed
            operation.completedAt = now
            operation.conflictFiles = []
        case .conflicted:
            operation.status = .conflicted
            operation.completedAt = nil
        case .stale:
            operation.status = .stale
            operation.completedAt = now
        case .failed:
            operation.status = .failed
            operation.completedAt = now
        }
    }

    static func abort(
        result: GitWorktreeMergeAbortResult,
        operation: inout AgentSessionWorktreeMergeOperation,
        now: Date = Date()
    ) {
        operation.status = .aborted
        operation.resultCommit = nil
        operation.conflictFiles = []
        operation.completedAt = now
        operation.updatedAt = now
        operation.lastError = result.message
    }
}

@MainActor
extension AgentModeViewModel {
    func previewWorktreeMerge(
        sessionID: UUID,
        repoRoot: String? = nil,
        target: String? = "@main",
        workspaceDirectory: URL? = nil,
        contextLines: Int = 3,
        detectRenames: Bool = false,
        publishArtifacts: Bool = true,
        graphLimit: Int = 24
    ) async throws -> GitWorktreeMergePreview {
        let session = try worktreeMergeSession(sessionID: sessionID)
        let sourceBinding = try WorktreeMergeSourceBindingResolver.resolve(
            bindings: session.worktreeBindings,
            repoRoot: repoRoot
        )
        let source = try await worktreeMergeEndpoint(from: sourceBinding)
        let targetEndpoint = try await resolveWorktreeMergeTargetEndpoint(
            selector: target,
            source: source
        )
        let directory = workspaceDirectory
            ?? workspaceManager?.activeWorkspace?.customStoragePath
            ?? FileManager.default.temporaryDirectory
        let preview = try await VCSService.shared.previewGitWorktreeMerge(.init(
            source: source,
            target: targetEndpoint,
            workspaceDirectory: directory,
            contextLines: contextLines,
            detectRenames: detectRenames,
            publishArtifacts: publishArtifacts,
            tabID: session.tabID,
            graphLimit: graphLimit
        ))
        upsertWorktreeMergeOperation(
            AgentWorktreeMergeCoordinator.makeOperation(preview: preview),
            in: session
        )
        return preview
    }

    func requestWorktreeMergeReviewAndApply(
        preview: GitWorktreeMergePreview,
        sessionID: UUID,
        timeoutSeconds: TimeInterval = MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let session = try worktreeMergeSession(sessionID: sessionID)
        return try await reviewAndApplyWorktreeMerge(
            preview: preview,
            session: session,
            expectedOperation: worktreeMergeOperationValue(preview.operationID, in: session),
            timeoutSeconds: timeoutSeconds,
            commitMessage: commitMessage
        )
    }

    func requestWorktreeMergeReviewAndApply(
        sessionID: UUID,
        operationID: String,
        timeoutSeconds: TimeInterval = MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let session = try worktreeMergeSession(sessionID: sessionID)
        let operation = try worktreeMergeOperation(operationID: operationID, in: session)
        guard operation.status == .previewed else {
            throw MCPError.invalidParams("apply is only valid for a previewed worktree merge operation.")
        }
        let preview = try await worktreeMergePreview(from: operation)
        guard (try? worktreeMergeSession(sessionID: sessionID)) === session else {
            throw MCPError.invalidParams(Self.worktreeMergeOperationChangedText)
        }
        return try await reviewAndApplyWorktreeMerge(
            preview: preview,
            session: session,
            expectedOperation: operation,
            timeoutSeconds: timeoutSeconds,
            commitMessage: commitMessage
        )
    }

    /// Explicitly confirmed direct apply (no review). Artifact-less previews stay supported; the
    /// `applying` operation is durably saved before the VCS handoff, and a failed save leaves the
    /// operation `previewed` without claiming Git ran.
    func applyConfirmedWorktreeMerge(
        sessionID: UUID,
        operationID: String,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let session = try worktreeMergeSession(sessionID: sessionID)
        let operation = try worktreeMergeOperation(operationID: operationID, in: session)
        guard operation.status == .previewed else {
            throw MCPError.invalidParams("apply is only valid for a previewed worktree merge operation.")
        }
        guard let owner = await captureWorktreeMergeOwner(session, operation: operation) else {
            throw MCPError.invalidParams(Self.worktreeMergeNotStartedText)
        }
        let preview = try await worktreeMergePreview(from: operation)
        guard worktreeMergeOwnerIsCurrent(owner), worktreeMergeOperationIsExact(operation, in: session) else {
            throw MCPError.invalidParams(Self.worktreeMergeOperationChangedText)
        }
        return try await runInitialWorktreeMergeApply(
            preview: preview,
            session: session,
            owner: owner,
            unstarted: operation,
            fallback: .previewed,
            commitMessage: commitMessage
        )
    }

    // MARK: Step 5c — preserved review and initial apply

    /// Reserve → retain the same bundle → install relocated refs → covering written save → show.
    /// Each new await is followed by owner and exact-operation revalidation.
    private func reviewAndApplyWorktreeMerge(
        preview: GitWorktreeMergePreview,
        session: AgentTabSession,
        expectedOperation: AgentSessionWorktreeMergeOperation?,
        timeoutSeconds: TimeInterval,
        commitMessage: String?
    ) async throws -> GitWorktreeMergeApplyResult {
        guard let originalArtifacts = preview.artifacts,
              let identity = GitWorktreeMergeReviewArtifactRetention.ExpectedIdentity(preview: preview)
        else {
            throw MCPError.invalidParams(Self.worktreeMergeReviewNeedsArtifactsText)
        }
        let existing = worktreeMergeOperationValue(preview.operationID, in: session)
        guard existing == expectedOperation, existing.map({ $0.status == .previewed }) ?? true else {
            throw MCPError.invalidParams(Self.worktreeMergeOperationChangedText)
        }
        // Older reviews end first: a shown one becomes history, an unshown reservation is withdrawn.
        cancelPendingWorktreeMergeReview(for: session, reason: Self.worktreeMergeReviewReplacedReason)
        upsertWorktreeMergeOperation(
            AgentWorktreeMergeCoordinator.makeOperation(preview: preview, status: .awaitingApproval),
            in: session
        )
        var expected = try worktreeMergeOperation(operationID: preview.operationID, in: session)

        guard let owner = await captureWorktreeMergeOwner(session, operation: expected) else {
            refuseUnshownWorktreeMergeReview(expected, priorPreviewed: expectedOperation, in: session, reason: Self.worktreeMergeReviewNotSavedText)
            throw MCPError.invalidParams(Self.worktreeMergeReviewNotSavedText)
        }

        await worktreeMergeAwaitHook(session, .retention)
        let retained: GitWorktreeMergePreviewArtifacts
        do {
            retained = try await retainWorktreeMergeReviewArtifacts(originalArtifacts, identity: identity, owner: owner)
        } catch {
            let reason = "This worktree merge review couldn't be preserved, so it wasn't shown: \(error.localizedDescription)"
            refuseUnshownWorktreeMergeReview(expected, priorPreviewed: expectedOperation, in: session, reason: reason)
            throw MCPError.invalidParams(reason)
        }
        guard worktreeMergeOwnerIsCurrent(owner), worktreeMergeOperationIsExact(expected, in: session) else {
            refuseUnshownWorktreeMergeReview(
                expected,
                priorPreviewed: expectedOperation,
                in: session,
                reason: Self.worktreeMergeReviewEndedBeforeShownText
            )
            throw MCPError.invalidParams(Self.worktreeMergeReviewEndedBeforeShownText)
        }
        try updateWorktreeMergeOperation(operationID: expected.id, in: session) { operation in
            operation.previewArtifacts = retained
            operation.reviewPreservation = .live
        }
        expected = try worktreeMergeOperation(operationID: expected.id, in: session)

        await worktreeMergeAwaitHook(session, .publicationSave)
        let covered = await commitRecoverySavedPlacement(session)
        guard covered, worktreeMergeOwnerIsCurrent(owner), worktreeMergeOperationIsExact(expected, in: session) else {
            refuseUnshownWorktreeMergeReview(expected, priorPreviewed: expectedOperation, in: session, reason: Self.worktreeMergeReviewNotSavedText)
            throw MCPError.invalidParams(Self.worktreeMergeReviewNotSavedText)
        }

        let retainedPreview = GitWorktreeMergePreview(
            operationID: preview.operationID,
            inspection: preview.inspection,
            artifacts: retained
        )
        let decision = await awaitWorktreeMergeReviewDecision(
            preview: retainedPreview,
            session: session,
            timeoutSeconds: timeoutSeconds
        )
        // A submitted decision stays "shown" to lifecycle ends until it has been processed here.
        defer { session.resolvingWorktreeMergeReviewOperationIDs.remove(expected.id) }
        switch decision {
        case .accept:
            break
        case .reject, .cancelled:
            // Explicit withdrawal of a shown review: acknowledged only by a covering written save.
            let reason = decision.cancelledReason ?? "Worktree merge review was rejected."
            let outcome = await withdrawWorktreeMergeReviewDurably(expected, in: session, owner: owner, reason: reason) { uncertain in
                var kept = expected
                kept.reviewPreservation = .historical(
                    reason: uncertain ? Self.worktreeMergeRejectUncertainText : Self.worktreeMergeRejectNotSavedText,
                    at: Date()
                )
                return kept
            }
            switch outcome {
            case .withdrawn: throw MCPError.invalidParams(reason)
            case .kept: throw MCPError.invalidParams(Self.worktreeMergeRejectNotSavedText)
            case .uncertain: throw MCPError.invalidParams(Self.worktreeMergeRejectUncertainText)
            case .changed: throw MCPError.invalidParams(Self.worktreeMergeRejectChangedText)
            }
        case .timeout, .preserved:
            let reason = decision.cancelledReason ?? Self.worktreeMergeReviewReplacedReason
            preserveWorktreeMergeReviewHistorically(expected, in: session, reason: reason)
            throw MCPError.invalidParams(reason)
        }
        guard worktreeMergeOwnerIsCurrent(owner), worktreeMergeOperationIsExact(expected, in: session) else {
            preserveWorktreeMergeReviewHistorically(expected, in: session, reason: Self.worktreeMergeNotStartedText)
            throw MCPError.invalidParams(Self.worktreeMergeNotStartedText)
        }
        return try await runInitialWorktreeMergeApply(
            preview: retainedPreview,
            session: session,
            owner: owner,
            unstarted: expected,
            fallback: .historicalReview,
            commitMessage: commitMessage
        )
    }

    /// Both initial apply routes: the `applying` operation is covered by a written session save
    /// before the VCS handoff. Without that receipt nothing is handed to Git and the operation
    /// returns to its known-unstarted state. A late result only updates the same operation of the
    /// same owner; it never retargets a replacement.
    private func runInitialWorktreeMergeApply(
        preview: GitWorktreeMergePreview,
        session: AgentTabSession,
        owner: WorktreeMergeOwner,
        unstarted: AgentSessionWorktreeMergeOperation,
        fallback: WorktreeMergeUnstartedFallback,
        commitMessage: String?
    ) async throws -> GitWorktreeMergeApplyResult {
        try updateWorktreeMergeOperation(operationID: unstarted.id, in: session) { pending in
            pending.status = .applying
            pending.lastError = nil
            pending.reviewPreservation = nil
        }
        let applying = try worktreeMergeOperation(operationID: unstarted.id, in: session)
        await worktreeMergeAwaitHook(session, .applyingSave)
        let covered = await commitRecoverySavedPlacement(session)
        guard covered, worktreeMergeOwnerIsCurrent(owner), worktreeMergeOperationIsExact(applying, in: session) else {
            restoreUnstartedWorktreeMerge(applying, to: unstarted, fallback: fallback, in: session)
            throw MCPError.invalidParams(Self.worktreeMergeNotStartedText)
        }
        do {
            let result = try await applyGitWorktreeMergeForReview(.init(preview: preview, commitMessage: commitMessage))
            if worktreeMergeResultTargetIsCurrent(applying, owner: owner, session: session) {
                applyWorktreeMergeResult(result, operationID: applying.id, session: session)
            }
            if result.status == .completed || result.status == .conflicted || result.status == .noOp {
                await refreshAfterWorktreeMergeMutation(session: session, target: result.target)
            }
            return result
        } catch {
            if worktreeMergeResultTargetIsCurrent(applying, owner: owner, session: session) {
                markWorktreeMergeOperationFailed(operationID: applying.id, session: session, error: error)
            }
            await refreshAfterWorktreeMergeMutation(session: session, target: preview.inspection.target)
            throw error
        }
    }

    func statusWorktreeMerge(
        sessionID: UUID,
        operationID: String?
    ) throws -> AgentSessionWorktreeMergeOperation {
        let session = try worktreeMergeSession(sessionID: sessionID)
        if let operationID, !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try worktreeMergeOperation(operationID: operationID, in: session)
        }
        // An ended, read-only review is never the implicit "active" operation (explicit lookup above
        // still returns it).
        let active = session.worktreeMergeOperations.filter { !$0.status.isTerminal && !$0.isHistoricalReview }
        if active.count == 1 { return active[0] }
        if active.isEmpty {
            throw MCPError.invalidParams("operation_id is required because this session has no active worktree merge operation.")
        }
        throw MCPError.invalidParams("operation_id is required because multiple active worktree merge operations exist: \(active.map(\.id).joined(separator: ", "))")
    }

    func continueWorktreeMerge(
        sessionID: UUID,
        operationID: String,
        confirmed: Bool = true,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        guard confirmed else { throw MCPError.invalidParams("continue requires confirmation.") }
        let session = try worktreeMergeSession(sessionID: sessionID)
        let operation = try worktreeMergeOperation(operationID: operationID, in: session)
        guard operation.status == .conflicted || operation.status == .awaitingCommit else {
            throw MCPError.invalidParams("continue is only valid for a conflicted or awaiting_commit worktree merge operation.")
        }
        try updateWorktreeMergeOperation(operationID: operationID, in: session) { pending in
            pending.status = .applying
            pending.lastError = nil
        }
        do {
            let result = try await VCSService.shared.continueGitWorktreeMerge(.init(
                source: operation.source,
                target: operation.target,
                sourceHead: operation.sourceHead,
                targetHeadBefore: operation.targetHeadBefore,
                commitMessage: commitMessage
            ))
            applyWorktreeMergeResult(result, operationID: operationID, session: session)
            if result.status == .completed || result.status == .noOp {
                await refreshAfterWorktreeMergeMutation(session: session, target: result.target)
            }
            return result
        } catch {
            markWorktreeMergeOperationFailed(operationID: operationID, session: session, error: error)
            await refreshAfterWorktreeMergeMutation(session: session, target: operation.target)
            throw error
        }
    }

    func abortWorktreeMerge(
        sessionID: UUID,
        operationID: String,
        confirmed: Bool = true
    ) async throws -> GitWorktreeMergeAbortResult {
        guard confirmed else { throw MCPError.invalidParams("abort requires confirmation.") }
        let session = try worktreeMergeSession(sessionID: sessionID)
        let operation = try worktreeMergeOperation(operationID: operationID, in: session)
        guard operation.status == .conflicted || operation.status == .awaitingCommit || operation.status == .applying else {
            throw MCPError.invalidParams("abort is only valid for an active worktree merge operation.")
        }
        do {
            let result = try await VCSService.shared.abortGitWorktreeMerge(.init(target: operation.target))
            try updateWorktreeMergeOperation(operationID: operationID, in: session) { pending in
                AgentWorktreeMergeCoordinator.abort(result: result, operation: &pending)
            }
            await refreshAfterWorktreeMergeMutation(session: session, target: operation.target)
            return result
        } catch {
            try? updateWorktreeMergeOperation(operationID: operationID, in: session) { pending in
                pending.lastError = "Abort failed: \(error.localizedDescription)"
            }
            await refreshAfterWorktreeMergeMutation(session: session, target: operation.target)
            throw error
        }
    }

    func submitWorktreeMergeReviewDecision(
        tabID: UUID,
        reviewID: UUID,
        decision: WorktreeMergeReviewDecision
    ) {
        guard let session = sessions[tabID],
              session.pendingWorktreeMergeReview?.id == reviewID,
              let review = session.pendingWorktreeMergeReview,
              let continuation = session.worktreeMergeReviewContinuation
        else { return }
        // The card clears now, but the review stays "shown" until the request processes the decision.
        session.resolvingWorktreeMergeReviewOperationIDs.insert(review.operationID)
        finishPendingWorktreeMergeReview(session: session)
        let fallbackResolvedBy = if case .timeout = decision { "system" } else { "user" }
        recordMCPInteractionResolution(
            for: session,
            interactionID: reviewID,
            fallbackResolvedBy: fallbackResolvedBy
        )
        continuation.resume(returning: decision)
    }

    func pendingWorktreeMergeReview(for tabID: UUID?) -> PendingWorktreeMergeReview? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingWorktreeMergeReview
    }

    /// Returns the most-recent active worktree merge operation in
    /// `.conflicted` or `.awaitingCommit` state for the given tab, used by the
    /// Agent Mode blocker stack to surface the conflict/awaiting-commit card.
    /// Returns `nil` when no such operation exists.
    func activeWorktreeMergeConflictOperation(for tabID: UUID?) -> AgentSessionWorktreeMergeOperation? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return AgentWorktreeMergeBlockerSelector.activeConflictOperation(
            in: session.worktreeMergeOperations
        )
    }

    // MARK: Step 5c — historical reviews (View / Copy saved patch / Discard)

    nonisolated static let historicalWorktreeMergePatchDisplayLimit = 1024 * 1024
    nonisolated static let historicalWorktreeMergePatchCopyLimit = 64 * 1024 * 1024

    /// The tab's most recent ended, read-only merge review (no Merge action exists for it). While a
    /// Discard is unacknowledged, the review it started from stays the visible one.
    func historicalWorktreeMergeReviewOperation(for tabID: UUID?) -> AgentSessionWorktreeMergeOperation? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        if let discard = session.worktreeMergeReviewDiscard, discard.isDiscarding {
            return discard.review
        }
        return AgentWorktreeMergeBlockerSelector.historicalReviewOperation(in: session.worktreeMergeOperations)
    }

    /// Discard progress or failure of the tab's visible historical review (session-owned, so it
    /// survives the card being removed and recreated).
    func historicalWorktreeMergeReviewDiscard(for tabID: UUID?) -> AgentWorktreeMergeReviewDiscardState? {
        guard let tabID,
              let session = sessions[tabID],
              let discard = session.worktreeMergeReviewDiscard,
              discard.review.id == historicalWorktreeMergeReviewOperation(for: tabID)?.id
        else { return nil }
        return discard
    }

    private func historicalWorktreeMergeOperation(
        tabID: UUID,
        operationID: String
    ) -> (session: AgentTabSession, operation: AgentSessionWorktreeMergeOperation)? {
        guard let session = sessions[tabID],
              let operation = worktreeMergeOperationValue(operationID, in: session),
              operation.isHistoricalReview
        else { return nil }
        return (session, operation)
    }

    /// The saved patch of the retained bundle (relocated refs only). Never regenerates it.
    func historicalWorktreeMergeSavedPatch(
        tabID: UUID,
        operationID: String,
        maximumBytes: Int = AgentModeViewModel.historicalWorktreeMergePatchDisplayLimit
    ) async -> WorktreeMergeSavedProposal {
        guard let artifacts = historicalWorktreeMergeOperation(tabID: tabID, operationID: operationID)?.operation.previewArtifacts else {
            return .unavailable("This merge proposal's saved files are unavailable.")
        }
        guard let patchPath = artifacts.allPatchPath else { return .noPatch }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try GitWorktreeMergeReviewArtifactRetention.readRetainedFile(patchPath, in: artifacts, maximumBytes: maximumBytes)
            }.value
            // Strict decoding: invalid UTF-8 is unavailable, never shown or copied lossily.
            guard let text = String(data: data, encoding: .utf8) else {
                return .unavailable("The saved merge patch isn't valid UTF-8 text, so it can't be shown or copied exactly.")
            }
            return .patch(text)
        } catch {
            return .unavailable("The saved merge patch is unavailable: \(error.localizedDescription)")
        }
    }

    /// Copy: the full saved patch. Returns a message instead when it can't be copied.
    func copyHistoricalWorktreeMergeSavedPatch(tabID: UUID, operationID: String) async -> String? {
        switch await historicalWorktreeMergeSavedPatch(
            tabID: tabID,
            operationID: operationID,
            maximumBytes: Self.historicalWorktreeMergePatchCopyLimit
        ) {
        case let .patch(text):
            #if DEBUG
                if let writer = test_recoveryListPasteboardWriter {
                    writer(text)
                    return nil
                }
            #endif
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return nil
        case .noPatch:
            return "This merge proposal has no saved patch content."
        case let .unavailable(message):
            return message
        }
    }

    /// The conflict prediction recorded with the proposal (past metadata, not current validation).
    func historicalWorktreeMergePastPrediction(tabID: UUID, operationID: String) async -> GitWorktreeMergeConflictPrediction? {
        guard let artifacts = historicalWorktreeMergeOperation(tabID: tabID, operationID: operationID)?.operation.previewArtifacts else {
            return nil
        }
        return try? await Task.detached(priority: .userInitiated) {
            try GitWorktreeMergeReviewArtifactRetention.retainedConflictPrediction(in: artifacts, operationID: operationID)
        }.value
    }

    /// Read-only observation of whether source and target still match the proposal's
    /// fingerprints. Never regenerates, mutates, or invalidates the saved proposal.
    func historicalWorktreeMergeCurrentState(tabID: UUID, operationID: String) async -> String {
        guard let (session, operation) = historicalWorktreeMergeOperation(tabID: tabID, operationID: operationID) else {
            return "Current source and target state is unavailable."
        }
        guard let sourceFingerprint = operation.sourceFingerprint, let targetFingerprint = operation.targetFingerprint else {
            return "Current source and target state can't be compared for this proposal."
        }
        do {
            let current = try await inspectGitWorktreeMergeForReview(.init(source: operation.source, target: operation.target))
            guard sessions[tabID] === session, worktreeMergeOperationIsExact(operation, in: session) else {
                return "Current source and target state is unavailable (this review changed while it was checked)."
            }
            return current.sourceFingerprint == sourceFingerprint && current.targetFingerprint == targetFingerprint
                ? "Now: source and target are unchanged since this merge was proposed."
                : "Now: source or target has changed since this merge was proposed."
        } catch {
            return "Current source and target state is unavailable: \(error.localizedDescription)"
        }
    }

    /// Discard: withdraws the historical review (saved as `cancelled`) and returns `nil` only once a
    /// covering written save under the same owner acknowledges it. Otherwise the review is kept
    /// (or, when what reached disk can't be confirmed, kept in memory with an uncertain message).
    /// Progress and the message live on the session (`worktreeMergeReviewDiscard`), not on the card.
    /// Never touches Git.
    func discardHistoricalWorktreeMergeReview(tabID: UUID, operationID: String) async -> String? {
        guard let (session, operation) = historicalWorktreeMergeOperation(tabID: tabID, operationID: operationID) else {
            return "This merge review is no longer available."
        }
        guard session.worktreeMergeReviewDiscard?.isDiscarding != true else {
            return "Discard is already in progress for this merge review."
        }
        setWorktreeMergeReviewDiscard(.init(review: operation, isDiscarding: true, message: nil), in: session)
        let message = await discardHistoricalWorktreeMergeReview(operation, in: session)
        if session.worktreeMergeReviewDiscard?.review.id == operation.id {
            setWorktreeMergeReviewDiscard(
                message.map { .init(review: operation, isDiscarding: false, message: $0) },
                in: session
            )
        }
        return message
    }

    private func discardHistoricalWorktreeMergeReview(
        _ operation: AgentSessionWorktreeMergeOperation,
        in session: AgentTabSession
    ) async -> String? {
        guard !isRecoveryShutdownFrozen(session),
              let owner = await captureWorktreeMergeOwner(session, operation: operation)
        else {
            return Self.worktreeMergeDiscardNotSavedText
        }
        let outcome = await withdrawWorktreeMergeReviewDurably(
            operation,
            in: session,
            owner: owner,
            reason: Self.worktreeMergeReviewDiscardedText,
            keeping: { _ in operation }
        )
        switch outcome {
        case .withdrawn: return nil
        case .kept: return Self.worktreeMergeDiscardNotSavedText
        case .uncertain: return Self.worktreeMergeDiscardUncertainText
        case .changed: return Self.worktreeMergeDiscardChangedText
        }
    }

    private func setWorktreeMergeReviewDiscard(_ state: AgentWorktreeMergeReviewDiscardState?, in session: AgentTabSession) {
        session.worktreeMergeReviewDiscard = state
        if session.tabID == currentTabID {
            syncRunInteractionUIState()
        }
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    /// Lifecycle end of a merge review (run end, terminal commit, reset, or replacement by a newer
    /// review). Not a reviewer decision: a shown preserved review becomes read-only history, and
    /// the waiting request receives `.preserved`. A reservation that was never shown, or a shown
    /// review without a retained bundle, is withdrawn.
    func cancelPendingWorktreeMergeReview(for session: AgentTabSession, reason: String) {
        // Shown: the pending card, plus any review whose submitted decision isn't processed yet.
        var shownOperationIDs = session.resolvingWorktreeMergeReviewOperationIDs
        if let pendingID = session.pendingWorktreeMergeReview?.operationID {
            shownOperationIDs.insert(pendingID)
        }
        let continuation = session.worktreeMergeReviewContinuation
        finishPendingWorktreeMergeReview(session: session)
        endWorktreeMergeReviewsForLifecycle(in: session, shownOperationIDs: shownOperationIDs, reason: reason)
        continuation?.resume(returning: .preserved(reason: reason))
    }

    private func endWorktreeMergeReviewsForLifecycle(
        in session: AgentTabSession,
        shownOperationIDs: Set<String>,
        reason: String
    ) {
        let now = Date()
        var changed = false
        for index in session.worktreeMergeOperations.indices {
            var operation = session.worktreeMergeOperations[index]
            guard operation.status == .awaitingApproval, !operation.isHistoricalReview else { continue }
            if shownOperationIDs.contains(operation.id), operation.reviewPreservation?.state == .live {
                operation.reviewPreservation = .historical(reason: reason, at: now)
            } else {
                operation.status = .cancelled
                operation.completedAt = now
                operation.lastError = reason
                operation.reviewPreservation = nil
            }
            operation.updatedAt = now
            session.worktreeMergeOperations[index] = operation
            changed = true
        }
        if changed {
            persistWorktreeMergeOperationsChange(in: session)
        }
    }

    /// Shows the already-preserved review and waits for its decision.
    private func awaitWorktreeMergeReviewDecision(
        preview: GitWorktreeMergePreview,
        session: AgentTabSession,
        timeoutSeconds: TimeInterval
    ) async -> WorktreeMergeReviewDecision {
        let review = PendingWorktreeMergeReview(
            scope: WorktreeMergeReviewScope(windowID: 0, tabID: session.tabID),
            preview: preview
        )
        return await withCheckedContinuation { continuation in
            guard session.pendingWorktreeMergeReview == nil, session.worktreeMergeReviewContinuation == nil else {
                // Never shown: withdrawn, not preserved.
                continuation.resume(returning: .cancelled(reason: "A worktree merge review is already pending."))
                return
            }
            session.pendingWorktreeMergeReview = review
            reconcileInteractiveRunState(session)
            requestUIRefresh(tabID: session.tabID, urgent: true)
            publishMCPStateChange(for: session)
            session.worktreeMergeReviewContinuation = continuation
            if timeoutSeconds > 0 {
                session.worktreeMergeReviewTimeoutTask = Task { @MainActor [weak self, weak session] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard let self, let session, session.pendingWorktreeMergeReview?.id == review.id else { return }
                    submitWorktreeMergeReviewDecision(
                        tabID: session.tabID,
                        reviewID: review.id,
                        decision: .timeout
                    )
                }
            }
        }
    }

    private func finishPendingWorktreeMergeReview(session: AgentTabSession) {
        session.worktreeMergeReviewTimeoutTask?.cancel()
        session.worktreeMergeReviewTimeoutTask = nil
        session.worktreeMergeReviewContinuation = nil
        session.pendingWorktreeMergeReview = nil
        reconcileInteractiveRunState(session)
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    // MARK: Step 5c helpers

    /// Neutral: the newer request that ends an older review may itself still be refused.
    static let worktreeMergeReviewReplacedReason = "Ended when another worktree merge review was requested"
    static let worktreeMergeReviewNeedsArtifactsText = "This worktree merge preview has no published artifacts, so its review can't be preserved and wasn't shown. Run manage_worktree preview again with publish_artifacts enabled."
    static let worktreeMergeReviewNotSavedText = "This worktree merge review wasn't shown because RepoPrompt couldn't save it with this session."
    static let worktreeMergeReviewEndedBeforeShownText = "This worktree merge review ended before it was shown (its session or operation changed)."
    static let worktreeMergeNotStartedText = "The worktree merge was not started because RepoPrompt couldn't durably record it with this session. Git was not changed."
    static let worktreeMergeOperationChangedText = "This worktree merge operation changed or is no longer previewed; run manage_worktree preview again."
    static let worktreeMergeReviewDiscardedText = "Merge review discarded."
    static let worktreeMergeRejectNotSavedText = "The worktree merge review was rejected, but RepoPrompt couldn't save the rejection with this session, so it is kept as a read-only ended review (Discard removes it). Git was not changed."
    static let worktreeMergeDiscardNotSavedText = "Discard wasn't saved with this session, so this ended merge review is kept. Git was not changed."
    static let worktreeMergeRejectUncertainText = "The worktree merge review was rejected, but RepoPrompt couldn't save the rejection with this session or confirm the review is kept; after a restart this ended review may be gone. Git was not changed."
    static let worktreeMergeRejectChangedText = "RepoPrompt couldn't save the rejection because this worktree merge review changed first, so it wasn't withdrawn. Git was not changed."
    static let worktreeMergeDiscardUncertainText = "RepoPrompt couldn't confirm whether Discard was saved with this session, so this ended merge review may not reappear after a restart. Git was not changed."
    static let worktreeMergeDiscardChangedText = "This merge review changed before Discard could be saved, so it wasn't discarded. Git was not changed."

    /// Historical card wording. A lifecycle end can overtake a submitted decision, so the default
    /// stays neutral rather than claiming no decision was made.
    static func historicalWorktreeMergeReviewEndedText(reason: String?) -> String {
        if reason == worktreeMergeNotStartedText {
            return "This merge was approved, but it wasn't started because RepoPrompt couldn't durably record it with this session. Git was not changed, and it can't be merged from here; ask the agent to preview it again."
        }
        if reason == worktreeMergeRejectNotSavedText {
            return "This merge was rejected, but the rejection couldn't be saved with this session, so the proposal is kept read-only. It was not merged; Discard removes it."
        }
        if reason == worktreeMergeRejectUncertainText {
            return "This merge was rejected, but RepoPrompt couldn't confirm what was saved with this session; after a restart this proposal may be gone. It was not merged; Discard removes it."
        }
        let suffix = reason.map { " (\($0))" } ?? ""
        return "This merge proposal's review ended\(suffix). No merge was started from this review, and it can't be merged from here; ask the agent to preview it again."
    }

    private func worktreeMergeAwaitHook(_ session: AgentTabSession, _ point: WorktreeMergeAwaitPoint) async {
        #if DEBUG
            await test_worktreeMergeAwaitHook?(session, point)
        #endif
    }

    private func applyGitWorktreeMergeForReview(_ request: GitWorktreeMergeApplyRequest) async throws -> GitWorktreeMergeApplyResult {
        #if DEBUG
            if let override = test_worktreeMergeApplyOverride {
                return try await override(request)
            }
        #endif
        return try await VCSService.shared.applyGitWorktreeMerge(request)
    }

    private func inspectGitWorktreeMergeForReview(_ request: GitWorktreeMergeInspectRequest) async throws -> GitWorktreeMergeInspection {
        #if DEBUG
            if let override = test_worktreeMergeInspectOverride {
                return try await override(request)
            }
        #endif
        return try await VCSService.shared.inspectGitWorktreeMerge(request)
    }

    /// Captured before the first new await. A never-saved session gets one covering save first so
    /// its persistence authority exists; that save is itself fenced by the exact operation.
    private func captureWorktreeMergeOwner(
        _ session: AgentTabSession,
        operation: AgentSessionWorktreeMergeOperation
    ) async -> WorktreeMergeOwner? {
        let tabID = session.tabID
        guard let sessionID = session.activeAgentSessionID,
              sessions[tabID] === session,
              !isRecoveryShutdownFrozen(session)
        else { return nil }
        if session.persistenceState == nil || session.persistentSessionBindingIdentity == nil {
            await worktreeMergeAwaitHook(session, .initialPersistence)
            guard await commitRecoverySavedPlacement(session),
                  !Task.isCancelled,
                  sessions[tabID] === session,
                  session.activeAgentSessionID == sessionID,
                  worktreeMergeOperationIsExact(operation, in: session)
            else { return nil }
        }
        guard !session.bindingTransitionInProgress,
              let binding = session.persistentSessionBindingIdentity,
              binding.sessionID == sessionID,
              let persistenceState = session.persistenceState
        else { return nil }
        return WorktreeMergeOwner(
            session: session,
            tabID: tabID,
            sessionID: sessionID,
            binding: binding,
            bindingTransitionGeneration: session.bindingTransitionGeneration,
            persistenceState: persistenceState
        )
    }

    /// Also false once the requesting task is cancelled: a cancelled request never publishes a
    /// review or hands an apply to Git.
    private func worktreeMergeOwnerIsCurrent(_ owner: WorktreeMergeOwner) -> Bool {
        !Task.isCancelled && worktreeMergeOwnerMatches(owner)
    }

    /// The same session object, durable session, binding, persistence context, and not frozen.
    private func worktreeMergeOwnerMatches(_ owner: WorktreeMergeOwner) -> Bool {
        guard let session = owner.session,
              sessions[owner.tabID] === session,
              !session.bindingTransitionInProgress,
              session.activeAgentSessionID == owner.sessionID,
              session.persistentSessionBindingIdentity == owner.binding,
              session.bindingTransitionGeneration == owner.bindingTransitionGeneration,
              session.persistenceState == owner.persistenceState,
              !isRecoveryShutdownFrozen(session)
        else { return false }
        return true
    }

    private func worktreeMergeOperationValue(
        _ operationID: String,
        in session: AgentTabSession
    ) -> AgentSessionWorktreeMergeOperation? {
        session.worktreeMergeOperations.first { $0.id == operationID }
    }

    private func worktreeMergeOperationIsExact(
        _ expected: AgentSessionWorktreeMergeOperation,
        in session: AgentTabSession
    ) -> Bool {
        worktreeMergeOperationValue(expected.id, in: session) == expected
    }

    /// A late VCS result may update only the exact `applying` operation of the same session owner.
    private func worktreeMergeResultTargetIsCurrent(
        _ applying: AgentSessionWorktreeMergeOperation,
        owner: WorktreeMergeOwner,
        session: AgentTabSession
    ) -> Bool {
        owner.session === session
            && sessions[owner.tabID] === session
            && session.activeAgentSessionID == owner.sessionID
            && worktreeMergeOperationIsExact(applying, in: session)
    }

    private func retainWorktreeMergeReviewArtifacts(
        _ artifacts: GitWorktreeMergePreviewArtifacts,
        identity: GitWorktreeMergeReviewArtifactRetention.ExpectedIdentity,
        owner: WorktreeMergeOwner
    ) async throws -> GitWorktreeMergePreviewArtifacts {
        let parent = try await dataService.worktreeMergeReviewRetentionParent(for: owner.persistenceState)
        guard worktreeMergeOwnerIsCurrent(owner) else {
            throw MCPError.invalidParams(Self.worktreeMergeReviewEndedBeforeShownText)
        }
        let sessionID = owner.sessionID
        return try await Task.detached(priority: .userInitiated) {
            try GitWorktreeMergeReviewArtifactRetention.retain(
                artifacts,
                expected: identity,
                agentSessionsFolder: parent,
                sessionID: sessionID
            )
        }.value
    }

    /// Refusal of a review that was never shown. A request for a stored `previewed` operation
    /// puts that exact operation back (with the reason) so explicitly confirmed direct apply stays
    /// available; a reservation with no prior operation is withdrawn. A replacement is untouched.
    private func refuseUnshownWorktreeMergeReview(
        _ expected: AgentSessionWorktreeMergeOperation,
        priorPreviewed prior: AgentSessionWorktreeMergeOperation?,
        in session: AgentTabSession,
        reason: String
    ) {
        guard let prior, prior.status == .previewed, prior.id == expected.id else {
            withdrawWorktreeMergeReview(expected, in: session, reason: reason)
            return
        }
        guard worktreeMergeOperationIsExact(expected, in: session) else { return }
        try? updateWorktreeMergeOperation(operationID: expected.id, in: session) { operation in
            operation = prior
            operation.lastError = reason
        }
    }

    /// In-memory withdrawal: the exact operation becomes `cancelled` and loses its preservation
    /// marker (scheduled save). Used directly only to refuse a review that was never shown; explicit
    /// Reject, Cancel, and Discard go through `withdrawWorktreeMergeReviewDurably`.
    private func withdrawWorktreeMergeReview(
        _ expected: AgentSessionWorktreeMergeOperation,
        in session: AgentTabSession,
        reason: String
    ) {
        guard worktreeMergeOperationIsExact(expected, in: session) else { return }
        try? updateWorktreeMergeOperation(operationID: expected.id, in: session) { operation in
            operation.status = .cancelled
            operation.completedAt = Date()
            operation.lastError = reason
            operation.reviewPreservation = nil
        }
    }

    /// Explicit withdrawal (Reject, Cancel, Discard) of a review the user has seen, reported as a
    /// `WorktreeMergeWithdrawalOutcome`:
    /// - The owner and exact operation are revalidated after the last new await and immediately
    ///   before the withdrawal is written; nothing awaits between that check and the save.
    /// - `withdrawn` needs a covering written save (`commitRecoverySavedPlacement`) under the same
    ///   owner with the withdrawn operation still exact.
    /// - Before the withdrawal exists in memory it can't have been written: an invalid owner keeps
    ///   the exact proposal as `kept(false)` (`kept`), a changed operation is left alone (`changed`).
    /// - Once it exists it may have reached disk (this save or any other). It is `kept` only after
    ///   a covering compensating save of `kept(false)` under the same, still-valid owner; otherwise
    ///   `kept(true)` stays in memory and the outcome is `uncertain`. A replacement is never
    ///   overwritten.
    private func withdrawWorktreeMergeReviewDurably(
        _ expected: AgentSessionWorktreeMergeOperation,
        in session: AgentTabSession,
        owner: WorktreeMergeOwner,
        reason: String,
        keeping kept: (_ uncertain: Bool) -> AgentSessionWorktreeMergeOperation
    ) async -> WorktreeMergeWithdrawalOutcome {
        await worktreeMergeAwaitHook(session, .withdrawalSave)
        guard worktreeMergeOperationIsExact(expected, in: session) else { return .changed }
        guard worktreeMergeOwnerMatches(owner) else {
            if sessions[owner.tabID] === session {
                installKeptWorktreeMergeReview(kept(false), over: expected, in: session)
            }
            return .kept
        }
        withdrawWorktreeMergeReview(expected, in: session, reason: reason)
        guard let withdrawn = worktreeMergeOperationValue(expected.id, in: session), withdrawn.status == .cancelled else {
            return .changed
        }
        if await commitRecoverySavedPlacement(session),
           worktreeMergeOwnerMatches(owner),
           worktreeMergeOperationIsExact(withdrawn, in: session)
        {
            return .withdrawn
        }
        // The withdrawal may be on disk now.
        guard sessions[owner.tabID] === session,
              let restored = installKeptWorktreeMergeReview(kept(false), over: withdrawn, in: session)
        else { return .uncertain }
        guard worktreeMergeOwnerMatches(owner) else {
            installKeptWorktreeMergeReview(kept(true), over: restored, in: session)
            return .uncertain
        }
        if await commitRecoverySavedPlacement(session),
           worktreeMergeOwnerMatches(owner),
           worktreeMergeOperationIsExact(restored, in: session)
        {
            return .kept
        }
        if sessions[owner.tabID] === session {
            installKeptWorktreeMergeReview(kept(true), over: restored, in: session)
        }
        return .uncertain
    }

    /// Puts `kept` in place of the exact `current` value (never over a replacement) and returns
    /// the installed value, or `nil` when `current` is no longer exact.
    @discardableResult
    private func installKeptWorktreeMergeReview(
        _ kept: AgentSessionWorktreeMergeOperation,
        over current: AgentSessionWorktreeMergeOperation,
        in session: AgentTabSession
    ) -> AgentSessionWorktreeMergeOperation? {
        guard worktreeMergeOperationIsExact(current, in: session) else { return nil }
        guard kept != current else { return current }
        try? updateWorktreeMergeOperation(operationID: current.id, in: session) { operation in
            operation = kept
        }
        return worktreeMergeOperationValue(current.id, in: session)
    }

    /// Lifecycle/timeout end of a shown preserved review: read-only history, same operation.
    private func preserveWorktreeMergeReviewHistorically(
        _ expected: AgentSessionWorktreeMergeOperation,
        in session: AgentTabSession,
        reason: String
    ) {
        guard worktreeMergeOperationIsExact(expected, in: session),
              expected.status == .awaitingApproval,
              expected.reviewPreservation?.state == .live
        else { return }
        try? updateWorktreeMergeOperation(operationID: expected.id, in: session) { operation in
            operation.reviewPreservation = .historical(reason: reason, at: Date())
        }
    }

    /// The `applying` save was not covered: nothing was handed to Git, so the operation returns
    /// to its known-unstarted state (historical review, or `previewed` for direct apply).
    private func restoreUnstartedWorktreeMerge(
        _ applying: AgentSessionWorktreeMergeOperation,
        to unstarted: AgentSessionWorktreeMergeOperation,
        fallback: WorktreeMergeUnstartedFallback,
        in session: AgentTabSession
    ) {
        guard worktreeMergeOperationIsExact(applying, in: session) else { return }
        try? updateWorktreeMergeOperation(operationID: applying.id, in: session) { operation in
            operation = unstarted
            switch fallback {
            case .historicalReview:
                operation.reviewPreservation = .historical(reason: Self.worktreeMergeNotStartedText, at: Date())
            case .previewed:
                operation.lastError = Self.worktreeMergeNotStartedText
            }
        }
    }

    private func worktreeMergePreview(from operation: AgentSessionWorktreeMergeOperation) async throws -> GitWorktreeMergePreview {
        guard let sourceFingerprint = operation.sourceFingerprint,
              let targetFingerprint = operation.targetFingerprint
        else {
            throw MCPError.invalidParams("Worktree merge preview fingerprints are unavailable; run manage_worktree preview again.")
        }
        let current = try await inspectGitWorktreeMergeForReview(.init(
            source: operation.source,
            target: operation.target
        ))
        let inspection = GitWorktreeMergeInspection(
            source: operation.source,
            target: operation.target,
            mergeBase: operation.mergeBase,
            sourceHead: operation.sourceHead,
            targetHead: operation.targetHeadBefore,
            sourceFingerprint: sourceFingerprint,
            targetFingerprint: targetFingerprint,
            blockers: current.blockers,
            conflictPrediction: current.conflictPrediction,
            summary: operation.summary ?? current.summary,
            visualization: operation.visualization ?? current.visualization
        )
        return GitWorktreeMergePreview(
            operationID: operation.id,
            inspection: inspection,
            artifacts: operation.previewArtifacts
        )
    }

    private func worktreeMergeSession(sessionID: UUID) throws -> AgentTabSession {
        guard let session = try authoritativeLiveSession(for: sessionID) else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        return session
    }

    private func worktreeMergeOperation(
        operationID: String,
        in session: AgentTabSession
    ) throws -> AgentSessionWorktreeMergeOperation {
        guard let operation = session.worktreeMergeOperations.first(where: { $0.id == operationID }) else {
            throw MCPError.invalidParams("Unknown worktree merge operation_id: \(operationID)")
        }
        return operation
    }

    private func updateWorktreeMergeOperation(
        operationID: String,
        in session: AgentTabSession,
        mutate: (inout AgentSessionWorktreeMergeOperation) -> Void
    ) throws {
        try AgentWorktreeMergeCoordinator.update(
            operationID: operationID,
            in: &session.worktreeMergeOperations,
            mutate: mutate
        )
        persistWorktreeMergeOperationsChange(in: session)
    }

    private func upsertWorktreeMergeOperation(
        _ operation: AgentSessionWorktreeMergeOperation,
        in session: AgentTabSession
    ) {
        AgentWorktreeMergeCoordinator.upsert(operation, in: &session.worktreeMergeOperations)
        persistWorktreeMergeOperationsChange(in: session)
    }

    private func applyWorktreeMergeResult(
        _ result: GitWorktreeMergeApplyResult,
        operationID: String,
        session: AgentTabSession
    ) {
        try? updateWorktreeMergeOperation(operationID: operationID, in: session) { operation in
            AgentWorktreeMergeCoordinator.apply(result: result, to: &operation)
        }
    }

    private func markWorktreeMergeOperationFailed(
        operationID: String,
        session: AgentTabSession,
        error: Error
    ) {
        try? updateWorktreeMergeOperation(operationID: operationID, in: session) { operation in
            operation.status = .failed
            operation.completedAt = Date()
            operation.lastError = error.localizedDescription
        }
    }

    private func persistWorktreeMergeOperationsChange(in session: AgentTabSession) {
        session.isDirty = true
        updateWorktreeMergeSummariesInIndex(for: session)
        syncSidebarUIState(refresh: true, reason: .metadataUpdated)
        // Surface conflict/awaiting-commit attention in the blocker stack and
        // workspace-root capsules whenever the persisted merge state changes.
        if session.tabID == currentTabID {
            syncRunInteractionUIState()
        }
        publishMCPStateChange(for: session)
        updateBindingsFromSession(session)
        scheduleSave(for: session.tabID)
    }

    private func worktreeMergeEndpoint(from binding: AgentSessionWorktreeBinding) async throws -> GitWorktreeMergeEndpoint {
        if let head = binding.head, !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try WorktreeMergeSourceBindingResolver.endpoint(from: binding)
        }
        let descriptors = try await VCSService.shared.listGitWorktrees(at: URL(fileURLWithPath: binding.worktreeRootPath))
        guard let descriptor = descriptors.first(where: { $0.worktreeID == binding.worktreeID || samePath($0.path, binding.worktreeRootPath) }) else {
            throw MCPError.invalidParams("Source worktree binding is no longer available: \(binding.worktreeRootPath)")
        }
        return try GitWorktreeMergeEndpoint(descriptor: descriptor)
    }

    private func resolveWorktreeMergeTargetEndpoint(
        selector: String?,
        source: GitWorktreeMergeEndpoint
    ) async throws -> GitWorktreeMergeEndpoint {
        let resolver = GitRepoTargetResolver()
        let sourceRepo = GitRepoDescriptor(rootURL: source.url)
        do {
            let descriptor = try await resolver.resolveWorktree(
                selector: selector ?? "@main",
                repo: sourceRepo,
                allRepos: [sourceRepo]
            )
            return try GitWorktreeMergeEndpoint(descriptor: descriptor)
        } catch let error as GitRepoTargetResolverError {
            throw MCPError.invalidParams(error.message)
        }
    }

    private func refreshAfterWorktreeMergeMutation(
        session: AgentTabSession,
        target: GitWorktreeMergeEndpoint
    ) async {
        await VCSService.shared.invalidateCache(for: target.url)
        if let store = promptManager?.workspaceFileContextStore {
            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: target.path,
                fallbackScope: .allLoaded
            )
        }
        updateWorktreeMergeSummariesInIndex(for: session)
        syncSidebarUIState(refresh: true, reason: .metadataUpdated)
        requestUIRefresh(tabID: session.tabID, urgent: true)
        publishMCPStateChange(for: session)
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        ((lhs as NSString).expandingTildeInPath as NSString).standardizingPath
            == ((rhs as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}

// MARK: - Step 5c types

/// New awaits of a worktree merge review or initial apply (test seam points).
enum WorktreeMergeAwaitPoint: Equatable {
    /// Covering save that establishes a never-saved session's persistence authority.
    case initialPersistence
    /// Retention of the preview bundle under the session's storage.
    case retention
    /// Covering save of the preserved review before it is shown.
    case publicationSave
    /// Last await before an explicit Reject, Cancel, or Discard is written (revalidated after).
    case withdrawalSave
    /// Covering save of the `applying` operation before the VCS handoff.
    case applyingSave
}

/// Session authority captured before a merge review's or initial apply's first new await.
struct WorktreeMergeOwner {
    weak var session: AgentTabSession?
    let tabID: UUID
    let sessionID: UUID
    let binding: AgentPersistentSessionBindingIdentity
    let bindingTransitionGeneration: UInt64
    let persistenceState: AgentSessionPersistenceState
}

/// Result of an explicit withdrawal (Reject, Cancel, Discard) of a shown review.
enum WorktreeMergeWithdrawalOutcome: Equatable {
    /// Covered by a written save under the same owner.
    case withdrawn
    /// Not withdrawn: never written, or a covering compensating save restored the kept review.
    case kept
    /// The withdrawal may have reached disk and the kept review's restoration couldn't be proved.
    case uncertain
    /// The operation changed before the withdrawal was written; nothing was withdrawn.
    case changed
}

/// Known-unstarted state restored when the `applying` save isn't covered.
enum WorktreeMergeUnstartedFallback: Equatable {
    case historicalReview
    case previewed
}

/// A historical review's saved patch, read from its retained bundle.
enum WorktreeMergeSavedProposal: Equatable {
    case patch(String)
    case noPatch
    case unavailable(String)
}
