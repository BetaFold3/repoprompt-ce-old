import Foundation
import RepoPromptAgentCore

// Step 8-attention-2 (O34-2): bulk Dismiss from the Needs Attention sheet. The coordinator runs it
// (`AgentRecoveryCoordinator+BulkDismiss.swift`: sequential, one at a time app-wide, each item
// revalidated against the item as displayed); this window only freezes the displayed rows when a
// bulk button is clicked and reads the shared status. Dismiss only hides cards; nothing is sent,
// stopped, discarded or unpaused.

/// A bulk Dismiss frozen when its button was clicked (review A ATT2-01): the coordinator's capture
/// of the displayed rows (its eligible items are the confirmed count) and how many of those eligible
/// rows belong to another workspace.
struct AgentRecoveryBulkDismissRequest {
    let section: AgentRecoveryBulkDismissSection
    let capture: AgentRecoveryBulkDismissCapture
    let otherWorkspaceCount: Int

    var eligibleCount: Int {
        capture.items.count
    }
}

extension AgentModeViewModel {
    /// Confirmation text of a needs-action bulk Dismiss.
    static let recoveryBulkDismissNeedsActionWarning =
        "Dismiss only hides these cards. Saved messages, questions, drafts and schedules stay saved and are never sent. Sending stays paused for crash holds until you confirm they stopped."

    /// The running bulk Dismiss, or the last finished one's summary (shared by every window).
    var recoveryBulkDismissStatus: AgentRecoveryBulkDismissStatus? {
        recoveryCoordinator?.bulkDismiss
    }

    var isRecoveryBulkDismissRunning: Bool {
        recoveryCoordinator?.isBulkDismissRunning == true
    }

    /// Freezes a bulk Dismiss of the displayed `rows` now (hidden rows, listed only while "Show
    /// dismissed and cleared" is on, are not captured); `nil` when recovery is not ready.
    func recoveryBulkDismissRequest(
        section: AgentRecoveryBulkDismissSection,
        rows: [AgentRecoveryNeedsAttentionRow]
    ) -> AgentRecoveryBulkDismissRequest? {
        guard let coordinator = recoveryCoordinator, coordinator.startupState == .ready else { return nil }
        let capture = coordinator.bulkDismissCapture(rows.filter { !$0.isHidden }.compactMap(\.item))
        let eligibleIDs = Set(capture.items.map(\.id))
        let otherWorkspaceCount = rows.count { row in
            row.isOtherWorkspace && row.item.map { eligibleIDs.contains($0.id) } == true
        }
        return AgentRecoveryBulkDismissRequest(section: section, capture: capture, otherWorkspaceCount: otherWorkspaceCount)
    }

    /// Rows a bulk Dismiss would dismiss now (the coordinator's eligibility predicate). The other
    /// displayed rows are reported as skipped.
    func recoveryBulkDismissEligibleCount(_ rows: [AgentRecoveryNeedsAttentionRow]) -> Int {
        recoveryBulkDismissRequest(section: .needsAction, rows: rows)?.eligibleCount ?? 0
    }

    /// Starts a bulk Dismiss of the displayed `rows`, frozen now (no confirmation step).
    @discardableResult
    func startRecoveryBulkDismiss(
        section: AgentRecoveryBulkDismissSection,
        rows: [AgentRecoveryNeedsAttentionRow]
    ) -> Task<AgentRecoveryBulkDismissStatus?, Never>? {
        recoveryBulkDismissRequest(section: section, rows: rows).flatMap { startRecoveryBulkDismiss($0) }
    }

    /// Starts a frozen bulk Dismiss: exactly its eligible items, as captured. The task belongs to no
    /// view (closing the sheet cancels nothing); `nil` while another bulk Dismiss runs or when
    /// recovery is not ready.
    @discardableResult
    func startRecoveryBulkDismiss(_ request: AgentRecoveryBulkDismissRequest) -> Task<AgentRecoveryBulkDismissStatus?, Never>? {
        guard let coordinator = recoveryCoordinator, coordinator.startupState == .ready,
              !coordinator.isBulkDismissRunning
        else { return nil }
        return Task { @MainActor in
            await coordinator.dismissCatalogItems(request.capture, section: request.section)
        }
    }

    /// Clears the last finished bulk Dismiss's summary when the sheet closes (review B F7).
    func clearRecoveryBulkDismissSummary() {
        recoveryCoordinator?.clearBulkDismissSummary()
    }

    /// Stops the running bulk Dismiss before its next item; dismissed items stay dismissed.
    func cancelRecoveryBulkDismiss() {
        recoveryCoordinator?.requestBulkDismissCancel()
    }
}
