import SwiftUI
#if DEBUG
    import OSLog
#endif

enum SnippetPaletteActivationGate {
    static func shouldActivate(
        requestWindowID: Int?,
        currentWindowID: Int,
        rootRoute: AppRootRoute,
        isMainWindowKey: Bool,
        hasAttachedSheet: Bool,
        isBlockingOverlayVisible: Bool,
        isNavigationHUDPresented: Bool,
        isModelSelectionHUDPresented: Bool,
        activeComposeTabID: UUID?
    ) -> Bool {
        requestWindowID == currentWindowID
            && rootRoute == .main
            && isMainWindowKey
            && !hasAttachedSheet
            && !isBlockingOverlayVisible
            && !isNavigationHUDPresented
            && !isModelSelectionHUDPresented
            && activeComposeTabID != nil
    }
}

/// Tab changes are delivered after storage, not on an incidental shell redraw.
enum AgentHUDActiveTabChangeGate {
    static func matches(requestWindowID: Int?, currentWindowID: Int) -> Bool {
        requestWindowID == currentWindowID
    }

    /// Shared body of the shell's `.activeComposeTabChanged` receiver; the caller supplies animation.
    /// Returns whether the event targeted this window.
    @MainActor
    @discardableResult
    static func handle(
        requestWindowID: Int?,
        currentWindowID: Int,
        navigationHUD: AgentNavigationHUDViewModel,
        modelSelectionHUD: AgentModelSelectionHUDViewModel
    ) -> Bool {
        guard matches(requestWindowID: requestWindowID, currentWindowID: currentWindowID) else {
            return false
        }
        if navigationHUD.isPresented, !navigationHUD.isRouting {
            navigationHUD.dismiss()
        }
        // Invalidate post-commit focus even when an in-flight operation cannot be dismissed.
        modelSelectionHUD.activeTabDidChange()
        return true
    }
}

// MARK: - Content Root Shell

struct ContentRootShellView: View {
    #if DEBUG
        private enum HUDRoutingCommand: String {
            case navigation
            case modelSelection
        }

        private enum HUDRoutingDisposition: String {
            case mismatch
            case routing
            case blocked
            case duplicate
            case workspaceEntry = "workspace-entry"
            case presented
            case toggleDismissed = "toggle-dismissed"
        }

        private static let hudRoutingLogger = Logger(subsystem: "com.repoprompt.app", category: "hud-routing")
    #endif

    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var workspaceApprovalManager: WorkspaceApprovalManager
    @ObservedObject var remoteDeviceApprovalManager: RemoteDeviceApprovalManager
    @Binding var showWorkspaceSwitchOverlay: Bool
    @StateObject private var agentNavigationHUD = AgentNavigationHUDViewModel()
    @StateObject private var agentModelSelectionHUD = AgentModelSelectionHUDViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastAgentNavigationHUDCommand: (mode: AgentNavigationHUDMode, at: Date)?
    @State private var lastAgentModelSelectionHUDCommand: (mode: AgentModelSelectionHUDMode, at: Date)?

    private var isBlockingOverlayVisible: Bool {
        showWorkspaceSwitchOverlay
            || (viewModel.state.mcpServer.pendingClientID != nil && viewModel.state.mcpServer.isApprovalOverlayVisible)
            || (workspaceApprovalManager.pendingRequest != nil && workspaceApprovalManager.isApprovalOverlayVisible)
            || (remoteDeviceApprovalManager.pendingRequest != nil && remoteDeviceApprovalManager.isApprovalOverlayVisible)
    }

