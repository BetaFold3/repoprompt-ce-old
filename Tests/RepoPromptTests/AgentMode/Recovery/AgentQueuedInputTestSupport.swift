import Foundation
@testable import RepoPromptAgentCore

/// Explicit test fixtures for queued-input identity under inactive (legacy) recovery admission.
/// They go through the production `untracked(userItemID:in:)` factory, so a session that requires
/// durable admission fails loudly instead of receiving untracked input.
extension AgentQueuedInputIdentity {
    @MainActor
    static func inactiveForTesting(userItemID: UUID? = nil, in session: AgentTabSession) -> AgentQueuedInputIdentity {
        guard let identity = untracked(userItemID: userItemID, in: session) else {
            preconditionFailure("Test fixture requires a session with inactive recovery admission")
        }
        return identity
    }
}

extension AgentTabSession {
    /// Provider texts of the generic follow-up queue, in order.
    var pendingInstructionTexts: [String] {
        pendingInstructions.map(\.text)
    }

    /// Replaces the generic follow-up queue with untracked entries (inactive admission only).
    func setUntrackedPendingInstructionsForTesting(_ texts: [String]) {
        pendingInstructions = texts.map { text in
            AgentPendingInstruction(text: text, identity: .inactiveForTesting(in: self))
        }
    }

    /// Appends one untracked entry to the generic follow-up queue (inactive admission only).
    func appendUntrackedPendingInstructionForTesting(_ text: String) {
        pendingInstructions.append(AgentPendingInstruction(text: text, identity: .inactiveForTesting(in: self)))
    }
}

/// A real recovery lane: temporary store and tombstone root behind the real `AgentSessionDataService`
/// gate, a started coordinator, and one durable session. Durable identities come only from receipts
/// the store issues through this lane (no synthetic receipts).
@MainActor
final class RecoveryLaneFixture {
    private struct Workspace: AgentWorkspaceStorageReference {
        var id = UUID()
        let name = "Recovery Lane Fixture"
        let customStoragePath: URL?
    }

    private final class Owner {}

    let root: URL
    let store: AgentRecoveryStore
    let service: AgentSessionDataService
    let coordinator: AgentRecoveryCoordinator
    let lane: AgentRecoverySessionLane
    private let owner: Owner
    private let workspace: Workspace
    /// Owners of sibling lanes (kept alive with the fixture).
    private var siblingOwners: [Owner] = []

    var sessionID: UUID {
        lane.sessionID
    }

    private init(
        root: URL,
        store: AgentRecoveryStore,
        service: AgentSessionDataService,
        coordinator: AgentRecoveryCoordinator,
        lane: AgentRecoverySessionLane,
        owner: Owner,
        workspace: Workspace
    ) {
        self.root = root
        self.store = store
        self.service = service
        self.coordinator = coordinator
        self.lane = lane
        self.owner = owner
        self.workspace = workspace
    }

    /// A real same-owner successor claim that preserves ownership (same incarnation and lifecycle
    /// binding, different persistence state), taking `claimLane`'s ownership-preserving hand-over
    /// path (review R2, B R2-F1). The state comes from `relocatedPersistenceState()`, loaded before
    /// any store write is held (loading takes the session persistence gate).
    func claimSuccessor(persistenceState: AgentSessionPersistenceState) throws -> AgentRecoverySessionLane {
        try coordinator.claimLane(owner: owner, persistenceState: persistenceState)
    }

    /// The same session incarnation's persistence state from a relocated file: the session's file is
    /// copied to another storage folder of the same workspace and loaded by the same service.
    func relocatedPersistenceState() async throws -> AgentSessionPersistenceState {
        guard let storage = workspace.customStoragePath else { throw RecoveryLaneFixtureError.relocatedSessionUnavailable }
        let fileName = "AgentSession-\(sessionID.uuidString).json"
        let relocatedStorage = root.appendingPathComponent("relocated", isDirectory: true)
        let relocatedFolder = relocatedStorage.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: relocatedFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: storage.appendingPathComponent("AgentSessions", isDirectory: true).appendingPathComponent(fileName),
            to: relocatedFolder.appendingPathComponent(fileName)
        )
        let relocated = Workspace(id: workspace.id, customStoragePath: relocatedStorage)
        guard let load = try await service.loadAgentSessionForEditing(id: sessionID, for: relocated) else {
            throw RecoveryLaneFixtureError.relocatedSessionUnavailable
        }
        return load.persistenceState
    }

    static func make(
        _ name: String,
        fileOperations: AgentRecoveryStore.FileOperations = .live
    ) async throws -> RecoveryLaneFixture {
        let root = try RecoveryTestSupport.makeTemporaryRoot(name)
        let recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        let workspace = Workspace(customStoragePath: root.appendingPathComponent("workspace", isDirectory: true))
        let store = AgentRecoveryStore(rootURL: recoveryRoot, fileOperations: fileOperations)
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
            name: "Recovery"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let owner = Owner()
        let lane = try coordinator.claimLane(owner: owner, persistenceState: load.persistenceState)
        return RecoveryLaneFixture(
            root: root,
            store: store,
            service: service,
            coordinator: coordinator,
            lane: lane,
            owner: owner,
            workspace: workspace
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Another durable session of the same workspace, claimed by a different owner (another window)
    /// through the same app-shared coordinator.
    func claimSiblingLane(workspaceID: UUID? = nil) async throws -> AgentRecoverySessionLane {
        let target = workspaceID.map { Workspace(id: $0, customStoragePath: workspace.customStoragePath) } ?? workspace
        let session = AgentSession(
            id: UUID(),
            workspaceID: target.id,
            composeTabID: UUID(),
            name: "Sibling"
        ).withItems([AgentChatItem.user("hello", sequenceIndex: 0)])
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: session,
            for: target,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let sibling = Owner()
        siblingOwners.append(sibling)
        return try coordinator.claimLane(owner: sibling, persistenceState: load.persistenceState)
    }

    /// Commits a real `queued` intent through the lane and returns its durable identity.
    func queuedIdentity(_ text: String, userItemID: UUID = UUID()) async throws -> AgentQueuedInputIdentity {
        let admitted = try await lane.admitQueued(AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: userItemID,
            origin: .mcp,
            target: .session,
            original: RecoveryTestSupport.content(text)
        )).get()
        return AgentQueuedInputIdentity(receipt: admitted.receipt)
    }

    /// A Codex submission context for a real `queued` intent admitted through this lane (queue ID ==
    /// intent ID), so a Codex fallback queues under its store-issued receipt.
    @MainActor
    func codexFallbackContext(
        _ text: String,
        origin: AgentTabSession.CodexFallbackOrigin = .manual,
        userItemID: UUID = UUID()
    ) async throws -> AgentTabSession.CodexFallbackSubmissionContext {
        let identity = try await queuedIdentity(text, userItemID: userItemID)
        guard let intentID = identity.intentID else { throw RecoveryLaneFixtureError.startupNotReady }
        return AgentTabSession.CodexFallbackSubmissionContext(
            queueID: intentID,
            providerText: text,
            images: [],
            taggedFileAttachments: [],
            draftText: text,
            identity: identity,
            origin: origin,
            dispatchTicket: nil
        )
    }

    /// A tab session bound to this lane (runs it begins carry this lane's persistent session ID).
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
}

enum RecoveryLaneFixtureError: Error {
    case startupNotReady
    case relocatedSessionUnavailable
}
