import Cocoa
import Combine
import Darwin
import RepoPromptAgentCore
import RepoPromptPlatform
import Sparkle
import SwiftUI

#if DEBUG
    private var appDelegateDebugLoggingEnabled = false
    private func appDelegateDebugLog(_ message: @autoclosure () -> String) {
        guard appDelegateDebugLoggingEnabled else { return }
        print("[AppDelegate] \(message())")
    }
#else
    private func appDelegateDebugLog(_ message: @autoclosure () -> String) {}
#endif

@MainActor
class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate {
    private var quitRequestPhase: AppQuitRequestPhase = .idle
    /// The shutdown request whose reply this delegate awaits (log correlation only).
    private var shutdownRequestID: UUID?
    private var presentedQuitAlert: NSAlert?
    private weak var presentedQuitAlertParent: NSWindow?
    private let dockMenuController = DockMenuController()

    // New global routing/settings services (kept alive by the AppDelegate)
    private var windowRoutingService: WindowRoutingService?
    private var appSettingsMCPService: AppSettingsMCPService?
    private var remotePairingMCPService: MCPRemotePairingToolService?

    // MARK: - Global references

    let sparkleManager: SparkleUpdaterManager
    private let sparkleFeedDelegate: SparkleUpdateFeedDelegate

    /// NEW: weak reference injected by `RepoPromptApp`
    weak var windowStatesManager: WindowStatesManager?

    /// Additional global toggles
    let debugMode: Bool = false

    static var appCounter = 0

    // MARK: - Init

    override init() {
        appDelegateDebugLog("Appcounter \(AppDelegate.appCounter)")
        AppDelegate.appCounter += 1

        // Clean any corrupt Sparkle preferences before initializing
        SparkleUpdaterManager.cleanCorruptPreferences()

        // Initialize Sparkle updater
        let feedDelegate = SparkleUpdateFeedDelegate()
        sparkleFeedDelegate = feedDelegate
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: feedDelegate,
            userDriverDelegate: nil
        )
        sparkleManager = SparkleUpdaterManager(updaterController: updaterController)
        SparkleUpdaterManager.shared = sparkleManager

        // super.init
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchConfiguration = AppLaunchConfiguration.current
        ProcessTermination.resetAppTerminationFastPath()

        if launchConfiguration.isUITestSession {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Prevent crashes from broken pipes when a peer closes unexpectedly
        signal(SIGPIPE, SIG_IGN)

        AppearanceController.shared.applyFromGlobalSettings()

        // ───────────────────────────────────────────────────
        // Register global MCP app-wide helpers
        let appSettingsMCPService = AppSettingsMCPService()
        ServiceRegistry.register(appSettingsMCPService)
        self.appSettingsMCPService = appSettingsMCPService

        let remotePairingMCPService = MCPRemotePairingToolService()
        ServiceRegistry.register(remotePairingMCPService)
        self.remotePairingMCPService = remotePairingMCPService

        // Register global MCP window-routing helpers
        windowRoutingService = WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
        if !launchConfiguration.suppressesNonessentialLaunchSideEffects {
            // Request notification authorization
            Task {
                await NotificationService.shared.requestAuthorization()
            }

            // Validate Codex prompts on app launch (if previously installed)
            Task.detached(priority: .utility) {
                await MCPPromptValidationService.shared.validateCodexPromptsOnLaunch()
            }
        }

        // Telegram attention notifications run on this (executing) Mac only; the launch guard
        // denies UI-test, stress, and XCTest launches before any secure-storage or HTTP dependency.
        TelegramAttentionNotificationService.shared.start(launch: .current(launchConfiguration))

        #if DEBUG
            sparkleManager.startUpdater()
            if !launchConfiguration.suppressesNonessentialLaunchSideEffects {
                Task {
                    // Ensure the user-space CLI symlink is available for external tools
                    CLISymlinkManagerUserSpace.ensureLocalSymlink()
                }
            }
            // Starts after this launch callback returns; idempotent.
            DispatchQueue.main.async {
                MainThreadStallWatchdog.startIfNeeded()
            }
            return
        #else
            sparkleManager.startUpdater()

            ApplicationSecurity.startMonitoring()
            ApplicationSecurity.enableAntiDebugging()

            Task {
                CLISymlinkManagerUserSpace.ensureLocalSymlink()
            }
        #endif
    }

    // MARK: - Application Lifecycle

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenuController.makeMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app running if we intentionally backgrounded the last window.
        !MCPBackgroundModeCoordinator.shared.isBackgrounded
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, MCPBackgroundModeCoordinator.shared.isBackgrounded {
            MCPBackgroundModeCoordinator.shared.restore()
            return true
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Bound to THIS termination request (review A P1-09): taken before any path that may not
        // start R4 (a cancelled confirmation, a request joining one in progress), so a later
        // ordinary Quit never restarts.
        let reason = WindowStatesManager.shared.shutdownReasonLatch.take()
        let activeItems = WindowStatesManager.shared.allWindows.flatMap { windowState in
            WindowCloseCoordinator.activeItems(for: windowState.makeCloseImpactSnapshot())
        }
        let decision = AppQuitPolicy.decide(
            warningEnabled: GlobalSettingsStore.shared.warnBeforeQuit(),
            suppressesConfirmation: AppLaunchConfiguration.current.suppressesNonessentialLaunchSideEffects,
            phase: quitRequestPhase,
            activeItems: activeItems
        )

        AgentLifecycleShutdownDiagnostics.terminateRequested(
            decision: Self.diagnosticToken(decision),
            phase: Self.diagnosticToken(quitRequestPhase),
            reason: reason,
            current: WindowStatesManager.shared.lifecycleShutdown.activeApplicationRequestID
        )
        switch decision {
        case let .showConfirmation(confirmation):
            presentQuitConfirmation(confirmation, reason: reason, sender: sender)
        case .beginTermination:
            beginTermination(sender: sender, reason: reason)
        case .awaitCurrentRequest:
            break
        }
        return .terminateLater
    }

