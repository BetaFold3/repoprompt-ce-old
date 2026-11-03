import Foundation

// Step 8-attention-2 (O34-2) bulk Dismiss of the Needs Attention sheet. Dismiss only hides cards:
// the set is frozen when the user chooses the bulk action (`bulkDismissCapture`: the eligible items
// are the confirmed count; the rest are skips and are never promoted into the batch later), and
// each eligible item goes through the existing revision-checked `dismissCatalogItem` with the item
// exactly as it was captured (never re-fetched by row ID and acted on in a newer form). Items are
// processed one at a time, one bulk at a time app-wide; progress and
// failures use the shared per-row action state, so a failure stays on its row. An explicit cancel
// stops before the next item (committed items stay dismissed); closing the sheet cancels nothing.
// Nothing here sends, stops, discards, confirms or unpauses anything: a dismissed crash hold still
// blocks its session and keeps its paused indicator.

/// Which Needs Attention section a bulk Dismiss covers.
package enum AgentRecoveryBulkDismissSection: Equatable {
    case needsAction
    case informational
}

/// Why a captured item was left untouched.
package enum AgentRecoveryBulkDismissSkipReason: Equatable {
    /// The item offers no Dismiss (save failures, restrictions, proposals, held transfers, ...).
    case noDismiss
    case alreadyDismissed
    /// An action on the item is in progress.
    case busy
    /// The item changed, or left the catalog, since it was shown.
    case changed
}

package struct AgentRecoveryBulkDismissSkip: Equatable {
    package let itemID: String
    package let reason: AgentRecoveryBulkDismissSkipReason
}

/// A bulk Dismiss's set, frozen when the user chooses it (review A ATT2-01): the items eligible then
/// (in displayed order, exactly as captured; the confirmation count) and every other displayed item
/// as a skip with its reason. Dismissed and cleared items (listed only while "Show dismissed and
/// cleared" is on, never counted) are not captured at all (review B F2).
package struct AgentRecoveryBulkDismissCapture {
    package let items: [AgentRecoveryCatalogItem]
    package let skipped: [AgentRecoveryBulkDismissSkip]

    package var total: Int {
        items.count + skipped.count
    }
}

package extension AgentRecoveryCatalogItem {
    /// Whether the item's row offers Dismiss: a durable acknowledgement of a session's card that is
    /// not dismissed. The one rule for the row's Dismiss action (`recoveryListRow`) and bulk Dismiss
    /// eligibility (review B F1).
    var offersDismiss: Bool {
        acknowledgement != nil && sessionID != nil && !isDismissed
    }
}

/// Progress and result of one bulk Dismiss (transient, never persisted).
package struct AgentRecoveryBulkDismissStatus: Equatable {
    package let section: AgentRecoveryBulkDismissSection
    /// Captured items, in displayed order.
    package let total: Int
    package internal(set) var dismissed = 0
    /// Items whose Dismiss failed (the failure stays on the row).
    package internal(set) var failed = 0
    package internal(set) var skipped: [AgentRecoveryBulkDismissSkip] = []
    package internal(set) var isRunning = true
    package internal(set) var cancelRequested = false
    /// Items not reached because the bulk was cancelled.
    package internal(set) var notAttempted = 0

    package init(section: AgentRecoveryBulkDismissSection, total: Int) {
        self.section = section
        self.total = total
    }

    package var processed: Int {
        dismissed + failed + skipped.count
    }

    /// One line naming its section, e.g. "Information: Dismissed 12 of 14 · 1 failed · 1 skipped (1 changed)".
    package var summaryText: String {
        let name = switch section {
        case .needsAction: "Needs action"
        case .informational: "Information"
        }
        if isRunning {
            let progress = "\(name): Dismissing \(min(processed + 1, total)) of \(total)…"
            return cancelRequested ? "\(progress) Stopping after this item." : progress
        }
        var parts = ["\(name): Dismissed \(dismissed) of \(total)"]
        if failed > 0 { parts.append("\(failed) failed") }
        if !skipped.isEmpty {
            let reasons: [(AgentRecoveryBulkDismissSkipReason, String)] = [
                (.noDismiss, "can't be dismissed"),
                (.alreadyDismissed, "already dismissed"),
                (.busy, "busy"),
                (.changed, "changed")
            ]
            let detail = reasons.compactMap { reason, label -> String? in
                let count = skipped.count { $0.reason == reason }
                return count > 0 ? "\(count) \(label)" : nil
            }
            parts.append("\(skipped.count) skipped (\(detail.joined(separator: ", ")))")
        }
        if notAttempted > 0 { parts.append("stopped, \(notAttempted) not attempted") }
        return parts.joined(separator: " · ")
    }
}

