import Foundation
@testable import RepoPromptAgentCore

/// Explicit inactive-admission (legacy) fixtures for the provider handoff seams. They go through
/// the production `untracked(userItemID:in:)` factory and the production dispatch begin, so a
/// session that requires durable admission fails loudly instead of sending untracked input.
extension AgentProviderHandoff {
    @MainActor
    static func inactiveForTesting(in session: AgentTabSession) async -> AgentProviderHandoff {
        let result = await begin(
            session: session,
            constituents: [.inactiveForTesting(in: session)],
            ownership: nil,
            processRunID: nil
        )
        guard case let .success(handoff) = result else {
            preconditionFailure("Test fixture requires a session with inactive recovery admission")
        }
        return handoff
    }
}

extension AgentModeRunService {
    /// Inactive-admission start used by lifecycle tests that predate durable admission: the run's
    /// input is one untracked constituent.
    @MainActor
    @discardableResult
    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        codexFallbackContext: AgentTabSession.CodexFallbackSubmissionContext? = nil,
        providerHandoffAuthorization: (@MainActor () -> Bool)? = nil,
        delegatedQuestionStageID: UUID? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        await startRun(
            tabID: tabID,
            session: session,
            initialUserMessage: initialUserMessage,
            initialMessageForRun: initialMessageForRun,
            attachments: attachments,
            inputConstituents: [.inactiveForTesting(in: session)],
            codexFallbackContext: codexFallbackContext,
            providerHandoffAuthorization: providerHandoffAuthorization,
            delegatedQuestionStageID: delegatedQuestionStageID
        )
    }
}

extension ClaudeAgentModeCoordinator {
    /// Inactive-admission send used by lifecycle tests that predate durable admission.
    @MainActor
    @discardableResult
    func sendClaudeNativeMessage(
        session: AgentTabSession,
        text: String,
        attachments: [AgentImageAttachment]
    ) async -> Bool {
        let handoff = await AgentProviderHandoff.inactiveForTesting(in: session)
        return await sendClaudeNativeMessage(
            session: session,
            text: text,
            attachments: attachments,
            handoff: handoff
        )
    }
}

/// A real recovery lane (as `RecoveryLaneFixture`) whose store file writes can be failed on demand,
/// for injected recovery write failures at the provider-handoff seams.
@MainActor
final class FailableRecoveryLaneFixture {
    private struct Workspace: AgentWorkspaceStorageReference {
        let id = UUID()
        let name = "Failable Recovery Lane Fixture"
        let customStoragePath: URL?
    }

    private final class Owner {}

    let root: URL
    let store: AgentRecoveryStore
    let coordinator: AgentRecoveryCoordinator
    let lane: AgentRecoverySessionLane
    let failures: RecoveryStoreWriteFailureSwitch
    private let service: AgentSessionDataService
    private let owner: Owner

    var sessionID: UUID {
        lane.sessionID
    }

    private init(
        root: URL,
        store: AgentRecoveryStore,
        service: AgentSessionDataService,
        coordinator: AgentRecoveryCoordinator,
        lane: AgentRecoverySessionLane,
        failures: RecoveryStoreWriteFailureSwitch,
        owner: Owner
    ) {
        self.root = root
        self.store = store
        self.service = service
        self.coordinator = coordinator
        self.lane = lane
        self.failures = failures
        self.owner = owner
    }

    static func make(_ name: String) async throws -> FailableRecoveryLaneFixture {
        let root = try RecoveryTestSupport.makeTemporaryRoot(name)
        let recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        let workspace = Workspace(customStoragePath: root.appendingPathComponent("workspace", isDirectory: true))
        let failures = RecoveryStoreWriteFailureSwitch()
        let store = AgentRecoveryStore(rootURL: recoveryRoot, fileOperations: failures.fileOperations())
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(
                    store: store,
                    gate: gate,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                )
            }
        )
        coordinator.startIfNeeded()
        guard await coordinator.awaitStartup() == .ready else {
            throw RecoveryLaneFixtureError.startupNotReady
        }
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Failable Recovery"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let owner = Owner()
        let lane = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        return FailableRecoveryLaneFixture(
            root: root,
            store: store,
            service: service,
            coordinator: coordinator,
            lane: lane,
            failures: failures,
            owner: owner
        )
    }

    func tearDown() {
        failures.shouldFailWrites = false
        try? FileManager.default.removeItem(at: root)
    }

    func queuedIdentity(_ text: String) async throws -> AgentQueuedInputIdentity {
        let admitted = try await lane.admitQueued(AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: UUID(),
            origin: .mcp,
            target: .session,
            original: RecoveryTestSupport.content(text)
        )).get()
        return AgentQueuedInputIdentity(receipt: admitted.receipt)
    }

    func boundTabSession() -> AgentTabSession {
        let session = AgentTabSession(tabID: UUID())
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: sessionID))
        session.recoveryLane = lane
        return session
    }

    func intent(_ identity: AgentQueuedInputIdentity) async -> AgentRecoveryIntent? {
        guard let intentID = identity.intentID else { return nil }
        return await store.read(sessionID: sessionID).record?.intent(id: intentID)
    }

    func attempts(for identity: AgentQueuedInputIdentity) async -> [AgentRecoveryAttempt] {
        guard let intentID = identity.intentID else { return [] }
        return await store.read(sessionID: sessionID).record?.attempts.filter { $0.intentID == intentID } ?? []
    }
}

extension RecoveryLaneFixture {
    /// Polls the durable intent until it reaches `state` (evidence writes are ordered but
    /// asynchronous) or the bound expires; returns the last observed intent.
    func waitForIntent(
        _ identity: AgentQueuedInputIdentity,
        state: AgentRecoveryDeliveryState,
        attempts: Int = 300
    ) async -> AgentRecoveryIntent? {
        for _ in 0 ..< attempts {
            let intent = await intent(identity)
            if intent?.deliveryState == state {
                return intent
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await intent(identity)
    }

    func attempts(for identity: AgentQueuedInputIdentity) async -> [AgentRecoveryAttempt] {
        guard let intentID = identity.intentID else { return [] }
        return await store.read(sessionID: sessionID).record?.attempts.filter { $0.intentID == intentID } ?? []
    }

    func hasRunAttempt(_ runAttemptID: UUID) async -> Bool {
        await store.read(sessionID: sessionID).record?.runAttempt(id: runAttemptID) != nil
    }
}
