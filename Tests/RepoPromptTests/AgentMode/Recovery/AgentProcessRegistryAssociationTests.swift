import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
import XCTest

/// Spec R6 runtime ownership data: the actual provider, operation-bound associations (managed
/// session, run attempt, conversation, requested permission) on reused transports, the
/// `detachedAtQuit` compatible state, same-session and provider-aware restrictions, observed headless
/// conversations, and immutable operation-owner capture. Temporary store, scripted processes only.
final class AgentProcessRegistryAssociationTests: XCTestCase {
    private typealias Fixtures = AgentProcessRegistryFixtures

    private var root: URL!
    private var recoveryRoot: URL!
    private var processes: ScriptedProcessSystem!
    private var registries: [AgentProcessRegistry] = []

    override func setUpWithError() throws {
        root = try RecoveryTestSupport.makeTemporaryRoot("AgentProcessRegistryAssociationTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        processes = ScriptedProcessSystem()
    }

    override func tearDown() async throws {
        for registry in registries {
            await registry.disposeWatches()
        }
        registries = []
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeStore() -> AgentRecoveryStore {
        AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
    }

    private func startedRegistry(_ store: AgentRecoveryStore) async -> AgentProcessRegistry {
        let registry = AgentProcessRegistry(store: store, qualification: Fixtures.qualified(), system: processes.system)
        registries.append(registry)
        await registry.start()
        return registry
    }

    private func launch(
        _ registry: AgentProcessRegistry,
        family: AgentRuntimeFamily,
        provider: AgentRuntimeProvider? = nil,
        session: AgentRuntimeSessionScope = .sessionless,
        worktreePath: String? = "/tmp/rpce-assoc",
        permission: AgentRuntimePermissionSnapshot = .unavailable
    ) throws -> AgentRuntimeLaunch {
        try XCTUnwrap(AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(Fixtures.context(
            family,
            provider: provider,
            session: session,
            worktreePath: worktreePath,
            permission: permission
        )))
    }

    private func expectError(
        _ expected: AgentProcessRegistryError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentProcessRegistryError, expected, file: file, line: line)
        }
    }

    // MARK: Codec

