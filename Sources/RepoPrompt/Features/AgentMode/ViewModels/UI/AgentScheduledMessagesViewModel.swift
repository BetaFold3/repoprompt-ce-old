import Combine
import Foundation
import RepoPromptAgentCore

@MainActor
final class AgentScheduledMessagesViewModel: ObservableObject {
    enum Scope: String, CaseIterable {
        case currentWorkspace = "Current workspace"
        case allWorkspaces = "All workspaces"
    }

    final class Row: Identifiable {
        let sessionID: UUID
        let tabID: UUID?
        let workspaceID: UUID
        let workspaceName: String
        let sessionName: String
        let previewText: String
        let statusText: String
        let props: AgentScheduledSendProps?
        weak var actionHost: AgentModeViewModel?
        let recovery: AgentScheduledSendRecoveryStatus?
        let isIndexUnavailable: Bool
        var workspaceOwner: AgentModeViewModel.SessionIndexOwner?

        init(
            sessionID: UUID,
            tabID: UUID?,
            workspaceID: UUID,
            workspaceName: String,
            sessionName: String,
            previewText: String,
            statusText: String,
            props: AgentScheduledSendProps?,
            actionHost: AgentModeViewModel?,
            recovery: AgentScheduledSendRecoveryStatus?,
            isIndexUnavailable: Bool = false
        ) {
            self.sessionID = sessionID
            self.tabID = tabID
            self.workspaceID = workspaceID
            self.workspaceName = workspaceName
            self.sessionName = sessionName
            self.previewText = previewText
            self.statusText = statusText
            self.props = props
            self.actionHost = actionHost
            self.recovery = recovery
            self.isIndexUnavailable = isIndexUnavailable
        }

        var id: String {
            "\(workspaceID.uuidString):\(isIndexUnavailable ? "index" : sessionID.uuidString)"
        }

        @MainActor var isActionable: Bool {
            guard let props,
                  let host = actionHost,
                  workspaceOwner != nil,
                  let tabID,
                  props.tabID == tabID,
                  host.persistenceWorkspace?.id == workspaceID,
                  let session = host.sessions[tabID],
                  session.activeAgentSessionID == sessionID,
                  session.hasLoadedPersistedState,
                  session.persistenceState(for: sessionID) != nil,
                  (session.scheduledSendWorkspaceID ?? host.persistenceWorkspace?.id) == workspaceID
            else { return false }
            return props.isUnreadable
                ? session.scheduledSend?.isUnreadable == true
                : session.pendingScheduledSendRecord?.id == props.id
        }
    }

    @Published var scope: Scope = .currentWorkspace
    @Published private(set) var rows: [Row] = []
    @Published private(set) var loadError: String?
    @Published private(set) var reloadRequest: UInt64 = 0

    private weak var agentModeVM: AgentModeViewModel?
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private let metadataRecords: @MainActor (WorkspaceModel) async throws -> [AgentSessionMetadataRecord]?
    private var reloadGeneration = 0
    private var workspaceObservation: AnyCancellable?

