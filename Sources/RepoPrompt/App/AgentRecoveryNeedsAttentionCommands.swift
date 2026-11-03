import AppKit
import SwiftUI

/// App-wide entry point of the Needs Attention sheet (lossless restart Phase 2): a View-menu
/// command that works from any window, with every tab or the session sidebar closed, and with no
/// window open at all. It is always enabled, even when nothing is undismissed, so dismissed items
/// stay reviewable through "Show dismissed and cleared". The menu owns no state.
struct AgentRecoveryNeedsAttentionCommands: Commands {
    /// Shared window tracker injected from the app.
    @ObservedObject var windowStatesManager: WindowStatesManager

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Needs Attention…") {
                Task { @MainActor in
                    await AgentRecoveryNeedsAttentionRouter.present(from: windowStatesManager)
                }
            }
            // Restart safely (lossless restart Phase 4): only shown while composed, never in
            // production until O3 live acceptance.
            if windowStatesManager.isSafeRestartAvailable {
                Button("Restart Safely") {
                    windowStatesManager.requestSafeRestart()
                }
            }
        }
    }
}

/// Routes an app-level Needs Attention request to one window's sheet host. Presenting reads the
/// recovery coordinator's catalog only: it starts, hydrates, or resumes nothing.
@MainActor
enum AgentRecoveryNeedsAttentionRouter {
    /// Presents in the focused window, else the most recent one; with no window, opens one through
    /// the existing main-window route and presents there once it registered.
    static func present(from windowStatesManager: WindowStatesManager) async {
        let existing = windowStatesManager.allWindows.first { $0.isCurrentlyFocused }
            ?? windowStatesManager.latestWindowState
        existing?.nsWindow?.makeKeyAndOrderFront(nil)
        await present(existing: existing?.agentModeViewModel) {
            try await windowStatesManager.openNewMainWindow().agentModeViewModel
        }
    }

    /// Requests the sheet from `existing`, or from a window opened by `openWindow` when there is
    /// none. Returns the requesting view model, or `nil` when no window could be opened.
    @discardableResult
    static func present(
        existing: AgentModeViewModel?,
        openWindow: @MainActor () async throws -> AgentModeViewModel
    ) async -> AgentModeViewModel? {
        let target: AgentModeViewModel
        if let existing {
            target = existing
        } else {
            guard let opened = try? await openWindow() else { return nil }
            target = opened
        }
        target.presentRecoveryNeedsAttention()
        return target
    }
}
