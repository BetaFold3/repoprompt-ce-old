import AppKit
import SwiftUI

/// What an open native recovery popover does with one app event.
///
/// SwiftUI's `.popover` swallows the outside click that dismisses it, so the user has to click
/// twice. The native popover instead closes from a local event monitor and hands the click on.
///
/// The popover's window doesn't become the key window, even with `makeKey()` (P5), so Escape
/// arrives in the anchor's window: the composer's window under the banner, or the Needs Attention
/// sheet. The monitor closes the popover on Escape there and swallows it, so the composer and the
/// sheet don't also act on that press.
enum AgentRecoveryNativePopoverEventDecision: Equatable {
    /// Keep the popover open and deliver the event normally.
    case ignore
    /// Close the popover, then deliver the event to whatever was clicked.
    case closeAndDeliver
    /// Close the popover and swallow the event (a click on the anchor toggles it closed; Escape in
    /// the popover's or the anchor's window).
    case closeAndConsume

    static func decide(
        isMouseDown: Bool,
        isEscapeKey: Bool,
        isInPopoverWindow: Bool,
        isInAnchorWindow: Bool,
        isOnAnchor: Bool
    ) -> Self {
        if isMouseDown {
            if isInPopoverWindow { return .ignore }
            // The anchor's own button would reopen the popover; a click there just closes it,
            // matching the toggle of the previous SwiftUI popover.
            return isOnAnchor ? .closeAndConsume : .closeAndDeliver
        }
        // Not any window: Escape in another window (a dialog above the sheet, a window reached
        // with Cmd-`) still goes to that window.
        if isEscapeKey, isInPopoverWindow || isInAnchorWindow { return .closeAndConsume }
        return .ignore
    }
}

/// The container of recovery rows (banner or Needs Attention sheet) that row popovers open outside
/// of, so a row's View popover never covers another row's buttons. Rows put their buttons at the
/// trailing edge and their widths vary (a run card's can be most of the row), so any placement over
/// the rows' width can land on some row's buttons.
@MainActor
final class AgentRecoveryNativePopoverRegion {
    fileprivate weak var view: NSView?
    fileprivate var edge: NSRectEdge = .maxY

    /// Where a row's popover is shown.
    enum Placement: Equatable {
        /// Against the whole region, on this edge. `preferredEdge` is only a preference to AppKit,
        /// but every edge of the region's own rect is outside the region, so no row is covered.
        case region(NSRectEdge)
        /// Against the View button, as before regions existed: no side of the region has room on
        /// the screen. The popover may then cover other rows.
        case anchor
    }

    /// Room the popover needs beyond its content size (arrow and border).
    nonisolated static let popoverChrome: CGFloat = 24

    /// The first edge of the region with room on the screen's visible frame for the popover beyond
    /// it: the preferred edge, its opposite, then the two edges at right angles to it (a sheet
    /// hangs from the title bar, so below it usually has room; a banner may have room beside it).
    /// The anchor only when no side has room. All rects are in screen coordinates.
    nonisolated static func placement(
        region: NSRect,
        popover: NSSize,
        visibleFrame: NSRect,
        preferredEdge: NSRectEdge
    ) -> Placement {
        for edge in [preferredEdge, opposite(of: preferredEdge)] + rightAngles(to: preferredEdge) {
            let isVertical = edge == .minY || edge == .maxY
            let needed = (isVertical ? popover.height : popover.width) + popoverChrome
            if room(beyond: edge, of: region, in: visibleFrame) >= needed {
                return .region(edge)
            }
        }
        return .anchor
    }

    private nonisolated static func opposite(of edge: NSRectEdge) -> NSRectEdge {
        if edge == .minX { return .maxX }
        if edge == .maxX { return .minX }
        if edge == .minY { return .maxY }
        return .minY
    }

    /// Below then above a horizontal edge; trailing then leading beside a vertical one.
    private nonisolated static func rightAngles(to edge: NSRectEdge) -> [NSRectEdge] {
        edge == .minY || edge == .maxY ? [.maxX, .minX] : [.minY, .maxY]
    }