    var body: some View {
        ZStack {
            routedContent
                .blur(radius: showWorkspaceSwitchOverlay ? 6 : 0, opaque: false)
                .animation(.easeInOut(duration: 0.12), value: showWorkspaceSwitchOverlay)

            if agentNavigationHUD.isPresented {
                AgentNavigationHUDView(
                    viewModel: agentNavigationHUD,
                    windowState: viewModel.state
                )
                .transition(hudTransition)
                .zIndex(998)
            }

            if agentModelSelectionHUD.isPresented {
                AgentModelSelectionHUDView(viewModel: agentModelSelectionHUD)
                    .transition(hudTransition)
                    .zIndex(998)
            }

            if showWorkspaceSwitchOverlay {
                WorkspaceSwitchLoadingOverlay {
                    await viewModel.workspaceManager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
                }
                .zIndex(999)
            }

            // MCP Client Approval Overlay
            if let clientID = viewModel.state.mcpServer.pendingClientID,
               viewModel.state.mcpServer.isApprovalOverlayVisible
            {
                MCPApprovalOverlayView(clientID: clientID)
                    .environmentObject(viewModel.state.mcpServer)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(1000)
            }

            // Workspace Operation Approval Overlay
            if let request = workspaceApprovalManager.pendingRequest,
               workspaceApprovalManager.isApprovalOverlayVisible
            {
                WorkspaceApprovalOverlayView(
                    approvalManager: workspaceApprovalManager,
                    request: request
                )
                // A promoted request gets a fresh overlay (visible card, Always Allow reset).
                .id(request.id)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1001)
            }

            // Remote Device Pairing Approval Overlay
            if let request = remoteDeviceApprovalManager.pendingRequest,
               remoteDeviceApprovalManager.isApprovalOverlayVisible
            {
                RemoteDeviceApprovalOverlayView(
                    approvalManager: remoteDeviceApprovalManager,
                    request: request
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1002)
            }
        }
        .animation(hudAnimation, value: agentNavigationHUD.isPresented)
        .animation(hudAnimation, value: agentModelSelectionHUD.isPresented)
        .onReceive(NotificationCenter.default.publisher(for: .openPromptSnippetPalette)) { note in
            let window = viewModel.state.nsWindow
            let tabID = viewModel.state.promptManager.activeComposeTabID
            guard SnippetPaletteActivationGate.shouldActivate(
                requestWindowID: note.userInfo?[SnippetPaletteNotificationUserInfoKey.windowID] as? Int,
                currentWindowID: viewModel.state.windowID,
                rootRoute: viewModel.rootRoute,
                isMainWindowKey: window?.isKeyWindow == true,
                hasAttachedSheet: window?.attachedSheet != nil,
                isBlockingOverlayVisible: isBlockingOverlayVisible,
                isNavigationHUDPresented: agentNavigationHUD.isPresented,
                isModelSelectionHUDPresented: agentModelSelectionHUD.isPresented,
                activeComposeTabID: tabID
            ), let tabID
            else { return }

            NotificationCenter.default.post(
                name: .performPromptSnippetPaletteActivation,
                object: nil,
                userInfo: [
                    SnippetPaletteNotificationUserInfoKey.windowID: viewModel.state.windowID,
                    SnippetPaletteNotificationUserInfoKey.tabID: tabID
                ]
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentNavigationHUD)) { note in
            guard noteTargetsCurrentWindow(note) else {
                #if DEBUG
                    logHUDRoutingReceive(command: .navigation, note: note, disposition: .mismatch)
                #endif
                return
            }
            guard !agentModelSelectionHUD.isCommitting else {
                #if DEBUG
                    logHUDRoutingReceive(command: .navigation, note: note, disposition: .routing)
                #endif
                return
            }
            guard !isBlockingOverlayVisible else {
                #if DEBUG
                    logHUDRoutingReceive(command: .navigation, note: note, disposition: .blocked)
                #endif
                animateHUD {
                    agentNavigationHUD.dismiss()
                    agentModelSelectionHUD.dismiss(reason: .blockingOverlay)
                }
                return
            }
            let rawMode = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.mode] as? String
            let mode = rawMode.flatMap(AgentNavigationHUDMode.init(rawValue:)) ?? .currentWindow
            guard !isDuplicateAgentNavigationHUDCommand(mode) else {
                #if DEBUG
                    logHUDRoutingReceive(command: .navigation, note: note, disposition: .duplicate)
                #endif
                return
            }
            guard viewModel.rootRoute != .workspaceEntry || mode == .allAgents else {
                #if DEBUG
                    logHUDRoutingReceive(command: .navigation, note: note, disposition: .workspaceEntry)
                #endif
                animateHUD { agentNavigationHUD.dismiss() }
                return
            }
            animateHUD {
                agentModelSelectionHUD.dismiss(reason: .navigation)
                agentNavigationHUD.present(mode: mode, currentWindow: viewModel.state)
            }
            #if DEBUG
                let disposition: HUDRoutingDisposition = agentNavigationHUD.isPresented ? .presented : .toggleDismissed
                logHUDRoutingReceive(command: .navigation, note: note, disposition: disposition)
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAgentModelSelectionHUD)) { note in
            guard noteTargetsCurrentWindow(note) else {
                #if DEBUG
                    logHUDRoutingReceive(command: .modelSelection, note: note, disposition: .mismatch)
                #endif
                return
            }
            guard !agentNavigationHUD.isRouting else {
                #if DEBUG
                    logHUDRoutingReceive(command: .modelSelection, note: note, disposition: .routing)
                #endif
                return
            }
            guard !isBlockingOverlayVisible else {
                #if DEBUG
                    logHUDRoutingReceive(command: .modelSelection, note: note, disposition: .blocked)
                #endif
                animateHUD {
                    agentNavigationHUD.dismiss()
                    agentModelSelectionHUD.dismiss(reason: .blockingOverlay)
                }
                return
            }
            let rawMode = note.userInfo?[AgentModelSelectionHUDNotificationUserInfoKey.mode] as? String
            let mode = rawMode.flatMap(AgentModelSelectionHUDMode.init(rawValue:)) ?? .switchModel
            guard !isDuplicateAgentModelSelectionHUDCommand(mode) else {
                #if DEBUG
                    logHUDRoutingReceive(command: .modelSelection, note: note, disposition: .duplicate)
                #endif
                return
            }
            guard viewModel.rootRoute != .workspaceEntry else {
                #if DEBUG
                    logHUDRoutingReceive(command: .modelSelection, note: note, disposition: .workspaceEntry)
                #endif
                animateHUD { agentModelSelectionHUD.dismiss(reason: .workspaceEntry) }
                return
            }

            let sourceTabID = viewModel.state.promptManager.activeComposeTabID
            animateHUD {
                agentNavigationHUD.dismiss()
                agentModelSelectionHUD.present(mode: mode) {
                    guard let sourceTabID else {
                        return .unavailable(
                            title: mode.title,
                            message: "No active Agent session is available."
                        )
                    }
                    return viewModel.state.agentModeViewModel.makeModelSelectionHUDPresentation(
                        mode: mode,
                        sourceTabID: sourceTabID,
                        windowID: viewModel.state.windowID
                    )
                }
            }
            #if DEBUG
                let disposition: HUDRoutingDisposition = agentModelSelectionHUD.isPresented ? .presented : .toggleDismissed
                logHUDRoutingReceive(command: .modelSelection, note: note, disposition: disposition)
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAgentNavigationHUDResult)) { note in
            guard noteTargetsCurrentWindow(note), agentNavigationHUD.isPresented else { return }
            (note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.handledRequest] as? AgentNavigationHUDHandledRequest)?.handled = true
            guard let index = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.resultIndex] as? Int else { return }
            Task {
                await agentNavigationHUD.selectItem(atDisplayIndex: index, currentWindow: viewModel.state)
            }
        }
        .onChange(of: isBlockingOverlayVisible) { _, isVisible in
            if isVisible {
                animateHUD {
                    agentNavigationHUD.dismiss()
                    if agentModelSelectionHUD.isCommitting {
                        agentModelSelectionHUD.suspendForBlockingOverlay()
                    } else {
                        agentModelSelectionHUD.dismiss(reason: .blockingOverlay)
                    }
                }
            }
        }
        .onChange(of: agentModelSelectionHUD.isCommitting) { _, isCommitting in
            if !isCommitting, isBlockingOverlayVisible {
                animateHUD { agentModelSelectionHUD.dismiss(reason: .blockingOverlay) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeComposeTabChanged)) { note in
            let requestWindowID = note.userInfo?["windowID"] as? Int
            let currentWindowID = viewModel.state.windowID
            guard AgentHUDActiveTabChangeGate.matches(
                requestWindowID: requestWindowID,
                currentWindowID: currentWindowID
            ) else { return }
            // No scheduler hop: a later shortcut must not be dismissed by an older tab event.
            #if DEBUG
                let hudTraceID = agentModelSelectionHUD.debugTraceID
                let modelPresented = agentModelSelectionHUD.isPresented
                let modelCommitting = agentModelSelectionHUD.isCommitting
                let navigationPresented = agentNavigationHUD.isPresented
                let navigationRouting = agentNavigationHUD.isRouting
                Self.hudRoutingLogger.debug(
                    "active-tab-change windowID=\(currentWindowID, privacy: .public) hud=\(hudTraceID, privacy: .public) modelPresented=\(modelPresented, privacy: .public) modelCommitting=\(modelCommitting, privacy: .public) navigationPresented=\(navigationPresented, privacy: .public) navigationRouting=\(navigationRouting, privacy: .public)"
                )
            #endif
            animateHUD {
                _ = AgentHUDActiveTabChangeGate.handle(
                    requestWindowID: requestWindowID,
                    currentWindowID: currentWindowID,
                    navigationHUD: agentNavigationHUD,
                    modelSelectionHUD: agentModelSelectionHUD
                )
            }
        }
    }

    private var hudTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    private var hudAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.10) : .snappy(duration: 0.18, extraBounce: 0)
    }

    private func animateHUD(_ action: () -> Void) {
        withAnimation(hudAnimation) {
            action()
        }
    }

    /// SwiftUI menu commands and the app-focus-gated KeyboardShortcuts handler
    /// can both see the same physical ⌘K event. Coalesce same-mode repeats from
    /// a single keypress so the VM's deliberate toggle semantics don't open and
    /// immediately close the switcher.
    private func isDuplicateAgentNavigationHUDCommand(_ mode: AgentNavigationHUDMode) -> Bool {
        let now = Date()
        defer { lastAgentNavigationHUDCommand = (mode, now) }
        guard let lastAgentNavigationHUDCommand,
              lastAgentNavigationHUDCommand.mode == mode
        else { return false }
        return now.timeIntervalSince(lastAgentNavigationHUDCommand.at) < 0.20
    }

    private func isDuplicateAgentModelSelectionHUDCommand(_ mode: AgentModelSelectionHUDMode) -> Bool {
        let now = Date()
        defer { lastAgentModelSelectionHUDCommand = (mode, now) }
        guard let lastAgentModelSelectionHUDCommand,
              lastAgentModelSelectionHUDCommand.mode == mode
        else { return false }
        return now.timeIntervalSince(lastAgentModelSelectionHUDCommand.at) < 0.20
    }

    private func noteTargetsCurrentWindow(_ note: Notification) -> Bool {
        if let id = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.windowID] as? Int {
            return id == viewModel.state.windowID
        }
        return true
    }

    #if DEBUG
        private func logHUDRoutingReceive(
            command: HUDRoutingCommand,
            note: Notification,
            disposition: HUDRoutingDisposition
        ) {
            let requestWindowID = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.windowID] as? Int
            let mode = switch command {
            case .navigation:
                (
                    (note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.mode] as? String)
                        .flatMap(AgentNavigationHUDMode.init(rawValue:)) ?? .currentWindow
                ).rawValue
            case .modelSelection:
                (
                    (note.userInfo?[AgentModelSelectionHUDNotificationUserInfoKey.mode] as? String)
                        .flatMap(AgentModelSelectionHUDMode.init(rawValue:)) ?? .switchModel
                ).rawValue
            }
            let window = viewModel.state.nsWindow
            let hudTraceID = agentModelSelectionHUD.debugTraceID
            Self.hudRoutingLogger.debug(
                "receive command=\(command.rawValue, privacy: .public) mode=\(mode, privacy: .public) hud=\(hudTraceID, privacy: .public) requestWindowID=\(requestWindowID ?? -1, privacy: .public) windowID=\(viewModel.state.windowID, privacy: .public) windowNumber=\(window?.windowNumber ?? -1, privacy: .public) windowIDMatch=\(noteTargetsCurrentWindow(note), privacy: .public) isKeyWindow=\(window?.isKeyWindow == true, privacy: .public) disposition=\(disposition.rawValue, privacy: .public)"
            )
        }
    #endif

    @ViewBuilder
    private var routedContent: some View {
        if viewModel.rootRoute == .workspaceEntry {
            WorkspaceEntryRootView(
                workspaceManager: viewModel.workspaceManager,
                windowState: viewModel.state,
                tab: $viewModel.workspaceEntryTab,
                onboardingViewModel: viewModel.onboardingViewModel,
                onCreateOnboardingViewModelIfNeeded: { viewModel.ensureOnboardingViewModel() },
                onContinueToMain: {
                    viewModel.continueFromOnboarding()
                }
            )
        } else {
            AgentModeView(
                windowState: viewModel.state,
                agentModeVM: viewModel.state.agentModeViewModel,
                promptManager: viewModel.promptManager
            )
        }
    }
}
