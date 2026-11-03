import Foundation
import RepoPromptAgentCore
import RepoPromptWorkspace

enum ApplyEditsReviewDecision: Hashable {
    case accept
    case reject(reason: String)
    case timeout
    case cancelled(reason: String)

    var editFlowPerfOutcome: String {
        switch self {
        case .accept:
            "accept"
        case .reject:
            "reject"
        case .timeout:
            "timeout"
        case .cancelled:
            "cancelled"
        }
    }
}

/// Step 5a: a review's identity, issued before its proposal is saved for recovery. Only the scope's
/// latest ticket may still show its review or start its accepted write; a newer review, any scope
/// cleanup (tab or window close), and an explicit lifecycle cancellation retire it. A
/// re-subscription of the same scope does not. (The provider maps each decision case directly:
/// only `reject` withdraws the saved proposal; `timeout` and `cancelled` keep it as history.)
struct ApplyEditsReviewTicket: Hashable {
    let scope: ApplyEditsApprovalScope
    let reviewID: UUID
}

struct ApplyEditsApprovalSnapshot: Equatable {
    let scope: ApplyEditsApprovalScope
    var autoEditEnabled: Bool
    var pendingReview: PendingApplyEditsReview?
}

actor ApplyEditsApprovalStore: Sendable {
    static let shared = ApplyEditsApprovalStore()

    private static let autoEditEnabledDefaultsKey = "agentModeAutoEditEnabled"

    nonisolated static func globalDefaultAutoEditEnabled() -> Bool {
        if let value = UserDefaults.standard.object(forKey: autoEditEnabledDefaultsKey) as? Bool {
            return value
        }
        return true
    }

    nonisolated static func setGlobalDefaultAutoEditEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoEditEnabledDefaultsKey)
    }

    private struct PendingRecord {
        let review: PendingApplyEditsReview
        let continuation: CheckedContinuation<ApplyEditsReviewDecision, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private typealias SnapshotContinuation = AsyncStream<ApplyEditsApprovalSnapshot>.Continuation

    private var autoEditOverridesByScope: [ApplyEditsApprovalScope: Bool] = [:]
    private var pendingByScope: [ApplyEditsApprovalScope: PendingRecord] = [:]
    private var subscriptions: [ApplyEditsApprovalScope: [UUID: SnapshotContinuation]] = [:]
    private var ownershipGenerationByScope: [ApplyEditsApprovalScope: UInt64] = [:]
    /// The latest issued review ticket of each scope (Step 5a).
    private var latestReviewIDByScope: [ApplyEditsApprovalScope: UUID] = [:]
    #if DEBUG
        private var testConditionalCleanupHook: (@Sendable (ApplyEditsApprovalScope, UInt64) async -> Void)?
        private var testInitialSetupHook: (@Sendable (ApplyEditsApprovalScope) async -> Void)?

        func test_setInitialSetupHook(
            _ hook: (@Sendable (ApplyEditsApprovalScope) async -> Void)?
        ) {
            testInitialSetupHook = hook
        }

        func test_setConditionalCleanupHook(
            _ hook: (@Sendable (ApplyEditsApprovalScope, UInt64) async -> Void)?
        ) {
            testConditionalCleanupHook = hook
        }
    #endif

    func autoEditEnabled(for scope: ApplyEditsApprovalScope) -> Bool {
        autoEditOverridesByScope[scope] ?? Self.globalDefaultAutoEditEnabled()
    }

    func setAutoEditEnabled(
        _ enabled: Bool,
        for scope: ApplyEditsApprovalScope,
        updateGlobalDefault: Bool
    ) {
        autoEditOverridesByScope[scope] = enabled
        if updateGlobalDefault {
            Self.setGlobalDefaultAutoEditEnabled(enabled)
        }
        publishSnapshot(for: scope)
    }

    @discardableResult
    func setAutoEditEnabled(
        _ enabled: Bool,
        for scope: ApplyEditsApprovalScope,
        ifOwnedBy generation: UInt64,
        updateGlobalDefault: Bool
    ) -> Bool {
        guard ownershipGenerationByScope[scope] == generation else { return false }
        autoEditOverridesByScope[scope] = enabled
        if updateGlobalDefault {
            Self.setGlobalDefaultAutoEditEnabled(enabled)
        }
        publishSnapshot(for: scope)
        return true
    }

    func requestReview(
        scope: ApplyEditsApprovalScope,
        path: String,
        unifiedDiff: String,
        timeoutSeconds: TimeInterval
    ) async -> ApplyEditsReviewDecision {
        let ticket = beginReview(scope: scope)
        return await awaitReview(ticket, path: path, unifiedDiff: unifiedDiff, timeoutSeconds: timeoutSeconds)
    }

    /// Step 5a: replaces the scope's pending review (as `requestReview` always did) and issues the
    /// next review's identity, so its proposal can be saved before the review is shown.
    func beginReview(scope: ApplyEditsApprovalScope) -> ApplyEditsReviewTicket {
        let replaceReason = "Replaced by newer apply_edits preview"
        cancelPendingReview(scope: scope, reason: replaceReason)
        let ticket = ApplyEditsReviewTicket(scope: scope, reviewID: UUID())
        latestReviewIDByScope[scope] = ticket.reviewID
        return ticket
    }

    /// Whether `ticket` may still show its review: still the scope's latest, not cleaned up since.
    func isReviewTicketCurrent(_ ticket: ApplyEditsReviewTicket) -> Bool {
        latestReviewIDByScope[ticket.scope] == ticket.reviewID
    }

    /// Shows `ticket`'s review and waits for its decision. A ticket replaced by a newer review, or
    /// whose scope was cleaned up since it was issued, is `cancelled` without being shown.
    func awaitReview(
        _ ticket: ApplyEditsReviewTicket,
        path: String,
        unifiedDiff: String,
        timeoutSeconds: TimeInterval
    ) async -> ApplyEditsReviewDecision {
        let scope = ticket.scope
        let review = PendingApplyEditsReview(
            id: ticket.reviewID,
            scope: scope,
            path: path,
            unifiedDiff: unifiedDiff
        )
        let cancellationReason = "Cancelled while awaiting apply_edits review"
        let staleReason = "Replaced or closed before the apply_edits review was shown"
        let timeoutNanoseconds = timeoutIntervalToNanoseconds(timeoutSeconds)

        let perfState = EditFlowPerf.begin(EditFlowPerf.Stage.ApplyEdits.approvalWait)
        let decision: ApplyEditsReviewDecision = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled(reason: cancellationReason))
                    return
                }
                guard isReviewTicketCurrent(ticket) else {
                    continuation.resume(returning: .cancelled(reason: staleReason))
                    return
                }

                let timeoutTask = Task { [reviewID = review.id, scope, timeoutNanoseconds] in
                    if timeoutNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    }
                    self.resolvePendingReviewIfMatching(
                        scope: scope,
                        reviewID: reviewID,
                        decision: .timeout
                    )
                }

                pendingByScope[scope] = PendingRecord(
                    review: review,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                publishSnapshot(for: scope)
            }
        }, onCancel: {
            Task {
                await self.cancelPendingReview(scope: scope, reviewID: ticket.reviewID, reason: cancellationReason)
            }
        })
        EditFlowPerf.end(
            EditFlowPerf.Stage.ApplyEdits.approvalWait,
            perfState,
            EditFlowPerf.Dimensions(outcome: decision.editFlowPerfOutcome)
        )
        return decision
    }

    func resolveReview(
        scope: ApplyEditsApprovalScope,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) {
        resolvePendingReviewIfMatching(scope: scope, reviewID: reviewID, decision: decision)
    }

    /// Explicit lifecycle or replacement cancellation of the scope's review. It also expires the
    /// scope's latest ticket, so an already accepted review still before its write (Step 5a:
    /// awaiting `applicationStarted`) never writes. `beginReview` issues its own ticket after this.
    /// The ID-scoped variant below (a cancelled waiter) never expires a newer ticket.
    func cancelPendingReview(scope: ApplyEditsApprovalScope, reason: String) {
        latestReviewIDByScope.removeValue(forKey: scope)
        guard let record = pendingByScope[scope] else { return }
        finishPendingReview(scope: scope, record: record, decision: .cancelled(reason: reason))
    }

    /// Cancels only review `reviewID` (a cancelled waiter never cancels a newer review).
    private func cancelPendingReview(scope: ApplyEditsApprovalScope, reviewID: UUID, reason: String) {
        resolvePendingReviewIfMatching(scope: scope, reviewID: reviewID, decision: .cancelled(reason: reason))
    }

    func cleanupScope(_ scope: ApplyEditsApprovalScope) {
        ownershipGenerationByScope[scope, default: 0] &+= 1
        cancelPendingReview(scope: scope, reason: "Approval scope cleaned up")
        latestReviewIDByScope.removeValue(forKey: scope)
        autoEditOverridesByScope.removeValue(forKey: scope)
        finishAndRemoveAllSubscriptions(for: scope)
    }

    @discardableResult
    func cleanupScope(
        _ scope: ApplyEditsApprovalScope,
        ifOwnedBy generation: UInt64
    ) async -> Bool {
        #if DEBUG
            if let testConditionalCleanupHook {
                await testConditionalCleanupHook(scope, generation)
            }
        #endif
        guard ownershipGenerationByScope[scope] == generation else { return false }
        ownershipGenerationByScope[scope, default: 0] &+= 1
        cancelPendingReview(scope: scope, reason: "Approval scope cleaned up")
        latestReviewIDByScope.removeValue(forKey: scope)
        autoEditOverridesByScope.removeValue(forKey: scope)
        finishAndRemoveAllSubscriptions(for: scope)
        return true
    }

    func cleanupWindowScopes(windowID: Int, reason: String) {
        var scopesToCleanup = Set<ApplyEditsApprovalScope>()
        for scope in autoEditOverridesByScope.keys where scope.windowID == windowID {
            scopesToCleanup.insert(scope)
        }
        for scope in pendingByScope.keys where scope.windowID == windowID {
            scopesToCleanup.insert(scope)
        }
        for scope in subscriptions.keys where scope.windowID == windowID {
            scopesToCleanup.insert(scope)
        }
        for scope in latestReviewIDByScope.keys where scope.windowID == windowID {
            scopesToCleanup.insert(scope)
        }
        guard !scopesToCleanup.isEmpty else { return }
        for scope in scopesToCleanup {
            ownershipGenerationByScope[scope, default: 0] &+= 1
            cancelPendingReview(scope: scope, reason: reason)
            latestReviewIDByScope.removeValue(forKey: scope)
            autoEditOverridesByScope.removeValue(forKey: scope)
            finishAndRemoveAllSubscriptions(for: scope)
        }
    }

    /// Setup claims the service generation before configuring or subscribing. There is no
    /// suspension after the cancellation check, so a retired owner's held setup cannot claim
    /// a replacement's scope after its task is cancelled.
    func subscribeForInitialOwner(
        scope: ApplyEditsApprovalScope,
        autoEditEnabled: Bool
    ) async -> (id: UUID, generation: UInt64, stream: AsyncStream<ApplyEditsApprovalSnapshot>)? {
        #if DEBUG
            if let testInitialSetupHook {
                await testInitialSetupHook(scope)
            }
        #endif
        guard !Task.isCancelled else { return nil }
        let generation = (ownershipGenerationByScope[scope] ?? 0) &+ 1
        ownershipGenerationByScope[scope] = generation
        autoEditOverridesByScope[scope] = autoEditEnabled
        let subscription = makeSubscription(scope: scope, generation: generation)
        publishSnapshot(for: scope)
        return subscription
    }

    func subscribe(scope: ApplyEditsApprovalScope) -> (id: UUID, generation: UInt64, stream: AsyncStream<ApplyEditsApprovalSnapshot>) {
        let generation = (ownershipGenerationByScope[scope] ?? 0) &+ 1
        ownershipGenerationByScope[scope] = generation
        return makeSubscription(scope: scope, generation: generation)
    }

    private func makeSubscription(
        scope: ApplyEditsApprovalScope,
        generation: UInt64
    ) -> (id: UUID, generation: UInt64, stream: AsyncStream<ApplyEditsApprovalSnapshot>) {
        let id = UUID()
        let streamPair = AsyncStream.makeStream(of: ApplyEditsApprovalSnapshot.self)
        let stream = streamPair.stream
        let continuation = streamPair.continuation
        var scopedSubscriptions = subscriptions[scope] ?? [:]
        scopedSubscriptions[id] = continuation
        subscriptions[scope] = scopedSubscriptions
        continuation.yield(snapshot(for: scope))
        continuation.onTermination = { [scope, id] _ in
            Task {
                await self.removeSubscription(scope: scope, id: id, finishContinuation: false)
            }
        }
        return (id, generation, stream)
    }

    func unsubscribe(scope: ApplyEditsApprovalScope, id: UUID) {
        removeSubscription(scope: scope, id: id, finishContinuation: true)
    }

    #if DEBUG
        func test_subscriptionCount() -> Int {
            subscriptions.values.reduce(0) { $0 + $1.count }
        }
    #endif

    private func resolvePendingReviewIfMatching(
        scope: ApplyEditsApprovalScope,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) {
        guard let record = pendingByScope[scope], record.review.id == reviewID else { return }
        finishPendingReview(scope: scope, record: record, decision: decision)
    }

    private func finishPendingReview(
        scope: ApplyEditsApprovalScope,
        record: PendingRecord,
        decision: ApplyEditsReviewDecision
    ) {
        record.timeoutTask?.cancel()
        pendingByScope.removeValue(forKey: scope)
        publishSnapshot(for: scope)
        record.continuation.resume(returning: decision)
    }

    private func snapshot(for scope: ApplyEditsApprovalScope) -> ApplyEditsApprovalSnapshot {
        ApplyEditsApprovalSnapshot(
            scope: scope,
            autoEditEnabled: autoEditEnabled(for: scope),
            pendingReview: pendingByScope[scope]?.review
        )
    }

    private func publishSnapshot(for scope: ApplyEditsApprovalScope) {
        guard let scopedSubscriptions = subscriptions[scope], !scopedSubscriptions.isEmpty else { return }
        let nextSnapshot = snapshot(for: scope)
        for continuation in scopedSubscriptions.values {
            continuation.yield(nextSnapshot)
        }
    }

    private func removeSubscription(
        scope: ApplyEditsApprovalScope,
        id: UUID,
        finishContinuation: Bool
    ) {
        guard var scopedSubscriptions = subscriptions[scope] else { return }
        guard let continuation = scopedSubscriptions.removeValue(forKey: id) else { return }
        if scopedSubscriptions.isEmpty {
            subscriptions.removeValue(forKey: scope)
        } else {
            subscriptions[scope] = scopedSubscriptions
        }
        if finishContinuation {
            continuation.finish()
        }
    }

    private func finishAndRemoveAllSubscriptions(for scope: ApplyEditsApprovalScope) {
        guard let scopedSubscriptions = subscriptions.removeValue(forKey: scope) else { return }
        for continuation in scopedSubscriptions.values {
            continuation.finish()
        }
    }

    private func timeoutIntervalToNanoseconds(_ timeoutSeconds: TimeInterval) -> UInt64 {
        let normalizedSeconds = max(0, timeoutSeconds)
        let maxSafeSeconds = Double(UInt64.max) / 1_000_000_000
        let cappedSeconds = min(normalizedSeconds, maxSafeSeconds)
        return UInt64(cappedSeconds * 1_000_000_000)
    }
}