    private nonisolated static func room(beyond edge: NSRectEdge, of region: NSRect, in visibleFrame: NSRect) -> CGFloat {
        if edge == .minX { return region.minX - visibleFrame.minX }
        if edge == .maxX { return visibleFrame.maxX - region.maxX }
        if edge == .minY { return region.minY - visibleFrame.minY }
        return visibleFrame.maxY - region.maxY
    }
}

extension EnvironmentValues {
    @Entry var agentRecoveryNativePopoverRegion: AgentRecoveryNativePopoverRegion? = nil
}

extension View {
    /// Marks this view as the region that `agentRecoveryNativePopover`s inside it open outside of,
    /// on `edge` (the banner: above it, over the transcript; the sheet: beside it, over the inert
    /// window behind).
    func agentRecoveryNativePopoverRegion(edge: Edge) -> some View {
        modifier(AgentRecoveryNativePopoverRegionModifier(edge: edge))
    }

    /// An AppKit `NSPopover` anchored to this view, hosting `content` in SwiftUI. Unlike `.popover`,
    /// the outside click that dismisses it still reaches what was clicked. Inside an
    /// `agentRecoveryNativePopoverRegion` it opens outside that region; otherwise on `arrowEdge`.
    func agentRecoveryNativePopover(
        isPresented: Binding<Bool>,
        arrowEdge: Edge,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        background(
            AgentRecoveryNativePopoverAnchor(isPresented: isPresented, arrowEdge: arrowEdge, content: content)
        )
    }
}

private struct AgentRecoveryNativePopoverRegionModifier: ViewModifier {
    let edge: Edge
    @State private var region = AgentRecoveryNativePopoverRegion()

    func body(content: Content) -> some View {
        content
            .background(AgentRecoveryNativePopoverRegionMarker(region: region, edge: edge))
            .environment(\.agentRecoveryNativePopoverRegion, region)
    }
}

/// An unflipped `NSView` filling the region, so popovers can be positioned relative to it.
private struct AgentRecoveryNativePopoverRegionMarker: NSViewRepresentable {
    let region: AgentRecoveryNativePopoverRegion
    let edge: Edge

    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        region.view = nsView
        region.edge = rectEdge(for: edge)
    }
}

/// The `NSView`s here are unflipped, so the top edge is `maxY`.
private func rectEdge(for edge: Edge) -> NSRectEdge {
    switch edge {
    case .top: .maxY
    case .bottom: .minY
    case .leading: .minX
    case .trailing: .maxX
    }
}