    init(
        agentModeVM: AgentModeViewModel,
        metadataRecords: (@MainActor (WorkspaceModel) async throws -> [AgentSessionMetadataRecord]?)? = nil,
        workspaceIDs: AnyPublisher<UUID?, Never>? = nil
    ) {
        self.agentModeVM = agentModeVM
        workspaceManager = agentModeVM.workspaceManager
        let dataService = agentModeVM.dataService
        self.metadataRecords = metadataRecords ?? { workspace in
            try await dataService.fastMetadataRecordsIfAvailable(for: workspace)?.records
        }
        let workspaceIDs = workspaceIDs ?? workspaceManager?.$activeWorkspaceID.eraseToAnyPublisher()
        workspaceObservation = workspaceIDs?
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                invalidateForWorkspaceChange()
                reloadRequest &+= 1
            }
    }

    static func currentWorkspaceCount(agentModeVM: AgentModeViewModel) -> Int {
        guard let workspaceID = agentModeVM.persistenceWorkspace?.id else { return 0 }
        let hydrated = hydratedSessions(agentModeVM: agentModeVM, workspaceID: workspaceID)
        let hydratedIDs = Set(hydrated.map(\.sessionID))
        let indexedIDs = Set(agentModeVM.ownerValidatedSessionIndex.values.compactMap { entry in
            entry.scheduledSendSummary != nil && !hydratedIDs.contains(entry.id) ? entry.id : nil
        })
        let hydratedScheduledIDs = Set(hydrated.compactMap { state in
            state.session.scheduledSend != nil ? state.sessionID : nil
        })
        let coordinator = agentModeVM.scheduledSendCoordinator
        let liveIDs = Set(coordinator?.dashboardCandidates(in: workspaceID).compactMap { snapshot in
            hydratedIDs.contains(snapshot.candidate.sessionID) && !hydratedScheduledIDs.contains(snapshot.candidate.sessionID)
                ? nil : snapshot.candidate.sessionID
        } ?? [])
        let recoveryIDs = Set(coordinator?.dashboardRecoveryStatuses(in: workspaceID).map(\.key.sessionID) ?? [])
        let confirmationIDs = Set(coordinator?.dashboardPendingConfirmations(in: workspaceID).map(\.sessionID) ?? [])
        return indexedIDs.union(hydratedScheduledIDs).union(liveIDs).union(recoveryIDs).union(confirmationIDs).count
    }

    private struct HydratedSession {
        let sessionID: UUID
        let session: AgentTabSession
    }

    private static func hydratedSessions(
        agentModeVM: AgentModeViewModel,
        workspaceID: UUID
    ) -> [HydratedSession] {
        agentModeVM.sessions.values.compactMap { session in
            guard session.hasLoadedPersistedState,
                  session.staleResetRecovery == nil,
                  session.persistenceRevokedSessionID == nil,
                  let sessionID = session.activeAgentSessionID,
                  (session.scheduledSendWorkspaceID ?? agentModeVM.persistenceWorkspace?.id) == workspaceID
            else { return nil }
            return HydratedSession(sessionID: sessionID, session: session)
        }
    }

    private func bindingIsCurrent(
        workspaceID: UUID?,
        owner: AgentModeViewModel.SessionIndexOwner?,
        selectedScope: Scope
    ) -> Bool {
        guard let agentModeVM else { return false }
        return scope == selectedScope
            && agentModeVM.persistenceWorkspace?.id == workspaceID
            && agentModeVM.sessionIndexOwner == owner
    }

    func invalidateForWorkspaceChange() {
        reloadGeneration &+= 1
        rows = []
        loadError = nil
    }

    func reload() async {
        guard let agentModeVM else {
            invalidateForWorkspaceChange()
            return
        }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let selectedScope = scope
        let activeWorkspace = agentModeVM.persistenceWorkspace
        let activeWorkspaceID = activeWorkspace?.id
        let owner = agentModeVM.sessionIndexOwner
        let workspaces: [WorkspaceModel] = switch selectedScope {
        case .currentWorkspace:
            activeWorkspace.map { [$0] } ?? []
        case .allWorkspaces:
            workspaceManager?.workspaces ?? activeWorkspace.map { [$0] } ?? []
        }

        var projected: [Row] = []
        for workspace in workspaces {
            let indexed: [AgentSessionMetadataRecord]?
            do {
                // Foreign workspaces are index-only: never hydrate or rebuild them here.
                indexed = try await metadataRecords(workspace)
            } catch {
                indexed = nil
            }
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            guard bindingIsCurrent(
                workspaceID: activeWorkspaceID,
                owner: owner,
                selectedScope: selectedScope
            ) else {
                invalidateForWorkspaceChange()
                return
            }
            if let indexed {
                projected += Self.indexRows(
                    from: indexed,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    coordinator: selectedScope == .currentWorkspace ? agentModeVM.scheduledSendCoordinator : nil
                )
            } else {
                projected.append(Row(
                    sessionID: workspace.id,
                    tabID: nil,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    sessionName: workspace.name,
                    previewText: "",
                    statusText: "Workspace index unavailable · scheduled messages may be missing",
                    props: nil,
                    actionHost: nil,
                    recovery: nil,
                    isIndexUnavailable: true
                ))
            }
        }

        if selectedScope == .currentWorkspace, let workspace = activeWorkspace {
            // An identity-matched in-memory entry supersedes the disk hint even when its
            // summary is nil. A hydrated member is stronger still, including nil.
            let entries = agentModeVM.ownerValidatedSessionIndex
            let indexedIDs = Set(entries.keys)
            projected.removeAll { !$0.isIndexUnavailable && indexedIDs.contains($0.sessionID) }
            let indexRows = entries.values.compactMap { entry -> Row? in
                guard let summary = entry.scheduledSendSummary else { return nil }
                return Self.indexRow(
                    sessionID: entry.id,
                    tabID: entry.tabID,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    sessionName: entry.name,
                    summary: summary,
                    coordinator: agentModeVM.scheduledSendCoordinator
                )
            }
            projected += indexRows

            let hydrated = Self.hydratedSessions(agentModeVM: agentModeVM, workspaceID: workspace.id)
            let hydratedIDs = Set(hydrated.map(\.sessionID))
            projected.removeAll { !$0.isIndexUnavailable && hydratedIDs.contains($0.sessionID) }
            // Presentation owns hydrated members independently of admission discovery. An
            // in-flight dispatch is deliberately absent from scheduledSendCandidates(), but
            // must remain visible while recovery preparation precedes the retained handoff.
            projected += hydrated.compactMap { state in
                Self.hydratedRow(
                    state,
                    workspace: workspace,
                    host: agentModeVM,
                    coordinator: agentModeVM.scheduledSendCoordinator
                )
            }

            if let coordinator = agentModeVM.scheduledSendCoordinator {
                let absentHydratedIDs = Set(hydrated.compactMap { state in
                    state.session.scheduledSend == nil ? state.sessionID : nil
                })
                let inFlightHydratedIDs = Set(hydrated.compactMap { state in
                    state.session.ownsLiveScheduledAttempt ? state.sessionID : nil
                })
                let liveRows = coordinator.dashboardCandidates(in: workspace.id)
                    .filter {
                        !absentHydratedIDs.contains($0.candidate.sessionID)
                            && !inFlightHydratedIDs.contains($0.candidate.sessionID)
                    }
                    .map { snapshot in
                        Self.liveRow(
                            snapshot,
                            workspaceName: workspace.name,
                            coordinator: coordinator
                        )
                    }
                projected = Self.merging(projected, replacingWith: liveRows)

                let recoveryRows = coordinator.dashboardRecoveryStatuses(in: workspace.id)
                    .filter { recovery in !projected.contains(where: { $0.sessionID == recovery.key.sessionID }) }
                    .map { recovery in
                        Row(
                            sessionID: recovery.key.sessionID,
                            tabID: entries[recovery.key.sessionID]?.tabID,
                            workspaceID: workspace.id,
                            workspaceName: workspace.name,
                            sessionName: entries[recovery.key.sessionID]?.name ?? "Agent Session",
                            previewText: "",
                            statusText: Self.recoveryStatusText(recovery),
                            props: nil,
                            actionHost: nil,
                            recovery: recovery
                        )
                    }
                projected += recoveryRows

                let confirmationRows = coordinator.dashboardPendingConfirmations(in: workspace.id)
                    .filter { pending in !projected.contains(where: { $0.sessionID == pending.sessionID }) }
                    .map { pending in
                        Row(
                            sessionID: pending.sessionID,
                            tabID: entries[pending.sessionID]?.tabID,
                            workspaceID: workspace.id,
                            workspaceName: workspace.name,
                            sessionName: entries[pending.sessionID]?.name ?? "Agent Session",
                            previewText: "",
                            statusText: Self.confirmationStatusText(pending.reason),
                            props: nil,
                            actionHost: nil,
                            recovery: nil
                        )
                    }
                projected += confirmationRows
            }

            for state in hydrated where state.session.scheduledSend?.isUnreadable == true {
                projected.removeAll { !$0.isIndexUnavailable && $0.sessionID == state.sessionID }
                projected.append(Row(
                    sessionID: state.sessionID,
                    tabID: state.session.tabID,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    sessionName: agentModeVM.resolvedSessionDisplayName(for: state.session.tabID),
                    previewText: "",
                    statusText: "",
                    props: .unreadable(tabID: state.session.tabID),
                    actionHost: agentModeVM,
                    recovery: nil
                ))
            }
        }

        guard !Task.isCancelled, generation == reloadGeneration else { return }
        guard bindingIsCurrent(
            workspaceID: activeWorkspaceID,
            owner: owner,
            selectedScope: selectedScope
        ) else {
            invalidateForWorkspaceChange()
            return
        }
        if selectedScope == .currentWorkspace {
            for row in projected {
                row.workspaceOwner = owner
            }
        }
        rows = projected.sorted {
            if $0.workspaceName != $1.workspaceName { return $0.workspaceName < $1.workspaceName }
            if $0.sessionName != $1.sessionName { return $0.sessionName < $1.sessionName }
            return $0.sessionID.uuidString < $1.sessionID.uuidString
        }
        loadError = projected.contains(where: \.isIndexUnavailable)
            ? "Some workspace indexes are unavailable; results are incomplete."
            : nil
    }

    static func merging(_ base: [Row], replacingWith replacements: [Row]) -> [Row] {
        let replacementIDs = Set(replacements.map(\.sessionID))
        return base.filter { !replacementIDs.contains($0.sessionID) } + replacements
    }

    static func indexRows(
        from records: [AgentSessionMetadataRecord],
        workspaceID: UUID,
        workspaceName: String,
        coordinator: AgentScheduledSendCoordinator? = nil
    ) -> [Row] {
        records.compactMap { record in
            guard let summary = record.scheduledSendSummary else { return nil }
            return indexRow(
                sessionID: record.id,
                tabID: record.composeTabID,
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                sessionName: record.name,
                summary: summary,
                coordinator: coordinator
            )
        }
    }

    static func indexRow(
        sessionID: UUID,
        tabID: UUID?,
        workspaceID: UUID,
        workspaceName: String,
        sessionName: String,
        summary: AgentSessionScheduledSendSummary,
        coordinator: AgentScheduledSendCoordinator? = nil
    ) -> Row {
        let pending = coordinator?.pendingConfirmationStatus(sessionID: sessionID)
        let recovery = coordinator?.recoveryStatus(sessionID: sessionID)
        let hasActiveAdmission = coordinator?.activeAdmission(sessionID: sessionID) != nil
        return Row(
            sessionID: sessionID,
            tabID: tabID,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            sessionName: sessionName,
            previewText: summary.previewText,
            statusText: indexStatus(
                summary: summary,
                pendingConfirmation: pending,
                recovery: recovery,
                hasActiveAdmission: hasActiveAdmission
            ),
            props: nil,
            actionHost: nil,
            recovery: recovery
        )
    }

    static func indexStatus(
        summary: AgentSessionScheduledSendSummary,
        pendingConfirmation: AgentScheduledSendPendingConfirmationStatus? = nil,
        recovery: AgentScheduledSendRecoveryStatus? = nil,
        hasActiveAdmission: Bool = false
    ) -> String {
        if summary.isUnreadable { return "Unreadable scheduled message · open session to discard" }
        if let pendingConfirmation {
            return confirmationStatusText(pendingConfirmation.reason)
        }
        if let recovery {
            return recoveryStatusText(recovery)
        }
        let time = summary.notBefore.map(AgentScheduledSendDateFormatting.dateAndTime) ?? "unknown time"
        switch summary.stateRaw.flatMap(AgentScheduledSendPersist.State.init(rawValue:)) {
        case .scheduled:
            return "Scheduled for \(time) · open session for live status"
        case .needsConfirmation:
            return "Scheduled for \(time) · confirmation required"
        case .failed:
            return "Delivery unconfirmed · open session to retry"
        case .dispatching:
            // Only a process-retained lease proves an in-process handoff. A bare index never does.
            return hasActiveAdmission
                ? "Sending scheduled message…"
                : "Delivery unconfirmed · open session to verify"
        case nil:
            return "Confirmation required · open session"
        }
    }

    private static func confirmationStatusText(
        _ reason: AgentScheduledSendPersist.ConfirmationReason
    ) -> String {
        "Confirmation required · \(reason.displayText) · sending paused"
    }

    private static func recoveryStatusText(_ recovery: AgentScheduledSendRecoveryStatus) -> String {
        switch recovery.phase {
        case .needsAttention:
            recovery.hasAcceptedPayload
                ? "Delivered · saving needs attention"
                : "Delivery unconfirmed · needs attention"
        case .awaitingProviderOutcome:
            "Delivery unconfirmed · provider outcome pending"
        case .saving:
            recovery.hasAcceptedPayload
                ? "Delivered · saving"
                : "Delivery unconfirmed · provider outcome pending"
        case .waitingToRetry:
            recovery.hasAcceptedPayload
                ? "Delivered · waiting to retry saving"
                : "Delivery unconfirmed · provider outcome pending"
        }
    }

    private static func hydratedRow(
        _ state: HydratedSession,
        workspace: WorkspaceModel,
        host: AgentModeViewModel,
        coordinator: AgentScheduledSendCoordinator?
    ) -> Row? {
        guard let record = state.session.pendingScheduledSendRecord else { return nil }
        let pending = coordinator?.pendingConfirmationStatus(sessionID: state.sessionID)
        let matchedPending = pending?.scheduleID == record.id ? pending : nil
        let recovery = coordinator?.recoveryStatus(sessionID: state.sessionID)
        let hasActiveAdmission = coordinator?.activeAdmission(sessionID: state.sessionID) != nil
        let snapshot = AgentScheduledSendDashboardCandidate(
            candidate: AgentScheduledSendCandidate(
                sessionID: state.sessionID,
                tabID: state.session.tabID,
                workspaceID: workspace.id,
                scheduledSend: record,
                isHydrated: true
            ),
            host: host,
            pendingConfirmation: matchedPending,
            recovery: recovery,
            hasActiveAdmission: hasActiveAdmission
        )
        let props = coordinator.map {
            dashboardProps(
                for: snapshot,
                blockingSessionName: $0.dashboardBlockingSessionName(for: snapshot),
                recoveryBlocker: $0.recoveryBlocker(scheduleID: record.id),
                hasHost: true
            )
        } ?? nil
        let summary = AgentSessionScheduledSendSummary.make(from: .v1(record))
        return Row(
            sessionID: state.sessionID,
            tabID: state.session.tabID,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            sessionName: host.resolvedSessionDisplayName(for: state.session.tabID),
            previewText: record.rawText,
            statusText: props == nil
                ? summary.map {
                    indexStatus(
                        summary: $0,
                        pendingConfirmation: matchedPending,
                        recovery: recovery,
                        hasActiveAdmission: hasActiveAdmission
                    )
                } ?? "Scheduled message · open session for live status"
                : "",
            props: props,
            actionHost: props == nil ? nil : host,
            recovery: recovery
        )
    }

    private static func liveRow(
        _ snapshot: AgentScheduledSendDashboardCandidate,
        workspaceName: String,
        coordinator: AgentScheduledSendCoordinator
    ) -> Row {
        let candidate = snapshot.candidate
        let record = candidate.scheduledSend
        let host = snapshot.host as? AgentModeViewModel
        let name = host?.resolvedSessionDisplayName(for: candidate.tabID) ?? "Agent Session"
        let blockingName = coordinator.dashboardBlockingSessionName(for: snapshot)
        let props = dashboardProps(
            for: snapshot,
            blockingSessionName: blockingName,
            recoveryBlocker: coordinator.recoveryBlocker(scheduleID: record.id),
            hasHost: host != nil
        )
        let summary = AgentSessionScheduledSendSummary.make(from: .v1(record))
        return Row(
            sessionID: candidate.sessionID,
            tabID: candidate.tabID,
            workspaceID: candidate.workspaceID,
            workspaceName: workspaceName,
            sessionName: name,
            previewText: candidate.isHydrated ? record.rawText : (summary?.previewText ?? record.rawText),
            statusText: props == nil
                ? summary.map {
                    indexStatus(
                        summary: $0,
                        pendingConfirmation: snapshot.pendingConfirmation,
                        recovery: snapshot.recovery,
                        hasActiveAdmission: snapshot.hasActiveAdmission
                    )
                } ?? "Scheduled message · open session for live status"
                : "",
            props: props,
            actionHost: props == nil ? nil : host,
            recovery: snapshot.recovery
        )
    }

    private static func dashboardProps(
        for snapshot: AgentScheduledSendDashboardCandidate,
        blockingSessionName: String?,
        recoveryBlocker: AgentScheduledSendRecoveryBlocker?,
        hasHost: Bool
    ) -> AgentScheduledSendProps? {
        let candidate = snapshot.candidate
        let record = candidate.scheduledSend
        guard candidate.isHydrated, hasHost else { return nil }
        let hasConfirmedDelivery = snapshot.recovery?.hasAcceptedPayload == true
        let hasLiveHandoff = snapshot.recovery == nil && snapshot.hasActiveAdmission
        guard record.state != .dispatching || hasConfirmedDelivery || hasLiveHandoff else {
            return nil
        }
        return AgentScheduledSendProps(
            tabID: candidate.tabID,
            scheduledSend: record,
            blockingSessionName: blockingSessionName,
            recoveryPhase: snapshot.recovery?.phase,
            pendingConfirmation: snapshot.pendingConfirmation,
            // Lossless restart F2: the same recovery-blocked message as the composer banner.
            recoveryBlocker: recoveryBlocker
        )
    }

    private func actionTarget(for row: Row) -> (AgentModeViewModel, AgentScheduledSendProps)? {
        guard scope == .currentWorkspace,
              let agentModeVM,
              let owner = row.workspaceOwner,
              agentModeVM.persistenceWorkspace?.id == row.workspaceID,
              agentModeVM.sessionIndexOwner == owner,
              row.isActionable,
              let host = row.actionHost,
              let props = row.props
        else { return nil }
        return (host, props)
    }

    func update(
        _ row: Row,
        text: String,
        notBefore: Date,
        runAlongsideOtherSessions: Bool,
        removingImageAttachmentIDs: Set<UUID> = [],
        removingTaggedFileAttachmentIDs: Set<UUID> = []
    ) async -> String? {
        guard let (host, props) = actionTarget(for: row) else { return "Open this session to manage its scheduled message." }
        let result = await host.updateScheduledSend(
            tabID: props.tabID,
            scheduleID: props.id,
            text: text,
            notBefore: notBefore,
            runAlongsideOtherSessions: runAlongsideOtherSessions,
            removingImageAttachmentIDs: removingImageAttachmentIDs,
            removingTaggedFileAttachmentIDs: removingTaggedFileAttachmentIDs
        )
        await reload()
        return result
    }

    func cancel(_ row: Row) async -> String? {
        guard let (host, props) = actionTarget(for: row) else { return "Open this session to manage its scheduled message." }
        let result = await host.cancelScheduledSend(tabID: props.tabID, scheduleID: props.id)
        await reload()
        return result
    }

    func sendNow(_ row: Row, runAlongsideOtherSessions: Bool) async -> String? {
        guard let (host, props) = actionTarget(for: row) else { return "Open this session to manage its scheduled message." }
        let result = await host.sendScheduledSendNow(
            tabID: props.tabID,
            scheduleID: props.id,
            runAlongsideOtherSessions: runAlongsideOtherSessions
        )
        await reload()
        return result
    }

    func discardUnreadable(_ row: Row) async -> String? {
        guard let (host, props) = actionTarget(for: row) else { return "Open this session to manage its scheduled message." }
        let result = await host.discardUnreadableScheduledSend(tabID: props.tabID)
        await reload()
        return result
    }

    func retrySaving(_ row: Row) async -> String? {
        guard let (host, props) = actionTarget(for: row) else { return "Open this session to manage its scheduled message." }
        let result = await host.retryScheduledSendSaving(tabID: props.tabID)
        await reload()
        return result
    }

    func openWorkspace(_ workspaceID: UUID) async {
        guard let workspaceManager,
              let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceID })
        else { return }
        if workspaceManager.activeWorkspace?.id == workspaceID {
            scope = .currentWorkspace
            await reload()
            return
        }
        let result = await workspaceManager.switchWorkspace(
            to: workspace,
            reason: "scheduledMessagesDashboard"
        )
        if result.didSwitch || workspaceManager.activeWorkspace?.id == workspaceID {
            scope = .currentWorkspace
            await reload()
        } else {
            loadError = result.message
        }
    }

    func openCurrentSession(_ row: Row) async {
        guard scope == .currentWorkspace,
              let agentModeVM, let tabID = row.tabID,
              agentModeVM.persistenceWorkspace?.id == row.workspaceID,
              agentModeVM.sessionIndexOwner == row.workspaceOwner,
              let promptManager = agentModeVM.promptManager
        else { return }
        if promptManager.currentComposeTabs.contains(where: { $0.id == tabID }) {
            await promptManager.switchComposeTab(tabID)
        } else if promptManager.currentStashedTabs.contains(where: { $0.id == tabID }) {
            await promptManager.unstashTab(tabID)
        } else {
            return
        }
        _ = await agentModeVM.ensureHydrated(tabID: tabID)
        await reload()
    }

    func retryRecovery(_ row: Row) {
        guard scope == .currentWorkspace,
              let agentModeVM,
              agentModeVM.persistenceWorkspace?.id == row.workspaceID,
              agentModeVM.sessionIndexOwner == row.workspaceOwner,
              let recovery = row.recovery,
              recovery.hasAcceptedPayload
        else { return }
        _ = agentModeVM.scheduledSendCoordinator?.retryRecovery(sessionID: row.sessionID)
    }
}
