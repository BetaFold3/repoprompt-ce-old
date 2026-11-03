import Foundation
import RepoPromptAgentCore
#if DEBUG
    import OSLog
#endif

enum AgentModelSelectionHUDMode: String, CaseIterable, Identifiable {
    case switchModel
    case handoffLastReply

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .switchModel:
            "Quick Model Picker"
        case .handoffLastReply:
            "Quick Handoff"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .switchModel:
            "Search models"
        case .handoffLastReply:
            "Search destination models"
        }
    }

    var commitLabel: String {
        switch self {
        case .switchModel:
            "Select"
        case .handoffLastReply:
            "Hand off"
        }
    }
}

enum AgentModelSelectionHUDPhase: Equatable {
    case ready
    case unavailable(message: String)
    case committing
}

enum AgentModelSelectionHUDNotificationUserInfoKey {
    static let windowID = "windowID"
    static let mode = "mode"
}

enum AgentModelSelectionHUDDismissalReason: String {
    case user
    case toggle
    case activeTabChanged
    case navigation
    case workspaceEntry
    case blockingOverlay
}

struct AgentModelSelectionHUDPresentation {
    let title: String
    let subtitle: String?
    let index: AgentModelSelectionIndex
    let noticeText: String?
    let unavailableMessage: String?
    let onSuccessfulModelSelection: (@MainActor () -> Void)?
    let commit: @MainActor (AgentModelSelectionLeaf) async throws -> Void

    init(
        title: String,
        subtitle: String? = nil,
        index: AgentModelSelectionIndex,
        noticeText: String? = nil,
        unavailableMessage: String? = nil,
        onSuccessfulModelSelection: (@MainActor () -> Void)? = nil,
        commit: @escaping @MainActor (AgentModelSelectionLeaf) async throws -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.index = index
        self.noticeText = noticeText
        self.unavailableMessage = unavailableMessage
        self.onSuccessfulModelSelection = onSuccessfulModelSelection
        self.commit = commit
    }

    static func unavailable(
        title: String,
        subtitle: String? = nil,
        message: String,
        noticeText: String? = nil
    ) -> AgentModelSelectionHUDPresentation {
        AgentModelSelectionHUDPresentation(
            title: title,
            subtitle: subtitle,
            index: AgentModelSelectionIndex(leaves: []),
            noticeText: noticeText,
            unavailableMessage: message,
            commit: { _ in }
        )
    }
}

@MainActor
final class AgentModelSelectionHUDViewModel: ObservableObject {
    static let displayLimit = 50
    #if DEBUG
        private static let logger = Logger(subsystem: "com.repoprompt.app", category: "hud-routing")
        /// Content-free per-instance ID; the shell's receive logs pair it with the owning window ID.
        let debugTraceID = String(UUID().uuidString.prefix(8))
    #endif

    @Published private(set) var isPresented = false
    @Published private(set) var focusAssertionEpoch: UInt64 = 0
    @Published private(set) var mode: AgentModelSelectionHUDMode = .switchModel
    @Published private(set) var phase: AgentModelSelectionHUDPhase = .ready
    @Published private(set) var title = AgentModelSelectionHUDMode.switchModel.title
    @Published private(set) var subtitle: String?
    @Published private(set) var noticeText: String?
    @Published private(set) var filteredLeaves: [AgentModelSelectionLeaf] = []
    @Published private(set) var selectedLeafID: AgentModelSelectionLeafID?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRouting = false
    @Published private(set) var isShowingLimitedResults = false
    @Published private(set) var totalMatchedLeafCount = 0
    @Published var query = "" {
        didSet { rebuildFilteredLeaves(preserveSelection: true) }
    }

    private var index = AgentModelSelectionIndex(leaves: [])
    private var commitAction: (@MainActor (AgentModelSelectionLeaf) async throws -> Void)?
    private var isSuspendedDuringCommit = false
    private var successfulModelSelectionAction: (@MainActor () -> Void)?

    var queryIsEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var totalLeafCount: Int {
        index.leaves.count
    }

    var canDismiss: Bool {
        phase != .committing
    }

    var isCommitting: Bool {
        phase == .committing
    }

    var unavailableMessage: String? {
        guard case let .unavailable(message) = phase else { return nil }
        return message
    }

    func present(
        mode: AgentModelSelectionHUDMode,
        presentationProvider: () -> AgentModelSelectionHUDPresentation
    ) {
        if isPresented, self.mode == mode {
            dismiss(reason: .toggle)
            return
        }
        guard phase != .committing else {
            trace("present-blocked-committing")
            return
        }

        let wasPresented = isPresented
        let presentation = presentationProvider()
        self.mode = mode
        title = presentation.title
        subtitle = presentation.subtitle
        noticeText = presentation.noticeText
        index = presentation.index
        commitAction = presentation.commit
        successfulModelSelectionAction = mode == .switchModel ? presentation.onSuccessfulModelSelection : nil
        errorMessage = nil
        isRouting = false
        phase = presentation.unavailableMessage.map(AgentModelSelectionHUDPhase.unavailable) ?? .ready
        isPresented = true

        if !wasPresented {
            query = ""
        }
        rebuildFilteredLeaves(preserveSelection: wasPresented)
        focusAssertionEpoch &+= 1
        trace("presented")
    }

