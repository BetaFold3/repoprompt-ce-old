//
//  WindowContentView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-24.
//

import SwiftUI

/// This view holds exactly one @StateObject WindowState, meaning
/// each new Window/Scene gets its own WindowState.
struct WindowContentView: View {
    @EnvironmentObject var versionManager: VersionManager
    @EnvironmentObject var windowStatesManager: WindowStatesManager
    @EnvironmentObject var sparkleManager: SparkleUpdaterManager
    @Environment(\.openWindow) private var openWindow

    /// The WindowState itself (your big manager of fileManager, promptManager, etc.). Its activation
    /// waits for app-wide admission at registration (`onAppear`).
    @StateObject private var windowState = WindowState.forWindowScene()

    var body: some View {
        // The host is one stable container that owns the lifecycle callbacks; admission changes
        // only the branch beneath it, so pending → admitted never reads as the window going away.
        WindowAdmissionLifecycleHost(
            admission: windowState.applicationAdmission,
            onAppear: handleAppear,
            onDisappear: handleDisappear
        ) { admission in
            admittedContent(admission)
        }
        // Let SwiftUI own the window title. Without this, the scene re-applies the
        // default app-name title over the workspace name whenever it refreshes the
        // window chrome (visible in both window titles and native tab names).
        .navigationTitle(windowState.displayedWindowTitle)
        .removingSystemToolbarTitle()
        .background(
            WindowAccessor { newWindow in
                // IMPORTANT: do not mutate SwiftUI @State here.
                // Attach is internally guarded and safe even if called multiple times.
                windowState.attachWindow(newWindow)
            }
        )
        // Example sheets or popups
        .sheet(isPresented: $versionManager.shouldShowWelcomeView) {
            WelcomeView(isPresented: $versionManager.shouldShowWelcomeView, versionManager: versionManager)
        }
        .sheet(isPresented: $versionManager.shouldShowVersionPopup) {
            VersionPopupView(isPresented: $versionManager.shouldShowVersionPopup)
        }
    }

    /// Once the view appears, register it with WindowStatesManager (the app-wide admission
    /// decision; a window refused during an app quit stays an inert shell).
    private func handleAppear() {
        guard windowStatesManager.registerWindowState(windowState) else { return }

        // Install the openWindow action into AppWindowOpener for programmatic window creation
        AppWindowOpener.shared.install {
            openWindow(id: "main")
        }
    }

    /// Cleanup when the window's content goes away.
    private func handleDisappear() {
        // A window never admitted holds no application state to save or tear down.
        guard windowState.applicationAdmission == .admitted else {
            windowState.beginClose()
            return
        }
        SettingsWindowCoordinator.shared.closeIfTargeting(windowState)

        // Stop focus/title side-effects early to avoid SwiftUI observation crashes during teardown.
        windowState.beginClose()

        // Save the current workspace state before closing, but avoid extra teardown work
        // or publish-heavy persistence once app termination has begun.
        if !windowStatesManager.isTerminating {
            windowState.workspaceManager.pollAndSaveState()
        }

        guard !windowStatesManager.isTerminating else {
            windowState.aiQueriesService.cancelQuery()
            return
        }

        windowStatesManager.unregisterWindowState(windowState)
        Task { await windowState.tearDown() }
    }

    /// The window's content only once admitted: nothing in it (sessions, composer, workspace
    /// views) appears before the app-wide admission decision.
    @ViewBuilder
    private func admittedContent(_ admission: WindowState.ApplicationAdmission) -> some View {
        switch admission {
        case .admitted:
            ContentView(windowState: windowState)
                .safeAreaInset(edge: .top) { GlobalSettingsPersistenceBlockBanner(allowsSessionDismissal: true) }
                // App-wide Needs Attention sheet, independent of the sidebar and any tab.
                .modifier(AgentRecoveryNeedsAttentionHost(agentModeVM: windowState.agentModeViewModel))
                .environmentObject(windowState) // If your subviews need it
                .environmentObject(sparkleManager)
                .environmentObject(versionManager) // Pass versionManager to ContentView
        case .pending:
            Color.clear
        case .refusedDuringQuit:
            Text("RepoPrompt is quitting")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One stable container that owns a window's appear/disappear callbacks. The admission-dependent
/// content is a branch beneath it, so the callbacks never depend on how SwiftUI treats lifecycle
/// modifiers on a changing conditional: a pending → admitted change replaces only the branch, and
/// `onDisappear` (unregister and teardown) means the window's content actually went away.
struct WindowAdmissionLifecycleHost<Content: View>: View {
    let admission: WindowState.ApplicationAdmission
    let onAppear: () -> Void
    let onDisappear: () -> Void
    @ViewBuilder let content: (WindowState.ApplicationAdmission) -> Content

    var body: some View {
        ZStack {
            content(admission)
        }
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
    }
}

private extension View {
    @ViewBuilder
    func removingSystemToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}
