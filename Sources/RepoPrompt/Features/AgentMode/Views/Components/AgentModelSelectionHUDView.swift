import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI
#if DEBUG
    import OSLog
#endif

struct AgentModelSelectionHUDView: View {
    @ObservedObject var viewModel: AgentModelSelectionHUDViewModel

    @FocusState private var queryFocused: Bool
    @StateObject private var hostingWindowReference = AgentModelSelectionHUDHostingWindowReference()
    @State private var suppressHoverSelectionUntil = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if viewModel.canDismiss {
                            viewModel.dismiss()
                        }
                    }
                    .accessibilityHidden(true)

                panel(maxSize: geometry.size)
                    .padding(.top, topInset(for: geometry.size))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(viewModel.title)
    }

    private func panel(maxSize: CGSize) -> some View {
        let width = min(CGFloat(540), max(360, maxSize.width - 48))
        return VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            if let noticeText = viewModel.noticeText {
                noticeSlot(noticeText)
            }
            if let errorMessage = viewModel.errorMessage {
                errorSlot(errorMessage)
            }
            rows(height: rowListHeight(maxSize: maxSize))
            footer
        }
        .padding(13)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(panelBackgroundStyle)
                .shadow(color: Color.black.opacity(0.24), radius: 24, y: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.62), lineWidth: 1)
        )
        .background(
            WindowAccessor { window in
                hostingWindowReference.window = window
            }
        )
        .onAppear {
            traceFocus("appear")
            assertQueryFocusEdge()
        }
        .onDisappear { traceFocus("disappear") }
        .onChange(of: queryFocused) { _, _ in
            traceFocus("focus-binding")
        }
        .onChange(of: viewModel.focusAssertionEpoch) { _, _ in
            assertQueryFocusEdge()
        }
        .onChange(of: viewModel.phase) { _, phase in
            if phase == .ready {
                assertQueryFocusEdge()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === hostingWindowReference.window,
                  viewModel.isPresented,
                  !queryFocused
            else {
                return
            }
            assertQueryFocusEdge()
        }
        .agentModelSelectionHUDKeys(
            viewModel: viewModel,
            onKeyboardNavigation: suppressHoverSelectionAfterKeyboardNavigation
        )
        .onExitCommand {
            _ = viewModel.clearQueryOrDismiss()
        }
        .accessibilityElement(children: .contain)
    }

    private var panelBackgroundStyle: AnyShapeStyle {
        if reduceTransparency {
            AnyShapeStyle(Color(NSColor.windowBackgroundColor))
        } else {
            AnyShapeStyle(.regularMaterial)
        }
    }

    private func topInset(for size: CGSize) -> CGFloat {
        min(max(size.height * 0.10, 48), 104)
    }

    private var rowHeight: CGFloat {
        fontPreset.scaledClamped(50, min: 46, max: 62)
    }

    private func rowListHeight(maxSize: CGSize) -> CGFloat {
        guard viewModel.unavailableMessage == nil,
              !viewModel.filteredLeaves.isEmpty
        else {
            return 104
        }
        let spacing: CGFloat = 4
        let visibleRows = CGFloat(min(viewModel.filteredLeaves.count, 6))
        let fullRowsHeight = visibleRows * rowHeight
            + max(0, visibleRows - 1) * spacing
            + 4
        let peekHeight = viewModel.filteredLeaves.count > 6 ? rowHeight * 0.55 : 0
        let maximum = min(fullRowsHeight + peekHeight, max(160, maxSize.height * 0.56))
        let count = CGFloat(viewModel.filteredLeaves.count)
        let desired = count * rowHeight + max(0, count - 1) * spacing + 4
        return min(maximum, max(96, desired))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 14, weight: .semibold))
                if let subtitle = viewModel.subtitle {
                    Text(subtitle)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if viewModel.isCommitting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Committing selection")
            }
            Button {
                viewModel.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canDismiss)
            .accessibilityLabel("Close \(viewModel.title)")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(viewModel.mode.searchPlaceholder, text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .disabled(viewModel.isCommitting)
                .onSubmit {
                    Task { await viewModel.commitSelected() }
                }
                .onExitCommand {
                    _ = viewModel.clearQueryOrDismiss()
                }
            if viewModel.isCommitting {
                Text(viewModel.mode == .handoffLastReply ? "Routing…" : "Saving…")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(NSColor.controlBackgroundColor)
                .opacity(reduceTransparency ? 1 : 0.82),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 0.75)
        )
    }

    private func noticeSlot(_ text: String) -> some View {
        Label(text, systemImage: "arrow.turn.up.right")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(
                Color.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }

    private func errorSlot(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
            .foregroundStyle(.red)
            .lineLimit(2)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                Color.red.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.22), lineWidth: 0.75)
            )
    }

    private func rows(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if let unavailableMessage = viewModel.unavailableMessage {
                        unavailableState(unavailableMessage)
                    } else if viewModel.filteredLeaves.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.filteredLeaves) { leaf in
                            AgentModelSelectionHUDRow(
                                leaf: leaf,
                                isSelected: leaf.id == viewModel.selectedLeafID,
                                isEnabled: viewModel.phase == .ready,
                                fontPreset: fontPreset,
                                onHover: {
                                    guard Date() >= suppressHoverSelectionUntil else { return }
                                    viewModel.moveSelection(to: leaf.id)
                                }
                            ) {
                                Task { await viewModel.commit(leaf) }
                            }
                            .frame(height: rowHeight)
                            .id(leaf.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: height)
            .onChange(of: viewModel.selectedLeafID) { _, newValue in
                guard let newValue else { return }
                if reduceMotion {
                    proxy.scrollTo(newValue)
                } else {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(newValue)
                    }
                }
            }
        }
    }

    private func unavailableState(_ message: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            Text(message)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(viewModel.queryIsEmpty ? "No models available" : "No matches for “\(viewModel.query)”")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
            Text(
                viewModel.queryIsEmpty
                    ? "No selectable catalog entries were captured for this session."
                    : "Try a provider, model, effort, or identifier."
            )
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerHint("↑↓", "Navigate")
            footerHint("↩", viewModel.mode.commitLabel)
            Spacer()
            if viewModel.isShowingLimitedResults {
                Text("Showing \(viewModel.filteredLeaves.count) of \(viewModel.totalMatchedLeafCount) · type to search all")
                    .lineLimit(1)
            }
            footerHint("esc", viewModel.queryIsEmpty ? "Close" : "Clear")
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
        .foregroundStyle(.secondary)
    }

    private func suppressHoverSelectionAfterKeyboardNavigation() {
        suppressHoverSelectionUntil = Date().addingTimeInterval(0.28)
    }

    private func traceFocus(_ event: String) {
        #if DEBUG
            let hudTraceID = viewModel.debugTraceID
            let modeName = viewModel.mode.rawValue
            let epoch = viewModel.focusAssertionEpoch
            let presented = viewModel.isPresented
            let focusedMirror = queryFocused
            let window = hostingWindowReference.window
            let windowNumber = window?.windowNumber ?? -1
            // Responder class only (never contents): tells the composer text view from the field editor.
            let firstResponderClass = window?.firstResponder.map { String(String(describing: type(of: $0)).prefix(80)) } ?? "nil"
            Logger(subsystem: "com.repoprompt.app", category: "hud-routing").debug(
                "query event=\(event, privacy: .public) hud=\(hudTraceID, privacy: .public) mode=\(modeName, privacy: .public) epoch=\(epoch, privacy: .public) presented=\(presented, privacy: .public) focusedMirror=\(focusedMirror, privacy: .public) window=\(windowNumber, privacy: .public) firstResponder=\(firstResponderClass, privacy: .public)"
            )
        #endif
    }

    private func assertQueryFocusEdge() {
        traceFocus("assert-edge")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            queryFocused = false
        }

        let epoch = viewModel.focusAssertionEpoch
        DispatchQueue.main.async {
            guard viewModel.isPresented,
                  viewModel.focusAssertionEpoch == epoch,
                  viewModel.phase != .committing
            else {
                traceFocus("assert-edge-bailed")
                return
            }
            var focusTransaction = Transaction()
            focusTransaction.disablesAnimations = true
            withTransaction(focusTransaction) {
                queryFocused = true
            }
            traceFocus("assert-edge-ran")
        }
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Color(NSColor.controlBackgroundColor).opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.55), lineWidth: 0.75)
                )
            Text(label)
        }
    }
}