    func dismiss(reason: AgentModelSelectionHUDDismissalReason = .user) {
        trace("dismiss-\(reason.rawValue)")
        guard phase != .committing else { return }
        resetPresentedState()
    }

    func activeTabDidChange() {
        guard isPresented || isCommitting else { return }
        successfulModelSelectionAction = nil
        dismiss(reason: .activeTabChanged)
    }

    /// Immediately unmounts a committing HUD when a higher-priority blocking
    /// overlay appears without cancelling or detaching the in-flight action.
    func suspendForBlockingOverlay() {
        guard phase == .committing else {
            dismiss(reason: .blockingOverlay)
            return
        }
        trace("suspend-blocking-overlay")
        successfulModelSelectionAction = nil
        isSuspendedDuringCommit = true
        isPresented = false
    }

    @discardableResult
    func clearQueryOrDismiss() -> Bool {
        guard phase != .committing else { return false }
        if !queryIsEmpty {
            query = ""
            errorMessage = nil
            return false
        }
        dismiss()
        return true
    }

    func moveSelection(by delta: Int) {
        guard phase == .ready, !filteredLeaves.isEmpty else {
            selectedLeafID = nil
            return
        }
        guard let selectedLeafID,
              let current = filteredLeaves.firstIndex(where: { $0.id == selectedLeafID })
        else {
            selectedLeafID = delta < 0 ? filteredLeaves.last?.id : filteredLeaves.first?.id
            return
        }
        let next = (current + delta + filteredLeaves.count) % filteredLeaves.count
        self.selectedLeafID = filteredLeaves[next].id
    }

    func moveSelection(to leafID: AgentModelSelectionLeafID) {
        guard phase == .ready,
              filteredLeaves.contains(where: { $0.id == leafID })
        else {
            return
        }
        selectedLeafID = leafID
    }

    func commit(_ leaf: AgentModelSelectionLeaf) async {
        guard phase == .ready,
              filteredLeaves.contains(where: { $0.id == leaf.id })
        else {
            return
        }
        selectedLeafID = leaf.id
        await commitSelected()
    }

    func commitSelected() async {
        guard phase == .ready,
              let selectedLeafID,
              let selectedIndex = filteredLeaves.firstIndex(where: { $0.id == selectedLeafID }),
              let commitAction
        else {
            return
        }

        let leaf = filteredLeaves[selectedIndex]
        phase = .committing
        errorMessage = nil
        isRouting = mode == .handoffLastReply

        trace("commit-start")
        do {
            try await commitAction(leaf)
            let completion = isPresented && !isSuspendedDuringCommit ? successfulModelSelectionAction : nil
            // The callback may still reject (source drift, shutdown) and AppKit delivery may fail.
            trace(completion == nil ? "commit-success-no-focus-callback" : "commit-success-invoke-focus-callback")
            resetPresentedState()
            // Logical dismissal precedes token publication; AppKit delivery remains deferred.
            completion?()
        } catch {
            trace("commit-failed")
            if isSuspendedDuringCommit {
                resetPresentedState()
            } else {
                isRouting = false
                phase = .ready
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetPresentedState() {
        isPresented = false
        phase = .ready
        errorMessage = nil
        noticeText = nil
        subtitle = nil
        isRouting = false
        isSuspendedDuringCommit = false
        query = ""
        selectedLeafID = nil
        index = AgentModelSelectionIndex(leaves: [])
        commitAction = nil
        successfulModelSelectionAction = nil
        filteredLeaves = []
        isShowingLimitedResults = false
        totalMatchedLeafCount = 0
    }

    private func trace(_ event: String) {
        #if DEBUG
            let modeName = mode.rawValue
            let epoch = focusAssertionEpoch
            let presented = isPresented
            let committing = isCommitting
            let suspended = isSuspendedDuringCommit
            let traceID = debugTraceID
            Self.logger.debug(
                "model-hud event=\(event, privacy: .public) hud=\(traceID, privacy: .public) mode=\(modeName, privacy: .public) epoch=\(epoch, privacy: .public) presented=\(presented, privacy: .public) committing=\(committing, privacy: .public) suspended=\(suspended, privacy: .public)"
            )
        #endif
    }

    private func rebuildFilteredLeaves(preserveSelection: Bool) {
        let previousSelection = preserveSelection ? selectedLeafID : nil
        let ranked = index.ranked(query: query)
        totalMatchedLeafCount = ranked.count
        var displayed = Array(ranked.prefix(Self.displayLimit))
        isShowingLimitedResults = ranked.count > displayed.count

        let preferredSelection: AgentModelSelectionLeafID? = {
            if queryIsEmpty {
                return index.currentSelectionID
            }
            if let previousSelection,
               ranked.contains(where: { $0.id == previousSelection })
            {
                return previousSelection
            }
            return ranked.first?.id
        }()

        if let preferredSelection,
           !displayed.contains(where: { $0.id == preferredSelection }),
           let preferredLeaf = ranked.first(where: { $0.id == preferredSelection })
        {
            if displayed.count == Self.displayLimit {
                displayed.removeLast()
            }
            displayed.append(preferredLeaf)
        }

        if filteredLeaves != displayed {
            filteredLeaves = displayed
        }
        selectedLeafID = preferredSelection.flatMap { preferred in
            displayed.contains(where: { $0.id == preferred }) ? preferred : nil
        }
    }
}
