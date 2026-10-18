import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

/// Plan §6 D3 Codex row: the read-only companion's host side. The role comes only from a live
/// grant's credential presented by a kernel-observed peer descending from the run's agent (never a
/// client name: both connections here share one). The companion lists exactly the four
/// exploration tools plus `code_mode` under run restrictions, never consumes or replaces the
/// primary's pending policy or route, parks on cleanup and re-arms on reinstall, and is pinned to
/// its run. The primary stays native.
final class MCPCodexReadOnlyCompanionTests: XCTestCase {
    private static let companionName = MCPCodeModeEligibility.codexReadOnlyCompanionServerName
    private static let companionTools: Set<String> = [
        MCPWindowToolName.readFile,
        MCPWindowToolName.search,
        MCPWindowToolName.getCodeStructure,
        MCPWindowToolName.getFileTree,
        MCPWindowToolName.codeMode
    ]

    func testCatalogNamesMatchTheCompanionContract() {
        XCTAssertEqual(MCPCodeModeEligibility.readOnlyCompanionToolNames.union([MCPWindowToolName.codeMode]), Self.companionTools)
        XCTAssertEqual(CodexOverrides.directOnlyToolNamespace(forServerName: Self.companionName), "mcp__RepoPromptCE_Direct")
    }

    #if DEBUG
        @MainActor
        func testAdmissionNeedsALiveGrantAKernelPeerOfTheRunsAgentAndPinsTheToken() async throws {
            try await MCPSharedServerTestLease.shared.withLease { _ in
                let manager = ServerNetworkManager.shared
                let runID = UUID()
                let otherRunID = UUID()
                let clientName = "codex-companion-admission-\(UUID().uuidString)"
                let ownPID = Int(getpid())
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: otherRunID)
                let credential = MCPBootstrapCompanionCredential.mint()
                let otherCredential = MCPBootstrapCompanionCredential.mint()
                let token = "companion-admission-\(UUID().uuidString)"
                func decide(
                    token: String,
                    credential: String?,
                    gateway: String? = nil,
                    peer: Int? = ownPID
                ) async -> ServerNetworkManager.CompanionAdmissionDecision {
                    await manager.debugCompanionAdmissionDecisionForTesting(
                        sessionToken: token,
                        companionCredential: credential,
                        gatewayCredential: gateway,
                        observedPeerPID: peer
                    )
                }

                var decision = await decide(token: token, credential: nil)
                XCTAssertEqual(decision, .notCompanion, "No credential is an ordinary connection")
                decision = await decide(token: token, credential: credential)
                XCTAssertTrue(Self.isRejected(decision), "No grant yet")

                await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: credential))
                await manager.registerCompanionGrant(runID: otherRunID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: otherCredential))
                decision = await decide(token: token, credential: credential)
                guard case let .companion(admittedRunID, firstGeneration) = decision else {
                    return XCTFail("A live grant admits the companion: \(decision)")
                }
                XCTAssertEqual(admittedRunID, runID)
                decision = await decide(token: token, credential: credential, gateway: "gateway-credential")
                XCTAssertTrue(Self.isRejected(decision), "Gateway and companion credentials are exclusive")
                decision = await decide(token: token, credential: credential, peer: nil)
                XCTAssertTrue(Self.isRejected(decision), "A kernel-observed peer is required")
                decision = await decide(token: token, credential: credential, peer: Int(getppid()))
                XCTAssertTrue(Self.isRejected(decision), "The peer must descend from the run's agent")
                decision = await decide(token: token, credential: MCPBootstrapCompanionCredential.mint())
                XCTAssertTrue(Self.isRejected(decision), "An unknown credential is rejected")

                // Admission pins the session token to its run.
                let connectionID = UUID()
                decision = await manager.debugAdmitCompanionForSocketFixture(
                    connectionID: connectionID,
                    sessionToken: token,
                    companionCredential: credential,
                    observedPeerPID: ownPID
                )
                XCTAssertEqual(decision, .companion(runID: runID, grantGeneration: firstGeneration))
                var pinned = await manager.debugIsCompanionSessionTokenPinned(token)
                XCTAssertTrue(pinned)
                decision = await decide(token: token, credential: nil)
                XCTAssertTrue(Self.isRejected(decision), "A pinned token never reconnects as an ordinary connection")
                decision = await decide(token: token, credential: otherCredential)
                XCTAssertTrue(Self.isRejected(decision), "A pinned token never moves to another run")
                decision = await decide(token: token, credential: credential)
                XCTAssertEqual(decision, .companion(runID: runID, grantGeneration: firstGeneration), "A reconnect keeps its run")

                // A new transport launch replaces the grant: the old credential and pin are gone.
                let replacement = MCPBootstrapCompanionCredential.mint()
                await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: replacement))
                let staleRole = await manager.companionRunID(for: connectionID)
                XCTAssertNil(staleRole, "The replaced grant's companion role is dropped")
                pinned = await manager.debugIsCompanionSessionTokenPinned(token)
                XCTAssertFalse(pinned)
                decision = await decide(token: token, credential: credential)
                XCTAssertTrue(Self.isRejected(decision), "A replaced grant's credential is revoked")
                decision = await decide(token: token, credential: replacement)
                guard case let .companion(_, secondGeneration) = decision else {
                    return XCTFail("The replacement grant admits: \(decision)")
                }
                XCTAssertGreaterThan(secondGeneration, firstGeneration)

                // Re-registering the same digest (another start/resume on the same transport) is a no-op.
                await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: replacement))
                decision = await decide(token: token, credential: replacement)
                XCTAssertEqual(decision, .companion(runID: runID, grantGeneration: secondGeneration))

                // A stale clear from the older launch never removes the newer grant.
                await manager.clearCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: credential))
                var hasGrant = await manager.debugHasCompanionGrant(runID: runID)
                XCTAssertTrue(hasGrant)
                await manager.clearCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: replacement))
                hasGrant = await manager.debugHasCompanionGrant(runID: runID)
                XCTAssertFalse(hasGrant)
                decision = await decide(token: token, credential: replacement)
                XCTAssertTrue(Self.isRejected(decision))

                await manager.clearCompanionGrant(runID: otherRunID, credentialDigest: nil)
                await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: otherRunID)
            }
        }

        @MainActor
        func testCompanionArrivingFirstListsOnlyItsToolsParksRearmsAndNeverTakesThePrimarysPolicy() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let context = fixture.contextA
                let runID = UUID()
                let clientName = "codex-companion-first-\(UUID().uuidString)"
                let credential = MCPBootstrapCompanionCredential.mint()
                do {
                    await Self.installRunPolicy(manager: manager, clientName: clientName, context: context, runID: runID)
                    await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                    await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: credential))

                    // The companion shares the primary's client name and arrives first.
                    let companion = try await Self.makeCompanion(fixture: fixture, clientName: clientName, credential: credential, label: "first")
                    var listed = try await Set(companion.listToolNames())
                    XCTAssertEqual(listed, Self.companionTools)
                    let pendingWhileCompanionOnly = await manager.debugPendingPolicySnapshot(for: clientName)
                    XCTAssertEqual(pendingWhileCompanionOnly.map(\.runID), [runID], "The companion never consumes the primary's pending policy")
                    let companionCachedRun = await manager.debugCachedRunIDByConnection(companion.connectionID)
                    XCTAssertNil(companionCachedRun, "The companion never takes the run route")

                    let primary = try await fixture.makeAdditionalEndpoint(
                        label: "codex-primary",
                        clientName: clientName,
                        clearPersistedRoutingState: false,
                        requiredToolNames: [MCPWindowToolName.readFile]
                    )
                    let primaryTools = try await Set(primary.listToolNames())
                    XCTAssertFalse(primaryTools.contains(MCPWindowToolName.codeMode), "The primary stays native")
                    XCTAssertTrue(primaryTools.contains(MCPWindowToolName.applyEdits))
                    let pendingAfterPrimary = await manager.debugPendingPolicySnapshot(for: clientName)
                    XCTAssertTrue(pendingAfterPrimary.isEmpty, "The primary consumed its own pending policy")
                    let primaryCachedRun = await manager.debugCachedRunIDByConnection(primary.connectionID)
                    XCTAssertEqual(primaryCachedRun, runID)
                    let primaryCodeMode = try await Self.wireResult(
                        primary.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": "return 1"])
                    )
                    XCTAssertEqual(primaryCodeMode["isError"] as? Bool, true, "The primary never gets code_mode")

                    try await Self.assertCompanionReadsThePrimaryTab(companion, fixture: fixture)
                    await Self.assertPrimaryOwnsTheRun(primary: primary, companions: [companion], context: context, runID: runID, manager: manager)

                    // A tool outside the companion ceiling is denied by name.
                    let denied = try await Self.wireResult(
                        companion.callTool(name: MCPWindowToolName.applyEdits, arguments: ["path": "x", "search": "a", "replace": "b"])
                    )
                    XCTAssertEqual(denied["isError"] as? Bool, true)
                    XCTAssertTrue(
                        Self.wireText(denied).contains(ServerNetworkManager.companionToolNotAllowedMessage(forCanonicalToolName: MCPWindowToolName.applyEdits)),
                        Self.wireText(denied)
                    )

                    // Run restrictions apply to the companion as well.
                    await Self.installRunPolicy(
                        manager: manager,
                        clientName: clientName,
                        context: context,
                        runID: runID,
                        restrictedTools: [MCPWindowToolName.getFileTree]
                    )
                    listed = try await Set(companion.listToolNames())
                    XCTAssertEqual(listed, Self.companionTools.subtracting([MCPWindowToolName.getFileTree]))

                    // Cleanup parks the companion (still connected, nothing listed, calls refused).
                    await manager.cleanupRunRoutingState(for: runID, windowID: context.window.windowID)
                    listed = try await Set(companion.listToolNames())
                    XCTAssertTrue(listed.isEmpty, "\(listed.sorted())")
                    let parked = try await Self.wireResult(
                        companion.callTool(name: MCPWindowToolName.readFile, arguments: ["path": "Sources/DistinctConnectionA.swift"])
                    )
                    XCTAssertEqual(parked["isError"] as? Bool, true)
                    XCTAssertTrue(Self.wireText(parked).contains(ServerNetworkManager.companionUnavailableMessage), Self.wireText(parked))
                    let parkedRole = await manager.companionRunID(for: companion.connectionID)
                    XCTAssertEqual(parkedRole, runID, "A parked companion keeps its role")

                    // A reinstalled run policy re-arms it.
                    await Self.installRunPolicy(manager: manager, clientName: clientName, context: context, runID: runID)
                    listed = try await Set(companion.listToolNames())
                    XCTAssertEqual(listed, Self.companionTools)

                    // Clearing the launch's grant disconnects the companion.
                    await manager.clearCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: credential))
                    let clearedRole = await manager.companionRunID(for: companion.connectionID)
                    XCTAssertNil(clearedRole)
                    let companionStillRegistered = await manager.debugContainsConnection(companion.connectionID)
                    XCTAssertFalse(companionStillRegistered)
                    let primaryStillRegistered = await manager.debugContainsConnection(primary.connectionID)
                    XCTAssertTrue(primaryStillRegistered, "Removing the companion never removes the primary")

                    await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.clearCompanionGrant(runID: runID, credentialDigest: nil)
                    await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        @MainActor
        func testCompanionAfterThePrimaryKeepsItsSemanticsAcrossPrimaryHandoverAndTheNewestCompanionWins() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let context = fixture.contextA
                let runID = UUID()
                let clientName = "codex-companion-after-\(UUID().uuidString)"
                let credential = MCPBootstrapCompanionCredential.mint()
                do {
                    await Self.installRunPolicy(manager: manager, clientName: clientName, context: context, runID: runID)
                    let primary = try await fixture.makeAdditionalEndpoint(
                        label: "codex-primary-first",
                        clientName: clientName,
                        clearPersistedRoutingState: false,
                        requiredToolNames: [MCPWindowToolName.readFile]
                    )
                    await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                    await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: credential))
                    let companion = try await Self.makeCompanion(fixture: fixture, clientName: clientName, credential: credential, label: "after")
                    let listed = try await Set(companion.listToolNames())
                    XCTAssertEqual(listed, Self.companionTools)
                    let primaryCachedRun = await manager.debugCachedRunIDByConnection(primary.connectionID)
                    XCTAssertEqual(primaryCachedRun, runID, "The companion never replaces the primary route")
                    try await Self.assertCompanionReadsThePrimaryTab(companion, fixture: fixture)
                    await Self.assertPrimaryOwnsTheRun(primary: primary, companions: [companion], context: context, runID: runID, manager: manager)

                    // Primary handover: a replacement primary for the same run.
                    await Self.installRunPolicy(manager: manager, clientName: clientName, context: context, runID: runID)
                    let roleAfterReinstall = await manager.companionRunID(for: companion.connectionID)
                    XCTAssertEqual(roleAfterReinstall, runID, "A reinstalled run policy keeps the companion")
                    let replacement = try await fixture.makeAdditionalEndpoint(
                        label: "codex-primary-replacement",
                        clientName: clientName,
                        clearPersistedRoutingState: false,
                        requiredToolNames: [MCPWindowToolName.readFile]
                    )
                    let replacementTools = try await Set(replacement.listToolNames())
                    XCTAssertFalse(replacementTools.contains(MCPWindowToolName.codeMode))
                    let roleAfterReplacement = await manager.companionRunID(for: companion.connectionID)
                    XCTAssertEqual(roleAfterReplacement, runID, "A primary handover never replaces the companion")
                    await Self.assertPrimaryOwnsTheRun(primary: replacement, companions: [companion], context: context, runID: runID, manager: manager)
                    let afterHandover = try await Set(companion.listToolNames())
                    XCTAssertEqual(afterHandover, Self.companionTools, "The companion keeps its semantics across handover")
                    try await Self.assertCompanionReadsThePrimaryTab(companion, fixture: fixture)

                    // The newest companion of a grant supersedes the older one.
                    let newer = try await Self.makeCompanion(fixture: fixture, clientName: clientName, credential: credential, label: "newer")
                    let olderRole = await manager.companionRunID(for: companion.connectionID)
                    let newerRole = await manager.companionRunID(for: newer.connectionID)
                    XCTAssertNil(olderRole)
                    XCTAssertEqual(newerRole, runID)
                    let newerTools = try await Set(newer.listToolNames())
                    XCTAssertEqual(newerTools, Self.companionTools)
                    let supersededStillRegistered = await manager.debugContainsConnection(companion.connectionID)
                    XCTAssertFalse(supersededStillRegistered, "The superseded companion is removed")
                    await Self.assertPrimaryOwnsTheRun(primary: replacement, companions: [companion, newer], context: context, runID: runID, manager: manager)

                    // Clearing the grant removes the companion and leaves the primary's run intact.
                    await manager.clearCompanionGrant(runID: runID, credentialDigest: nil)
                    let clearedStillRegistered = await manager.debugContainsConnection(newer.connectionID)
                    XCTAssertFalse(clearedStillRegistered)
                    await Self.assertPrimaryOwnsTheRun(primary: replacement, companions: [newer], context: context, runID: runID, manager: manager)
                    await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.clearCompanionGrant(runID: runID, credentialDigest: nil)
                    await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        /// Production bootstrap path (listener admission → accepted fd publication → deferred
        /// commit → production initialize closure) on an isolated manager. A companion admission
        /// whose grant is cleared, replaced or superseded while its accept is still in flight keeps
        /// a revoked tombstone, is abandoned at commit (descriptor closed) and never becomes an
        /// ordinary client that could consume the primary's pending policy.
        func testAPendingCompanionAdmissionRevokedBeforeCommitIsAbandonedNeverAnOrdinaryClient() async throws {
            try await Self.withIsolatedBootstrapManager(prefix: "pending") { manager in
                let runID = UUID()
                let clientName = "codex-companion-pending-\(UUID().uuidString)"
                await manager.registerExpectedAgentPID(getpid(), for: clientName, runID: runID)
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: 1,
                    restrictedTools: [],
                    tabID: UUID(),
                    runID: runID,
                    additionalTools: [],
                    purpose: .agentModeRun,
                    codeModeEligibility: .codexReadOnlyCompanion(serverName: Self.companionName)
                )
                let pendingBefore = await manager.debugPendingPolicySnapshot(for: clientName).map(\.runID)
                XCTAssertEqual(pendingBefore, [runID])

                for revocation in ["cleared", "replaced", "superseded"] {
                    let credential = MCPBootstrapCompanionCredential.mint()
                    await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: credential))
                    let pending = try await Self.admitPendingCompanion(manager: manager, runID: runID, clientName: clientName, credential: credential)
                    defer { Darwin.close(pending.clientFD) }

                    var supersedingClient: PersistentMCPTestSocketClient?
                    var supersedingConnectionID: UUID?
                    switch revocation {
                    case "cleared":
                        await manager.clearCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: credential))
                    case "replaced":
                        await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: MCPBootstrapCompanionCredential.mint()))
                    default:
                        // Same grant generation: a newer companion commits and initializes through
                        // the production closure, superseding the still-pending one.
                        let newer = try await Self.admitPendingCompanion(manager: manager, runID: runID, clientName: clientName, credential: credential)
                        await newer.admission.postAccept?()
                        let committed = await manager.debugContainsConnection(newer.connectionID)
                        XCTAssertTrue(committed, revocation)
                        let client = PersistentMCPTestSocketClient(fd: newer.clientFD)
                        supersedingClient = client
                        supersedingConnectionID = newer.connectionID
                        let initialize = try await client.request(
                            method: "initialize",
                            params: [
                                "protocolVersion": "2025-11-25",
                                "capabilities": [:],
                                "clientInfo": ["name": clientName, "version": "companion-pending-test"]
                            ]
                        )
                        XCTAssertTrue(initialize.rawJSON.contains("\"result\""), initialize.rawJSON)
                        let eligibility = await manager.effectiveCodeModeEligibility(for: newer.connectionID)
                        XCTAssertEqual(eligibility, .codexReadOnlyCompanion(serverName: Self.companionName))
                        let newerCachedRun = await manager.debugCachedRunIDByConnection(newer.connectionID)
                        XCTAssertNil(newerCachedRun, "The initialized companion never takes the run route")
                    }

                    let roles = await manager.debugCompanionRoles(runID: runID)
                    XCTAssertEqual(roles[pending.connectionID], true, "\(revocation): the pending admission keeps a revoked tombstone")
                    if let supersedingConnectionID {
                        XCTAssertEqual(roles[supersedingConnectionID], false, "The superseding companion stays live")
                    }

                    await pending.admission.postAccept?()
                    let registered = await manager.debugContainsConnection(pending.connectionID)
                    XCTAssertFalse(registered, "\(revocation): a revoked admission never commits")
                    let rolesAfterCommit = await manager.debugCompanionRoles(runID: runID)
                    XCTAssertNil(rolesAfterCommit[pending.connectionID], "\(revocation): the tombstone ends with the admission")
                    let reservations = await manager.debugBootstrapReservationCount()
                    let transferred = await manager.debugTransferredBootstrapSocketCountForShutdownTest()
                    XCTAssertEqual(reservations, 0, revocation)
                    XCTAssertEqual(transferred, 0, revocation)
                    var byte: UInt8 = 0
                    XCTAssertEqual(Darwin.recv(pending.clientFD, &byte, 1, MSG_DONTWAIT), 0, "\(revocation): the transferred descriptor is closed")
                    let pendingAfter = await manager.debugPendingPolicySnapshot(for: clientName).map(\.runID)
                    XCTAssertEqual(pendingAfter, [runID], "\(revocation): the primary's pending policy is never consumed")

                    if let supersedingConnectionID {
                        let supersedingEligibility = await manager.effectiveCodeModeEligibility(for: supersedingConnectionID)
                        XCTAssertEqual(supersedingEligibility, .codexReadOnlyCompanion(serverName: Self.companionName))
                        supersedingClient?.close()
                        await manager.debugRemoveConnection(supersedingConnectionID)
                    }
                }

                // Server stop with admissions still pending: a revoked tombstone and a live pending
                // role are both removed once stop has invalidated and drained the lifecycle, and a
                // late commit still never registers (descriptor closed).
                let firstCredential = MCPBootstrapCompanionCredential.mint()
                await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: firstCredential))
                let tombstoned = try await Self.admitPendingCompanion(manager: manager, runID: runID, clientName: clientName, credential: firstCredential)
                defer { Darwin.close(tombstoned.clientFD) }
                await manager.clearCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: firstCredential))
                let liveCredential = MCPBootstrapCompanionCredential.mint()
                await manager.registerCompanionGrant(runID: runID, credentialDigest: MCPBootstrapCompanionCredential.digest(of: liveCredential))
                let live = try await Self.admitPendingCompanion(manager: manager, runID: runID, clientName: clientName, credential: liveCredential)
                defer { Darwin.close(live.clientFD) }
                let rolesBeforeStop = await manager.debugCompanionRoles(runID: runID)
                XCTAssertEqual(rolesBeforeStop[tombstoned.connectionID], true)
                XCTAssertEqual(rolesBeforeStop[live.connectionID], false)

                await manager.stop()
                let rolesAfterStop = await manager.debugCompanionRoles(runID: runID)
                XCTAssertTrue(rolesAfterStop.isEmpty, "Stop removes every pending companion role it invalidated")
                for pending in [tombstoned, live] {
                    await pending.admission.postAccept?()
                    let registered = await manager.debugContainsConnection(pending.connectionID)
                    XCTAssertFalse(registered, "A commit after stop never registers")
                    var byte: UInt8 = 0
                    XCTAssertEqual(Darwin.recv(pending.clientFD, &byte, 1, MSG_DONTWAIT), 0, "The stopped lifecycle closed the descriptor")
                }
                let rolesAfterLateCommit = await manager.debugCompanionRoles(runID: runID)
                XCTAssertTrue(rolesAfterLateCommit.isEmpty)

                await manager.clearCompanionGrant(runID: runID, credentialDigest: nil)
                await manager.clearExpectedAgentPID(getpid(), for: clientName, runID: runID)
            }
        }

        // MARK: - Helpers

        private struct PendingCompanionAdmission {
            let admission: BootstrapSocketServer.Admission
            let connectionID: UUID
            let clientFD: Int32
        }

        /// Runs the production listener admission for a companion and publishes its accepted fd,
        /// stopping before the deferred commit.
        private static func admitPendingCompanion(
            manager: ServerNetworkManager,
            runID: UUID,
            clientName: String,
            credential: String
        ) async throws -> PendingCompanionAdmission {
            let before = await Set(manager.debugCompanionRoles(runID: runID).keys)
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw PersistentMCPTestSocketClient.ClientError.posix(operation: "socketpair", code: errno)
            }
            var noSigPipe: Int32 = 1
            for descriptor in descriptors {
                _ = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            }
            let optionalAdmission = await manager.debugHandleBootstrapAdmissionThroughCurrentListenerForTesting(
                clientFD: descriptors[0],
                sessionToken: "codex-companion-pending-\(UUID().uuidString)",
                clientPid: Int(getpid()),
                clientName: clientName,
                companionCredential: credential,
                observedPeerPID: Int(getpid())
            )
            guard let admission = optionalAdmission, admission.accepted,
                  admission.publishTransferredFD?(descriptors[0]) == true
            else {
                Darwin.close(descriptors[0])
                Darwin.close(descriptors[1])
                XCTFail("The production listener admits the companion")
                throw PersistentMCPTestEndpoint.CompanionFixtureError.admissionDenied("production admission")
            }
            let after = await Set(manager.debugCompanionRoles(runID: runID).keys)
            let connectionID = try XCTUnwrap(after.subtracting(before).first, "Admission records the companion role")
            return PendingCompanionAdmission(admission: admission, connectionID: connectionID, clientFD: descriptors[1])
        }

        /// An isolated manager with its own bootstrap listener (never the shared server's socket).
        private static func withIsolatedBootstrapManager(
            prefix: String,
            operation: (ServerNetworkManager) async throws -> Void
        ) async throws {
            let directory = URL(
                fileURLWithPath: "/tmp/rpce-companion-\(prefix)-\(getpid())-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let socketURL = directory.appendingPathComponent("s.sock")
            let manager = ServerNetworkManager()
            try await manager.debugInstallBootstrapSocketURLOverride(socketURL)
            await manager.setConnectionApprovalHandler { _, _ in true }
            await manager.start()
            do {
                try await AsyncTestWait.waitUntil("isolated bootstrap listener", timeout: 15) {
                    await manager.debugHasCurrentBootstrapListenerForLifecycleFenceTest()
                }
                try await operation(manager)
            } catch {
                await manager.stop()
                try? await manager.debugRestoreBootstrapSocketURLOverride(expected: socketURL)
                throw error
            }
            await manager.stop()
            try await manager.debugRestoreBootstrapSocketURLOverride(expected: socketURL)
        }

        @MainActor
        private static func installRunPolicy(
            manager: ServerNetworkManager,
            clientName: String,
            context: PersistentMCPTestContext,
            runID: UUID,
            restrictedTools: Set<String> = []
        ) async {
            await manager.installClientConnectionPolicy(
                for: clientName,
                windowID: context.window.windowID,
                restrictedTools: restrictedTools,
                tabID: context.tabID,
                runID: runID,
                additionalTools: [],
                purpose: .agentModeRun,
                codeModeEligibility: .codexReadOnlyCompanion(serverName: companionName)
            )
        }

        @MainActor
        private static func makeCompanion(
            fixture: PersistentMCPTestFixture,
            clientName: String,
            credential: String,
            label: String
        ) async throws -> PersistentMCPTestEndpoint {
            try await fixture.makeAdditionalEndpoint(
                label: "codex-companion-\(label)",
                clientName: clientName,
                clearPersistedRoutingState: false,
                requiredToolNames: [],
                companion: .init(credential: credential, observedPeerPID: Int(getpid()))
            )
        }

        /// Direct reads and `code_mode` children resolve in the primary's tab; routing overrides
        /// are refused on direct calls, and a child outside the ceiling is denied.
        @MainActor
        private static func assertCompanionReadsThePrimaryTab(
            _ companion: PersistentMCPTestEndpoint,
            fixture: PersistentMCPTestFixture
        ) async throws {
            let path = "Sources/DistinctConnectionA.swift"
            try await AsyncTestWait.waitUntil("companion read in the primary tab", timeout: 15) {
                let response = try? await companion.callTool(name: MCPWindowToolName.readFile, arguments: ["path": path])
                return response.flatMap { try? wireText(wireResult($0)) }?.contains("sentinel-a") == true
            }
            for (label, arguments) in [
                ("_windowID", ["path": path, "_windowID": fixture.contextB.window.windowID]),
                ("window_id", ["path": path, "window_id": fixture.contextB.window.windowID]),
                ("context_id", ["path": path, "context_id": UUID().uuidString]),
                ("_tabID", ["path": path, "_tabID": fixture.contextB.tabID.uuidString])
            ] as [(String, [String: Any])] {
                let result = try await wireResult(companion.callTool(name: MCPWindowToolName.readFile, arguments: arguments))
                XCTAssertEqual(result["isError"] as? Bool, true, label)
                XCTAssertTrue(
                    wireText(result).contains(ServerNetworkManager.companionRoutingOverrideDenial.message),
                    "\(label): \(wireText(result))"
                )
                XCTAssertFalse(wireText(result).contains("sentinel-b"), label)
            }
            let script = """
            const r = await tools.read_file({ path: 'Sources/DistinctConnectionA.swift' });
            const tree = await tools.get_file_tree({ max_depth: 1 }, { allowError: true });
            let edit;
            try {
              const e = await tools.apply_edits({ path: 'x', search: 'a', replace: 'b' }, { allowError: true });
              edit = e.isError ? 'denied' : 'ran';
            } catch (error) {
              edit = 'denied';
            }
            return r.data.content + '|edit:' + edit;
            """
            let codeMode = try await wireResult(companion.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": script]))
            let text = wireText(codeMode)
            XCTAssertNotEqual(codeMode["isError"] as? Bool, true, text)
            XCTAssertTrue(text.contains("sentinel-a"), text)
            XCTAssertTrue(text.contains("|edit:denied"), text)
        }

        /// The primary keeps the run's route, cached run mapping and tab binding; companion calls,
        /// supersede and removal never move them (a removed companion leaves no binding at all).
        @MainActor
        private static func assertPrimaryOwnsTheRun(
            primary: PersistentMCPTestEndpoint,
            companions: [PersistentMCPTestEndpoint],
            context: PersistentMCPTestContext,
            runID: UUID,
            manager: ServerNetworkManager,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            let server = context.window.mcpServer
            XCTAssertEqual(server.connectionBindingSnapshot(forConnection: primary.connectionID).tabID, context.tabID, file: file, line: line)
            XCTAssertEqual(server.connectionID(forRunID: runID), primary.connectionID, file: file, line: line)
            let cachedRun = await manager.debugCachedRunIDByConnection(primary.connectionID)
            XCTAssertEqual(cachedRun, runID, file: file, line: line)
            let primaryAlive = await manager.debugContainsConnection(primary.connectionID)
            XCTAssertTrue(primaryAlive, file: file, line: line)
            for companion in companions {
                XCTAssertEqual(server.connectionBindingSnapshot(forConnection: companion.connectionID).bindingKind, .unbound, file: file, line: line)
                let companionCachedRun = await manager.debugCachedRunIDByConnection(companion.connectionID)
                XCTAssertNil(companionCachedRun, file: file, line: line)
            }
        }

        private static func isRejected(_ decision: ServerNetworkManager.CompanionAdmissionDecision) -> Bool {
            if case .rejected = decision { return true }
            return false
        }

        private static func wireResult(_ response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(response.rawJSON.utf8)) as? [String: Any], response.rawJSON
            )
            return try XCTUnwrap(object["result"] as? [String: Any], response.rawJSON)
        }

        private static func wireText(_ result: [String: Any]) -> String {
            ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        }
    #endif
}