    func testCodecRoundTripsProviderAssociationsAndDetachedAtQuitAndKeepsLegacyRecordsUnknown() throws {
        let timestamp = AgentRecoveryTimestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let session = Fixtures.session(processRunID: UUID())
        let record = AgentRuntimeRecord(
            runtimeID: UUID(),
            revision: .make(),
            appInstanceID: UUID(),
            family: .acp,
            provider: .acp(.ohMyPi),
            state: .detachedAtQuit,
            associations: [
                AgentRuntimeAssociation(
                    session: session,
                    conversationID: "acp-1",
                    worktreePath: "/tmp/wt",
                    permission: .acp(sessionModeID: "plan", autoApproveAllToolPermissions: false)
                ),
                AgentRuntimeAssociation(session: nil, conversationID: nil, worktreePath: nil, permission: .claude(permissionMode: nil)),
                AgentRuntimeAssociation(session: nil, conversationID: nil, worktreePath: nil, permission: .codex(approvalPolicy: nil, sandbox: "read-only")),
                AgentRuntimeAssociation(session: nil, conversationID: nil, worktreePath: nil, permission: .unavailable)
            ],
            conversationIDs: ["acp-1"],
            worktreePaths: ["/tmp/wt"],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let data = try AgentRuntimeRecordCodec.encode(record)
        guard case let .success(decoded) = AgentRuntimeRecordCodec.decode(data, expectedRuntimeID: record.runtimeID) else {
            return XCTFail("Expected the record to round-trip")
        }
        XCTAssertEqual(decoded, record)
        XCTAssertTrue(decoded.state.mayHoldWriter, "a detached runtime is a possible writer")

        let text = String(decoding: data, as: UTF8.self)
        let unknownProvider = text.replacingOccurrences(of: "\"acp.ohMyPi\"", with: "\"acp.futureAgent\"")
        XCTAssertNotEqual(unknownProvider, text)
        if case .success = AgentRuntimeRecordCodec.decode(Data(unknownProvider.utf8), expectedRuntimeID: record.runtimeID) {
            XCTFail("An unknown provider must be preserved, never decoded or guessed from the family")
        }

        // An earlier draft record (no provider, no associations) stays readable with an unknown
        // provider and no fabricated association.
        let legacy = AgentRuntimeRecord(
            runtimeID: UUID(),
            revision: .make(),
            appInstanceID: UUID(),
            family: .claudeNative,
            provider: nil,
            state: .live,
            conversationIDs: ["conv-old"],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let legacyData = try AgentRuntimeRecordCodec.encode(legacy)
        let legacyText = String(decoding: legacyData, as: UTF8.self)
        XCTAssertFalse(legacyText.contains("\"provider\""))
        XCTAssertFalse(legacyText.contains("\"associations\""))
        guard case let .success(decodedLegacy) = AgentRuntimeRecordCodec.decode(legacyData, expectedRuntimeID: legacy.runtimeID) else {
            return XCTFail("Expected a legacy record to decode")
        }
        XCTAssertNil(decodedLegacy.provider)
        XCTAssertTrue(decodedLegacy.associations.isEmpty)
    }

    // MARK: detachedAtQuit

    func testDetachedAtQuitStaysAPossibleWriterUntilDiscoveryProvesExit() async throws {
        processes.add(processes.observation(pid: 3100, group: 3100))
        let alive = try Fixtures.seed(
            rootURL: recoveryRoot,
            state: .detachedAtQuit,
            root: processes.identity(pid: 3100),
            rootGroup: 3100,
            conversationIDs: ["conv-D"]
        )
        let gone = try Fixtures.seed(
            rootURL: recoveryRoot,
            state: .detachedAtQuit,
            root: processes.identity(pid: 3101),
            conversationIDs: ["conv-G"]
        )
        let store = makeStore()
        let registry = await startedRegistry(store)
        let snapshot = await registry.restrictionSnapshot()

        XCTAssertEqual(Fixtures.record(store, alive.runtimeID)?.state, .detachedAtQuit, "discovery keeps the compatible state")
        XCTAssertEqual(snapshot.restrictions.first { $0.runtimeID == alive.runtimeID }?.kind, .possibleWriter)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-D", worktreePath: nil)))
        XCTAssertEqual(Fixtures.record(store, gone.runtimeID)?.state, .exited, "complete qualified discovery proves exit")
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-G", worktreePath: nil)))
    }

    // MARK: Restrictions

    func testSameSessionWriterRestrictsBeforeAnyConversationIsKnown() async throws {
        processes.add(processes.observation(pid: 3200, group: 3200))
        let owner = Fixtures.session()
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 3200),
            rootGroup: 3200,
            associations: [AgentRuntimeAssociation(session: owner, conversationID: nil, worktreePath: nil, permission: .unavailable)]
        )
        let store = makeStore()
        let registry = await startedRegistry(store)
        let snapshot = await registry.restrictionSnapshot()
        let restriction = try XCTUnwrap(snapshot.restrictions.first)
        XCTAssertEqual(restriction.sessionIDs, [owner.sessionID])

        XCTAssertTrue(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(sessionID: owner.sessionID, conversationID: nil, worktreePath: "/tmp/other")),
            "the same managed session is restricted before a native conversation exists"
        )
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(sessionID: UUID(), conversationID: nil, worktreePath: "/tmp/other")))
        await expectError(.ownershipConflict(runtimeID: seeded.runtimeID)) {
            // A reset (new incarnation, new attempt) of the same session never evades the owner.
            let reset = Fixtures.session(owner.sessionID, resetGeneration: 1)
            _ = try await registry.reserveLaunch(Fixtures.context(.claudeNative, session: .session(reset), worktreePath: "/tmp/other"))
        }
    }

    func testConversationOverlapIsProviderAwareAndUnknownProvidersOverlap() async throws {
        processes.add(processes.observation(pid: 3300, group: 3300))
        processes.add(processes.observation(pid: 3301, group: 3301))
        try Fixtures.seed(
            rootURL: recoveryRoot,
            provider: .claude(.standard),
            root: processes.identity(pid: 3300),
            rootGroup: 3300,
            conversationIDs: ["shared-id"]
        )
        try Fixtures.seed(
            rootURL: recoveryRoot,
            unknownProvider: true,
            root: processes.identity(pid: 3301),
            rootGroup: 3301,
            conversationIDs: ["legacy-id"]
        )
        let registry = await startedRegistry(makeStore())
        let snapshot = await registry.restrictionSnapshot()

        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "shared-id", provider: .claude(.standard), worktreePath: nil)))
        XCTAssertFalse(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "shared-id", provider: .codex, worktreePath: nil)),
            "distinct known providers are distinct conversation keys"
        )
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "shared-id", provider: .claude(.glm), worktreePath: nil)))
        XCTAssertTrue(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "shared-id", provider: nil, worktreePath: nil)),
            "an unknown requested provider overlaps"
        )
        XCTAssertTrue(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "legacy-id", provider: .codex, worktreePath: nil)),
            "a record without a provider overlaps every provider"
        )
        let codex = try launch(registry, family: .codexAppServer, worktreePath: nil)
        _ = try await codex.prepareSpawn()
        try await codex.associate(conversationID: "shared-id")
    }

    // MARK: Associations

    func testReservationCarriesProviderLifecycleAttemptAndRequestedPermission() async throws {
        let store = makeStore()
        let registry = await startedRegistry(store)
        let owner = Fixtures.session(processRunID: UUID())
        let permission = AgentRuntimePermissionSnapshot.claude(permissionMode: "plan")
        let claude = try launch(registry, family: .claudeCompatible, provider: .claude(.kimi), session: .session(owner), permission: permission)
        let runtimeID = try await claude.prepareSpawn()

        let record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.provider, .claude(.kimi))
        XCTAssertEqual(record.state, .reserved)
        XCTAssertEqual(record.associations, [AgentRuntimeAssociation(
            session: owner,
            conversationID: nil,
            worktreePath: AgentRuntimePaths.standardized("/tmp/rpce-assoc"),
            permission: permission
        )])

        // Missing Agent Mode context fails before anything is written; nothing is fabricated.
        let before = Fixtures.runtimeFileCount(rootURL: recoveryRoot)
        let missing = try launch(registry, family: .claudeNative, session: .unavailable)
        await expectError(.sessionContextUnavailable) { _ = try await missing.prepareSpawn() }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), before)

        // Genuinely sessionless work is explicitly nil.
        let sessionless = try launch(registry, family: .codexAppServer, worktreePath: nil)
        let sessionlessID = try await sessionless.prepareSpawn()
        XCTAssertEqual(Fixtures.record(store, sessionlessID)?.associations.map(\.session), [nil])
    }

    func testReusedTransportKeepsDistinctThreadAssociationsAndPermissions() async throws {
        let store = makeStore()
        let registry = await startedRegistry(store)
        let codex = try launch(registry, family: .codexAppServer, worktreePath: nil)
        let runtimeID = try await codex.prepareSpawn()
        let first = Fixtures.session()
        let second = Fixtures.session()
        let fullAccess = AgentRuntimePermissionSnapshot.codex(approvalPolicy: "never", sandbox: "danger-full-access")

        try await codex.associate(session: .session(first), conversationID: "thread-A", worktreePath: "/tmp/wt-a", permission: fullAccess)
        try await codex.associate(session: .session(second), conversationID: "thread-B", worktreePath: "/tmp/wt-b")
        // A later operation on thread A without a permission request keeps its own requested one.
        try await codex.associate(session: .session(first), conversationID: "thread-A", worktreePath: "/tmp/wt-a")

        let record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        let threadA = record.associations.filter { $0.conversationID == "thread-A" }
        let threadB = record.associations.filter { $0.conversationID == "thread-B" }
        XCTAssertEqual(threadA.count, 1)
        XCTAssertEqual(threadA.first?.session?.sessionID, first.sessionID)
        XCTAssertEqual(threadA.first?.permission, fullAccess)
        XCTAssertEqual(threadB.first?.session?.sessionID, second.sessionID)
        XCTAssertEqual(threadB.first?.permission, .unavailable, "one thread's permission is never lent to another")
        XCTAssertEqual(Set(record.conversationIDs), ["thread-A", "thread-B"])
        XCTAssertTrue(record.associations.contains { $0.session == nil }, "the sessionless launch association is retained")

        await expectError(.sessionContextUnavailable) {
            try await codex.associate(session: .unavailable, conversationID: "thread-C")
        }
        XCTAssertFalse(Fixtures.record(store, runtimeID)?.conversationIDs.contains("thread-C") ?? true)
    }

    func testObservedHeadlessConversationIsRecordedEvenAfterTheRootIsReaped() async throws {
        let store = makeStore()
        let registry = await startedRegistry(store)
        let owner = Fixtures.session(processRunID: UUID())
        let headless = try launch(registry, family: .claudeHeadless, session: .session(owner), permission: .claude(permissionMode: "acceptEdits"))
        let runtimeID = try await headless.prepareSpawn()
        processes.add(processes.observation(pid: 3400, group: 3400, marker: runtimeID))
        try await headless.commitSpawn(pid: 3400, processGroupID: 3400)
        processes.remove(pid: 3400)
        await headless.rootReaped(pid: 3400, confirmed: true)

        let recorded = await headless.recordObservedConversation("claude-session-1")
        XCTAssertTrue(recorded)
        let record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertTrue(record.conversationIDs.contains("claude-session-1"))
        let observed = try XCTUnwrap(record.associations.first { $0.conversationID == "claude-session-1" })
        XCTAssertEqual(observed.session, owner)
        XCTAssertEqual(observed.permission, .claude(permissionMode: "acceptEdits"))
        await expectError(.staleLaunch) { try await headless.authorizeWrite(conversationID: "claude-session-1") }

        let unprepared = try launch(registry, family: .claudeHeadless, session: .session(owner))
        let unpreparedRecorded = await unprepared.recordObservedConversation("other")
        XCTAssertFalse(unpreparedRecorded, "evidence needs this exact launch's reservation")
    }

    // MARK: Operation owner capture

    func testOperationOwnerIsCapturedOnceAndNeverRetargetedForLateOrDetachedWrites() async throws {
        let store = makeStore()
        let registry = await startedRegistry(store)
        let codex = try launch(registry, family: .codexAppServer, worktreePath: nil)
        let runtimeID = try await codex.prepareSpawn()
        let sessionID = UUID()
        let incarnation = UUID()
        let firstAttempt = Fixtures.session(sessionID, incarnationID: incarnation, runAttemptID: UUID())
        let secondAttempt = Fixtures.session(sessionID, incarnationID: incarnation, runAttemptID: UUID())

        XCTAssertEqual(AgentRuntimeOperationOwner.current, .unavailable, "no owner bound means no session, never sessionless")
        // An owner operation of the first attempt starts a late write (a detached retry) and returns.
        let late: Task<Void, Error> = AgentRuntimeOperationOwner.$session.withValue(.session(firstAttempt)) {
            let captured = AgentRuntimeOperationOwner.current
            let gate = AsyncStream<Void>.makeStream()
            let task = Task.detached {
                for await _ in gate.stream {
                    break
                }
                try await AgentRuntimeOperationOwner.$session.withValue(captured) {
                    try await codex.associate(session: AgentRuntimeOperationOwner.current, conversationID: "thread-late")
                }
            }
            // The session moves to its next attempt before the late write runs.
            AgentRuntimeOperationOwner.$session.withValue(.session(secondAttempt)) {
                XCTAssertEqual(AgentRuntimeOperationOwner.current, .session(secondAttempt))
            }
            gate.continuation.yield()
            gate.continuation.finish()
            return task
        }
        try await late.value

        let association = try XCTUnwrap(Fixtures.record(store, runtimeID)?.associations.first { $0.conversationID == "thread-late" })
        XCTAssertEqual(association.session?.runAttemptID, firstAttempt.runAttemptID, "the late write carries its owner's attempt")
        XCTAssertEqual(AgentRuntimeOperationOwner.current, .unavailable)
    }
}
