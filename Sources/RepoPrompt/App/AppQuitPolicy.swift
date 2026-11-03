import Foundation
import RepoPromptAgentCore

enum AppQuitRequestPhase: Equatable {
    case idle
    case awaitingConfirmation
    case terminating
}

enum AppQuitRequestDecision: Equatable {
    case showConfirmation(AppQuitConfirmation)
    case beginTermination
    case awaitCurrentRequest
}

struct AppQuitConfirmation: Equatable {
    let title: String
    let message: String
    let cancelButtonTitle: String
    let confirmButtonTitle: String
}

/// The reason of exactly one app termination request (review A P1-09). Restart safely arms it
/// immediately before its own `NSApp.terminate`; the termination entry takes it once, first thing,
/// whatever happens next (a quit confirmation the user cancels, a request that joins one already in
/// progress, or R4 itself), and Restart safely disarms it again after `terminate` returns. A later
/// ordinary Quit therefore never restarts.
struct AppShutdownReasonLatch: Equatable {
    private(set) var pending: AgentRecoveryShutdownReason = .appQuit

    mutating func armSafeRestart() {
        pending = .safeRestart
    }

    mutating func disarm() {
        pending = .appQuit
    }

    /// The reason of the termination request that starts now; the latch is disarmed.
    mutating func take() -> AgentRecoveryShutdownReason {
        defer { pending = .appQuit }
        return pending
    }
}

enum AppQuitPolicy {
    static func decide(
        warningEnabled: Bool,
        suppressesConfirmation: Bool,
        phase: AppQuitRequestPhase,
        activeItems: [WindowCloseActivityItem]
    ) -> AppQuitRequestDecision {
        guard phase == .idle else {
            return .awaitCurrentRequest
        }
        guard warningEnabled, !suppressesConfirmation else {
            return .beginTermination
        }

        let items = consolidatedActiveItems(activeItems)
        var message = "Are you sure you want to quit RepoPrompt?"
        if !items.isEmpty {
            message += " Quitting will end \(summaryText(for: items))."
        }
        return .showConfirmation(
            AppQuitConfirmation(
                title: "Quit RepoPrompt?",
                message: message,
                cancelButtonTitle: "Cancel",
                confirmButtonTitle: "Quit"
            )
        )
    }

    static func consolidatedActiveItems(
        _ items: [WindowCloseActivityItem]
    ) -> [WindowCloseActivityItem] {
        var itemsByID: [String: WindowCloseActivityItem] = [:]
        for item in items where item.count > 0 {
            if let existing = itemsByID[item.id] {
                itemsByID[item.id] = WindowCloseActivityItem(
                    id: item.id,
                    count: existing.count + item.count,
                    singularLabel: existing.singularLabel,
                    pluralLabel: existing.pluralLabel
                )
            } else {
                itemsByID[item.id] = item
            }
        }
        return itemsByID.values.sorted { $0.id < $1.id }
    }

    private static func summaryText(for items: [WindowCloseActivityItem]) -> String {
        items.map { $0.formattedCount() }.joined(separator: " and ")
    }
}