    private static func diagnosticToken(_ decision: AppQuitRequestDecision) -> String {
        switch decision {
        case .showConfirmation: "show_confirmation"
        case .beginTermination: "begin_termination"
        case .awaitCurrentRequest: "await_current_request"
        }
    }

    private static func diagnosticToken(_ phase: AppQuitRequestPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .awaitingConfirmation: "awaiting_confirmation"
        case .terminating: "terminating"
        }
    }

    private func presentQuitConfirmation(
        _ confirmation: AppQuitConfirmation,
        reason: AgentRecoveryShutdownReason,
        sender: NSApplication
    ) {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmation.cancelButtonTitle)
        alert.addButton(withTitle: confirmation.confirmButtonTitle)
        presentedQuitAlert = alert
        quitRequestPhase = .awaitingConfirmation

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Task { @MainActor in
                self?.handleQuitConfirmationResponse(response, alert: alert, reason: reason, sender: sender)
            }
        }
        if let parentWindow = sender.keyWindow ?? sender.mainWindow {
            presentedQuitAlertParent = parentWindow
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(quitConfirmationParentWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: parentWindow
            )
            alert.beginSheetModal(for: parentWindow, completionHandler: completion)
        } else {
            sender.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                completion(alert.runModal())
            }
        }
    }

    @objc private func quitConfirmationParentWillClose(_ notification: Notification) {
        guard let parentWindow = presentedQuitAlertParent,
              notification.object as? NSWindow === parentWindow,
              let alert = presentedQuitAlert,
              alert.window.sheetParent === parentWindow
        else {
            return
        }
        parentWindow.endSheet(alert.window, returnCode: .cancel)
    }

    private func handleQuitConfirmationResponse(
        _ response: NSApplication.ModalResponse,
        alert: NSAlert,
        reason: AgentRecoveryShutdownReason,
        sender: NSApplication
    ) {
        guard quitRequestPhase == .awaitingConfirmation,
              presentedQuitAlert === alert
        else {
            AgentLifecycleShutdownDiagnostics.quitConfirmationAnswered("stale")
            return
        }
        AgentLifecycleShutdownDiagnostics.quitConfirmationAnswered(
            response == .alertSecondButtonReturn ? "quit" : "cancel"
        )
        if let parentWindow = presentedQuitAlertParent {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: parentWindow
            )
        }
        presentedQuitAlertParent = nil
        presentedQuitAlert = nil

        if response == .alertSecondButtonReturn {
            beginTermination(sender: sender, reason: reason)
        } else {
            quitRequestPhase = .idle
            sender.reply(toApplicationShouldTerminate: false)
        }
    }

    private func beginTermination(sender: NSApplication, reason: AgentRecoveryShutdownReason) {
        guard quitRequestPhase != .terminating else {
            AgentLifecycleShutdownDiagnostics.terminationBegan(
                started: false,
                current: WindowStatesManager.shared.lifecycleShutdown.activeApplicationRequestID,
                cause: "already_terminating"
            )
            return
        }
        quitRequestPhase = .terminating

        // Two-stage quit (spec R4): the coordinator freezes admission synchronously, preserves
        // layout and agent state (Stage A, cancellable), and only then sets the termination flags
        // and tears down (Stage B). It owns the single reply: `false` after a cancelled Stage A
        // (the app stays usable), `true` once Stage B finished or the user chose Quit Anyway.
        let lifecycleShutdown = WindowStatesManager.shared.lifecycleShutdown
        // A refused request replies synchronously, before any request of its own exists.
        shutdownRequestID = nil
        let started = lifecycleShutdown.requestApplicationQuit(reason: reason) { [weak self] shouldTerminate in
            AgentLifecycleShutdownDiagnostics.terminateReply(shouldTerminate, current: self?.shutdownRequestID)
            if !shouldTerminate {
                self?.quitRequestPhase = .idle
                self?.shutdownRequestID = nil
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        // Not started: refused (it already replied `false`, resetting the phase, or an earlier quit
        // is sealed past its point of no return), or joined the request in progress.
        let refused = !started && (quitRequestPhase == .idle || lifecycleShutdown.isApplicationAdmissionSealed)
        let cause = started ? "started" : refused ? "refused" : "joined_in_progress"
        shutdownRequestID = refused ? nil : lifecycleShutdown.activeApplicationRequestID
        AgentLifecycleShutdownDiagnostics.terminationBegan(started: started, current: shutdownRequestID, cause: cause)
        if !started {
            appDelegateDebugLog("quit request did not start a shutdown (\(cause))")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("Application is terminating...")

        // Defensive fallback: ensure termination flag is set and session is persisted.
        // These are fast, synchronous, and idempotent.
        MCPBackgroundModeCoordinator.shared.resetForTermination()
        WindowStatesManager.shared.signalTermination()
        ProcessTermination.beginAppTerminationFastPath()
        if !AppLaunchConfiguration.current.suppressesWindowPersistence {
            WindowStatesManager.shared.persistWindowSession(reason: "appWillTerminate")
        }
    }

    // MARK: - App Teardown

    func tearDown() async {
        // Put any global-level teardown logic here
        // e.g. flush analytics, etc.
        print("Application teardown completed")
    }
}