private struct AgentRecoveryNativePopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let content: () -> PopoverContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            anchor: nsView,
            region: context.environment.agentRecoveryNativePopoverRegion,
            isPresented: $isPresented,
            preferredEdge: rectEdge(for: arrowEdge),
            content: content
        )
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        // Never write the binding mid-update; reset it afterwards so a View button that comes back
        // doesn't start with a stale `true` (which would make it look dead).
        coordinator.close(reportingClosed: .deferred)
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        /// When `close` writes `false` to the binding.
        enum BindingReport {
            /// Synchronously (event monitor, app deactivation, SwiftUI-requested close).
            case now
            /// On the next main-queue turn, if still `true` (SwiftUI dismantle, AppKit close).
            case deferred
        }

        private var popover: NSPopover?
        private var host: NSHostingController<PopoverContent>?
        private var eventMonitor: Any?
        private var resignActiveObserver: NSObjectProtocol?
        private weak var anchor: NSView?
        private weak var region: AgentRecoveryNativePopoverRegion?
        private var isPresented: Binding<Bool>?

        func update(
            anchor: NSView,
            region: AgentRecoveryNativePopoverRegion?,
            isPresented: Binding<Bool>,
            preferredEdge: NSRectEdge,
            content: () -> PopoverContent
        ) {
            self.anchor = anchor
            self.region = region
            self.isPresented = isPresented
            if isPresented.wrappedValue {
                if let host {
                    host.rootView = content()
                } else {
                    show(anchor: anchor, preferredEdge: preferredEdge, content: content())
                }
            } else if popover != nil {
                close()
            }
        }

        private func show(anchor: NSView, preferredEdge: NSRectEdge, content: PopoverContent) {
            guard anchor.window != nil else { return }
            // A fresh hosting controller per presentation, so the content's `.task` runs on each
            // open and is cancelled on close, as with SwiftUI's popover.
            let host = NSHostingController(rootView: content)
            host.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            // AppKit's transient handling is replaced by the event monitor below, which closes the
            // popover without consuming the click.
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.contentViewController = host
            popover.delegate = self
            self.host = host
            self.popover = popover
            installMonitors()
            // Outside the rows' region when there is one and the screen has room beside it: shown
            // against the whole region, so whichever edge AppKit settles on stays outside it (the
            // arrow then points at the region's edge, and the popover stays put if the rows scroll).
            // The anchor itself still toggles it.
            if let region, let regionView = region.view, let window = regionView.window, window === anchor.window,
               let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame,
               case let .region(edge) = AgentRecoveryNativePopoverRegion.placement(
                   region: window.convertToScreen(regionView.convert(regionView.bounds, to: nil)),
                   popover: host.view.fittingSize,
                   visibleFrame: visibleFrame,
                   preferredEdge: region.edge
               )
            {
                popover.show(relativeTo: regionView.bounds, of: regionView, preferredEdge: edge)
            } else {
                // No region, or no room on either side of it: next to the View button, as before.
                // The popover may then cover other rows.
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
            }
        }

        /// Closes the popover (if shown) and reports it closed through the binding. Idempotent.
        func close(reportingClosed report: BindingReport = .now) {
            removeMonitors()
            let popover = popover
            self.popover = nil
            host = nil
            popover?.delegate = nil
            popover?.close()
            guard let isPresented else { return }
            switch report {
            case .now:
                if isPresented.wrappedValue { isPresented.wrappedValue = false }
            case .deferred:
                DispatchQueue.main.async {
                    if isPresented.wrappedValue { isPresented.wrappedValue = false }
                }
            }
        }

        func popoverDidClose(_: Notification) {
            // AppKit closed it (e.g. its window went away); keep the binding in sync without
            // writing it from inside whatever AppKit or SwiftUI work triggered the close.
            close(reportingClosed: .deferred)
        }

        private func installMonitors() {
            removeMonitors()
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                let consume = MainActor.assumeIsolated { self?.shouldConsume(event) ?? false }
                return consume ? nil : event
            }
            // Closes on app switch. This doesn't move key, so AppKit restores the window that was
            // key when the app is reactivated.
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }

        private func removeMonitors() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
            resignActiveObserver = nil
        }

        /// Applies the decision for `event`; `true` means the event must not be dispatched.
        private func shouldConsume(_ event: NSEvent) -> Bool {
            guard let popover else { return false }
            let popoverWindow = popover.contentViewController?.view.window
            let isMouseDown = event.type != .keyDown
            // Esc cancels an input-method composition in progress first; the next Esc closes the popover.
            let isComposing = (event.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
            let decision = AgentRecoveryNativePopoverEventDecision.decide(
                isMouseDown: isMouseDown,
                isEscapeKey: event.type == .keyDown && event.keyCode == 53 && !isComposing,
                isInPopoverWindow: event.window != nil && event.window === popoverWindow,
                isInAnchorWindow: event.window != nil && event.window === anchor?.window,
                isOnAnchor: isMouseDown && isOnAnchor(event)
            )
            switch decision {
            case .ignore:
                return false
            case .closeAndConsume:
                close()
                return true
            case .closeAndDeliver:
                close()
                // If the click is on the anchor's window and that is not key, make it key before
                // AppKit dispatches the event, so it is delivered as a normal click rather than
                // spent activating the window. Other windows keep normal macOS first-click activation,
                // so sheets, panels and window order are left to AppKit.
                if let window = event.window, window === anchor?.window, !window.isKeyWindow {
                    window.makeKey()
                }
                return false
            }
        }

        private func isOnAnchor(_ event: NSEvent) -> Bool {
            guard let anchor, let window = anchor.window, event.window === window else { return false }
            let point = anchor.convert(event.locationInWindow, from: nil)
            return anchor.bounds.contains(point)
        }
    }
}
