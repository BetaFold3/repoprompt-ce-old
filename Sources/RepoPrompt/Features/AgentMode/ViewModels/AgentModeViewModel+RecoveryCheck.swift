import Foundation
import RepoPromptAgentCore

// Step 9-check: "Check and resolve" from the Needs Attention sheet. The coordinator runs it
// (`AgentRecoveryCoordinator+Check.swift`: captured items, one at a time app-wide, Stop before the
// next item); this window freezes the displayed rows when the button is clicked, decides whether
// process and provider-history checks are active (the recovery action runner's Reconcile gate:
// qualification AND verified registration), and lends its existing Reconcile path for run cards of
// the session open in this window. Nothing is sent, stopped, discarded, dismissed or opened.

/// What one recovery choice did, for a caller that reports it (Check and resolve): the runner's
/// typed result and the history observation it ran. Both stay `nil` when the choice was refused
/// before reaching the runner.
@MainActor
final class RecoveryResumeActionReport {
    var result: AgentRecoveryActionResult?
    var observed: AgentRecoveryReconcileResult?
}

extension AgentModeViewModel {
    /// The running check, or the last finished one's report (shared by every window).
    var recoveryCheckStatus: AgentRecoveryCheckStatus? {
        recoveryCoordinator?.recoveryCheck
    }

    var isRecoveryCheckRunning: Bool {
        recoveryCoordinator?.isRecoveryCheckRunning == true
    }

    /// Whether Check may refresh process ownership and reconcile provider history: exactly when
    /// Reconcile itself is available (not active while the production activation is off).
    var recoveryChecksActive: Bool {
        recoveryActionRunner.isAvailable(.reconcileOnly)
    }

    /// Starts Check and resolve on the displayed `rows`, frozen now (hidden rows are not captured).
    /// The task belongs to no view (closing the sheet cancels nothing); `nil` while another check
    /// runs or when recovery is not ready.
    @discardableResult
    func startRecoveryCheck(rows: [AgentRecoveryNeedsAttentionRow]) -> Task<AgentRecoveryCheckStatus?, Never>? {
        guard let coordinator = recoveryCoordinator, coordinator.startupState == .ready,
              !coordinator.isRecoveryCheckRunning
        else { return nil }
        let items = Self.recoveryCheckItems(rows)
        let checksActive = recoveryChecksActive
        return Task { @MainActor [weak self] in
            await coordinator.checkCatalogItems(items, checksActive: checksActive) { item in
                guard let self else { return .notAttempted(AgentModeViewModel.recoveryActionStaleText) }
                return await self.reconcileRecoveryCheckItem(item)
            }
        }
    }

    /// The rows Check would capture: displayed (not hidden) rows that have a catalog item. The
    /// button's enable state and the report's total both come from these.
    static func recoveryCheckItems(_ rows: [AgentRecoveryNeedsAttentionRow]) -> [AgentRecoveryCatalogItem] {
        rows.filter { !$0.isHidden }.compactMap(\.item)
    }

    /// The Check button's help text. With checks active it names the restriction warning (a
    /// Refresh that proves a process exited, or a crash hold confirmed from process records, may let
    /// already-authorized scheduled sends run).
    var recoveryCheckHelpText: String {
        recoveryChecksActive
            ? "\(AgentRecoveryCheckStatus.activeNoticeText) Then reports what each listed item needs."
            : "Reports what each listed item needs. Process and provider-history checks are not active, so nothing is changed."
    }

    /// Shown in the sheet before a check starts while checks are active (Step 9-activation-b): what
    /// Check may clear or confirm, visible at the moment the user decides to click. `nil` while a
    /// check report is shown (its header carries the same text) or checks are not active.
    var recoveryCheckNoticeText: String? {
        guard recoveryCheckStatus == nil, recoveryChecksActive else { return nil }
        return AgentRecoveryCheckStatus.activeNoticeText
    }

    /// Stops the running check before its next item; checked items keep their result.
    func cancelRecoveryCheck() {
        recoveryCoordinator?.requestRecoveryCheckCancel()
    }

    /// Clears the last finished check's report when the sheet closes.
    func clearRecoveryCheckReport() {
        recoveryCoordinator?.clearRecoveryCheckReport()
    }

    /// The existing Reconcile of one run card, only for the session open in this window (Check never
    /// opens a session). Its progress and any failure are the row's shared action state. If Stop
    /// abandoned the wait, this still finishes later and records its result on the row only.
    private func reconcileRecoveryCheckItem(_ item: AgentRecoveryCatalogItem) async -> AgentRecoveryCheckReconcile {
        guard let coordinator = recoveryCoordinator,
              let sessionID = item.sessionID,
              let (session, _) = recoveryListLane(sessionID: sessionID)
        else { return .notAttempted("Open this session to check its provider history.") }
        guard recoveryActionTarget(for: session).providerConversationID != nil else {
            return .notAttempted("No provider conversation is recorded for this session.")
        }
        guard coordinator.catalogActionStates[item.id] != .working else {
            return .notAttempted("Another action on this item is in progress.")
        }
        coordinator.setCatalogActionState(.working, for: item.id)
        refreshRecoveryListUI()
        let report = RecoveryResumeActionReport()
        let failure = await performRecoveryResumeAction(rowID: item.id, action: .reconcileHistory, report: report)
        coordinator.setCatalogActionState(failure.map { .failed($0) }, for: item.id)
        refreshRecoveryListUI()
        guard let result = report.result else {
            // Refused before the runner (with its reason); a `nil` failure there means the choice
            // was found already performed.
            return .notAttempted(failure ?? AgentRecoveryCheckReconcile.alreadyChosenText)
        }
        return .performed(result, observed: report.observed)
    }
}