package extension AgentRecoveryCoordinator {
    /// Whether a bulk Dismiss is running (app-wide; the sheet disables its bulk buttons).
    var isBulkDismissRunning: Bool {
        bulkDismiss?.isRunning == true
    }

    /// Freezes a bulk Dismiss of the displayed `items` now: the hidden ones are dropped, each other
    /// one is eligible or a skip with its reason (`bulkDismissIneligibility`).
    func bulkDismissCapture(_ items: [AgentRecoveryCatalogItem]) -> AgentRecoveryBulkDismissCapture {
        var eligible: [AgentRecoveryCatalogItem] = []
        var skipped: [AgentRecoveryBulkDismissSkip] = []
        for item in items where !item.isHidden {
            if let reason = bulkDismissIneligibility(of: item) {
                skipped.append(AgentRecoveryBulkDismissSkip(itemID: item.id, reason: reason))
            } else {
                eligible.append(item)
            }
        }
        return AgentRecoveryBulkDismissCapture(items: eligible, skipped: skipped)
    }

    /// Captures `items` now and dismisses the eligible ones (no confirmation step).
    @discardableResult
    func dismissCatalogItems(
        _ items: [AgentRecoveryCatalogItem],
        section: AgentRecoveryBulkDismissSection
    ) async -> AgentRecoveryBulkDismissStatus? {
        await dismissCatalogItems(bulkDismissCapture(items), section: section)
    }

    /// Dismisses exactly the capture's eligible items, as captured, one at a time in order; its
    /// skips are reported as they were captured. Before each one it is revalidated against the
    /// current catalog (synchronously, before the Dismiss write begins); an item already dismissed,
    /// busy, changed or gone is skipped with its reason. Each eligible item goes through
    /// `dismissCatalogItem` with the captured item (store-side revalidation included), publishing
    /// `.working` and then its failure (or nothing) as the row's shared action state. Returns the
    /// final status, or `nil` without doing anything while another bulk Dismiss runs.
    @discardableResult
    func dismissCatalogItems(
        _ capture: AgentRecoveryBulkDismissCapture,
        section: AgentRecoveryBulkDismissSection
    ) async -> AgentRecoveryBulkDismissStatus? {
        guard !isBulkDismissRunning else { return nil }
        let items = capture.items
        bulkDismiss = AgentRecoveryBulkDismissStatus(section: section, total: capture.total)
        bulkDismiss?.skipped = capture.skipped
        postCatalogChange()
        for (index, item) in items.enumerated() {
            if bulkDismiss?.cancelRequested == true {
                bulkDismiss?.notAttempted = items.count - index
                break
            }
            if let reason = bulkDismissIneligibility(of: item) {
                bulkDismiss?.skipped.append(AgentRecoveryBulkDismissSkip(itemID: item.id, reason: reason))
                postCatalogChange()
                continue
            }
            setCatalogActionState(.working, for: item.id)
            let failure = await dismissCatalogItem(item)
            setCatalogActionState(failure.map { .failed($0) }, for: item.id)
            if failure == nil {
                bulkDismiss?.dismissed += 1
            } else {
                bulkDismiss?.failed += 1
            }
        }
        bulkDismiss?.isRunning = false
        postCatalogChange()
        return bulkDismiss
    }

    /// Stops the running bulk Dismiss before its next item (the current one settles).
    func requestBulkDismissCancel() {
        guard bulkDismiss?.isRunning == true, bulkDismiss?.cancelRequested == false else { return }
        bulkDismiss?.cancelRequested = true
        postCatalogChange()
    }

    /// Clears the last finished bulk Dismiss's summary (the sheet was closed); a running one stays.
    func clearBulkDismissSummary() {
        guard let status = bulkDismiss, !status.isRunning else { return }
        bulkDismiss = nil
        postCatalogChange()
    }

    /// Bulk Dismiss eligibility, the one predicate for the sheet's count and capture and for each
    /// item's revalidation: why `item` must not be dismissed now, or `nil` when its row offers
    /// Dismiss (`offersDismiss`), it is not busy, and it is still the shown item. A class change
    /// counts as a change: an informational note that now needs action is never dismissed without
    /// the needs-action confirmation.
    func bulkDismissIneligibility(of item: AgentRecoveryCatalogItem) -> AgentRecoveryBulkDismissSkipReason? {
        guard item.offersDismiss, let acknowledgement = item.acknowledgement else {
            return item.isDismissed ? .alreadyDismissed : .noDismiss
        }
        if catalogActionStates[item.id] == .working { return .busy }
        guard let current = catalog.item(id: item.id),
              current.acknowledgement?.key == acknowledgement.key,
              current.acknowledgement?.freshness == acknowledgement.freshness,
              current.attention == item.attention
        else { return .changed }
        if current.isDismissed { return .alreadyDismissed }
        return nil
    }
}
