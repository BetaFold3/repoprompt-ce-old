import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
import XCTest

/// Spec R6 runtime-ownership registry over a temporary recovery store and a scripted process
/// system: the coupled activation gate, reservation/commit/fence lifecycle, conservative family
/// discovery, exit watches, coalesced rediscovery, preserved records, Let finish, and the Stop
/// engine with injected actions. Nothing inspects, watches or signals a real process.
final class AgentProcessRegistryTests: XCTestCase {
    private typealias Fixtures = AgentProcessRegistryFixtures

    private var root: URL!
    private var recoveryRoot: URL!
    private var failures: RecoveryStoreWriteFailureSwitch!
    private var processes: ScriptedProcessSystem!
    private var registries: [AgentProcessRegistry] = []

    override func setUpWithError() throws {
        root = try RecoveryTestSupport.makeTemporaryRoot("AgentProcessRegistryTests")
        recoveryRoot = root.appendingPathComponent("AgentRecovery/v1", isDirectory: true)
        failures = RecoveryStoreWriteFailureSwitch()
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

    // MARK: Fixtures

    private func makeStore() -> AgentRecoveryStore {
        AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID(), fileOperations: failures.fileOperations())
    }

    private func makeRegistry(
        store: AgentRecoveryStore,
        qualification: AgentRuntimeQualification = AgentProcessRegistryFixtures.qualified(),
        stop: Bool = false
    ) -> AgentProcessRegistry {
        let registry = AgentProcessRegistry(
            store: store,
            qualification: qualification,
            system: processes.system,
            stopActions: stop ? processes.stopActions : nil
        )
        registries.append(registry)
        return registry
    }

    private func newLaunch(
        _ registry: AgentProcessRegistry,
        family: AgentRuntimeFamily = .claudeNative,
        provider: AgentRuntimeProvider? = nil,
        session: AgentRuntimeSessionScope = .sessionless,
        worktreePath: String? = "/tmp/rpce-wt",
        conversationID: String? = nil,
        permission: AgentRuntimePermissionSnapshot = .unavailable
    ) throws -> AgentRuntimeLaunch {
        try XCTUnwrap(AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(Fixtures.context(
            family,
            provider: provider,
            session: session,
            worktreePath: worktreePath,
            conversationID: conversationID,
            permission: permission
        )))
    }

