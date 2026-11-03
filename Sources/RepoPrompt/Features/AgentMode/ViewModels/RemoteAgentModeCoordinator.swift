import Foundation
import OSLog
import RepoPromptAgentCore
import RepoPromptRemoteWire

@MainActor
final class RemoteAgentModeCoordinator {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "RemoteAgentModeCoordinator")
    private static let sendingResponseStatusPrefix = "Sending response to "

    private struct HostConnectionTasks {
        var inbound: Task<Void, Never>
        var state: Task<Void, Never>
    }

    private struct RemoteChildDiscoveryContext {
        var key: String
        var parentTabID: UUID
        var parentRemoteSessionID: String
        var hostBinding: AgentSessionRemoteHostBinding
    }

    private struct WorkspacePickupKey: Hashable {
        var hostID: String
        var remoteSessionID: String
    }

    /// Exact runtime target of one remote input handoff, captured before the first await.
    private struct RemoteDispatchTarget {
        let tabID: UUID
        let controller: RemoteAgentSessionController
        let hostID: String
        let remoteSessionID: String?
        let dispatch: RemoteInputDispatch
    }

    struct WorkspaceOpenEpisodeKey: Hashable {
        var hostID: String
        var clientWorkspaceID: UUID
    }

    enum WorkspaceOpenEpisodeState: Equatable {
        case opening
        case failed(String)
    }

    struct RestorableInteractionState {
        let interactionID: String
        let priorRunState: AgentSessionRunState
        let pendingApproval: AgentApprovalRequest?
        let pendingAskUser: AgentAskUserPendingState?
        let pendingUserInputRequest: AgentRequestUserInputRequest?
        let pendingMCPElicitationRequest: AgentMCPElicitationRequest?
    }

    struct StashedAskUserState {
        let interactionID: String
        let draftsByQuestionID: [String: AgentAskUserDraft]
        let currentQuestionIndex: Int
    }

    private weak var viewModel: AgentModeViewModel?
    private let connectionManagerProvider: @MainActor () -> RemoteHostConnectionManager
    private let catalogProvider: @MainActor (String) -> RemoteHostAgentCatalog?
    private let hostRecordProvider: @MainActor (String) -> PairedHostRecord?
    private let workspaceSessionCatalogStore: any RemoteWorkspaceSessionCatalogStoring
    private let workspaceOpenConnectionProvider: @MainActor (String) throws -> any RemoteWorkspaceSessionCatalogConnection
    private var controllersByTabID: [UUID: RemoteAgentSessionController] = [:]
    private var eventTasksByTabID: [UUID: Task<Void, Never>] = [:]
    /// Per-tab delivery generation: captured by each event task when its attachment starts,
    /// advanced whenever the attachment is (re)started or stopped, and checked before an event is
    /// applied. A delivery that belongs to a retired attachment can therefore never mutate the tab,
    /// even if it was in flight across `stop(tabID:)` — the boundary stale-reset recovery relies on
    /// before it replaces a retained conversation with authoritative state.
    private var deliveryGenerationByTabID: [UUID: UInt64] = [:]
    private var hostIDByTabID: [UUID: String] = [:]
    private var forkCapabilityByHostID: [String: Bool] = [:]
    private var forkCapabilityProbeTasksByHostID: [String: Task<Void, Never>] = [:]
    private var hostRowIDByClientItemIDByTabID: [UUID: [UUID: UUID]] = [:]
    private var connectionTasksByHostID: [String: HostConnectionTasks] = [:]
    private var surfacedChannelReasonsByTabID: [UUID: Set<String>] = [:]
    /// Tabs whose current running label came from host status_text (not a client placeholder).
    private var hostProvidedRunningStatusTabIDs: Set<UUID> = []
    private var tabsWithSyntheticSettlements: Set<UUID> = []
    private var lastAdoptedHostNameByTabID: [UUID: String] = [:]
    private var startSessionNameByTabID: [UUID: String] = [:]
    private var childDiscoveryInFlightKeys: Set<String> = []
    private var childDiscoveryImmediatePendingKeys: Set<String> = []
    private var activeRunStateChildDiscoveryKeys: Set<String> = []
    private var discoveryKeyByTabID: [UUID: String] = [:]
    private var reportedChildMaterializationFailuresByDiscoveryKey: [String: Set<String>] = [:]
    private var workspacePickupInFlightKeys: Set<WorkspacePickupKey> = []
    private var workspaceOpenEpisodes: [WorkspaceOpenEpisodeKey: WorkspaceOpenEpisodeState] = [:]
    private var stashedAskUserStateByTabID: [UUID: StashedAskUserState] = [:]
    private var childDiscoveryPendingContextsByKey: [String: RemoteChildDiscoveryContext] = [:]
    private var childDiscoveryTasksByKey: [String: Task<Void, Never>] = [:]
    private var lastChildDiscoveryStartedAtByKey: [String: Date] = [:]
    private let childDiscoveryDebounceInterval: TimeInterval
    #if DEBUG
        private var materializedRemoteChildAttachHandler: (@MainActor (AgentTabSession) async throws -> Void)?
        private var materializedRemoteWorkspaceAttachHandler: (@MainActor (AgentTabSession) async throws -> Void)?
        private var childDiscoveryRequestObserver: ((UUID, Bool) -> Void)?
        private var syntheticSettlementRevertScanObserver: ((UUID) -> Void)?
        private var connectionStateDeliveryObserver: ((String, RemoteHostConnection.State) -> Void)?
    #endif

    init(
        connectionManagerProvider: @escaping @MainActor () -> RemoteHostConnectionManager = { RemoteHostConnectionManager.shared },
        catalogProvider: @escaping @MainActor (String) -> RemoteHostAgentCatalog? = { RemoteHostCatalog.shared.cachedCatalog(for: $0) },
        hostRecordProvider: @escaping @MainActor (String) -> PairedHostRecord? = { try? RemoteHostRegistry.shared.host(id: $0) },
        workspaceSessionCatalogStore: (any RemoteWorkspaceSessionCatalogStoring)? = nil,
        workspaceOpenConnectionProvider: (@MainActor (String) throws -> any RemoteWorkspaceSessionCatalogConnection)? = nil,
        childDiscoveryDebounceInterval: TimeInterval = 3
    ) {
        self.connectionManagerProvider = connectionManagerProvider
        self.catalogProvider = catalogProvider
        self.hostRecordProvider = hostRecordProvider
        self.workspaceSessionCatalogStore = workspaceSessionCatalogStore ?? RemoteWorkspaceSessionCatalogStore.shared
        self.workspaceOpenConnectionProvider = workspaceOpenConnectionProvider ?? {
            try RemoteHostConnectionManager.shared.connection(for: $0)
        }
        self.childDiscoveryDebounceInterval = childDiscoveryDebounceInterval
    }

    deinit {
        for tasks in connectionTasksByHostID.values {
            tasks.inbound.cancel()
            tasks.state.cancel()
        }
        for task in eventTasksByTabID.values {
            task.cancel()
        }
        for task in forkCapabilityProbeTasksByHostID.values {
            task.cancel()
        }
        for task in childDiscoveryTasksByKey.values {
            task.cancel()
        }
    }

    func attach(viewModel: AgentModeViewModel) {
        self.viewModel = viewModel
    }

    func attachPersistedSessionIfNeeded(_ session: AgentTabSession) {
        guard session.remoteHost != nil else { return }
        guard !(session.parentSessionID != nil && session.runState.isTerminalForCommit) else { return }
        do {
            let controller = try controller(for: session)
            Task { [weak self] in
                do {
                    try await controller.attachAndCatchUp()
                } catch {
                    self?.appendSystemMessage("Remote attach failed: \(Self.describe(error))", tabID: session.tabID)
                }
            }
        } catch {
            appendSystemMessage("Remote attach failed: \(Self.describe(error))", tabID: session.tabID)
        }
    }

    /// Starts a remote session with one user input. `dispatch` is the caller's immutable admission
    /// identity (allocated at input admission); its delivery attempt is committed before the `start`
    /// request, and the exact tab, controller, host binding, and recovery lane are revalidated after
    /// every await. A successful host response is not provider acceptance, so durable input ends
    /// `deliveryUnknown` (see `RemoteInputHandoffError` for the failure dispositions).
    @discardableResult
    func startRemoteSession(
        session: AgentTabSession,
        message: String,
        modelSelectionRaw: String?,
        sessionName: String?,
        windowID: Int?,
        workspaceID: String?,
        workspaceName: String?,
        allowHostSessionNameAdoptionFromStartName: Bool = false,
        dispatch: RemoteInputDispatch
    ) async throws -> AgentRecoveryDispatchEvidence {
        let target = try captureDispatchTarget(session: session, dispatch: dispatch)
        let evidence = try await beginRemoteDispatch(target, session: session)
        let controller = target.controller
        recordStartSessionName(
            sessionName,
            tabID: session.tabID,
            allowHostSessionNameAdoptionFromStartName: allowHostSessionNameAdoptionFromStartName
        )
        hostProvidedRunningStatusTabIDs.remove(session.tabID)
        session.runState = .running
        session.setRunningStatus("Starting on \(session.remoteHost?.hostDisplayName ?? "remote host")…", source: .transport)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        let remoteSessionID: String
        do {
            remoteSessionID = try await controller.start(
                message: message,
                modelSelectionRaw: modelSelectionRaw,
                sessionName: sessionName,
                windowID: windowID,
                workspaceID: workspaceID,
                workspaceName: workspaceName
            )
        } catch {
            throw Self.ambiguousRemoteHandoff(error, evidence: evidence)
        }
        // The host adopted the start. That is bridge/host evidence, not provider acceptance.
        evidence.noteDeliveryUnknown()
        if var binding = session.remoteHost {
            binding.remoteSessionID = remoteSessionID
            session.remoteHost = binding
            updateSessionIndex(for: session)
            Task { @MainActor [weak self] in
                await self?.refreshWorkspaceSessionCatalogAfterSuccessfulStart(hostID: binding.hostID)
            }
        }
        return evidence
    }

    /// Steers the remote session with one user input. The observation preflight runs before the
    /// dispatch is committed (it never hands the input off); the delivery attempt is committed right
    /// before the `steer` request and the exact target is revalidated after every await. A successful
    /// host response is not provider acceptance, so durable input ends `deliveryUnknown`.
    @discardableResult
    func steer(
        session: AgentTabSession,
        text: String,
        dispatch: RemoteInputDispatch
    ) async throws -> AgentRecoveryDispatchEvidence {
        let target = try captureDispatchTarget(session: session, dispatch: dispatch)
        let controller = target.controller
        // Self-heal: a session can reach steer without observation ever attaching —
        // e.g. a restored terminal child session that attachPersistedSessionIfNeeded
        // deliberately skipped, or a proxy whose earlier attach failed non-transiently.
        // Steering without the subscribe would run the turn on the host while this
        // client never receives the response, so a hard attach failure withholds the
        // steer and surfaces as a send failure (resending retries the attach).
        // Transient failures are absorbed inside attachAndCatchUp, which schedules
        // automatic observation recovery; the steer then proceeds.
        // Nothing is committed yet, so a preflight failure or a stale target is a proven no-handoff.
        do {
            if await !controller.hasAttachedObservation() {
                try await controller.attachAndCatchUp()
            }
        } catch {
            throw RemoteInputHandoffError(disposition: .notHandedOff, cause: .remote(error), evidence: nil)
        }
        // Only the runtime target is revalidated here; the admission authority is decided by the
        // dispatch begin (an untracked input under mandatory admission is refused there, not stale),
        // and `beginRemoteDispatch` revalidates the full target after its commit.
        guard isRuntimeTargetCurrent(target, session: session) else {
            throw RemoteInputHandoffError(disposition: .notHandedOff, cause: .staleTarget, evidence: nil)
        }
        let evidence = try await beginRemoteDispatch(target, session: session)
        do {
            try await controller.steer(text)
        } catch {
            throw Self.ambiguousRemoteHandoff(error, evidence: evidence)
        }
        // The host accepted the steer command. That is bridge/host evidence, not provider acceptance.
        evidence.noteDeliveryUnknown()
        return evidence
    }

    // MARK: Remote input dispatch evidence

    /// Captures the exact runtime target before any await. Throwing here is a proven no-handoff.
    private func captureDispatchTarget(
        session: AgentTabSession,
        dispatch: RemoteInputDispatch
    ) throws -> RemoteDispatchTarget {
        let controller: RemoteAgentSessionController
        do {
            controller = try self.controller(for: session)
        } catch {
            throw RemoteInputHandoffError(disposition: .notHandedOff, cause: .remote(error), evidence: nil)
        }
        guard let binding = session.remoteHost else {
            throw RemoteInputHandoffError(
                disposition: .notHandedOff,
                cause: .remote(RemoteClientError.protocolViolation("Session is not bound to a remote host.")),
                evidence: nil
            )
        }
        return RemoteDispatchTarget(
            tabID: session.tabID,
            controller: controller,
            hostID: binding.hostID,
            remoteSessionID: binding.normalizedRemoteSessionID,
            dispatch: dispatch
        )
    }

    /// Commits the delivery attempt (durable input) and revalidates the exact target after the await.
    /// A refused commit or a stale target never reaches the network; a stale target settles the same
    /// intent back to `queued` (proven pre-handoff).
    private func beginRemoteDispatch(
        _ target: RemoteDispatchTarget,
        session: AgentTabSession
    ) async throws -> AgentRecoveryDispatchEvidence {
        let evidence: AgentRecoveryDispatchEvidence
        let begun: Result<AgentRecoveryDispatchEvidence, AgentRecoveryAdmissionFailure> =
            switch target.dispatch.source {
            case let .input(input):
                await AgentRecoveryDispatchEvidence.begin(
                    session: session,
                    constituents: [input],
                    runAttemptID: nil,
                    authorization: target.dispatch.authorization
                )
            case let .existingIntent(intent):
                await AgentRecoveryDispatchEvidence.beginExistingIntent(
                    session: session,
                    intent: intent,
                    runAttemptID: nil
                )
            }
        switch begun {
        case let .success(begun):
            evidence = begun
        case let .failure(failure):
            Self.logger.notice("remote dispatch refused tab_id=\(target.tabID.uuidString, privacy: .public) failure=\(String(describing: failure), privacy: .public)")
            throw RemoteInputHandoffError(disposition: .notHandedOff, cause: .dispatchRefused(failure), evidence: nil)
        }
        // Final synchronous ownership check (R06): callers reach the network with no suspension after
        // this, so a lane retired or frozen for reset since the commit never hands off.
        guard isDispatchTargetCurrent(target, session: session),
              evidence.isValidForHandoff(in: session)
        else {
            evidence.noteNoHandoff(message: RemoteInputHandoffError.staleTargetMessage)
            Self.logger.notice("remote dispatch target went stale before handoff tab_id=\(target.tabID.uuidString, privacy: .public)")
            throw RemoteInputHandoffError(disposition: .notHandedOff, cause: .staleTarget, evidence: evidence)
        }
        return evidence
    }

    /// Synchronous freshness check: same live tab session, same controller, same host and remote
    /// session, and the admission authority the input was issued under.
    private func isDispatchTargetCurrent(_ target: RemoteDispatchTarget, session: AgentTabSession) -> Bool {
        guard isRuntimeTargetCurrent(target, session: session) else { return false }
        let durableBinding: AgentRecoveryLifecycleBinding? = switch target.dispatch.source {
        case let .input(input):
            input.queueReceipt?.intent.binding
        case let .existingIntent(intent):
            intent.binding
        }
        if let durableBinding {
            guard let lane = session.recoveryLane,
                  !lane.isRetired,
                  lane.binding == durableBinding
            else { return false }
        } else {
            guard session.recoveryAdmissionMode == .inactive else { return false }
        }
        return true
    }

    /// Same live tab session, same controller, and same host and remote session (no admission check).
    private func isRuntimeTargetCurrent(_ target: RemoteDispatchTarget, session: AgentTabSession) -> Bool {
        guard let viewModel, viewModel.sessions[target.tabID] === session else { return false }
        guard controllersByTabID[target.tabID] === target.controller else { return false }
        guard let binding = session.remoteHost,
              binding.hostID == target.hostID,
              binding.normalizedRemoteSessionID == target.remoteSessionID
        else { return false }
        return true
    }

    /// The request was handed to the remote bridge and failed without proof either way (the
    /// controller can throw after the host adopted the input, e.g. in post-response observation, and
    /// even start-target codes can follow a host-side retry). Never a retryable no-handoff.
    private static func ambiguousRemoteHandoff(
        _ error: Error,
        evidence: AgentRecoveryDispatchEvidence
    ) -> RemoteInputHandoffError {
        evidence.noteDeliveryUnknown()
        return RemoteInputHandoffError(disposition: .deliveryUnknown, cause: .remote(error), evidence: evidence)
    }

    func fork(
        session: AgentTabSession,
        upToClientItemID clientItemID: UUID,
        destinationAgent: String,
        destinationModelID: String,
        destinationEffort: String?
    ) async throws {
        guard let binding = session.remoteHost else {
            throw RemoteClientError.protocolViolation("Session is not bound to a remote host.")
        }
        guard let hostRecord = hostRecordProvider(binding.hostID) else {
            throw RemoteClientError.hostNotFound(binding.hostID)
        }
        guard let viewModel else {
            throw RemoteClientError.protocolViolation("Remote Agent Mode coordinator is not attached.")
        }
        let controller = try controller(for: session)
        let descriptor = try await controller.fork(
            upToClientItemID: clientItemID,
            destinationAgent: destinationAgent,
            destinationModelID: destinationModelID,
            destinationEffort: destinationEffort
        )
        let pickupKey = WorkspacePickupKey(
            hostID: binding.hostID,
            remoteSessionID: descriptor.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Treat an in-flight sidebar pickup of the same descriptor as "already exists":
        // the pickup path materializes and attaches it, and racing a second
        // materialization would double-create the local proxy tab.
        let alreadyExists = workspacePickupInFlightKeys.contains(pickupKey)
            || localSessionExists(
                hostID: binding.hostID,
                remoteSessionID: descriptor.sessionID
            )
        var materializedSession: AgentTabSession?
        if !alreadyExists {
            workspacePickupInFlightKeys.insert(pickupKey)
            defer { workspacePickupInFlightKeys.remove(pickupKey) }
            materializedSession = await viewModel.materializeRemoteWorkspaceSession(
                descriptor: descriptor,
                hostRecord: hostRecord
            )
        }
        if let materializedSession {
            // Mirror pickUpWorkspaceSession's host-name adoption so later host renames
            // of the forked session propagate to this client proxy.
            if let adoptedName = descriptor.name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !adoptedName.isEmpty
            {
                lastAdoptedHostNameByTabID[materializedSession.tabID] = AgentSession.validatedName(adoptedName)
            }
            // Attach immediately (mirrors pickUpWorkspaceSession): this is the only path
            // that subscribes the client to the forked session's host push events and arms
            // stale-recovery polling. Without it, a subsequent steer runs on the host while
            // the client never receives the response and stays frozen on the initial status.
            do {
                try await attachMaterializedRemoteWorkspaceSession(materializedSession)
            } catch {
                let description = Self.describe(
                    error,
                    workspaceName: viewModel.remoteWorkspaceCatalogContext(hostID: binding.hostID)?.workspaceName,
                    hostName: hostRecord.displayName
                )
                appendSystemMessage(
                    "Remote workspace session attach failed: \(description)",
                    tabID: materializedSession.tabID
                )
            }
        }
        await refreshWorkspaceSessionCatalogAfterSuccessfulStart(hostID: binding.hostID)
        guard alreadyExists || materializedSession != nil else {
            throw RemoteClientError.protocolViolation(
                "The host fork succeeded, but the returned session could not be opened on this client. Refresh the remote workspace sessions and open it manually."
            )
        }
    }

    func extractHandoff(
        session: AgentTabSession,
        upToClientItemID clientItemID: UUID,
        maxTranscriptItems: Int? = nil,
        maxToolArgsCharacters: Int? = nil
    ) async throws -> String {
        let controller = try controller(for: session)
        return try await controller.extractHandoff(
            upToClientItemID: clientItemID,
            maxTranscriptItems: maxTranscriptItems,
            maxToolArgsCharacters: maxToolArgsCharacters
        )
    }

    func canForkRemoteSession(session: AgentTabSession) -> Bool {
        guard let hostID = session.remoteHost?.hostID,
              catalogProvider(hostID) != nil
        else { return false }
        guard let supported = forkCapabilityByHostID[hostID] else {
            scheduleForkCapabilityProbe(for: session)
            return false
        }
        return supported
    }

    func hostRowID(
        for session: AgentTabSession,
        clientItemID: UUID
    ) -> UUID? {
        hostRowIDByClientItemIDByTabID[session.tabID]?[clientItemID]
    }

    func cancel(session: AgentTabSession) async throws {
        let controller = try controller(for: session)
        try await controller.cancel()
    }

    func submitApprovalDecision(
        session: AgentTabSession,
        interactionID: String,
        decision: AgentApprovalDecision
    ) {
        let restorable = optimisticallyClearPendingInteraction(session, interactionID: interactionID)
        let payload = RemoteInteractionResponsePayload.approval(decision: decision)
        submitResponse(session: session, interactionID: interactionID, payload: payload, restorable: restorable)
    }

    func submitAskUserResponse(
        session: AgentTabSession,
        interactionID: String,
        response: AgentAskUserResponse
    ) {
        let restorable = optimisticallyClearPendingInteraction(session, interactionID: interactionID)
        submitResponse(session: session, interactionID: interactionID, payload: .askUser(response), restorable: restorable)
    }

    func submitUserInputResponse(
        session: AgentTabSession,
        request: AgentRequestUserInputRequest,
        response: AgentRequestUserInputResponse
    ) {
        let interactionID = request.remoteInteractionID ?? request.id.uuidString
        let restorable = optimisticallyClearPendingInteraction(session, interactionID: interactionID)
        submitResponse(session: session, interactionID: interactionID, payload: .userInput(response), restorable: restorable)
    }

    func submitMCPElicitationResponse(
        session: AgentTabSession,
        request: AgentMCPElicitationRequest,
        response: AgentMCPElicitationResponse
    ) {
        let interactionID = request.remoteInteractionID ?? request.id.uuidString
        let restorable = optimisticallyClearPendingInteraction(session, interactionID: interactionID)
        submitResponse(session: session, interactionID: interactionID, payload: .mcpElicitation(response), restorable: restorable)
    }

    /// Whether a live attachment (controller + event task) currently delivers into `tabID`.
    func isAttached(tabID: UUID) -> Bool {
        controllersByTabID[tabID] != nil
    }

    @discardableResult
    private func advanceDeliveryGeneration(tabID: UUID) -> UInt64 {
        let next = (deliveryGenerationByTabID[tabID] ?? 0) &+ 1
        deliveryGenerationByTabID[tabID] = next
        return next
    }

    func stop(tabID: UUID) {
        let remoteBinding = viewModel?.sessions[tabID]?.remoteHost
        let storedDiscoveryKey = discoveryKeyByTabID.removeValue(forKey: tabID)
        let currentDiscoveryKey = viewModel?.sessions[tabID].flatMap { childDiscoveryKey(for: $0) }
        for key in Set([storedDiscoveryKey, currentDiscoveryKey].compactMap(\.self)) {
            cancelChildDiscovery(key: key)
        }
        eventTasksByTabID.removeValue(forKey: tabID)?.cancel()
        // Retire the attachment's delivery generation: an event captured by the stopped event task
        // (or any later delivery claiming it) is dropped by `handle(_:tabID:deliveryGeneration:)`.
        advanceDeliveryGeneration(tabID: tabID)
        clearAskUserStash(tabID: tabID)
        surfacedChannelReasonsByTabID.removeValue(forKey: tabID)
        hostProvidedRunningStatusTabIDs.remove(tabID)
        tabsWithSyntheticSettlements.remove(tabID)
        lastAdoptedHostNameByTabID.removeValue(forKey: tabID)
        startSessionNameByTabID.removeValue(forKey: tabID)
        if hostRowIDByClientItemIDByTabID.removeValue(forKey: tabID)?.isEmpty == false {
            viewModel?.syncRunInteractionUIState()
        }
        let controller = controllersByTabID.removeValue(forKey: tabID)
        if let hostID = hostIDByTabID.removeValue(forKey: tabID) {
            stopConnectionFanoutIfUnused(hostID: hostID)
        }
        if let controller {
            Task {
                await controller.unsubscribe()
                await controller.shutdown()
            }
        } else if let remoteBinding {
            do {
                let connection = try connectionManagerProvider().connection(for: remoteBinding.hostID)
                Task {
                    do {
                        try await connection.unsubscribe(sessionIDs: [remoteBinding.remoteSessionID])
                    } catch {
                        Self.logger.debug("remote unsubscribe failed host_id=\(remoteBinding.hostID, privacy: .public) session_id=\(remoteBinding.remoteSessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    }
                }
            } catch {
                Self.logger.debug("remote unsubscribe skipped host_id=\(remoteBinding.hostID, privacy: .public) session_id=\(remoteBinding.remoteSessionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func submitResponse(
        session: AgentTabSession,
        interactionID: String,
        payload: RemoteInteractionResponsePayload,
        restorable: RestorableInteractionState
    ) {
        do {
            let controller = try controller(for: session)
            Task { [weak self] in
                do {
                    // Same observation preflight as steer(): responding can resume a
                    // long-running turn, so a hard attach failure withholds the response
                    // and flows into the restorable-interaction recovery below.
                    if await !controller.hasAttachedObservation() {
                        try await controller.attachAndCatchUp()
                    }
                    try await controller.respond(interactionID: interactionID, payload: payload)
                } catch RemoteClientError.interactionAlreadyResolved {
                    self?.clearResolvedInteraction(tabID: session.tabID, interactionID: interactionID, resolvedBy: nil)
                } catch {
                    self?.appendSystemMessage("Remote response failed: \(Self.describe(error))", tabID: session.tabID)
                    await self?.recoverFromRespondFailure(tabID: session.tabID, restorable: restorable, controller: controller)
                }
            }
        } catch {
            appendSystemMessage("Remote response failed: \(Self.describe(error))", tabID: session.tabID)
            Task { await recoverFromRespondFailure(tabID: session.tabID, restorable: restorable, controller: nil) }
        }
    }

    private func controller(for session: AgentTabSession) throws -> RemoteAgentSessionController {
        if let existing = controllersByTabID[session.tabID] {
            return existing
        }
        guard let binding = session.remoteHost else {
            throw RemoteClientError.protocolViolation("Session is not bound to a remote host.")
        }
        let connectionManager = connectionManagerProvider()
        let connection = try connectionManager.connection(for: binding.hostID)
        let controller = RemoteAgentSessionController(
            binding: binding,
            connection: connection
        )
        controllersByTabID[session.tabID] = controller
        hostIDByTabID[session.tabID] = binding.hostID
        startEventTask(for: session.tabID, controller: controller)
        startConnectionFanoutIfNeeded(hostID: binding.hostID, connection: connection)
        return controller
    }

    private func startEventTask(for tabID: UUID, controller: RemoteAgentSessionController) {
        eventTasksByTabID[tabID]?.cancel()
        let deliveryGeneration = advanceDeliveryGeneration(tabID: tabID)
        eventTasksByTabID[tabID] = Task { [weak self] in
            for await event in controller.events {
                await self?.handle(event, tabID: tabID, deliveryGeneration: deliveryGeneration)
            }
        }
    }

    private func scheduleForkCapabilityProbe(for session: AgentTabSession) {
        guard let hostID = session.remoteHost?.hostID,
              forkCapabilityProbeTasksByHostID[hostID] == nil
        else { return }
        let controller: RemoteAgentSessionController
        do {
            controller = try self.controller(for: session)
        } catch {
            updateForkCapability(false, hostID: hostID)
            return
        }
        forkCapabilityProbeTasksByHostID[hostID] = Task { @MainActor [weak self] in
            let supported = await controller.supportsForkSessionFeature()
            guard !Task.isCancelled else { return }
            self?.forkCapabilityProbeTasksByHostID.removeValue(forKey: hostID)
            self?.updateForkCapability(supported, hostID: hostID)
        }
    }

    private func updateForkCapability(_ supported: Bool, hostID: String) {
        let previous = forkCapabilityByHostID.updateValue(supported, forKey: hostID)
        if previous != supported {
            viewModel?.syncRunInteractionUIState()
        }
    }

    private func startConnectionFanoutIfNeeded(hostID: String, connection: RemoteHostConnection) {
        guard connectionTasksByHostID[hostID] == nil else { return }
        let inbound = Task { [weak self] in
            // Frames before subscription are reconciled by the controller's attach-and-catch-up path.
            let frames = await connection.inboundFramesStream()
            for await frame in frames {
                guard let self else { return }
                await deliver(frame, hostID: hostID)
            }
        }
        let state = Task { [weak self] in
            let states = await connection.stateEventsStream()
            for await state in states {
                guard let self else { return }
                await deliver(state, hostID: hostID)
            }
        }
        connectionTasksByHostID[hostID] = HostConnectionTasks(inbound: inbound, state: state)
    }

    private func stopConnectionFanoutIfUnused(hostID: String) {
        guard !hostIDByTabID.values.contains(hostID) else { return }
        let tasks = connectionTasksByHostID.removeValue(forKey: hostID)
        tasks?.inbound.cancel()
        tasks?.state.cancel()
        forkCapabilityProbeTasksByHostID.removeValue(forKey: hostID)?.cancel()
        forkCapabilityByHostID.removeValue(forKey: hostID)
    }

    private func deliver(_ frame: RemoteServerFrame, hostID: String) async {
        let controllers = controllersByTabID.compactMap { tabID, controller in
            hostIDByTabID[tabID] == hostID ? controller : nil
        }
        guard !controllers.isEmpty else {
            Self.logger.notice("remote inbound frame dropped host_id=\(hostID, privacy: .public) type=\(frame.type, privacy: .public) session_id=\(frame.sessionID ?? "", privacy: .public) seq=\(frame.seq ?? 0) has_seq=\(frame.seq != nil) reason=no_matching_controller")
            return
        }
        for controller in controllers {
            await controller.handleInboundFrame(frame)
        }
    }

    private func deliver(_ state: RemoteHostConnection.State, hostID: String) async {
        #if DEBUG
            connectionStateDeliveryObserver?(hostID, state)
        #endif
        if case let .connected(scopes) = state {
            // Late coordinators receive a replayed connected state, so these refreshes must remain idempotent.
            workspaceSessionCatalogStore.invalidate(hostID: hostID)
            if scopes.contains("sessions:operate") {
                workspaceOpenEpisodes = workspaceOpenEpisodes.filter { $0.key.hostID != hostID }
            }
            viewModel?.refreshRemoteHostCatalogAfterConnect(hostID: hostID)
            if let session = viewModel?.sessions.values.first(where: { $0.remoteHost?.hostID == hostID }) {
                forkCapabilityByHostID.removeValue(forKey: hostID)
                forkCapabilityProbeTasksByHostID.removeValue(forKey: hostID)?.cancel()
                scheduleForkCapabilityProbe(for: session)
            }
        } else {
            forkCapabilityProbeTasksByHostID.removeValue(forKey: hostID)?.cancel()
            updateForkCapability(false, hostID: hostID)
        }
        let controllers = controllersByTabID.compactMap { tabID, controller in
            hostIDByTabID[tabID] == hostID ? controller : nil
        }
        for controller in controllers {
            await controller.handleConnectionState(state)
        }
    }

    /// Applies one remote event to the tab. `deliveryGeneration` is the generation captured by the
    /// delivering event task; a delivery from a retired attachment (generation advanced by a stop
    /// or a restart) is dropped so it can never mutate the tab after that attachment ended.
    private func handle(_ event: RemoteSessionEvent, tabID: UUID, deliveryGeneration: UInt64? = nil) {
        if let deliveryGeneration, deliveryGenerationByTabID[tabID] != deliveryGeneration {
            Self.logger.debug("remote event dropped tab_id=\(tabID.uuidString, privacy: .public) reason=retired_delivery_generation")
            return
        }
        guard let session = viewModel?.sessions[tabID] else { return }
        let shouldRefreshActivity = Self.shouldRefreshActivity(for: event)
        if shouldRefreshActivity {
            session.lastActivityAt = Date()
        }
        switch event {
        case let .transcriptRows(rows, removedIDs, hostRowIDByClientItemID):
            mirrorHostRowIDs(hostRowIDByClientItemID, tabID: tabID)
            let containsSpawnTool = Self.containsSpawnToolCall(rows)
            applyTranscriptRows(rows, removedIDs: removedIDs, to: session)
            if containsSpawnTool {
                requestChildSessionDiscovery(for: session, reason: "transcript_spawn")
            }
        case let .runState(runState, pendingInteraction, statusText):
            applyRunState(runState, pendingInteraction: pendingInteraction, statusText: statusText, to: session)
            if runState.isActive {
                requestFirstActiveChildSessionDiscovery(for: session, reason: "session_update")
            }
        case let .interactionResolved(interactionID, resolvedBy):
            clearResolvedInteraction(tabID: tabID, interactionID: interactionID, resolvedBy: resolvedBy)
        case .sessionExpired:
            hostProvidedRunningStatusTabIDs.remove(tabID)
            clearAskUserStash(tabID: tabID)
            session.runState = .failed
            clearPendingInteractions(session)
            appendSystemMessage("Remote session expired on host.", tabID: tabID)
        case let .terminal(status):
            let wasAlreadyTerminal = Self.isTerminalRunState(session.runState)
            applyTerminal(status: status, to: session)
            requestChildSessionDiscovery(for: session, reason: "terminal", immediate: !wasAlreadyTerminal)
        case let .channel(channelState):
            applyChannel(channelState, to: session)
        case let .systemMessage(message):
            appendSystemMessage(message, tabID: tabID)
        case let .metadata(agentKindRaw, modelRaw, reasoningEffortRaw, sessionName):
            if let agentKindRaw,
               let kind = AgentProviderKind(rawValue: agentKindRaw)
            {
                session.selectedAgent = kind
            }
            applyHostModelMetadata(
                agentKindRaw: agentKindRaw,
                modelRaw: modelRaw,
                reasoningEffortRaw: reasoningEffortRaw,
                to: session
            )
            adoptHostSessionNameIfAllowed(sessionName, for: session, tabID: tabID)
        case let .binding(binding):
            session.remoteHost = binding
        }
        if shouldRefreshActivity {
            updateSessionIndex(for: session)
        }
        session.isDirty = true
        viewModel?.reconcileInteractiveRunState(session)
        viewModel?.updateBindingsFromSession(session)
        viewModel?.requestUIRefresh(tabID: tabID, urgent: true)
        viewModel?.scheduleSave(for: tabID)
    }

    private func mirrorHostRowIDs(_ mappings: [UUID: UUID], tabID: UUID) {
        let previous = hostRowIDByClientItemIDByTabID[tabID] ?? [:]
        guard previous != mappings else { return }
        if mappings.isEmpty {
            hostRowIDByClientItemIDByTabID.removeValue(forKey: tabID)
        } else {
            hostRowIDByClientItemIDByTabID[tabID] = mappings
        }
        viewModel?.syncRunInteractionUIState()
    }

    private func applyTranscriptRows(
        _ rows: [AgentChatItem],
        removedIDs: [UUID] = [],
        to session: AgentTabSession
    ) {
        guard !rows.isEmpty || !removedIDs.isEmpty else { return }
        let remoteSessionID = session.remoteHost?.remoteSessionID ?? "remote"
        let projector = RemoteTranscriptProjector(remoteSessionID: remoteSessionID)
        let projectedUserTextKeys = Set(rows.filter { $0.kind == .user }.map { Self.normalizedTextKey($0.text) })
        let wasTerminal = Self.isTerminalRunState(session.runState)
        var settledCount = 0
        session.mutateItemsBatch { items in
            let removedIDSet = Set(removedIDs)
            if !removedIDSet.isEmpty {
                items.removeAll { removedIDSet.contains($0.id) }
            }
            let existingItemIDs = Set(items.map(\.id))
            let optimisticUserTimestampByText = Self.optimisticUserTimestampByText(
                in: items,
                pendingIDs: session.pendingRemoteOptimisticUserItemIDs,
                providerTextByItemID: session.pendingRemoteOptimisticProviderTextByItemID,
                projectedUserTextKeys: projectedUserTextKeys
            )
            var merged = projector.upserting(rows, into: items)
            if !projectedUserTextKeys.isEmpty, !session.pendingRemoteOptimisticUserItemIDs.isEmpty {
                merged = merged.map { item in
                    guard item.kind == .user,
                          !existingItemIDs.contains(item.id),
                          let optimisticTimestamp = optimisticUserTimestampByText[Self.normalizedTextKey(item.text)],
                          optimisticTimestamp > item.timestamp
                    else { return item }
                    return item.replacingTimestamp(optimisticTimestamp)
                }
                merged.removeAll { item in
                    item.kind == .user
                        && session.pendingRemoteOptimisticUserItemIDs.contains(item.id)
                        && projectedUserTextKeys.contains(Self.optimisticUserMatchKey(
                            for: item,
                            providerTextByItemID: session.pendingRemoteOptimisticProviderTextByItemID
                        ))
                }
                session.pendingRemoteOptimisticUserItemIDs = session.pendingRemoteOptimisticUserItemIDs.filter { id in
                    merged.contains { $0.id == id }
                }
                let pendingIDs = session.pendingRemoteOptimisticUserItemIDs
                session.pendingRemoteOptimisticProviderTextByItemID = session.pendingRemoteOptimisticProviderTextByItemID.filter {
                    pendingIDs.contains($0.key)
                }
                session.remoteResendPayloadsByItemID = session.remoteResendPayloadsByItemID.filter {
                    pendingIDs.contains($0.key)
                }
                session.remoteResendInFlightItemIDs.formIntersection(pendingIDs)
            }
            if wasTerminal {
                settledCount = Self.settleResultlessToolCalls(in: &merged, terminalRunState: session.runState)
            }
            items = merged
        }
        if settledCount > 0 {
            tabsWithSyntheticSettlements.insert(session.tabID)
        }
        logTranscriptRowsApplied(rows, removedIDs: removedIDs, remoteSessionID: remoteSessionID, tabID: session.tabID)
        if wasTerminal {
            viewModel?.ensureDerivedTranscriptCurrentForExport(tabID: session.tabID)
        }
        session.hasSentFirstMessage = session.items.contains { $0.kind == .user }
        session.lastUserMessageAt = session.items
            .filter { $0.kind == .user }
            .map(\.timestamp)
            .filter { $0 >= AgentSessionRecencySanity.syntheticTimestampFloor }
            .max() ?? session.lastUserMessageAt
    }

    /// Internal for draft-stash tests.
    func applyRunState(
        _ runState: AgentSessionRunState,
        pendingInteraction: RemotePendingInteraction?,
        statusText: String?,
        to session: AgentTabSession
    ) {
        let wasTerminal = Self.isTerminalRunState(session.runState)
        if let pendingInteraction {
            clearPendingInteractions(session, preserving: pendingInteraction.interactionID)
            switch pendingInteraction {
            case let .approval(interactionID, request):
                clearAskUserStash(tabID: session.tabID)
                if !Self.interactionMatches(
                    session.pendingApproval?.id,
                    remoteInteractionID: approvalRemoteInteractionID(session.pendingApproval),
                    interactionID: interactionID
                ) {
                    session.pendingApproval = request
                }
            case let .question(interactionID, pending):
                if !Self.interactionMatches(
                    session.pendingAskUser?.interaction.id,
                    remoteInteractionID: session.pendingAskUser?.interaction.remoteInteractionID,
                    interactionID: interactionID
                ) {
                    clearAskUserStashIfDifferent(tabID: session.tabID, interactionID: interactionID)
                    session.pendingAskUser = mergedPendingAskUser(tabID: session.tabID, interactionID: interactionID, pending: pending)
                } else {
                    clearAskUserStash(tabID: session.tabID, interactionID: interactionID)
                }
            case let .userInput(interactionID, request):
                clearAskUserStash(tabID: session.tabID)
                if !Self.interactionMatches(
                    session.pendingUserInputRequest?.id,
                    remoteInteractionID: session.pendingUserInputRequest?.remoteInteractionID,
                    interactionID: interactionID
                ) {
                    session.pendingUserInputRequest = request
                }
            case let .mcpElicitation(interactionID, request):
                clearAskUserStash(tabID: session.tabID)
                if !Self.interactionMatches(
                    session.pendingMCPElicitationRequest?.id,
                    remoteInteractionID: session.pendingMCPElicitationRequest?.remoteInteractionID,
                    interactionID: interactionID
                ) {
                    session.pendingMCPElicitationRequest = request
                }
            }
        } else {
            clearAskUserStash(tabID: session.tabID)
            clearPendingInteractions(session)
        }
        let shouldRevertSyntheticSettlements = runState.isActive
            && (wasTerminal || tabsWithSyntheticSettlements.contains(session.tabID))
        session.runState = runState
        if shouldRevertSyntheticSettlements {
            #if DEBUG
                syntheticSettlementRevertScanObserver?(session.tabID)
            #endif
            session.mutateItemsBatch { items in
                for index in items.indices where items[index].kind == .toolCall
                    && AgentToolResultPersistencePolicy.isSyntheticSettlementJSON(items[index].toolResultJSON)
                {
                    items[index].toolResultJSON = nil
                    items[index].toolIsError = nil
                }
            }
            tabsWithSyntheticSettlements.remove(session.tabID)
        }
        if runState == .running {
            if let statusText {
                session.setRunningStatus(statusText, source: .transport)
                hostProvidedRunningStatusTabIDs.insert(session.tabID)
            } else if !hostProvidedRunningStatusTabIDs.contains(session.tabID) {
                session.setRunningStatus(
                    "Running on \(session.remoteHost?.hostDisplayName ?? "remote host")…",
                    source: .transport
                )
            }
        }
    }

    private func applyTerminal(status: String, to session: AgentTabSession) {
        clearAskUserStash(tabID: session.tabID)
        clearPendingInteractions(session)
        switch status {
        case "completed":
            session.runState = .completed
        case "cancelled":
            session.runState = .cancelled
        case "expired", "failed":
            session.runState = .failed
        default:
            session.runState = .failed
        }
        session.setRunningStatus(nil, source: nil)
        hostProvidedRunningStatusTabIDs.remove(session.tabID)
        var settledCount = 0
        session.mutateItemsBatch { items in
            settledCount = Self.settleResultlessToolCalls(in: &items, terminalStatus: status)
        }
        if settledCount > 0 {
            tabsWithSyntheticSettlements.insert(session.tabID)
        }
    }

    private func requestFirstActiveChildSessionDiscovery(
        for session: AgentTabSession,
        reason: String
    ) {
        guard let context = childDiscoveryContext(for: session),
              controllersByTabID[session.tabID] != nil,
              activeRunStateChildDiscoveryKeys.insert(context.key).inserted
        else { return }
        requestChildSessionDiscovery(for: session, reason: reason)
    }

    private func requestChildSessionDiscovery(
        for session: AgentTabSession,
        reason _: String,
        immediate: Bool = false
    ) {
        #if DEBUG
            childDiscoveryRequestObserver?(session.tabID, immediate)
        #endif
        guard let context = childDiscoveryContext(for: session) else { return }
        guard let controller = controllersByTabID[session.tabID] else { return }
        recordDiscoveryKey(context.key, tabID: context.parentTabID)
        if childDiscoveryInFlightKeys.contains(context.key) {
            childDiscoveryPendingContextsByKey[context.key] = context
            if immediate {
                childDiscoveryImmediatePendingKeys.insert(context.key)
            }
            return
        }
        if !immediate,
           let lastStartedAt = lastChildDiscoveryStartedAtByKey[context.key]
        {
            let delay = childDiscoveryDebounceInterval - Date().timeIntervalSince(lastStartedAt)
            if delay > 0 {
                childDiscoveryPendingContextsByKey[context.key] = context
                guard childDiscoveryTasksByKey[context.key] == nil else { return }
                childDiscoveryTasksByKey[context.key] = Task { [weak self, key = context.key] in
                    let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
                    if nanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: nanoseconds)
                    }
                    guard !Task.isCancelled else { return }
                    await self?.startPendingChildDiscovery(key: key)
                }
                return
            }
        }
        if immediate {
            childDiscoveryTasksByKey.removeValue(forKey: context.key)?.cancel()
            childDiscoveryPendingContextsByKey.removeValue(forKey: context.key)
            childDiscoveryImmediatePendingKeys.remove(context.key)
        }
        startChildDiscovery(context: context, controller: controller)
    }

    private func startPendingChildDiscovery(key: String) {
        childDiscoveryTasksByKey.removeValue(forKey: key)
        childDiscoveryImmediatePendingKeys.remove(key)
        guard let pending = childDiscoveryPendingContextsByKey.removeValue(forKey: key),
              let controller = controllersByTabID[pending.parentTabID]
        else { return }
        startChildDiscovery(context: pending, controller: controller)
    }

    private func startChildDiscovery(
        context: RemoteChildDiscoveryContext,
        controller: RemoteAgentSessionController
    ) {
        lastChildDiscoveryStartedAtByKey[context.key] = Date()
        childDiscoveryInFlightKeys.insert(context.key)
        childDiscoveryTasksByKey[context.key]?.cancel()
        childDiscoveryTasksByKey[context.key] = Task { [weak self, controller, context] in
            do {
                let descriptors = try await controller.listChildSessions()
                await self?.completeChildDiscovery(context: context, descriptors: descriptors)
            } catch is CancellationError {
                self?.finishChildDiscovery(context: context)
            } catch {
                self?.failChildDiscovery(context: context, error: error)
            }
        }
    }

    private func completeChildDiscovery(
        context: RemoteChildDiscoveryContext,
        descriptors: [RemoteAgentSessionDescriptor]
    ) async {
        childDiscoveryTasksByKey.removeValue(forKey: context.key)
        // Discovery may resume after the parent tab was stopped (for example a run-location
        // switch): never materialize children or restart discovery for a torn-down parent.
        guard !Task.isCancelled, controllersByTabID[context.parentTabID] != nil else {
            finishChildDiscovery(context: context)
            return
        }
        for descriptor in descriptors {
            guard !Task.isCancelled, controllersByTabID[context.parentTabID] != nil else {
                finishChildDiscovery(context: context)
                return
            }
            await materializeRemoteChildSession(descriptor, context: context)
        }
        childDiscoveryInFlightKeys.remove(context.key)
        restartPendingChildDiscoveryIfNeeded(after: context)
    }

    private func failChildDiscovery(context: RemoteChildDiscoveryContext, error _: Error) {
        childDiscoveryTasksByKey.removeValue(forKey: context.key)
        childDiscoveryInFlightKeys.remove(context.key)
        restartPendingChildDiscoveryIfNeeded(after: context)
    }

    private func finishChildDiscovery(context: RemoteChildDiscoveryContext) {
        childDiscoveryTasksByKey.removeValue(forKey: context.key)
        childDiscoveryInFlightKeys.remove(context.key)
        childDiscoveryImmediatePendingKeys.remove(context.key)
        childDiscoveryPendingContextsByKey.removeValue(forKey: context.key)
    }

    private func restartPendingChildDiscoveryIfNeeded(after context: RemoteChildDiscoveryContext) {
        guard let pending = childDiscoveryPendingContextsByKey.removeValue(forKey: context.key),
              let controller = controllersByTabID[pending.parentTabID]
        else { return }
        if childDiscoveryImmediatePendingKeys.remove(context.key) != nil {
            startChildDiscovery(context: pending, controller: controller)
            return
        }
        let delay = childDiscoveryDebounceInterval - Date().timeIntervalSince(lastChildDiscoveryStartedAtByKey[context.key] ?? .distantPast)
        if delay > 0 {
            childDiscoveryPendingContextsByKey[context.key] = pending
            guard childDiscoveryTasksByKey[context.key] == nil else { return }
            childDiscoveryTasksByKey[context.key] = Task { [weak self, key = context.key] in
                let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
                if nanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
                guard !Task.isCancelled else { return }
                await self?.startPendingChildDiscovery(key: key)
            }
            return
        }
        startChildDiscovery(context: pending, controller: controller)
    }

    private func materializeRemoteChildSession(
        _ descriptor: RemoteAgentSessionDescriptor,
        context: RemoteChildDiscoveryContext
    ) async {
        let childRemoteSessionID = descriptor.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !childRemoteSessionID.isEmpty,
              childRemoteSessionID != context.parentRemoteSessionID,
              descriptor.parentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) == context.parentRemoteSessionID,
              !isRemoteSessionMaterialized(hostID: context.hostBinding.hostID, remoteSessionID: childRemoteSessionID)
        else { return }
        guard let viewModel,
              let parentSession = viewModel.sessions[context.parentTabID]
        else { return }
        guard let childSession = await viewModel.materializeRemoteChildSession(
            descriptor,
            parentSession: parentSession,
            parentRemoteHost: context.hostBinding
        ) else {
            reportChildMaterializationFailureIfNeeded(
                childRemoteSessionID: childRemoteSessionID,
                context: context
            )
            return
        }
        clearReportedChildMaterializationFailure(
            childRemoteSessionID: childRemoteSessionID,
            discoveryKey: context.key
        )
        if let adoptedName = descriptor.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !adoptedName.isEmpty
        {
            lastAdoptedHostNameByTabID[childSession.tabID] = AgentSession.validatedName(adoptedName)
        }
        do {
            try await attachMaterializedRemoteChildSession(childSession)
        } catch {
            appendSystemMessage("Remote child session attach failed: \(Self.describe(error))", tabID: context.parentTabID)
        }
    }

    private func attachMaterializedRemoteChildSession(_ session: AgentTabSession) async throws {
        #if DEBUG
            if let materializedRemoteChildAttachHandler {
                try await materializedRemoteChildAttachHandler(session)
                return
            }
        #endif
        let controller = try controller(for: session)
        try await controller.attachAndCatchUp()
    }

    private func childDiscoveryContext(for session: AgentTabSession) -> RemoteChildDiscoveryContext? {
        guard let remoteHost = session.remoteHost,
              session.activeAgentSessionID != nil
        else { return nil }
        let parentRemoteSessionID = remoteHost.remoteSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parentRemoteSessionID.isEmpty else { return nil }
        return RemoteChildDiscoveryContext(
            key: childDiscoveryKey(hostID: remoteHost.hostID, remoteSessionID: parentRemoteSessionID),
            parentTabID: session.tabID,
            parentRemoteSessionID: parentRemoteSessionID,
            hostBinding: remoteHost
        )
    }

    private func childDiscoveryKey(for session: AgentTabSession) -> String? {
        guard let remoteHost = session.remoteHost else { return nil }
        let parentRemoteSessionID = remoteHost.remoteSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parentRemoteSessionID.isEmpty else { return nil }
        return childDiscoveryKey(hostID: remoteHost.hostID, remoteSessionID: parentRemoteSessionID)
    }

    private func childDiscoveryKey(hostID: String, remoteSessionID: String) -> String {
        "\(hostID)|\(remoteSessionID)"
    }

    private func recordDiscoveryKey(_ key: String, tabID: UUID) {
        if let previousKey = discoveryKeyByTabID[tabID], previousKey != key {
            cancelChildDiscovery(key: previousKey)
        }
        discoveryKeyByTabID[tabID] = key
    }

    private func cancelChildDiscovery(key: String) {
        childDiscoveryTasksByKey.removeValue(forKey: key)?.cancel()
        childDiscoveryInFlightKeys.remove(key)
        activeRunStateChildDiscoveryKeys.remove(key)
        childDiscoveryImmediatePendingKeys.remove(key)
        childDiscoveryPendingContextsByKey.removeValue(forKey: key)
        lastChildDiscoveryStartedAtByKey.removeValue(forKey: key)
        reportedChildMaterializationFailuresByDiscoveryKey.removeValue(forKey: key)
        discoveryKeyByTabID = discoveryKeyByTabID.filter { $0.value != key }
    }

    private func reportChildMaterializationFailureIfNeeded(
        childRemoteSessionID: String,
        context: RemoteChildDiscoveryContext
    ) {
        var reported = reportedChildMaterializationFailuresByDiscoveryKey[context.key, default: []]
        if reported.insert(childRemoteSessionID).inserted {
            reportedChildMaterializationFailuresByDiscoveryKey[context.key] = reported
            appendSystemMessage(
                "Remote child session materialization failed for '\(childRemoteSessionID)'.",
                tabID: context.parentTabID
            )
        } else {
            Self.logger.debug("remote child materialization failure already reported discovery_key=\(context.key, privacy: .public) child_session_id=\(childRemoteSessionID, privacy: .public)")
        }
    }

    private func clearReportedChildMaterializationFailure(
        childRemoteSessionID: String,
        discoveryKey: String
    ) {
        guard var reported = reportedChildMaterializationFailuresByDiscoveryKey[discoveryKey] else { return }
        reported.remove(childRemoteSessionID)
        if reported.isEmpty {
            reportedChildMaterializationFailuresByDiscoveryKey.removeValue(forKey: discoveryKey)
        } else {
            reportedChildMaterializationFailuresByDiscoveryKey[discoveryKey] = reported
        }
    }

    func cachedWorkspaceSessionCatalogState(
        hostID: String,
        clientWorkspaceID: UUID
    ) -> RemoteWorkspaceSessionCatalogStore.State? {
        workspaceSessionCatalogStore.cachedState(hostID: hostID, clientWorkspaceID: clientWorkspaceID)
    }

    func fetchWorkspaceSessionCatalog(
        hostID: String,
        clientWorkspaceID: UUID,
        workspaceName: String,
        forceRefresh: Bool
    ) async -> RemoteWorkspaceSessionCatalogStore.State {
        await workspaceSessionCatalogStore.fetch(
            hostID: hostID,
            clientWorkspaceID: clientWorkspaceID,
            workspaceName: workspaceName,
            forceRefresh: forceRefresh
        )
    }

    func invalidateWorkspaceSessionCatalog(hostID: String, clientWorkspaceID: UUID) {
        workspaceSessionCatalogStore.invalidate(hostID: hostID, clientWorkspaceID: clientWorkspaceID)
    }

    func workspaceOpenEpisodeState(
        hostID: String,
        clientWorkspaceID: UUID
    ) -> WorkspaceOpenEpisodeState? {
        workspaceOpenEpisodes[WorkspaceOpenEpisodeKey(
            hostID: hostID,
            clientWorkspaceID: clientWorkspaceID
        )]
    }

    func resetWorkspaceOpenEpisode(hostID: String, clientWorkspaceID: UUID) {
        workspaceOpenEpisodes.removeValue(forKey: WorkspaceOpenEpisodeKey(
            hostID: hostID,
            clientWorkspaceID: clientWorkspaceID
        ))
    }

    func autoOpenWorkspaceIfNeeded(
        hostRecord: PairedHostRecord,
        clientWorkspaceID: UUID,
        workspaceName: String
    ) async {
        guard hostRecord.grantedScopes.contains("sessions:operate") else { return }
        let key = WorkspaceOpenEpisodeKey(hostID: hostRecord.id, clientWorkspaceID: clientWorkspaceID)
        guard workspaceOpenEpisodes[key] == nil else { return }

        workspaceOpenEpisodes[key] = .opening
        viewModel?.publishRemoteWorkspaceSidebarChange()
        let learnedID = workspaceSessionCatalogStore.learnedHostWorkspaceID(
            hostID: hostRecord.id,
            clientWorkspaceID: clientWorkspaceID
        )
        do {
            do {
                try await openWorkspace(
                    hostID: hostRecord.id,
                    workspaceID: learnedID,
                    workspaceName: workspaceName
                )
            } catch {
                let code = (error as? RemoteClientError)?.commandError?.code
                guard learnedID != nil, code == "workspace_not_found" else { throw error }
                try await openWorkspace(
                    hostID: hostRecord.id,
                    workspaceID: nil,
                    workspaceName: workspaceName
                )
            }
            workspaceSessionCatalogStore.invalidate(hostID: hostRecord.id)
            let refreshedState = await workspaceSessionCatalogStore.fetch(
                hostID: hostRecord.id,
                clientWorkspaceID: clientWorkspaceID,
                workspaceName: workspaceName,
                forceRefresh: true
            )
            switch refreshedState {
            case .loaded:
                workspaceOpenEpisodes.removeValue(forKey: key)
            case .workspaceNotOpen:
                workspaceOpenEpisodes[key] = .failed(
                    "Workspace '\(workspaceName)' is still not open on \(hostRecord.displayName). Try again."
                )
            case .unsupported:
                workspaceOpenEpisodes[key] = .failed(
                    "\(hostRecord.displayName) doesn't support workspace browsing (update RepoPrompt on the host)."
                )
            case let .error(message):
                workspaceOpenEpisodes[key] = .failed(message)
            }
        } catch {
            workspaceOpenEpisodes[key] = .failed(Self.describe(
                error,
                workspaceName: workspaceName,
                hostName: hostRecord.displayName
            ))
        }
        viewModel?.publishRemoteWorkspaceSidebarChange()
    }

    func openWorkspaceForStartRecovery(
        hostID: String,
        workspaceName: String
    ) async throws {
        try await openWorkspace(
            hostID: hostID,
            workspaceID: nil,
            workspaceName: workspaceName
        )
        workspaceSessionCatalogStore.invalidate(hostID: hostID)
    }

    private func openWorkspace(
        hostID: String,
        workspaceID: String?,
        workspaceName: String
    ) async throws {
        var payload: [String: JSONValue] = ["workspace_name": .string(workspaceName)]
        if let workspaceID {
            payload["workspace_id"] = .string(workspaceID)
        }
        let connection = try workspaceOpenConnectionProvider(hostID)
        _ = try await connection.command(
            RemoteClientFrame(
                type: "open_workspace",
                requestID: "open-workspace-\(UUID().uuidString.lowercased())",
                payload: .object(payload)
            ),
            timeout: RemoteHostConnection.commandTimeout
        )
    }

    /// Materializes a client projection of a host-authoritative workspace session.
    /// The host remains the execution authority; v1 intentionally adds no locking.
    @discardableResult
    func pickUpWorkspaceSession(
        descriptor: RemoteAgentSessionDescriptor,
        hostRecord: PairedHostRecord
    ) async -> AgentTabSession? {
        let remoteSessionID = descriptor.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteSessionID.isEmpty else { return nil }
        let key = WorkspacePickupKey(hostID: hostRecord.id, remoteSessionID: remoteSessionID)
        guard !workspacePickupInFlightKeys.contains(key),
              !localSessionExists(hostID: hostRecord.id, remoteSessionID: remoteSessionID)
        else { return nil }

        workspacePickupInFlightKeys.insert(key)
        defer { workspacePickupInFlightKeys.remove(key) }
        guard let viewModel,
              let session = await viewModel.materializeRemoteWorkspaceSession(
                  descriptor: descriptor,
                  hostRecord: hostRecord
              )
        else { return nil }

        if let adoptedName = descriptor.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !adoptedName.isEmpty
        {
            lastAdoptedHostNameByTabID[session.tabID] = AgentSession.validatedName(adoptedName)
        }
        do {
            try await attachMaterializedRemoteWorkspaceSession(session)
        } catch {
            let description = Self.describe(
                error,
                workspaceName: viewModel.remoteWorkspaceCatalogContext(hostID: hostRecord.id)?.workspaceName,
                hostName: hostRecord.displayName
            )
            appendSystemMessage(
                "Remote workspace session attach failed: \(description)",
                tabID: session.tabID
            )
        }
        return session
    }

    private func attachMaterializedRemoteWorkspaceSession(_ session: AgentTabSession) async throws {
        #if DEBUG
            if let materializedRemoteWorkspaceAttachHandler {
                try await materializedRemoteWorkspaceAttachHandler(session)
                return
            }
        #endif
        let controller = try controller(for: session)
        try await controller.attachAndCatchUp()
    }

    private func refreshWorkspaceSessionCatalogAfterSuccessfulStart(hostID: String) async {
        guard let context = viewModel?.remoteWorkspaceCatalogContext(hostID: hostID) else { return }
        _ = await fetchWorkspaceSessionCatalog(
            hostID: hostID,
            clientWorkspaceID: context.clientWorkspaceID,
            workspaceName: context.workspaceName,
            forceRefresh: true
        )
        viewModel?.publishRemoteWorkspaceSidebarChange()
    }

    func localSessionExists(hostID: String, remoteSessionID: String) -> Bool {
        let normalizedRemoteSessionID = remoteSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemoteSessionID.isEmpty else { return false }
        if isRemoteSessionMaterialized(hostID: hostID, remoteSessionID: normalizedRemoteSessionID) {
            return true
        }
        return viewModel?.ownerValidatedSessionIndex.values.contains { entry in
            entry.remoteHostID == hostID && entry.remoteSessionID == normalizedRemoteSessionID
        } == true
    }

    private func isRemoteSessionMaterialized(hostID: String, remoteSessionID: String) -> Bool {
        viewModel?.sessions.values.contains { session in
            session.remoteHost?.hostID == hostID
                && session.remoteHost?.normalizedRemoteSessionID == remoteSessionID
        } == true
    }

    private func logTranscriptRowsApplied(
        _ rows: [AgentChatItem],
        removedIDs: [UUID],
        remoteSessionID: String,
        tabID: UUID
    ) {
        let lastAssistant = rows.last { $0.kind == .assistant }
        let lastAssistantIDSuffix = lastAssistant.map { String($0.id.uuidString.suffix(12)) } ?? "none"
        let lastAssistantTextCount = lastAssistant?.text.count ?? -1
        Self.logger.log("remote transcript apply session_id=\(remoteSessionID, privacy: .public) tab_id=\(tabID.uuidString, privacy: .public) applied_row_count=\(rows.count) removed_row_count=\(removedIDs.count) last_assistant_id_suffix=\(lastAssistantIDSuffix, privacy: .public) last_assistant_text_count=\(lastAssistantTextCount)")
    }

    private static func optimisticUserTimestampByText(
        in items: [AgentChatItem],
        pendingIDs: Set<UUID>,
        providerTextByItemID: [UUID: String],
        projectedUserTextKeys: Set<String>
    ) -> [String: Date] {
        guard !pendingIDs.isEmpty, !projectedUserTextKeys.isEmpty else { return [:] }
        var timestamps: [String: Date] = [:]
        for item in items where item.kind == .user && pendingIDs.contains(item.id) {
            let key = optimisticUserMatchKey(for: item, providerTextByItemID: providerTextByItemID)
            guard projectedUserTextKeys.contains(key) else { continue }
            if let existing = timestamps[key] {
                timestamps[key] = max(existing, item.timestamp)
            } else {
                timestamps[key] = item.timestamp
            }
        }
        return timestamps
    }

    private static func optimisticUserMatchKey(
        for item: AgentChatItem,
        providerTextByItemID: [UUID: String]
    ) -> String {
        normalizedTextKey(providerTextByItemID[item.id] ?? item.text)
    }

    private static func containsSpawnToolCall(_ rows: [AgentChatItem]) -> Bool {
        rows.contains { row in
            guard row.kind == .toolCall,
                  let toolName = row.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            else { return false }
            return toolName == "agent_run" || toolName == "agent_manage"
        }
    }

    private static func settleResultlessToolCalls(
        in items: inout [AgentChatItem],
        terminalRunState: AgentSessionRunState
    ) -> Int {
        settleResultlessToolCalls(in: &items, terminalSettlement: terminalSettlement(for: terminalRunState))
    }

    private static func settleResultlessToolCalls(
        in items: inout [AgentChatItem],
        terminalStatus: String
    ) -> Int {
        settleResultlessToolCalls(in: &items, terminalSettlement: terminalSettlement(for: terminalStatus))
    }

    private static func settleResultlessToolCalls(
        in items: inout [AgentChatItem],
        terminalSettlement: (statusWord: String, isError: Bool)
    ) -> Int {
        var settledCount = 0
        for index in items.indices where items[index].kind == .toolCall
            && items[index].toolResultJSON == nil
            && items[index].toolIsError == nil
        {
            items[index].toolResultJSON = AgentToolResultPersistencePolicy.syntheticSettlementResultJSON(
                statusWord: terminalSettlement.statusWord,
                normalizedToolName: items[index].toolName
            )
            items[index].toolIsError = terminalSettlement.isError
            settledCount += 1
        }
        return settledCount
    }

    private static func terminalSettlement(for runState: AgentSessionRunState) -> (statusWord: String, isError: Bool) {
        switch runState {
        case .completed:
            ("completed", false)
        case .cancelled:
            ("cancelled", true)
        case .failed:
            ("failed", true)
        case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
            ("failed", true)
        }
    }

    private static func terminalSettlement(for status: String) -> (statusWord: String, isError: Bool) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed":
            ("completed", false)
        case "cancelled", "canceled":
            ("cancelled", true)
        case "expired", "failed":
            ("failed", true)
        default:
            ("failed", true)
        }
    }

    private static func isTerminalRunState(_ runState: AgentSessionRunState) -> Bool {
        runState == .completed || runState == .cancelled || runState == .failed
    }

    private func applyChannel(_ state: RemoteChannelState, to session: AgentTabSession) {
        switch state.kind {
        case .connected:
            let hadSurfacedDegradation = !(surfacedChannelReasonsByTabID[session.tabID] ?? []).isEmpty
            surfacedChannelReasonsByTabID[session.tabID] = []
            if hadSurfacedDegradation {
                appendSystemMessage("Remote channel restored.", to: session)
            }
            if session.runState.isActive {
                // This intentionally surfaces the channel recovery over any host status_text label.
                // While hostProvidedRunningStatusTabIDs remains set, later nil-status running frames
                // keep this label until the host sends the next non-empty status_text.
                session.setRunningStatus("Connected to \(session.remoteHost?.hostDisplayName ?? "remote host")", source: .transport)
            }
        case let .degraded(reason):
            let displayReason = Self.displayChannelReason(reason)
            session.setRunningStatus("Remote reconnecting (\(displayReason))…", source: .reconnect)
            surfaceChannelReasonIfNeeded(displayReason, to: session)
        case .revoked:
            surfacedChannelReasonsByTabID.removeValue(forKey: session.tabID)
            hostProvidedRunningStatusTabIDs.remove(session.tabID)
            clearAskUserStash(tabID: session.tabID)
            session.runState = .failed
            clearPendingInteractions(session)
            appendSystemMessage("Remote host revoked this device. Forget and pair again to restore access.", to: session)
        }
    }

    private func applyHostModelMetadata(
        agentKindRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        to session: AgentTabSession
    ) {
        guard let model = Self.normalizedMetadataString(modelRaw) else { return }
        let hostID = session.remoteHost?.hostID
        let catalog = hostID.flatMap { catalogProvider($0) }
        if catalog == nil, let hostID {
            // Best-effort self-heal for the cold-cache case. While a *degraded* entry
            // sits in the cache (20s TTL), this call is a no-op (its guard checks
            // cachedCatalog == nil), so mapping stays unavailable until TTL expiry or
            // refreshRemoteHostCatalogAfterConnect; the no-clobber path below keeps the
            // selection safe for that window.
            viewModel?.loadRemoteHostCatalogIfNeeded(hostID: hostID)
        }
        let mapped = catalog?.resolveCompoundSelection(
            agentIDRaw: agentKindRaw,
            baseModelRaw: model,
            effortRaw: reasoningEffortRaw
        )
        if let mapped {
            session.selectedModelRaw = mapped.modelID
            session.selectedReasoningEffortRaw = mapped.effort
            return
        }

        if RemoteHostAgentCatalog.agentKind(forModelID: session.selectedModelRaw) != nil {
            // Residual risk by design: if a structured host echoes a model outside its catalog,
            // keep the client's compound-shaped selection rather than clobbering the picker.
            Self.logger.debug("metadata echo unmappable; kept compound selection")
            return
        }

        session.selectedModelRaw = model
        session.selectedReasoningEffortRaw = reasoningEffortRaw
    }

    private func optimisticallyClearPendingInteraction(
        _ session: AgentTabSession,
        interactionID: String
    ) -> RestorableInteractionState {
        let restorable = RestorableInteractionState(
            interactionID: interactionID,
            priorRunState: session.runState,
            pendingApproval: session.pendingApproval,
            pendingAskUser: session.pendingAskUser,
            pendingUserInputRequest: session.pendingUserInputRequest,
            pendingMCPElicitationRequest: session.pendingMCPElicitationRequest
        )
        clearPendingInteractions(session, matching: interactionID)
        session.runState = .running
        session.setRunningStatus(Self.sendingResponseStatusPrefix + (session.remoteHost?.hostDisplayName ?? "remote host") + "…", source: .transport)
        viewModel?.reconcileInteractiveRunState(session)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        return restorable
    }

    private func stashAskUserStateIfNeeded(tabID: UUID, restorable: RestorableInteractionState) {
        guard let pendingAskUser = restorable.pendingAskUser else { return }
        // The host owns the authoritative ask_user timeout. If a re-sync re-applies
        // the question, preserving drafts is more important than restarting the
        // client-side countdown from the original timestamps.
        stashedAskUserStateByTabID[tabID] = StashedAskUserState(
            interactionID: restorable.interactionID,
            draftsByQuestionID: pendingAskUser.draftsByQuestionID,
            currentQuestionIndex: pendingAskUser.currentQuestionIndex
        )
    }

    private func mergedPendingAskUser(
        tabID: UUID,
        interactionID: String,
        pending: AgentAskUserPendingState
    ) -> AgentAskUserPendingState {
        guard let stash = stashedAskUserStateByTabID[tabID],
              stash.interactionID == interactionID,
              pending.draftsByQuestionID.values.allSatisfy({ !$0.hasContent })
        else { return pending }

        var merged = pending
        let questionIDs = Set(pending.interaction.questions.map(\.id))
        for (questionID, draft) in stash.draftsByQuestionID where questionIDs.contains(questionID) {
            merged.draftsByQuestionID[questionID] = draft
        }
        if pending.interaction.questions.isEmpty {
            merged.currentQuestionIndex = 0
        } else {
            merged.currentQuestionIndex = min(max(stash.currentQuestionIndex, 0), pending.interaction.questions.count - 1)
        }
        clearAskUserStash(tabID: tabID, interactionID: interactionID)
        return merged
    }

    private func clearAskUserStashIfDifferent(tabID: UUID, interactionID: String) {
        guard let stash = stashedAskUserStateByTabID[tabID], stash.interactionID != interactionID else { return }
        stashedAskUserStateByTabID.removeValue(forKey: tabID)
    }

    private func clearAskUserStash(tabID: UUID, interactionID: String? = nil) {
        guard let interactionID else {
            stashedAskUserStateByTabID.removeValue(forKey: tabID)
            return
        }
        guard stashedAskUserStateByTabID[tabID]?.interactionID == interactionID else { return }
        stashedAskUserStateByTabID.removeValue(forKey: tabID)
    }

    func recoverFromRespondFailure(
        tabID: UUID,
        restorable: RestorableInteractionState,
        controller: RemoteAgentSessionController?
    ) async {
        guard let session = viewModel?.sessions[tabID] else { return }
        stashAskUserStateIfNeeded(tabID: tabID, restorable: restorable)
        session.setRunningStatus(nil, source: nil)
        hostProvidedRunningStatusTabIDs.remove(tabID)

        if let controller {
            do {
                try await controller.attachAndCatchUp()
                return
            } catch {
                // Fall through to local restore.
            }
        }

        // Offline restore can briefly re-surface a concurrently resolved card; the next
        // sync or interaction_resolved frame clears it through the normal remote paths.
        guard let refetchedSession = viewModel?.sessions[tabID], refetchedSession.runState == .running else { return }
        if refetchedSession.pendingApproval == nil, let pendingApproval = restorable.pendingApproval {
            refetchedSession.pendingApproval = pendingApproval
        }
        if refetchedSession.pendingAskUser == nil, let pendingAskUser = restorable.pendingAskUser {
            clearAskUserStash(tabID: tabID, interactionID: restorable.interactionID)
            refetchedSession.pendingAskUser = pendingAskUser
        }
        if refetchedSession.pendingUserInputRequest == nil, let pendingUserInputRequest = restorable.pendingUserInputRequest {
            refetchedSession.pendingUserInputRequest = pendingUserInputRequest
        }
        if refetchedSession.pendingMCPElicitationRequest == nil, let pendingMCPElicitationRequest = restorable.pendingMCPElicitationRequest {
            refetchedSession.pendingMCPElicitationRequest = pendingMCPElicitationRequest
        }
        refetchedSession.runState = restorable.priorRunState
        viewModel?.reconcileInteractiveRunState(refetchedSession)
        viewModel?.requestUIRefresh(tabID: tabID, urgent: true)
    }

    /// Internal for respond-recovery tests.
    func clearResolvedInteraction(tabID: UUID, interactionID: String, resolvedBy _: String?) {
        guard let session = viewModel?.sessions[tabID] else { return }
        clearAskUserStash(tabID: tabID, interactionID: interactionID)
        clearPendingInteractions(session, matching: interactionID)
        if session.runningStatusSource == .transport,
           session.runningStatusText?.hasPrefix(Self.sendingResponseStatusPrefix) == true
        {
            session.setRunningStatus(nil, source: nil)
            hostProvidedRunningStatusTabIDs.remove(tabID)
        }
        viewModel?.reconcileInteractiveRunState(session)
        viewModel?.requestUIRefresh(tabID: tabID, urgent: true)
    }

    private func clearPendingInteractions(
        _ session: AgentTabSession,
        matching interactionID: String? = nil,
        preserving preservedInteractionID: String? = nil
    ) {
        func shouldClear(_ id: UUID?, remoteInteractionID: String? = nil) -> Bool {
            if let preservedInteractionID,
               Self.interactionMatches(
                   id,
                   remoteInteractionID: remoteInteractionID,
                   interactionID: preservedInteractionID
               )
            {
                return false
            }
            guard let interactionID else { return true }
            return Self.interactionMatches(id, remoteInteractionID: remoteInteractionID, interactionID: interactionID)
        }
        let approvalRemoteID = approvalRemoteInteractionID(session.pendingApproval)
        if shouldClear(session.pendingApproval?.id, remoteInteractionID: approvalRemoteID) { session.pendingApproval = nil }
        if shouldClear(session.pendingAskUser?.interaction.id, remoteInteractionID: session.pendingAskUser?.interaction.remoteInteractionID) { session.pendingAskUser = nil }
        if shouldClear(session.pendingUserInputRequest?.id, remoteInteractionID: session.pendingUserInputRequest?.remoteInteractionID) { session.pendingUserInputRequest = nil }
        if shouldClear(session.pendingMCPElicitationRequest?.id, remoteInteractionID: session.pendingMCPElicitationRequest?.remoteInteractionID) { session.pendingMCPElicitationRequest = nil }
        if interactionID == nil {
            session.pendingPermissionsRequest = nil
            session.queuedUserInputRequests.removeAll()
            session.queuedMCPElicitationRequests.removeAll()
        }
    }

    private func surfaceChannelReasonIfNeeded(_ reason: String, to session: AgentTabSession) {
        var reasons = surfacedChannelReasonsByTabID[session.tabID, default: []]
        guard reasons.insert(reason).inserted else { return }
        surfacedChannelReasonsByTabID[session.tabID] = reasons
        appendSystemMessage("Remote channel degraded: \(reason). Reconnecting…", to: session)
    }

    private func recordStartSessionName(
        _ sessionName: String?,
        tabID: UUID,
        allowHostSessionNameAdoptionFromStartName: Bool
    ) {
        guard allowHostSessionNameAdoptionFromStartName,
              let sessionName
        else { return }
        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startSessionNameByTabID[tabID] = AgentSession.validatedName(trimmed)
    }

    private func adoptHostSessionNameIfAllowed(
        _ sessionName: String?,
        for session: AgentTabSession,
        tabID: UUID
    ) {
        guard session.remoteHost != nil,
              let viewModel,
              let sessionName
        else { return }
        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hostName = AgentSession.validatedName(trimmed)
        guard !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let currentName = viewModel.resolvedSessionDisplayName(for: tabID)
        guard hostName != currentName else { return }

        let shouldAdopt = AgentSessionTitleNaming.isDefaultSessionTitle(currentName)
            || lastAdoptedHostNameByTabID[tabID] == currentName
            || startSessionNameByTabID[tabID] == currentName
        guard shouldAdopt else { return }

        viewModel.renameSession(tabID: tabID, to: hostName)
        lastAdoptedHostNameByTabID[tabID] = hostName
    }

    private func appendSystemMessage(_ message: String, tabID: UUID) {
        guard let session = viewModel?.sessions[tabID] else { return }
        appendSystemMessage(message, to: session)
    }

    private func appendSystemMessage(_ message: String, to session: AgentTabSession) {
        session.appendItem(.system(message))
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        viewModel?.scheduleSave(for: session.tabID)
    }

    private func updateSessionIndex(for session: AgentTabSession) {
        guard let viewModel,
              let sessionID = session.activeAgentSessionID,
              let remoteHost = session.remoteHost
        else { return }
        viewModel.upsertSessionIndex(
            sessionID: sessionID,
            tabID: session.tabID,
            name: viewModel.resolvedSessionDisplayName(for: session.tabID),
            lastUserMessageAt: session.lastUserMessageAt,
            savedAt: session.lastActivityAt,
            lastRunStateRaw: session.runState.rawValue,
            itemCount: max(session.transcriptCanonicalVisibleRowCount, session.items.count),
            agentKindRaw: session.selectedAgent.rawValue,
            agentModelRaw: session.selectedModelRaw,
            agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
            autoEditEnabled: session.autoEditEnabled,
            parentSessionID: session.parentSessionID,
            isMCPOriginated: session.isMCPOriginated,
            origin: session.origin,
            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
            remoteHostID: remoteHost.hostID,
            remoteHostName: remoteHost.hostDisplayName,
            remoteSessionID: remoteHost.normalizedRemoteSessionID,
            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
        )
    }

    private static func normalizedTextKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldRefreshActivity(for event: RemoteSessionEvent) -> Bool {
        switch event {
        case let .transcriptRows(items, removedIDs, _):
            !items.isEmpty || !removedIDs.isEmpty
        case .runState, .terminal, .metadata:
            true
        case .interactionResolved, .sessionExpired, .channel, .systemMessage, .binding:
            false
        }
    }

    private static func displayChannelReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "channel_closing" : trimmed
    }

    private static func normalizedMetadataString(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func interactionMatches(
        _ id: UUID?,
        remoteInteractionID: String?,
        interactionID: String
    ) -> Bool {
        if id?.uuidString.caseInsensitiveCompare(interactionID) == .orderedSame {
            return true
        }
        return remoteInteractionID?.caseInsensitiveCompare(interactionID) == .orderedSame
    }

    private func approvalRemoteInteractionID(_ request: AgentApprovalRequest?) -> String? {
        if case let .remoteGateway(interactionID)? = request?.requestID {
            return interactionID
        }
        return nil
    }

    #if DEBUG
        func test_controller(for session: AgentTabSession) throws -> RemoteAgentSessionController {
            try controller(for: session)
        }

        func test_deliverFrame(_ frame: RemoteServerFrame, hostID: String) async {
            await deliver(frame, hostID: hostID)
        }

        func test_deliverConnectionState(_ state: RemoteHostConnection.State, hostID: String) async {
            await deliver(state, hostID: hostID)
        }

        func test_applyChannel(_ state: RemoteChannelState, to session: AgentTabSession) {
            applyChannel(state, to: session)
        }

        func test_attachController(
            tabID: UUID,
            hostID: String,
            controller: RemoteAgentSessionController,
            connection: RemoteHostConnection
        ) {
            controllersByTabID[tabID] = controller
            hostIDByTabID[tabID] = hostID
            startEventTask(for: tabID, controller: controller)
            startConnectionFanoutIfNeeded(hostID: hostID, connection: connection)
        }

        /// Internal for respond-wiring tests.
        func test_installController(
            _ controller: RemoteAgentSessionController,
            for session: AgentTabSession,
            hostID: String
        ) {
            if session.remoteHost == nil {
                session.remoteHost = AgentSessionRemoteHostBinding(
                    hostID: hostID,
                    hostDisplayName: "Remote Host",
                    remoteSessionID: "",
                    lastAppliedSeq: 0,
                    nextLogOffset: 0
                )
            }
            controllersByTabID[session.tabID] = controller
            hostIDByTabID[session.tabID] = hostID
            startEventTask(for: session.tabID, controller: controller)
        }

        func test_lifecycleCounts() -> (controllers: Int, eventTasks: Int, hostFanoutTasks: Int, tabHostBindings: Int) {
            (
                controllers: controllersByTabID.count,
                eventTasks: eventTasksByTabID.count,
                hostFanoutTasks: connectionTasksByHostID.count,
                tabHostBindings: hostIDByTabID.count
            )
        }

        func test_setConnectionStateDeliveryObserver(
            _ observer: ((String, RemoteHostConnection.State) -> Void)?
        ) {
            connectionStateDeliveryObserver = observer
        }

        func test_applyMetadata(
            agentKindRaw: String? = nil,
            modelRaw: String? = nil,
            reasoningEffortRaw: String? = nil,
            sessionName: String?,
            tabID: UUID
        ) {
            handle(
                .metadata(
                    agentKindRaw: agentKindRaw,
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw,
                    sessionName: sessionName
                ),
                tabID: tabID
            )
        }

        func test_handleEvent(_ event: RemoteSessionEvent, tabID: UUID) {
            handle(event, tabID: tabID)
        }

        /// Delivers an event as if it came from the attachment that captured `deliveryGeneration`.
        func test_handleEvent(_ event: RemoteSessionEvent, tabID: UUID, deliveryGeneration: UInt64) {
            handle(event, tabID: tabID, deliveryGeneration: deliveryGeneration)
        }

        func test_deliveryGeneration(tabID: UUID) -> UInt64 {
            deliveryGenerationByTabID[tabID] ?? 0
        }

        func test_applyTranscriptRows(
            _ rows: [AgentChatItem],
            removedIDs: [UUID] = [],
            to session: AgentTabSession
        ) {
            applyTranscriptRows(rows, removedIDs: removedIDs, to: session)
        }

        func test_applyRunState(
            _ runState: AgentSessionRunState,
            pendingInteraction: RemotePendingInteraction? = nil,
            statusText: String? = nil,
            to session: AgentTabSession
        ) {
            applyRunState(runState, pendingInteraction: pendingInteraction, statusText: statusText, to: session)
        }

        func test_applyTerminal(status: String, to session: AgentTabSession) {
            applyTerminal(status: status, to: session)
        }

        static func test_terminalSettlement(for status: String) -> (statusWord: String, isError: Bool) {
            terminalSettlement(for: status)
        }

        static func test_terminalSettlement(for runState: AgentSessionRunState) -> (statusWord: String, isError: Bool) {
            terminalSettlement(for: runState)
        }

        func test_recordStartSessionName(
            _ sessionName: String?,
            tabID: UUID,
            allowHostSessionNameAdoptionFromStartName: Bool = true
        ) {
            recordStartSessionName(
                sessionName,
                tabID: tabID,
                allowHostSessionNameAdoptionFromStartName: allowHostSessionNameAdoptionFromStartName
            )
        }

        func test_setMaterializedRemoteChildAttachHandler(
            _ handler: (@MainActor (AgentTabSession) async throws -> Void)?
        ) {
            materializedRemoteChildAttachHandler = handler
        }

        func test_setMaterializedRemoteWorkspaceAttachHandler(
            _ handler: (@MainActor (AgentTabSession) async throws -> Void)?
        ) {
            materializedRemoteWorkspaceAttachHandler = handler
        }

        func test_workspacePickupInFlightCount() -> Int {
            workspacePickupInFlightKeys.count
        }

        func test_setChildDiscoveryRequestObserver(_ observer: ((UUID, Bool) -> Void)?) {
            childDiscoveryRequestObserver = observer
        }

        func test_setSyntheticSettlementRevertScanObserver(_ observer: ((UUID) -> Void)?) {
            syntheticSettlementRevertScanObserver = observer
        }

        func test_requestChildSessionDiscovery(tabID: UUID) {
            guard let session = viewModel?.sessions[tabID] else { return }
            requestChildSessionDiscovery(for: session, reason: "test")
        }

        func test_startSessionNameRecord(tabID: UUID) -> String? {
            startSessionNameByTabID[tabID]
        }
    #endif

    static func describe(
        _ error: Error,
        workspaceName: String? = nil,
        hostName: String? = nil
    ) -> String {
        if let handoffError = error as? RemoteInputHandoffError {
            if let remoteError = handoffError.remoteError {
                return describe(remoteError, workspaceName: workspaceName, hostName: hostName)
            }
            return handoffError.errorDescription ?? String(describing: handoffError)
        }
        if let commandError = (error as? RemoteClientError)?.commandError {
            if commandError.code == "binding_required" {
                return "The host couldn't route this message to its window. Try again — if it keeps failing, the session's window may have been closed on the host."
            }
            if ["workspace_not_open", "workspace_mismatch"].contains(commandError.code) {
                let details = commandError.details?.objectValue
                let resolvedWorkspaceName = normalizedFriendlyName(workspaceName)
                    ?? normalizedFriendlyName(details?["workspace_name"]?.stringValue)
                    ?? (
                        commandError.code == "workspace_not_open"
                            ? quotedWorkspaceName(in: commandError.message)
                            : nil
                    )
                let resolvedHostName = normalizedFriendlyName(hostName)
                    ?? normalizedFriendlyName(details?["host_name"]?.stringValue)
                let hostPhrase = resolvedHostName ?? "the host"
                if let resolvedWorkspaceName {
                    return "Workspace '\(resolvedWorkspaceName)' is not open on \(hostPhrase). Open it there and try again."
                }
                return "The requested workspace is not open on \(hostPhrase). Open it there and try again."
            }
            if commandError.code == "workspace_not_found" {
                let workspace = normalizedFriendlyName(workspaceName) ?? "requested workspace"
                let host = normalizedFriendlyName(hostName) ?? "the host"
                return "Workspace '\(workspace)' was not found on \(host)."
            }
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }

    private static func normalizedFriendlyName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func quotedWorkspaceName(in message: String) -> String? {
        let parts = message.split(separator: "'", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return normalizedFriendlyName(String(parts[1]))
    }
}

// MARK: - Remote input dispatch (lossless restart Phase 1b)

/// The caller-provided admission identity of one remote `start`/`steer` input. `input` is allocated
/// once at input admission (a store-issued queue receipt, or an untracked identity only while the
/// session's recovery admission is explicitly `.inactive`) and carries the original user item ID.
/// Use `.explicitUserAction` for user-initiated resend and start-target picker retries: those are
/// the only dispatches the store allows for `deliveryUnknown`/`failed` intents.
struct RemoteInputDispatch {
    enum Source {
        /// Input admitted for this send (store-issued queue receipt, or untracked while inactive).
        case input(AgentQueuedInputIdentity)
        /// An intent already committed for this item, re-dispatched by an explicit user action
        /// (read from the lane's record; no receipt is minted).
        case existingIntent(AgentRecoveryExistingIntentReference)
    }

    let source: Source
    let authorization: AgentRecoveryDispatchAuthorization

    init(input: AgentQueuedInputIdentity, authorization: AgentRecoveryDispatchAuthorization = .liveQueue) {
        source = .input(input)
        self.authorization = authorization
    }

    /// Explicit user re-dispatch of an existing durable intent (always `.explicitUserAction`).
    init(existingIntent: AgentRecoveryExistingIntentReference) {
        source = .existingIntent(existingIntent)
        authorization = .explicitUserAction
    }
}

/// A remote `start`/`steer` input that did not complete with a host response.
struct RemoteInputHandoffError: Error, LocalizedError {
    enum Disposition: Equatable {
        /// Nothing reached the remote bridge: target capture, observation preflight, dispatch
        /// commit, or post-await revalidation failed. Durable input keeps (or settles back to) the
        /// same `queued` intent.
        case notHandedOff
        /// The request reached the remote bridge without proof either way. Durable input stays
        /// `deliveryUnknown`: no automatic resend and no retryable draft restore.
        case deliveryUnknown
    }

    enum Cause {
        /// Durable dispatch commit refused or failed (`AgentRecoveryDispatchEvidence.begin`).
        case dispatchRefused(AgentRecoveryAdmissionFailure)
        /// Tab session, controller, host binding, or recovery authority changed during an await.
        case staleTarget
        /// The remote client/bridge error (unchanged; see `remoteError`).
        case remote(any Error)
    }

    static let staleTargetMessage = "The remote session changed before the message was sent."

    let disposition: Disposition
    let cause: Cause
    /// Evidence of the committed dispatch; `nil` when no dispatch was begun.
    let evidence: AgentRecoveryDispatchEvidence?

    /// The remote client error, for start-target picker and error classification.
    var remoteError: (any Error)? {
        if case let .remote(error) = cause {
            return error
        }
        return nil
    }

    /// `error`'s remote client error when it is a handoff error, otherwise `error` itself.
    static func remoteError(of error: any Error) -> any Error {
        (error as? RemoteInputHandoffError)?.remoteError ?? error
    }

    var errorDescription: String? {
        switch cause {
        case let .remote(error):
            (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        case .staleTarget:
            Self.staleTargetMessage + " It stays saved."
        case let .dispatchRefused(failure):
            failure.dispatchFailureText
        }
    }
}
