import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

/// Lossless restart F3: the banner header counts this session's rows and never contradicts the
/// "Needs Attention (n)…" button, which counts items elsewhere. O34-1: items elsewhere never keep
/// the banner visible on their own.
@MainActor
final class AgentRecoveryListHeaderTextTests: XCTestCase {
    private func row(_ id: String) -> AgentRecoveryListRowProps {
        AgentRecoveryListRowProps(
            id: id,
            sessionID: UUID(),
            sessionName: "Session",
            title: "Interrupted turn",
            detail: "Detail",
            text: nil,
            attachmentNames: [],
            actions: [.dismiss],
            isWorking: false,
            error: nil
        )
    }

    private func props(rows: Int, other: Int, status: AgentRecoveryListProps.Status = .ready) -> AgentRecoveryListProps {
        AgentRecoveryListProps(
            status: status,
            rows: (0 ..< rows).map { row("row-\($0)") },
            canRetry: false,
            otherItemCount: other
        )
    }

    func testNoRowsHereHidesTheBannerEvenWithItemsElsewhere() {
        let many = props(rows: 0, other: 64)
        XCTAssertTrue(many.isEmpty, "Items elsewhere never keep the banner visible on their own (O34-1)")
        XCTAssertFalse(many.headerText.contains("elsewhere"))
        XCTAssertFalse(many.headerText.contains("0 saved"))
        XCTAssertTrue(props(rows: 0, other: 1).isEmpty)
    }

    func testRowsHereOnlyCountThisSession() {
        XCTAssertEqual(props(rows: 1, other: 0).headerText, "1 saved or interrupted item needs your attention.")
        XCTAssertEqual(props(rows: 3, other: 0).headerText, "3 saved or interrupted items need your attention.")
    }

    func testRowsHereAndElsewhereKeepBothCountsDistinct() {
        XCTAssertEqual(
            props(rows: 1, other: 5).headerText,
            "1 saved or interrupted item in this session needs your attention. 5 items elsewhere need attention."
        )
        XCTAssertEqual(
            props(rows: 2, other: 1).headerText,
            "2 saved or interrupted items in this session need your attention. 1 item elsewhere needs attention."
        )
    }

    func testEmptyIsHiddenAndNeverClaimsZeroItemsNeedAttention() {
        let empty = props(rows: 0, other: 0)
        XCTAssertTrue(empty.isEmpty, "Nothing here and nothing elsewhere: the banner is not shown")
        XCTAssertEqual(empty.headerText, "Nothing interrupted in this session.")
    }

    func testDismissedCrashHoldIndicatorCountsAsThisSessionsItem() {
        // The paused indicator of a dismissed crash hold is this session's only row.
        let indicator = AgentRecoveryListProps(
            status: .ready,
            rows: [row("\(AgentModeViewModel.recoveryListPausedRowPrefix)\(UUID().uuidString)")],
            canRetry: false,
            otherItemCount: 0
        )
        XCTAssertEqual(indicator.headerText, "1 saved or interrupted item needs your attention.")
        let withElsewhere = AgentRecoveryListProps(status: .ready, rows: indicator.rows, canRetry: false, otherItemCount: 4)
        XCTAssertEqual(
            withElsewhere.headerText,
            "1 saved or interrupted item in this session needs your attention. 4 items elsewhere need attention."
        )
    }

    /// Review B ATT1-4: the sheet's "Needs action (n)" and "Information (m)" counts exclude
    /// dismissed rows (listed only when "Show dismissed" is on).
    func testSheetSectionCountsExcludeDismissedRows() {
        func entry(_ id: String, dismissed: Bool, attention: AgentRecoveryCatalogAttention) -> AgentRecoveryNeedsAttentionRow {
            AgentRecoveryNeedsAttentionRow(row: row(id), isDismissed: dismissed, isOtherWorkspace: false, attention: attention)
        }
        let needsAction = [
            entry("a", dismissed: false, attention: .needsAction),
            entry("b", dismissed: true, attention: .needsAction),
            entry("c", dismissed: false, attention: .needsAction)
        ]
        let informational = [
            entry("d", dismissed: true, attention: .informational),
            entry("e", dismissed: true, attention: .informational)
        ]
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.headerCount(needsAction), 2)
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.headerCount(informational), 0)
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.headerCount([]), 0)
    }

    /// Step 8-attention-2: automatically cleared notes are not counted and, when listed under "Show
    /// dismissed and cleared", are labelled with why they were cleared.
    func testClearedNotesAreNotCountedAndAreLabelledWithTheirReason() {
        func entry(_ id: String, clear: AgentRecoveryCatalogAutomaticClear?, dismissed: Bool = false) -> AgentRecoveryNeedsAttentionRow {
            AgentRecoveryNeedsAttentionRow(row: row(id), isDismissed: dismissed, isOtherWorkspace: false, attention: .informational, automaticClear: clear)
        }
        let rows = [
            entry("a", clear: nil),
            entry("b", clear: .sessionContinued),
            entry("c", clear: .conversationCleared),
            entry("d", clear: .resolved, dismissed: true)
        ]
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.headerCount(rows), 1)
        XCTAssertEqual(rows.map(\.isHidden), [false, true, true, true])
        XCTAssertNil(AgentRecoveryNeedsAttentionSheet.label(for: rows[0]))
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.label(for: rows[1]), "Cleared: session continued")
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.label(for: rows[2]), "Cleared: conversation cleared")
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.label(for: rows[3]), "Dismissed · Cleared: resolved")
    }

    /// The needs-action bulk Dismiss confirmation states the count, how many are in other
    /// workspaces, and that Dismiss only hides.
    func testNeedsActionBulkDismissConfirmationText() {
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.needsActionConfirmationTitle(eligible: 1), "Dismiss 1 card that needs action?")
        XCTAssertEqual(AgentRecoveryNeedsAttentionSheet.needsActionConfirmationTitle(eligible: 3), "Dismiss 3 cards that need action?")
        XCTAssertEqual(
            AgentRecoveryNeedsAttentionSheet.needsActionConfirmationTitle(eligible: 5, otherWorkspaces: 2),
            "Dismiss 5 cards that need action (2 in other workspaces)?"
        )
        XCTAssertEqual(
            AgentRecoveryNeedsAttentionSheet.needsActionConfirmationTitle(eligible: 1, otherWorkspaces: 1),
            "Dismiss 1 card that needs action (1 in another workspace)?"
        )
        XCTAssertEqual(
            AgentModeViewModel.recoveryBulkDismissNeedsActionWarning,
            "Dismiss only hides these cards. Saved messages, questions, drafts and schedules stay saved and are never sent. Sending stays paused for crash holds until you confirm they stopped."
        )
    }

    func testLoadingAndFailedStatusesAreUnchanged() {
        XCTAssertEqual(
            props(rows: 0, other: 3, status: .loading).headerText,
            "Checking for work interrupted when RepoPrompt last closed…"
        )
        XCTAssertEqual(props(rows: 0, other: 3, status: .failed("Paused.")).headerText, "Paused.")
    }
}
