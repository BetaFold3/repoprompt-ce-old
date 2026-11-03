import AppKit

@MainActor
final class InterceptingWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var windowState: WindowState?
    weak var forwardedDelegate: NSWindowDelegate?

    init(windowState: WindowState, forwardedDelegate: NSWindowDelegate?) {
        self.windowState = windowState
        self.forwardedDelegate = forwardedDelegate
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let windowState else {
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        let manager = windowState.windowStatesManager ?? WindowStatesManager.shared
        // One-shot: a two-stage close finished Stage B (its forwarded veto was checked before the
        // point of no return and `beginClose` already ran), so this close is not re-routed.
        if windowState.closeCoordinator.consumeFinalizedCloseAuthorization() {
            windowState.beginClose()
            return true
        }
        if !manager.isTerminating {
            let lifecycle = manager.lifecycleShutdown
            // An app quit still preparing owns every window; a close of this window already in
            // progress keeps its single request.
            if lifecycle.isApplicationRequestActive || lifecycle.isWindowRequestActive(windowState.windowID) {
                return false
            }
        }

        switch windowState.closeCoordinator.handleCloseAttempt(for: sender) {
        case .allow:
            guard !manager.isTerminating else {
                // App quit past its point of no return: it already preserved and tore down.
                // Set isClosing early to suppress @Published mutations before AppKit
                // sends focus/key events during close (fixes EXC_BAD_ACCESS in ObservationTracking).
                let shouldClose = forwardedDelegate?.windowShouldClose?(sender) ?? true
                if shouldClose {
                    windowState.beginClose()
                }
                return shouldClose
            }
            // Two-stage close: preserved and torn down first, then closed by a one-shot
            // authorization. The forwarded delegate decides before anything irreversible.
            return manager.handleLifecycleWindowCloseAttempt(
                windowState,
                forwardedVeto: { [weak self, weak sender] in
                    guard let sender else { return false }
                    return self?.forwardedDelegate?.windowShouldClose?(sender) ?? true
                }
            )
        case .background, .confirm, .denyDuplicatePrompt:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        windowState?.closeCoordinator.windowWillClose()
        // Backstop: ensure beginClose is called even if windowShouldClose was bypassed.
        windowState?.beginClose()

        if let windowID = windowState?.windowID {
            MCPBackgroundModeCoordinator.shared.clearIfBackgroundedWindow(windowID: windowID)
        }
        forwardedDelegate?.windowWillClose?(notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let windowID = windowState?.windowID {
            MCPBackgroundModeCoordinator.shared.clearIfBackgroundedWindow(windowID: windowID)
        }
        forwardedDelegate?.windowDidBecomeKey?(notification)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return forwardedDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwardedDelegate
    }
}