    private func assertThrows(
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

    private func signalNames() -> [String] {
        processes.sentSignals.map { sent in
            let name = sent.signal == SIGTERM ? "TERM" : sent.signal == SIGKILL ? "KILL" : "\(sent.signal)"
            return "\(sent.group):\(name)"
        }
    }

    // MARK: Activation gate

    func testProductionActivationStaysOffAndInactiveRegistryRefusesReservations() async {
        // 9-flip (2026-10-29, after 9-live round 4 passed): production is `.claudeAndCodex`; its runtime
        // activates registration but covers only a subset, and fresh --session-id stays off.
        XCTAssertEqual(AgentRecoveryActivation.production, .claudeAndCodex)
        XCTAssertTrue(AgentRecoveryActivation.production.runtime.activatesRegistration)
        XCTAssertFalse(AgentRecoveryActivation.production.runtime.coversAllSupportedPairs)
        XCTAssertFalse(AgentRecoveryActivation.production.runtime.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))
        XCTAssertFalse(AgentRecoveryActivation.off.runtime.activatesRegistration)
        // Subset activation: any covered supported pair activates registration; only all of them
        // speak for the whole app.
        var partial = Fixtures.qualified(freshSessionID: true)
        partial.families[.acp] = nil
        XCTAssertTrue(partial.activatesRegistration, "subset activation: covered pairs register")
        XCTAssertFalse(partial.coversAllSupportedPairs, "an uncovered family leaves whole-app proofs unavailable")
        XCTAssertTrue(Fixtures.qualified().coversAllSupportedPairs)
        XCTAssertTrue(partial.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)), "fresh --session-id follows its own pair")
        XCTAssertFalse(
            AgentRecoveryActivation.off.runtime.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)),
            "fresh --session-id is gated on activation"
        )
        XCTAssertTrue(Fixtures.qualified(freshSessionID: true).allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))
        XCTAssertFalse(Fixtures.qualified(freshSessionID: true).allowsFreshSessionID(.claudeCompatible, provider: .claude(.glm)))
        XCTAssertFalse(
            Fixtures.qualified(freshSessionID: true).allowsFreshSessionID(.claudeNative, provider: .claude(.kimi)),
            "qualification is keyed to the actual provider, never the family alone"
        )
        XCTAssertFalse(Fixtures.qualified().allowsFreshSessionID(.claudeNative, provider: .claude(.standard)), "fresh --session-id is a separate gate")
        var emptyProviders = AgentRuntimeQualification(families: [:])
        emptyProviders.families[.acp] = Fixtures.qualified().families[.acp]
        emptyProviders.families[.acp]?.providers = []
        XCTAssertFalse(emptyProviders.activatesRegistration, "a family qualified for no actual provider does not activate")

        XCTAssertNil(AgentProcessRegistry.production, "XCTest composes no production registry")
        guard case .activationOff = AgentRuntimeLaunchAuthority.production else {
            return XCTFail("Without a production registry (XCTest), launch authority must stay off")
        }
        XCTAssertNil(AgentRuntimeLaunchAuthority.activationOff.makeLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/x")))
        XCTAssertFalse(AgentRuntimeLaunchAuthority.activationOff.isRegistrationActive(family: .claudeNative, provider: .claude(.standard)))
        XCTAssertFalse(AgentRuntimeLaunchAuthority.activationOff.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))

        let registry = makeRegistry(store: makeStore(), qualification: AgentRecoveryActivation.off.runtime)
        XCTAssertFalse(registry.isAnyPairRegistered)
        await registry.start()
        XCTAssertNil(
            AgentRuntimeLaunchAuthority.registry(registry).makeLaunch(Fixtures.context(.codexAppServer, worktreePath: "/tmp/x")),
            "an inactive registry issues no launch owner (no shadow reservations)"
        )
        await assertThrows(.registrationInactive) {
            _ = try await registry.reserveLaunch(Fixtures.context(.codexAppServer, worktreePath: "/tmp/x"))
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0)
        let stopEnabled = await registry.isStopEnabled
        XCTAssertFalse(stopEnabled, "production registries carry no Stop actions")
    }

    func testExistingRecordsAreEnforcedWhileRegistrationIsOff() async throws {
        processes.add(processes.observation(pid: 500, group: 500))
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 500),
            rootGroup: 500,
            conversationIDs: ["conv-A"],
            worktreePaths: ["/tmp/wt-a"]
        )
        let registry = makeRegistry(store: makeStore(), qualification: AgentRecoveryActivation.off.runtime)
        let snapshot = await registry.start()

        XCTAssertEqual(snapshot.restrictions.map(\.runtimeID), [seeded.runtimeID])
        let restriction = try XCTUnwrap(snapshot.restrictions.first)
        XCTAssertEqual(restriction.kind, .possibleWriter)
        XCTAssertEqual(restriction.state, .unknown, "an alive writer under unqualified discovery stays unresolved")
        XCTAssertTrue(restriction.isPreviousInstance)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-A", worktreePath: "/tmp/elsewhere")))
        XCTAssertFalse(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-B", worktreePath: "/tmp/wt-b")),
            "unrelated conversations continue"
        )
        XCTAssertFalse(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-B", worktreePath: "/tmp/wt-a")),
            "an associated writer blocks its own conversation, not other sends on the worktree"
        )
        XCTAssertTrue(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-a/sub")))
        XCTAssertFalse(snapshot.hasGlobalUncertainty)
    }

    func testRootExitNeverProvesFamilyExitWithoutCompleteQualifiedDiscovery() async throws {
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 501),
            conversationIDs: ["conv-A"]
        )
        let unqualified = makeRegistry(store: makeStore(), qualification: AgentRecoveryActivation.off.runtime)
        var snapshot = await unqualified.start()
        XCTAssertEqual(snapshot.restrictions.first?.state, .unknown, "root gone, family discovery unqualified")
        await unqualified.disposeWatches()

        processes.inventoryIsIncomplete = true
        let store = makeStore()
        let qualified = makeRegistry(store: store)
        snapshot = await qualified.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "root gone, inventory incomplete")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-A", worktreePath: nil)))

        processes.inventoryIsIncomplete = false
        await qualified.refresh()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .exited, "complete qualified discovery proves exit")
        snapshot = await qualified.restrictionSnapshot()
        XCTAssertTrue(snapshot.restrictions.isEmpty)
    }

    func testRootlessReservationStaysUnresolvedWithoutMarkerEvidence() async throws {
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, state: .reserved, root: nil, worktreePaths: ["/tmp/wt-r"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "an absent marker never proves exit")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-r")))
    }

    // MARK: Launch lifecycle

    func testFailedReservationWritesNothingAndTheLaunchCannotCommitOrRetry() async throws {
        let registry = makeRegistry(store: makeStore())
        await registry.start()
        failures.shouldFailWrites = true
        let launch = try newLaunch(registry, conversationID: "conv-A")
        do {
            _ = try await launch.prepareSpawn()
            XCTFail("Expected the reservation write to fail")
        } catch {
            guard case .storage = error as? AgentProcessRegistryError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0)
        let runtimeID = await launch.runtimeID
        XCTAssertNil(runtimeID)
        await assertThrows(.staleLaunch) { try await launch.commitSpawn(pid: 10, processGroupID: nil) }
        await assertThrows(.staleLaunch) { try await launch.authorizeWrite() }
        failures.shouldFailWrites = false
        await assertThrows(.staleLaunch) { _ = try await launch.prepareSpawn() }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0)
    }

    func testTwoWriterRuleRefusesConflictingReservationAndAssociationWithoutWriting() async throws {
        processes.add(processes.observation(pid: 600, group: 600))
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 600),
            rootGroup: 600,
            conversationIDs: ["conv-A"],
            worktreePaths: ["/tmp/wt-a"]
        )
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .live)

        await assertThrows(.ownershipConflict(runtimeID: seeded.runtimeID)) {
            _ = try await registry.reserveLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/elsewhere", conversationID: "conv-A"))
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 1, "a refused reservation writes nothing")

        let unrelated = try await registry.reserveLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/wt-b", conversationID: "conv-B"))
        XCTAssertEqual(Fixtures.record(store, unrelated.runtimeID)?.state, .reserved, "unrelated work continues")
        await assertThrows(.ownershipConflict(runtimeID: seeded.runtimeID)) {
            try await registry.associate(
                runtimeID: unrelated.runtimeID,
                launchToken: unrelated.launchToken,
                association: AgentRuntimeAssociation(session: nil, conversationID: "conv-A", worktreePath: nil, permission: .unavailable)
            )
        }
        XCTAssertEqual(Fixtures.record(store, unrelated.runtimeID)?.conversationIDs, ["conv-B"])
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertEqual(snapshot.restrictions.map(\.runtimeID), [seeded.runtimeID], "an active launch restricts nothing")
    }

    func testCommitFailuresLeaveOwnershipUnresolvedAndFenceEveryWrite() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()

        // Birth identity unavailable.
        let denied = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-denied")
        let deniedID = try await denied.prepareSpawn()
        processes.deny(pid: 700)
        await assertThrows(.identityUnavailable) { try await denied.commitSpawn(pid: 700, processGroupID: 700) }
        XCTAssertEqual(Fixtures.record(store, deniedID)?.state, .unknown)
        await assertThrows(.staleLaunch) { try await denied.authorizeWrite() }
        await assertThrows(.staleLaunch) { try await denied.associate(conversationID: "thread-1") }

        // Commit write failure.
        let unwritten = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-unwritten")
        let unwrittenID = try await unwritten.prepareSpawn()
        processes.add(processes.observation(pid: 701, executable: "/opt/fixture/bin/codex", group: 701, marker: unwrittenID))
        failures.shouldFailWrites = true
        do {
            try await unwritten.commitSpawn(pid: 701, processGroupID: 701)
            XCTFail("Expected the commit write to fail")
        } catch {
            guard case .storage = error as? AgentProcessRegistryError else { return XCTFail("\(error)") }
        }
        failures.shouldFailWrites = false
        XCTAssertEqual(Fixtures.record(store, unwrittenID)?.state, .reserved, "the durable record keeps its reservation")
        await assertThrows(.staleLaunch) { try await unwritten.authorizeWrite() }

        let snapshot = await registry.restrictionSnapshot()
        let restricted = Dictionary(uniqueKeysWithValues: snapshot.restrictions.map { ($0.runtimeID, $0) })
        XCTAssertEqual(restricted[deniedID]?.kind, .possibleWriter)
        XCTAssertEqual(restricted[unwrittenID]?.state, .unknown, "an unpersisted classification is unresolved")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-denied")))
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "thread-9", worktreePath: "/tmp/wt-unwritten")))
    }

    /// Lossless restart Phase 4 §G Stage B proof and the Claude history home lookup.
    func testRestartStageBProofAndClaudeHistoryHomesFollowRegisteredRecords() async throws {
        let inactive = makeRegistry(store: makeStore(), qualification: AgentRecoveryActivation.off.runtime)
        await inactive.start()
        let inactiveProof = await inactive.verifyAllFamiliesStopped()
        XCTAssertEqual(inactiveProof, .notProven("Runtime registration is not active."))

        let store = makeStore()
        let registry = makeRegistry(store: store)
        let unchecked = await registry.verifyAllFamiliesStopped()
        XCTAssertEqual(unchecked, .notProven("Runtime ownership has not been checked yet."))
        await registry.start()
        let empty = await registry.verifyAllFamiliesStopped()
        XCTAssertEqual(empty, .allStopped)
        // Review A P1-08: the proof seals launches for the rest of the process (Stage B has no Cancel),
        // sessionless probes included, so nothing can start between the proof, the arm and the exit.
        let sealed = await registry.isSealedForSafeRestart
        XCTAssertTrue(sealed)
        let sessionless = try newLaunch(registry, session: .sessionless)
        await assertThrows(.launchesSealed) { _ = try await sessionless.prepareSpawn() }
        let afterSealed = try newLaunch(registry, conversationID: "conv-A")
        await assertThrows(.launchesSealed) { _ = try await afterSealed.prepareSpawn() }
        XCTAssertEqual(processes.sentSignals.count, 0)

        let liveRegistry = makeRegistry(store: makeStore())
        await liveRegistry.start()
        let launch = try newLaunch(liveRegistry, conversationID: "conv-A")
        let runtimeID = try await launch.prepareSpawn()
        let reserved = await liveRegistry.verifyAllFamiliesStopped()
        XCTAssertEqual(reserved, .notProven("A provider launch is still in progress."), "a durable reservation is never proof")
        processes.add(processes.observation(pid: 800, group: 800, marker: runtimeID, home: "/Users/fixture/.claude-alt"))
        try await launch.commitSpawn(pid: 800, processGroupID: 800)

        let homes = await liveRegistry.claudeProviderHomes(conversationID: "conv-A")
        XCTAssertEqual(homes, ["/Users/fixture/.claude-alt"], "the observed CLAUDE_CONFIG_DIR of the exact conversation")
        let otherHomes = await liveRegistry.claudeProviderHomes(conversationID: "conv-other")
        XCTAssertEqual(otherHomes, [])
        let live = await liveRegistry.verifyAllFamiliesStopped()
        guard case .notProven = live else { return XCTFail("a live family is never proof that everything stopped") }
        XCTAssertEqual(processes.sentSignals.count, 0, "the proof never signals")
    }

    func testStaleLaunchGenerationsAreFencedAfterRootReap() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        let launch = try newLaunch(registry, conversationID: "conv-A")
        let runtimeID = try await launch.prepareSpawn()
        processes.add(processes.observation(pid: 800, group: 800, marker: runtimeID, home: "/Users/fixture/.claude-alt"))
        processes.add(processes.observation(pid: 801, start: 200, parent: 800, executable: "/usr/bin/node", group: 800, marker: runtimeID))
        try await launch.commitSpawn(pid: 800, processGroupID: 800)

        var record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.state, .live)
        XCTAssertEqual(record.root, processes.identity(pid: 800))
        XCTAssertEqual(record.providerHome, "/Users/fixture/.claude-alt", "the home comes from the process's own environment")
        try await launch.authorizeWrite(conversationID: "conv-A")
        await assertThrows(.ownershipConflict(runtimeID: nil)) { try await launch.authorizeWrite(conversationID: "conv-other") }
        XCTAssertEqual(processes.liveWatchCount(pid: 800), 1)
        await assertThrows(.staleLaunch) { _ = try await launch.prepareSpawn() }

        // The root exits and is reaped by its launcher; its tool survives, reparented to launchd.
        processes.remove(pid: 800)
        processes.add(processes.observation(pid: 801, start: 200, parent: 1, executable: "/usr/bin/node", group: 800, marker: runtimeID))
        await launch.rootReaped(pid: 800, confirmed: true)
        record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertTrue(record.rootReaped)
        XCTAssertEqual(record.state, .toolsRemaining, "root exit is not family exit")
        XCTAssertEqual(record.members.map(\.role), [.tool])
        await assertThrows(.staleLaunch) { try await launch.authorizeWrite(conversationID: "conv-A") }
        await assertThrows(.staleLaunch) { try await launch.associate(conversationID: "conv-Z") }

        let snapshot = await registry.restrictionSnapshot()
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-A", worktreePath: "/tmp/rpce-wt")))
        XCTAssertTrue(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: "conv-B", worktreePath: "/tmp/rpce-wt")))

        await launch.spawnFailed()
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .toolsRemaining, "a late callback of an ended launch is ignored")

        XCTAssertEqual(processes.processExited(pid: 801), 1, "every identified member is watched")
        let exited = await Fixtures.eventually { Fixtures.record(store, runtimeID)?.state == .exited }
        XCTAssertTrue(exited)
    }

    /// Q4 writer basenames: under `.claudeAndCodex` (writers `["claude"]`, no tool basenames) a
    /// marker-bearing family member running as `node` (an npm-installed Claude, or any tool) is never
    /// a harmless tool: after its root exits it keeps the conversation blocked, unlike the fixture
    /// qualification that lists `node` as a tool.
    func testNodeBasenameMemberKeepsBlockingSendsUnderClaudeAndCodex() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let launch = try newLaunch(registry, conversationID: "conv-A")
        let runtimeID = try await launch.prepareSpawn()
        processes.add(processes.observation(pid: 820, group: 820, marker: runtimeID))
        processes.add(processes.observation(pid: 821, start: 200, parent: 820, executable: "/usr/bin/node", group: 820, marker: runtimeID))
        try await launch.commitSpawn(pid: 820, processGroupID: 820)

        processes.remove(pid: 820)
        processes.add(processes.observation(pid: 821, start: 200, parent: 1, executable: "/usr/bin/node", group: 820, marker: runtimeID))
        await launch.rootReaped(pid: 820, confirmed: true)
        let record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertNotEqual(record.state, .toolsRemaining, "a `node` member is not positively a tool")
        XCTAssertFalse(record.members.contains { $0.role == .tool })
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertTrue(
            snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-A", worktreePath: "/tmp/rpce-wt")),
            "an unlisted basename stays a possible writer and blocks its conversation"
        )
    }

    /// O42: under a shim that sets `CLAUDE_CONFIG_DIR` only for its child, the real native-installer
    /// CLI (`…/claude/versions/<version>`, basename = the version) is the writer, so its home is
    /// recorded; the root's own environment has none.
    func testNativeInstallerClaudeDescendantIsTheWriterAndRecordsItsHome() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let launch = try newLaunch(registry, conversationID: "conv-H")
        let runtimeID = try await launch.prepareSpawn()
        processes.add(processes.observation(pid: 830, executable: "/opt/fixture/bin/node", group: 830, marker: runtimeID))
        processes.add(processes.observation(
            pid: 831,
            start: 200,
            parent: 830,
            executable: "/Users/fixture/.local/share/claude/versions/2.1.302",
            group: 830,
            marker: runtimeID,
            home: "/Users/fixture/.claude-rotator/profiles/a"
        ))
        try await launch.commitSpawn(pid: 830, processGroupID: 830)
        XCTAssertNil(Fixtures.record(store, runtimeID)?.providerHome, "the shim's environment carries no home")

        await registry.refresh()
        let record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.members.map(\.identity.pid), [831])
        XCTAssertEqual(record.members.map(\.role), [.writer])
        XCTAssertEqual(record.providerHome, "/Users/fixture/.claude-rotator/profiles/a")
        let homes = await registry.claudeProviderHomes(conversationID: "conv-H")
        XCTAssertEqual(homes, ["/Users/fixture/.claude-rotator/profiles/a"])
        let allHomes = await registry.allClaudeProviderHomes()
        XCTAssertEqual(allHomes, ["/Users/fixture/.claude-rotator/profiles/a"])
    }

    /// O42 review B P1-2: a nested Claude that a tool started (shim → real CLI → bash → nested CLI,
    /// all carrying the marker) is a writer, but only the writer closest to the root supplies the home.
    func testANestedClaudeStartedByAToolNeverSuppliesTheHome() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let launch = try newLaunch(registry, conversationID: "conv-nested")
        let runtimeID = try await launch.prepareSpawn()
        let versions = "/Users/fixture/.local/share/claude/versions/2.1.302"
        processes.add(processes.observation(pid: 860, executable: "/opt/fixture/bin/node", group: 860, marker: runtimeID))
        processes.add(processes.observation(
            pid: 861, start: 200, parent: 860, executable: versions, group: 860, marker: runtimeID, home: "/fixture/home-a"
        ))
        processes.add(processes.observation(pid: 862, start: 300, parent: 861, executable: "/bin/bash", group: 862, marker: runtimeID))
        processes.add(processes.observation(
            pid: 863, start: 400, parent: 862, executable: versions, group: 862, marker: runtimeID, home: "/fixture/home-b"
        ))
        try await launch.commitSpawn(pid: 860, processGroupID: 860)

        await registry.refresh()
        let record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.members.map(\.identity.pid), [861, 862, 863])
        XCTAssertEqual(record.members.map(\.role), [.writer, .unknown, .writer], "the nested CLI still counts as a possible writer")
        XCTAssertEqual(record.providerHome, "/fixture/home-a")

        // Without the session's CLI observed, the nested CLI (whose nearest writer ancestor is not the
        // root) supplies nothing either.
        let boot = UUID()
        let nested = AgentRuntimeProcessIdentity(bootSessionID: boot, pid: 3, startSeconds: 3, startMicroseconds: 0, uid: 0)
        XCTAssertNil(AgentProcessRegistry.closestWriterHome(
            root: AgentRuntimeProcessIdentity(bootSessionID: boot, pid: 1, startSeconds: 1, startMicroseconds: 0, uid: 0),
            roles: [nested: .writer],
            observations: [nested: processes.observation(pid: 3, start: 3, parent: 2, executable: versions, home: "/fixture/home-b")]
        ))
    }

    /// O42: a member first seen with an unreadable environment stays unknown with no home; once its
    /// marker is readable it upgrades to the writer and supplies the home.
    func testAnUnknownMemberUpgradesToTheWriterOnceItsEnvironmentIsReadable() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let launch = try newLaunch(registry, conversationID: "conv-U")
        let runtimeID = try await launch.prepareSpawn()
        let versions = "/Users/fixture/.local/share/claude/versions/2.1.302"
        processes.add(processes.observation(pid: 870, executable: "/opt/fixture/bin/node", group: 870, marker: runtimeID))
        processes.add(processes.observation(pid: 871, start: 200, parent: 870, executable: versions, group: 870, environmentAvailable: false))
        try await launch.commitSpawn(pid: 870, processGroupID: 870)

        await registry.refresh()
        var record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.members.map(\.role), [.unknown])
        XCTAssertNil(record.providerHome)

        processes.add(processes.observation(
            pid: 871, start: 200, parent: 870, executable: versions, group: 870, marker: runtimeID, home: "/fixture/home-u"
        ))
        await registry.refresh()
        record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.members.map(\.role), [.writer])
        XCTAssertEqual(record.providerHome, "/fixture/home-u")
    }

    /// O42 review B P1-1 (round 1): discovery has no timer or spawn event, so a lookup that saw only
    /// the shim doesn't end the retries: once the child appears, the next lookup refreshes and returns
    /// its home. Reservations never refresh; a runtime whose writer was seen without a home stops
    /// refreshing; otherwise at most `maxHomeRefreshesPerRuntime` lookups refresh.
    func testHomeLookupRefreshesUntilTheWriterIsSeenWithinTheCap() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let none = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-none")
        XCTAssertEqual(none, [])
        let versions = "/opt/fixture/claude/versions/2.1.302"
        let launch = try newLaunch(registry, worktreePath: "/tmp/rpce-wt-r", conversationID: "conv-R")
        let runtimeID = try await launch.prepareSpawn()
        var before = processes.inventoryCalls
        let reserved = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-R")
        XCTAssertEqual(reserved, [])
        XCTAssertEqual(processes.inventoryCalls, before, "a reservation has no process to observe")
        processes.add(processes.observation(pid: 880, executable: "/opt/fixture/bin/node", group: 880, marker: runtimeID))
        try await launch.commitSpawn(pid: 880, processGroupID: 880)

        before = processes.inventoryCalls
        let shimOnly = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-R")
        XCTAssertEqual(shimOnly, [])
        XCTAssertEqual(processes.inventoryCalls, before + 1, "one discovery pass")
        processes.add(processes.observation(
            pid: 881, start: 200, parent: 880, executable: versions, group: 880, marker: runtimeID, home: "/fixture/home-r"
        ))
        let found = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-R")
        XCTAssertEqual(found, ["/fixture/home-r"], "the child appeared: the second lookup refreshes and returns its home")
        XCTAssertEqual(processes.inventoryCalls, before + 2)
        let recorded = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-R")
        XCTAssertEqual(recorded, ["/fixture/home-r"], "a recorded home is returned without a refresh")
        XCTAssertEqual(processes.inventoryCalls, before + 2)

        // The writer seen with a readable environment and no home: another refresh can't help.
        let settled = try newLaunch(registry, worktreePath: "/tmp/rpce-wt-s", conversationID: "conv-S")
        let settledID = try await settled.prepareSpawn()
        processes.add(processes.observation(pid: 882, executable: "/opt/fixture/bin/node", group: 882, marker: settledID))
        processes.add(processes.observation(pid: 883, start: 200, parent: 882, executable: versions, group: 882, marker: settledID))
        try await settled.commitSpawn(pid: 882, processGroupID: 882)
        before = processes.inventoryCalls
        _ = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-S")
        _ = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-S")
        XCTAssertEqual(processes.inventoryCalls, before + 1, "no refresh after the writer was seen without a home")

        // The shim alone forever: at most the cap.
        let capped = try newLaunch(registry, worktreePath: "/tmp/rpce-wt-c", conversationID: "conv-C")
        let cappedID = try await capped.prepareSpawn()
        processes.add(processes.observation(pid: 884, executable: "/opt/fixture/bin/node", group: 884, marker: cappedID))
        try await capped.commitSpawn(pid: 884, processGroupID: 884)
        before = processes.inventoryCalls
        for _ in 0 ..< AgentProcessRegistry.maxHomeRefreshesPerRuntime + 2 {
            _ = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-C")
        }
        XCTAssertEqual(processes.inventoryCalls, before + AgentProcessRegistry.maxHomeRefreshesPerRuntime)
    }

    /// O42 review A P1 (round 2): a nested homeless writer under an unreadable outer CLI never settles
    /// the runtime, so the next lookup refreshes and returns the outer CLI's home once it is readable.
    func testANestedHomelessWriterNeverEndsTheHomeLookupRetries() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let launch = try newLaunch(registry, conversationID: "conv-nested-homeless")
        let runtimeID = try await launch.prepareSpawn()
        let versions = "/Users/fixture/.local/share/claude/versions/2.1.302"
        processes.add(processes.observation(pid: 900, executable: "/opt/fixture/bin/node", group: 900, marker: runtimeID))
        processes.add(processes.observation(pid: 901, start: 200, parent: 900, executable: versions, group: 900, environmentAvailable: false))
        processes.add(processes.observation(pid: 902, start: 300, parent: 901, executable: "/bin/bash", group: 902, marker: runtimeID))
        processes.add(processes.observation(pid: 903, start: 400, parent: 902, executable: versions, group: 902, marker: runtimeID))
        try await launch.commitSpawn(pid: 900, processGroupID: 900)

        var before = processes.inventoryCalls
        let first = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-nested-homeless")
        XCTAssertEqual(first, [])
        XCTAssertEqual(processes.inventoryCalls, before + 1)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.members.map(\.role), [.unknown, .unknown, .writer])

        processes.add(processes.observation(
            pid: 901, start: 200, parent: 900, executable: versions, group: 900, marker: runtimeID, home: "/fixture/home-a"
        ))
        before = processes.inventoryCalls
        let second = await registry.claudeProviderHomesRefreshingIfPending(conversationID: "conv-nested-homeless")
        XCTAssertEqual(processes.inventoryCalls, before + 1, "the nested homeless writer didn't settle the runtime")
        XCTAssertEqual(second, ["/fixture/home-a"])
    }

    /// O42 review A P1 (round 1): an unknown member between a writer and the root (the real CLI while
    /// its environment is unreadable) is a barrier, so a nested Claude never supplies the home; once
    /// the real CLI is readable, its home is recorded.
    func testAnUnknownAncestorBlocksANestedClaudesHome() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let launch = try newLaunch(registry, conversationID: "conv-barrier")
        let runtimeID = try await launch.prepareSpawn()
        let versions = "/Users/fixture/.local/share/claude/versions/2.1.302"
        processes.add(processes.observation(pid: 890, executable: "/opt/fixture/bin/node", group: 890, marker: runtimeID))
        processes.add(processes.observation(pid: 891, start: 200, parent: 890, executable: versions, group: 890, environmentAvailable: false))
        processes.add(processes.observation(pid: 892, start: 300, parent: 891, executable: "/bin/bash", group: 892, marker: runtimeID))
        processes.add(processes.observation(
            pid: 893, start: 400, parent: 892, executable: versions, group: 892, marker: runtimeID, home: "/fixture/home-b"
        ))
        try await launch.commitSpawn(pid: 890, processGroupID: 890)

        await registry.refresh()
        var record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.members.map(\.role), [.unknown, .unknown, .writer])
        XCTAssertNil(record.providerHome, "the nested CLI's home is never attributed through an unknown ancestor")

        processes.add(processes.observation(
            pid: 891, start: 200, parent: 890, executable: versions, group: 890, marker: runtimeID, home: "/fixture/home-a"
        ))
        await registry.refresh()
        record = try XCTUnwrap(Fixtures.record(store, runtimeID))
        XCTAssertEqual(record.members.map(\.role), [.writer, .unknown, .writer])
        XCTAssertEqual(record.providerHome, "/fixture/home-a")
    }

    /// O42: the native-installer path rule makes no writer outside a Claude family, nor a Claude
    /// descendant that lacks the family's own marker.
    func testNativeInstallerPathIsNoWriterOutsideClaudeOrWithoutTheMarker() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store, qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let codex = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/rpce-wt-codex")
        let codexID = try await codex.prepareSpawn()
        processes.add(processes.observation(pid: 840, executable: "/opt/fixture/bin/codex", group: 840, marker: codexID))
        processes.add(processes.observation(
            pid: 841, start: 200, parent: 840, executable: "/opt/fixture/claude/versions/2.1.302", group: 840, marker: codexID
        ))
        try await codex.commitSpawn(pid: 840, processGroupID: 840)

        let claude = try newLaunch(registry, worktreePath: "/tmp/rpce-wt-claude", conversationID: "conv-N")
        let claudeID = try await claude.prepareSpawn()
        processes.add(processes.observation(pid: 850, executable: "/opt/fixture/bin/node", group: 850, marker: claudeID))
        processes.add(processes.observation(
            pid: 851,
            start: 200,
            parent: 850,
            executable: "/opt/fixture/claude/versions/2.1.302",
            group: 850,
            home: "/Users/fixture/.claude-other"
        ))
        try await claude.commitSpawn(pid: 850, processGroupID: 850)

        await registry.refresh()
        XCTAssertEqual(Fixtures.record(store, codexID)?.members.map(\.role), [.unknown], "a non-Claude family never gains a writer by path")
        let claudeRecord = try XCTUnwrap(Fixtures.record(store, claudeID))
        XCTAssertEqual(claudeRecord.members.map(\.role), [.unknown], "a parent-linked descendant without the marker stays unknown")
        XCTAssertNil(claudeRecord.providerHome, "an unknown member's environment is never the home")

        XCTAssertTrue(AgentProcessRegistry.isClaudeNativeInstallerExecutable("/Users/a/.local/share/claude/versions/2.1.302"))
        XCTAssertFalse(AgentProcessRegistry.isClaudeNativeInstallerExecutable("/Users/a/.local/share/other/versions/2.1.302"))
        XCTAssertFalse(AgentProcessRegistry.isClaudeNativeInstallerExecutable("/Users/a/claude/versions"))
        XCTAssertFalse(AgentProcessRegistry.isClaudeNativeInstallerExecutable("/versions/2.1.302"))
    }

    // MARK: Discovery

    func testPIDReuseAndDeniedInspection() async throws {
        // The recorded root PID now belongs to an unrelated later process.
        processes.add(processes.observation(pid: 900, start: 999, executable: "/bin/zsh", group: 900))
        let reused = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 900, start: 10), conversationIDs: ["conv-reused"])
        let denied = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 901), conversationIDs: ["conv-denied"])
        processes.deny(pid: 901)
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()

        let reusedRecord = try XCTUnwrap(Fixtures.record(store, reused.runtimeID))
        XCTAssertEqual(reusedRecord.state, .exited, "a different birth identity proves only that the lifetime ended")
        XCTAssertTrue(reusedRecord.members.isEmpty, "the reused PID never joins the family")
        XCTAssertEqual(Fixtures.record(store, denied.runtimeID)?.state, .unknown, "denied inspection is never exit")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-denied", worktreePath: nil)))
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-reused", worktreePath: nil)))
    }

    func testMixedExecUpgradesToolsToWritersAndNeverDemotesWriters() async throws {
        processes.add(processes.observation(pid: 951, start: 200, parent: 1, executable: "/opt/fixture/bin/claude", group: 950))
        processes.add(processes.observation(pid: 952, start: 210, parent: 1, executable: "/usr/bin/node", group: 950))
        let seeded = try Fixtures.seed(
            rootURL: recoveryRoot,
            root: processes.identity(pid: 950),
            rootGroup: 950,
            members: [
                AgentRuntimeMember(identity: processes.identity(pid: 951, start: 200), processGroupID: 950, role: .tool),
                AgentRuntimeMember(identity: processes.identity(pid: 952, start: 210), processGroupID: 950, role: .writer)
            ],
            conversationIDs: ["conv-M"]
        )
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()

        let record = try XCTUnwrap(Fixtures.record(store, seeded.runtimeID))
        XCTAssertEqual(record.state, .live)
        XCTAssertEqual(record.members.map(\.identity.pid), [951, 952])
        XCTAssertEqual(record.members.map(\.role), [.writer, .writer], "exec into a writer upgrades; writers are never demoted")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-M", worktreePath: nil)))
        // 9-live S5: the restriction names the root and its first writer member (the agent's own PID).
        XCTAssertEqual(snapshot.restrictions.first?.rootPID, 950)
        XCTAssertEqual(snapshot.restrictions.first?.writerPID, 951)
    }

    func testMarkersAndParentLinksFindDescendantsButNotEarlierBornOrAppProcesses() async throws {
        processes.add(processes.observation(pid: 960, executable: "/opt/fixture/bin/claude", group: 960))
        processes.add(processes.observation(pid: 961, start: 200, parent: 960, executable: "/usr/bin/node", group: 961))
        processes.add(processes.observation(pid: 963, start: 300, parent: 961, executable: nil, group: 961, environmentAvailable: false))
        // Born before the root: a parent-PID match through PID reuse, never a member.
        processes.add(processes.observation(pid: 964, start: 50, parent: 960, executable: "/usr/bin/node", group: 964))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 960), rootGroup: 960, conversationIDs: ["conv-F"])
        // A reparented tool found only by its marker, and the app itself carrying the same marker.
        processes.add(processes.observation(pid: 962, start: 250, parent: 1, executable: "/usr/bin/node", group: 962, marker: seeded.runtimeID))
        processes.add(processes.observation(pid: processes.appPID, start: 20, parent: 1, group: processes.appProcessGroupID, marker: seeded.runtimeID))

        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()

        let record = try XCTUnwrap(Fixtures.record(store, seeded.runtimeID))
        XCTAssertEqual(record.members.map(\.identity.pid), [961, 962, 963])
        XCTAssertEqual(record.members.map(\.role), [.tool, .tool, .unknown], "unclassifiable members stay unknown")
        XCTAssertEqual(record.state, .live)
        for pid: pid_t in [960, 961, 962, 963] {
            XCTAssertEqual(processes.liveWatchCount(pid: pid), 1, "watch every member, pid \(pid)")
        }
        XCTAssertEqual(processes.liveWatchCount(pid: 964), 0)
    }

    func testStaleWatchEventsAreIgnoredAndExitEventsRediscover() async throws {
        processes.add(processes.observation(pid: 970, group: 970))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 970), rootGroup: 970, conversationIDs: ["conv-W"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        XCTAssertEqual(processes.liveWatchCount(pid: 970), 1)

        let stale = processes.capturedHandlers(pid: 970)
        await registry.disposeWatches()
        XCTAssertEqual(processes.liveWatchCount(pid: 970), 0, "disposal cancels every watch")
        let passesBefore = processes.inventoryCalls
        stale.forEach { $0() }
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await registry.restrictionSnapshot()
        XCTAssertEqual(processes.inventoryCalls, passesBefore, "a disposed watch generation never triggers rediscovery")

        await registry.refresh()
        XCTAssertEqual(processes.liveWatchCount(pid: 970), 1, "refresh reinstalls the watch")
        processes.processExited(pid: 970)
        let exited = await Fixtures.eventually { Fixtures.record(store, seeded.runtimeID)?.state == .exited }
        XCTAssertTrue(exited)
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertTrue(snapshot.restrictions.isEmpty)
    }

    func testUnwatchableLifetimeStaysUnresolved() async throws {
        processes.add(processes.observation(pid: 980, group: 980))
        processes.makeUnwatchable(pid: 980)
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 980), rootGroup: 980, conversationIDs: ["conv-U"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "no polling fallback for a missed watch")
    }

    func testRediscoveryRequestsCoalesceIntoOneFollowUpPass() async throws {
        processes.add(processes.observation(pid: 990, group: 990))
        try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 990), rootGroup: 990, conversationIDs: ["conv-C"])
        let registry = makeRegistry(store: makeStore())
        await registry.start()
        let before = processes.inventoryCalls

        let gate = InventoryGate()
        processes.inventoryHook = { await gate.pass() }
        let first = Task { await registry.refresh() }
        await gate.waitForArrival()
        let followers = (0 ..< 3).map { _ in Task { await registry.refresh() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        await first.value
        for follower in followers {
            await follower.value
        }
        XCTAssertEqual(processes.inventoryCalls - before, 2, "requests during a pass coalesce into exactly one more pass")
    }

    // MARK: Preserved records and uncertainty

    func testUnidentifiableRecordIsGlobalUncertainty() async throws {
        let directory = recoveryRoot.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("not-a-runtime.json")
        try Data("{}".utf8).write(to: file)
        let registry = makeRegistry(store: makeStore())
        let snapshot = await registry.start()

        XCTAssertTrue(snapshot.hasGlobalUncertainty)
        XCTAssertEqual(snapshot.unidentifiedRecordCount, 1)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "anything", worktreePath: "/tmp/any")))
        await assertThrows(.ownershipUnknown) {
            _ = try await registry.reserveLaunch(Fixtures.context(.acp, worktreePath: "/tmp/any"))
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8), "preserved bytes are never rewritten")
    }

    func testUnreadableRecordWithBindingsIsScopedAndNonwritable() async throws {
        let runtimeID = UUID()
        let directory = recoveryRoot.appendingPathComponent("runtimes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(runtimeID.uuidString).json")
        let bytes = Data(#"{"schemaVersion":99,"conversationIDs":["conv-X"],"worktreePaths":["/tmp/wt-x"]}"#.utf8)
        try bytes.write(to: file)
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()

        XCTAssertFalse(snapshot.hasGlobalUncertainty)
        let restriction = try XCTUnwrap(snapshot.restrictions.first { $0.runtimeID == runtimeID })
        XCTAssertTrue(restriction.isUnreadable)
        XCTAssertNil(restriction.family)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-X", worktreePath: nil)))
        XCTAssertFalse(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-Y", worktreePath: "/tmp/wt-y")))
        XCTAssertTrue(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-x")))
        await assertThrows(.ownershipConflict(runtimeID: runtimeID)) {
            _ = try await registry.reserveLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/other", conversationID: "conv-X"))
        }
        await assertThrows(.staleLaunch) {
            try await registry.letFinish(runtimeID: runtimeID, expectedRevision: .make())
        }
        await registry.refresh()
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        if case .preserved = store.readRuntime(runtimeID: runtimeID) {} else { XCTFail("Expected a preserved record") }
    }

    func testRecordCodecRoundTripsWithoutArgumentsOrEnvironment() throws {
        let timestamp = AgentRecoveryTimestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let record = AgentRuntimeRecord(
            runtimeID: UUID(),
            revision: .make(),
            appInstanceID: UUID(),
            family: .codexAppServer,
            provider: .codex,
            providerHome: nil,
            state: .toolsRemaining,
            root: processes.identity(pid: 42),
            rootProcessGroupID: 42,
            rootReaped: true,
            members: [AgentRuntimeMember(identity: processes.identity(pid: 43, start: 7), processGroupID: 42, role: .tool)],
            associations: [
                AgentRuntimeAssociation(
                    session: Fixtures.session(),
                    conversationID: "thread-1",
                    worktreePath: "/tmp/wt",
                    permission: .codex(approvalPolicy: "on-request", sandbox: "workspace-write")
                ),
                AgentRuntimeAssociation(session: nil, conversationID: nil, worktreePath: nil, permission: .unavailable)
            ],
            conversationIDs: ["thread-1"],
            worktreePaths: ["/tmp/wt"],
            letFinish: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let data = try AgentRuntimeRecordCodec.encode(record)
        guard case let .success(decoded) = AgentRuntimeRecordCodec.decode(data, expectedRuntimeID: record.runtimeID) else {
            return XCTFail("Expected the record to round-trip")
        }
        XCTAssertEqual(decoded, record)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["argv", "arguments", "environment", "\"env\""] {
            XCTAssertFalse(text.contains(forbidden), "runtime records never persist \(forbidden)")
        }
        let unknownFamily = text.replacingOccurrences(of: "\"codexAppServer\"", with: "\"futureFamily\"")
        if case .success = AgentRuntimeRecordCodec.decode(Data(unknownFamily.utf8), expectedRuntimeID: record.runtimeID) {
            XCTFail("An unknown family variant must be preserved, not decoded")
        }
    }

    // MARK: Let finish

    func testLetFinishPersistsTheChoiceAndKeepsRestricting() async throws {
        processes.add(processes.observation(pid: 1100, group: 1100))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1100), rootGroup: 1100, conversationIDs: ["conv-L"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()
        let revision = try XCTUnwrap(snapshot.restrictions.first?.revision)

        try await registry.letFinish(runtimeID: seeded.runtimeID, expectedRevision: revision)
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.letFinish, true)
        let after = await registry.restrictionSnapshot()
        XCTAssertEqual(after.restrictions.first?.letFinish, true)
        XCTAssertTrue(
            after.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-L", worktreePath: nil)),
            "Let finish keeps watching and restricting"
        )
        XCTAssertEqual(processes.liveWatchCount(pid: 1100), 1)
        do {
            try await registry.letFinish(runtimeID: seeded.runtimeID, expectedRevision: revision)
            XCTFail("A stale revision must be refused")
        } catch {
            guard case .storage = error as? AgentProcessRegistryError else { return XCTFail("\(error)") }
        }
    }

    // MARK: Stop (injected actions only)

    private func seedStoppableFamily(group: pid_t = 1000) throws -> AgentRuntimeRecord {
        processes.add(processes.observation(pid: 1000, group: group))
        processes.add(processes.observation(pid: 1001, start: 200, parent: 1000, executable: "/usr/bin/node", group: group))
        return try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1000), rootGroup: group, conversationIDs: ["conv-S"])
    }

    private func stopPreview(_ registry: AgentProcessRegistry, _ runtimeID: UUID) async throws -> AgentRuntimeStopPreview {
        let preview = await registry.previewStop(runtimeID: runtimeID)
        return try XCTUnwrap(preview)
    }

    func testStopIsDisabledWithoutInjectedActions() async throws {
        let seeded = try seedStoppableFamily()
        let registry = makeRegistry(store: makeStore())
        await registry.start()
        let result = try await registry.stop(preview: stopPreview(registry, seeded.runtimeID))
        XCTAssertEqual(result, .disabled)
        XCTAssertTrue(processes.sentSignals.isEmpty)
    }

    func testStopSignalsVerifiedGroupsThenVerifiesExit() async throws {
        let seeded = try seedStoppableFamily()
        let store = makeStore()
        let registry = makeRegistry(store: store, stop: true)
        await registry.start()
        let preview = try await stopPreview(registry, seeded.runtimeID)
        XCTAssertTrue(preview.isComplete)
        XCTAssertEqual(preview.members.map(\.identity.pid), [1000, 1001])

        let result = await registry.stop(preview: preview)
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(signalNames(), ["1000:TERM"], "no SIGKILL once the family is verified gone")
        XCTAssertEqual(processes.recordedSleeps, [3])
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .stopped)
    }

    func testStopEscalatesToKillAfterTheGracePeriod() async throws {
        let seeded = try seedStoppableFamily()
        processes.survivesTERM = true
        let store = makeStore()
        let registry = makeRegistry(store: store, stop: true)
        await registry.start()
        let result = try await registry.stop(preview: stopPreview(registry, seeded.runtimeID))
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(signalNames(), ["1000:TERM", "1000:KILL"])
        XCTAssertEqual(processes.recordedSleeps, [3])
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .stopped)
    }

    func testStopRefusesChangedMembershipAndUnownedGroupMembers() async throws {
        let seeded = try seedStoppableFamily()
        let registry = makeRegistry(store: makeStore(), stop: true)
        await registry.start()

        var current = try await stopPreview(registry, seeded.runtimeID)
        processes.add(processes.observation(pid: 1002, start: 300, parent: 1, executable: "/usr/bin/node", group: 1000, marker: seeded.runtimeID))
        var result = await registry.stop(preview: current)
        XCTAssertEqual(result, .changed)
        processes.remove(pid: 1002)

        current = try await stopPreview(registry, seeded.runtimeID)
        processes.add(processes.observation(pid: 1003, start: 300, parent: 1, executable: "/bin/zsh", group: 1000))
        result = await registry.stop(preview: current)
        XCTAssertEqual(result, .refusedUnsafeGroup, "a group with an unowned process is never signalled")
        XCTAssertTrue(processes.sentSignals.isEmpty)
    }

    func testStopRefusesTheAppProcessGroup() async throws {
        let seeded = try seedStoppableFamily(group: processes.appProcessGroupID)
        let registry = makeRegistry(store: makeStore(), stop: true)
        await registry.start()
        let result = try await registry.stop(preview: stopPreview(registry, seeded.runtimeID))
        XCTAssertEqual(result, .refusedUnsafeGroup)
        XCTAssertTrue(processes.sentSignals.isEmpty)
    }

    func testStopRefusesIncompleteFamiliesAndPermissionDenialStaysUnresolved() async throws {
        let seeded = try seedStoppableFamily()
        let store = makeStore()
        let registry = makeRegistry(store: store, stop: true)
        await registry.start()

        processes.inventoryIsIncomplete = true
        var current = try await stopPreview(registry, seeded.runtimeID)
        XCTAssertFalse(current.isComplete)
        var result = await registry.stop(preview: current)
        XCTAssertEqual(result, .refusedUnsafeGroup, "an incomplete family is never signalled")
        XCTAssertTrue(processes.sentSignals.isEmpty)

        processes.inventoryIsIncomplete = false
        processes.signalErrno = EPERM
        current = try await stopPreview(registry, seeded.runtimeID)
        result = await registry.stop(preview: current)
        XCTAssertEqual(result, .unresolved, "EPERM leaves the item unresolved")
        XCTAssertNotEqual(Fixtures.record(store, seeded.runtimeID)?.state, .stopped)
    }

    func testStopRevalidatesEveryGroupMemberImmediatelyBeforeSignalling() async throws {
        let seeded = try seedStoppableFamily()
        let registry = makeRegistry(store: makeStore(), stop: true)
        await registry.start()

        // A process whose group cannot be read appears after the preview: membership is unverifiable.
        var current = try await stopPreview(registry, seeded.runtimeID)
        processes.add(processes.observation(pid: 1005, start: 300, parent: 1, executable: "/bin/zsh", group: nil))
        var result = await registry.stop(preview: current)
        XCTAssertEqual(result, .refusedUnsafeGroup, "unreadable group membership is never signalled")
        processes.remove(pid: 1005)

        // The root moved to another group after the preview: the observed group, not the persisted one.
        current = try await stopPreview(registry, seeded.runtimeID)
        processes.add(processes.observation(pid: 1000, group: 1010))
        result = await registry.stop(preview: current)
        XCTAssertEqual(result, .changed, "a member in another group than the reviewed one is a changed family")
        XCTAssertTrue(processes.sentSignals.isEmpty, "no signal from a stale membership view")
    }

    // MARK: Phase 3 remediation counterexamples

    func testUnreadableOwnershipEvidenceNeverProvesFamilyExit() async throws {
        // The root is gone; a reparented process born after it survives whose marker cannot be read.
        processes.add(processes.observation(pid: 1201, start: 200, parent: 1, executable: "/usr/bin/node", group: 1201, environmentAvailable: false))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1200), rootGroup: 1200, conversationIDs: ["conv-R1"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        let snapshot = await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "unreadable ownership evidence is incomplete discovery")
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-R1", worktreePath: nil)))

        processes.remove(pid: 1201)
        await registry.refresh()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .exited, "complete readable discovery proves exit")
    }

    func testUnfamiliarDescendantsAreUnknownNotTools() async throws {
        processes.add(processes.observation(pid: 1300, group: 1300))
        processes.add(processes.observation(pid: 1301, start: 200, parent: 1300, executable: "/opt/fixture/bin/unfamiliar-shim", group: 1300))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1300), rootGroup: 1300, conversationIDs: ["conv-R2"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()

        let record = try XCTUnwrap(Fixtures.record(store, seeded.runtimeID))
        XCTAssertEqual(record.members.map(\.role), [.unknown], "only explicit qualified tool evidence classifies a tool")

        // The root exits: an unknown member keeps the conversation restricted (never tool-only).
        processes.remove(pid: 1300)
        await registry.refresh()
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertNotEqual(Fixtures.record(store, seeded.runtimeID)?.state, .toolsRemaining)
        XCTAssertTrue(snapshot.blocksSend(AgentRuntimeOwnershipKeys(conversationID: "conv-R2", worktreePath: nil)))
    }

    func testActiveSameSessionRuntimesExcludeEachOtherBeforeAnyConversationIsKnown() async throws {
        let registry = makeRegistry(store: makeStore())
        await registry.start()
        let session = AgentRuntimeSessionScope.session(Fixtures.session())
        let first = try await registry.reserveLaunch(Fixtures.context(.claudeNative, session: session, worktreePath: "/tmp/wt-s1"))
        await assertThrows(.ownershipConflict(runtimeID: first.runtimeID)) {
            _ = try await registry.reserveLaunch(Fixtures.context(.claudeNative, session: session, worktreePath: "/tmp/wt-s2"))
        }
        // A different session continues.
        _ = try await registry.reserveLaunch(Fixtures.context(
            .claudeNative,
            session: .session(Fixtures.session()),
            worktreePath: "/tmp/wt-s3"
        ))
    }

    /// Subset activation (Step 9-activation): narrowed qualification activates registration for the
    /// covered pairs only. An uncovered pair gets no launch owner (it launches unregistered, as
    /// before activation); `reserveLaunch` still refuses a direct caller for it.
    func testNarrowedProviderQualificationRegistersOnlyCoveredPairs() async throws {
        let narrowedACP = Fixtures.qualified(providers: [.acp: [.acp(.cursor)]])
        XCTAssertTrue(narrowedACP.activatesRegistration, "subset activation")
        XCTAssertFalse(narrowedACP.coversAllSupportedPairs)
        let narrowedCompatible = Fixtures.qualified(providers: [.claudeCompatible: [.claude(.glm)]])
        XCTAssertTrue(narrowedCompatible.activatesRegistration)
        XCTAssertFalse(narrowedCompatible.covers(family: .claudeCompatible, provider: .claude(.kimi)))
        XCTAssertTrue(Fixtures.qualified().activatesRegistration)

        let registry = makeRegistry(store: makeStore(), qualification: narrowedACP)
        await registry.start()
        let authority = AgentRuntimeLaunchAuthority.registry(registry)
        XCTAssertFalse(authority.isRegistrationActive(family: .acp, provider: .acp(.openCode)))
        XCTAssertNil(
            authority.makeLaunch(Fixtures.context(.acp, provider: .acp(.openCode), worktreePath: "/tmp/x")),
            "no registration for an uncovered provider: it launches unregistered"
        )
        await assertThrows(.unqualifiedProvider) {
            _ = try await registry.reserveLaunch(Fixtures.context(.acp, provider: .acp(.openCode), worktreePath: "/tmp/x"))
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0, "an uncovered pair writes no runtime file")
        XCTAssertTrue(authority.isRegistrationActive(family: .acp, provider: .acp(.cursor)))
        let covered = try XCTUnwrap(authority.makeLaunch(Fixtures.context(.acp, provider: .acp(.cursor), worktreePath: "/tmp/x")))
        _ = try await covered.prepareSpawn()
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 1, "the covered pair reserves before its spawn")
    }

    /// D 3.5 item 2: under `.claudeAndCodex`, sessionless work (model listing, auth, Oracle print
    /// mode, Context Builder) on a covered pair reserves when it says `.sessionless` explicitly;
    /// a launch whose owner never bound a scope (`.unavailable`) is refused before its spawn.
    func testClaudeAndCodexSessionlessLaunchesReserveAndUnboundLaunchesAreRefused() async throws {
        let registry = makeRegistry(store: makeStore(), qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let covered: [(AgentRuntimeFamily, AgentRuntimeProvider)] = [
            (.claudeNative, .claude(.standard)),
            (.claudeHeadless, .claude(.standard)),
            (.codexAppServer, .codex),
            (.codexExec, .codex)
        ]
        for (family, provider) in covered {
            await assertThrows(.sessionContextUnavailable) {
                _ = try await registry.reserveLaunch(
                    Fixtures.context(family, provider: provider, session: .unavailable, worktreePath: nil)
                )
            }
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), 0, "a refused launch reserves nothing")
        for (family, provider) in covered {
            _ = try await registry.reserveLaunch(
                Fixtures.context(family, provider: provider, session: .sessionless, worktreePath: nil)
            )
        }
        XCTAssertEqual(Fixtures.runtimeFileCount(rootURL: recoveryRoot), covered.count, "each sessionless launch reserves")
    }

    /// O32 / Step 9-activation-a value test: `.claudeAndCodex` covers exactly the four Claude
    /// standard and Codex pairs; every other supported pair stays unregistered; its actions offer
    /// same-conversation resume and history reconciliation only.
    func testClaudeAndCodexActivationCoversExactlyTheFourQualifiedPairs() {
        let activation = AgentRecoveryActivation.claudeAndCodex
        let expected: [(AgentRuntimeFamily, AgentRuntimeProvider)] = [
            (.claudeNative, .claude(.standard)),
            (.claudeHeadless, .claude(.standard)),
            (.codexAppServer, .codex),
            (.codexExec, .codex)
        ]
        let pairs = AgentRuntimeQualification.supportedPairs
        XCTAssertEqual(pairs.count, 13, "the supported-pair inventory is unchanged")
        let covered = pairs.filter { activation.runtime.covers(family: $0.family, provider: $0.provider) }
        XCTAssertEqual(covered.map(\.family), expected.map(\.0))
        XCTAssertEqual(covered.map(\.provider), expected.map(\.1))
        XCTAssertEqual(pairs.count - covered.count, 9, "the other nine pairs launch unregistered")
        XCTAssertTrue(activation.runtime.activatesRegistration)
        XCTAssertFalse(activation.runtime.coversAllSupportedPairs)
        XCTAssertFalse(AgentRecoveryActivation.off.runtime.activatesRegistration)
        for family in [AgentRuntimeFamily.claudeNative, .claudeHeadless] {
            let qualification = activation.runtime.families[family]
            XCTAssertEqual(qualification?.writerExecutableBasenames, ["claude"])
            XCTAssertEqual(qualification?.toolExecutableBasenames, [])
            XCTAssertEqual(qualification?.freshSessionID, false)
        }
        for family in [AgentRuntimeFamily.codexAppServer, .codexExec] {
            XCTAssertEqual(activation.runtime.families[family]?.writerExecutableBasenames, ["codex"])
            XCTAssertEqual(activation.runtime.families[family]?.toolExecutableBasenames, [])
        }
        XCTAssertFalse(activation.runtime.allowsFreshSessionID(.claudeNative, provider: .claude(.standard)))
        XCTAssertTrue(activation.coversProvider(.claude(.standard)))
        XCTAssertTrue(activation.coversProvider(.codex))
        for provider in [AgentRuntimeProvider.claude(.glm), .claude(.kimi), .claude(.customCompatible), .acp(.openCode), .acp(.cursor), .acp(.ohMyPi)] {
            XCTAssertFalse(activation.coversProvider(provider), "\(provider.rawValue) is not qualified")
        }
        XCTAssertFalse(activation.coversProvider(nil))
        for kind in [AgentRecoveryActionKind.continueWithText, .sendSaved, .questionAnswerAsInput, .reconcileOnly] {
            XCTAssertTrue(activation.actions.allows(kind), "\(kind)")
        }
        XCTAssertFalse(activation.actions.allows(.continueInNewConversation))
        XCTAssertFalse(activation.actions.freshClaudeConversation)
        XCTAssertFalse(activation.actions.safeRestart)
    }

    /// Partial coverage never proves whole-app quiescence (Restart safely): an unregistered family
    /// can't be proven stopped, so the proof is refused and launches are not sealed.
    func testPartialCoverageRefusesTheWholeAppStoppedProof() async throws {
        let registry = makeRegistry(store: makeStore(), qualification: AgentRecoveryActivation.claudeAndCodex.runtime)
        await registry.start()
        let proof = await registry.verifyAllFamiliesStopped()
        guard case .notProven = proof else { return XCTFail("partial coverage proves nothing app-wide: \(proof)") }
        let sealed = await registry.isSealedForSafeRestart
        XCTAssertFalse(sealed, "a refused proof does not seal launches")
        _ = try await registry.reserveLaunch(Fixtures.context(.claudeNative, worktreePath: "/tmp/x"))
    }

    func testRefreshRetriesAFailedRuntimeDirectoryRead() async throws {
        // The runtimes directory cannot be listed at startup (a file stands in its place).
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let runtimesPath = recoveryRoot.appendingPathComponent("runtimes")
        try Data("blocked".utf8).write(to: runtimesPath)
        let store = makeStore()
        let registry = makeRegistry(store: store)
        var snapshot = await registry.start()
        XCTAssertNotNil(snapshot.storageFailure)
        await assertThrows(.ownershipUnknown) {
            _ = try await registry.reserveLaunch(Fixtures.context(.codexAppServer, worktreePath: "/tmp/any"))
        }

        // Access is restored (and an earlier instance's runtime is now readable): Refresh recovers.
        try FileManager.default.removeItem(at: runtimesPath)
        processes.add(processes.observation(pid: 1500, group: 1500))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: processes.identity(pid: 1500), rootGroup: 1500, conversationIDs: ["conv-R11"])
        snapshot = await registry.refreshRetryingStorage()
        XCTAssertNil(snapshot.storageFailure, "uncertainty clears only after a successful read")
        XCTAssertEqual(snapshot.restrictions.map(\.runtimeID), [seeded.runtimeID])
        _ = try await registry.reserveLaunch(Fixtures.context(.codexAppServer, worktreePath: "/tmp/any"))
    }

    func testRootlessFailedCommitResolvesOnlyOnAConfirmedExactReapAndCompleteDiscovery() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()

        // An unconfirmed reap (no exit status observed) is not exit proof.
        let unconfirmed = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-unconfirmed")
        let unconfirmedID = try await unconfirmed.prepareSpawn()
        processes.deny(pid: 1400)
        await assertThrows(.identityUnavailable) { try await unconfirmed.commitSpawn(pid: 1400, processGroupID: 1400) }
        await unconfirmed.rootReaped(pid: 1400, confirmed: false)
        XCTAssertEqual(Fixtures.record(store, unconfirmedID)?.rootReaped, false)
        XCTAssertEqual(Fixtures.record(store, unconfirmedID)?.state, .unknown)

        // A confirmed reap of the exact spawned child, but discovery is incomplete: unresolved.
        let confirmed = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-confirmed")
        let confirmedID = try await confirmed.prepareSpawn()
        processes.deny(pid: 1401)
        await assertThrows(.identityUnavailable) { try await confirmed.commitSpawn(pid: 1401, processGroupID: 1401) }
        processes.inventoryIsIncomplete = true
        await confirmed.rootReaped(pid: 1401, confirmed: true)
        XCTAssertEqual(Fixtures.record(store, confirmedID)?.rootReaped, true)
        XCTAssertEqual(Fixtures.record(store, confirmedID)?.state, .unknown, "incomplete discovery never proves exit")

        // Complete qualified discovery resolves only the confirmed exact reap.
        processes.inventoryIsIncomplete = false
        await registry.refresh()
        XCTAssertEqual(Fixtures.record(store, confirmedID)?.state, .exited)
        XCTAssertEqual(Fixtures.record(store, unconfirmedID)?.state, .unknown, "marker absence alone is not exit proof")
        let snapshot = await registry.restrictionSnapshot()
        XCTAssertTrue(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-unconfirmed")))
        XCTAssertFalse(snapshot.blocksAutomaticWork(AgentRuntimeOwnershipKeys(conversationID: nil, worktreePath: "/tmp/wt-confirmed")))
    }

    // MARK: Phase 3 re-review counterexamples (R-1)

    func testUnrelatedZombieAndEarlierBornUnreadableProcessesDoNotKeepAnExitedFamilyUnresolved() async throws {
        // The root (born at 10 000 s) is gone. An unrelated same-UID zombie (no readable environment
        // or group) and a process born long before the root (unreadable environment) are present.
        let root = processes.identity(pid: 1500, start: 10000)
        processes.add(processes.observation(pid: 1501, start: 20000, parent: 1, executable: nil, environmentAvailable: false, zombie: true))
        processes.add(processes.observation(pid: 1502, start: 1000, parent: 1, executable: "/usr/bin/node", group: 1502, environmentAvailable: false))
        // Contrast: born before the root but within the wall-clock margin (could descend from it).
        let withinMargin = 10000 - AgentProcessRegistry.birthOrderingMarginSeconds + 1
        processes.add(processes.observation(pid: 1503, start: withinMargin, parent: 1, executable: "/usr/bin/node", group: 1503, environmentAvailable: false))
        let seeded = try Fixtures.seed(rootURL: recoveryRoot, root: root, rootGroup: 1500, conversationIDs: ["conv-Z"])
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .unknown, "an unreadable process inside the margin keeps discovery incomplete")

        processes.remove(pid: 1503)
        await registry.refresh()
        let record = try XCTUnwrap(Fixtures.record(store, seeded.runtimeID))
        XCTAssertEqual(record.state, .exited, "a zombie and an earlier-born process are never reparented members")
        XCTAssertTrue(record.members.isEmpty, "neither is adopted as a member")
    }

    func testRootlessReservationOfThisInstanceAnchorsBirthOrderingOnItsCreation() async throws {
        let store = makeStore()
        let registry = makeRegistry(store: store)
        await registry.start()
        let nowSeconds = UInt64(Date().timeIntervalSince1970)
        // Long before this reservation existed: cannot descend from its child.
        processes.add(processes.observation(pid: 1602, start: 1000, parent: 1, executable: "/usr/bin/node", group: 1602, environmentAvailable: false))
        processes.add(processes.observation(pid: 1603, start: nowSeconds, parent: 1, executable: nil, environmentAvailable: false, zombie: true))
        // Within the margin of the reservation: could be its reparented child.
        processes.add(processes.observation(pid: 1604, start: nowSeconds - 60, parent: 1, executable: "/usr/bin/node", group: 1604, environmentAvailable: false))

        let launch = try newLaunch(registry, family: .codexAppServer, worktreePath: "/tmp/wt-rootless-r1")
        let runtimeID = try await launch.prepareSpawn()
        processes.deny(pid: 1601)
        await assertThrows(.identityUnavailable) { try await launch.commitSpawn(pid: 1601, processGroupID: 1601) }
        await launch.rootReaped(pid: 1601, confirmed: true)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.rootReaped, true)
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .unknown, "the within-margin unreadable process keeps it unresolved")

        processes.remove(pid: 1604)
        await registry.refresh()
        XCTAssertEqual(Fixtures.record(store, runtimeID)?.state, .exited)
    }

    func testStopIgnoresAnUnreadableGroupOnlyForAZombie() async throws {
        let seeded = try seedStoppableFamily()
        // An exited, uncollected process: its group cannot be read, and it can neither be harmed nor
        // survive a signal. (A live process with an unreadable group still refuses Stop: see
        // `testStopRevalidatesEveryGroupMemberImmediatelyBeforeSignalling`.)
        processes.add(processes.observation(pid: 1007, start: 300, parent: 1, executable: nil, environmentAvailable: false, zombie: true))
        let store = makeStore()
        let registry = makeRegistry(store: store, stop: true)
        await registry.start()
        let preview = try await stopPreview(registry, seeded.runtimeID)
        XCTAssertTrue(preview.isComplete)
        XCTAssertEqual(preview.members.map(\.identity.pid), [1000, 1001], "the zombie is not a member")

        let result = await registry.stop(preview: preview)
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(signalNames(), ["1000:TERM"])
        XCTAssertEqual(Fixtures.record(store, seeded.runtimeID)?.state, .stopped)
    }
}