@MainActor
private final class AgentModelSelectionHUDHostingWindowReference: ObservableObject {
    weak var window: NSWindow?
}

private extension View {
    func agentModelSelectionHUDKeys(
        viewModel: AgentModelSelectionHUDViewModel,
        onKeyboardNavigation: @escaping () -> Void
    ) -> some View {
        onKeyPress(phases: [.down, .repeat]) { press in
            if press.modifiers == .control {
                if press.key == "n" {
                    onKeyboardNavigation()
                    viewModel.moveSelection(by: 1)
                    return .handled
                }
                if press.key == "p" {
                    onKeyboardNavigation()
                    viewModel.moveSelection(by: -1)
                    return .handled
                }
            }
            switch press.key {
            case .escape:
                _ = viewModel.clearQueryOrDismiss()
                return .handled
            case .upArrow:
                onKeyboardNavigation()
                viewModel.moveSelection(by: -1)
                return .handled
            case .downArrow:
                onKeyboardNavigation()
                viewModel.moveSelection(by: 1)
                return .handled
            default:
                // Digits intentionally remain ordinary TextField query input.
                return .ignored
            }
        }
    }
}

private struct AgentModelSelectionHUDRow: View {
    let leaf: AgentModelSelectionLeaf
    let isSelected: Bool
    let isEnabled: Bool
    let fontPreset: FontScalePreset
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(leaf.title)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                            .lineLimit(1)
                        if leaf.showsWarning {
                            Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(
                                    isSelected
                                        ? Color.white
                                        : AgentModelSelectionWarningVisuals.warningColor
                                )
                                .accessibilityLabel("Fast model warning")
                        }
                        if leaf.isCurrentSelection {
                            Text("Current")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    isSelected
                                        ? Color.white.opacity(0.18)
                                        : Color.accentColor.opacity(0.13),
                                    in: Capsule()
                                )
                        }
                    }
                    HStack(spacing: 5) {
                        Text(leaf.providerSubtitle)
                            .lineLimit(1)
                        if let detail = leaf.detail, !detail.isEmpty {
                            Text("·")
                            Text(detail)
                                .lineLimit(1)
                        }
                    }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Text("↩")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 11)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovered in
            if hovered, isEnabled {
                onHover()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityLabel: String {
        var parts = [leaf.title, leaf.providerSubtitle]
        if leaf.isCurrentSelection {
            parts.append("Current selection")
        }
        if leaf.showsWarning {
            parts.append("Fast model warning")
        }
        if let detail = leaf.detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }
}
