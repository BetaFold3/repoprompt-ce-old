import CryptoKit
import Foundation
import Logging
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import XCTest

/// Step 3 end-to-end passkey contract over a REAL loopback WebSocket into a real `GatewayHTTPServer`.
///
/// Every passkey ceremony travels: signed browser frame → gateway handler/authority → the gateway's
/// `GatewayPasskeyRelay` on the ONE principal `AppLinkSession` → a test app-link connection that hands
/// the gateway's ACTUAL tool arguments to the REAL app `MCPRemotePairingToolProvider` →
/// `RemotePasskeyCoordinator` → `WebAuthnRemotePasskeyVerifier`. The credential is a real software
/// P-256 WebAuthn registration/assertion (`SoftwareAuthenticator`); nothing is pre-verified, no
/// `verified:true` is canned, and the connection generation is whatever the gateway put on the wire,
/// echoed back by the app. Trust (`list_devices` capability 1 → strict parse → authority, then
/// `acknowledge_trust`) also runs through the production `GatewayTrustRefreshCoordinator` operations.
final class GatewayPasskeyE2EContractTests: XCTestCase {
    private var root: URL!
    private var configuration: GatewayConfiguration!
    private var hostSigner: P256.Signing.PrivateKey!
    private var device: GatewayAuthTestSupport.TestDeviceIdentity!
    private var clock: ManualAccessClock!
    private var app: PasskeyE2EApp!
    private var principalConnection: ProviderBackedPrincipalConnection!
    private var principalAppLink: AppLinkSession!
    private var authenticator: DeviceAuthenticator!
    private var poolConnector: PasskeyE2EPoolConnector!
    private var appLinkPool: AppLinkPool!
    private var watchManager: SessionWatchManager!
    private var trustCoordinator: GatewayTrustRefreshCoordinator!
    private var server: GatewayHTTPServer!
    private var port: Int!

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("gateway-passkey-e2e")
        hostSigner = P256.Signing.PrivateKey()
        device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:5e6f7a8b")
        clock = ManualAccessClock()
        configuration = try GatewayConfiguration.parse(
            arguments: [
                "--app-support-root", root.path,
                "--audit-dir", root.appendingPathComponent("audit", isDirectory: true).path,
                "--bootstrap-token", "bootstrap-token",
                "--bootstrap-socket", root.appendingPathComponent("bootstrap.sock").path,
                "--port", "0"
            ],
            environment: [:]
        )

        // The app side: a real identity store holding the host key and the paired device's public
        // key, the real passkey coordinator with the production WebAuthn verifier, and the real
        // remote_pairing provider bound to one gateway-principal connection id.
        let appDirectory = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        let hostSigner = hostSigner!
        let device = device!
        let (app, execute) = try await MainActor.run {
            let app = try PasskeyE2EApp(directory: appDirectory, hostSigner: hostSigner, device: device)
            return (app, app.execute)
        }
        self.app = app
        let principalConnection = ProviderBackedPrincipalConnection(execute: execute)
        self.principalConnection = principalConnection
        let principalAppLink = AppLinkSession(
            config: configuration,
            connector: ProviderBackedPrincipalConnector(connection: principalConnection)
        )
        self.principalAppLink = principalAppLink
        try await principalAppLink.connect()
        let relay = GatewayPasskeyRelay(appLink: principalAppLink)

        let authenticator = try DeviceAuthenticator(
            usedTicketStore: GatewayAuthTestSupport.makeUsedTicketStore(root: root),
            accessClock: clock
        )
        self.authenticator = authenticator
        let poolConnector = PasskeyE2EPoolConnector()
        self.poolConnector = poolConnector
        let pool = AppLinkPool(configuration: configuration, connector: poolConnector, bindingProbe: { _ in .bound })
        appLinkPool = pool
        let watchManager = SessionWatchManager(appLink: principalAppLink, appLinkPool: pool)
        self.watchManager = watchManager
        let auditLog = try RemoteAuditLog(directoryURL: configuration.auditDirectoryURL)
        let runtime = try RemoteGatewayRuntime(
            appLink: principalAppLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: auditLog,
            appLinkPool: pool
        )
        let server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            authenticator: authenticator,
            appLinkPool: pool,
            auditLog: auditLog,
            accessClock: clock,
            passkeyRelay: relay,
            hostName: "Gateway Passkey E2E Host"
        )
        self.server = server
        // Production trust wiring: strict fetch → authority barrier → legacy consumers → cleanup → ACK.
        let trustCoordinator = GatewayTrustRefreshCoordinator(operations: .production(
            relay: relay,
            authenticator: authenticator,
            applyLegacySnapshot: { snapshot in
                await authenticator.updateTrust(snapshot)
                _ = await pool.applyTrustSnapshot(snapshot)
            },
            closeAccessDeniedConnections: { await server.closeAccessDeniedConnections() }
        ))
        self.trustCoordinator = trustCoordinator
        server.setPasskeyTrustRefreshAction { try await trustCoordinator.refresh() }

        // Real trust round-trips: policy off first (records the capable principal on the app), then
        // the Mac-side Enable (required, not enrolled, enrollment window open), then a fresh refresh.
        let initial = try await trustCoordinator.refresh()
        XCTAssertEqual(try appliedPolicy(initial)?.state, .off)
        try await app.coordinator.enable(deviceID: device.deviceID)
        let required = try await trustCoordinator.refresh()
        let requiredPolicy = try XCTUnwrap(appliedPolicy(required))
        XCTAssertEqual(requiredPolicy.state, .required)
        XCTAssertFalse(requiredPolicy.enrolled)

        try await server.start()
        port = try XCTUnwrap(server.localAddress?.port)
    }

    override func tearDown() async throws {
        await server?.shutdown()
        await trustCoordinator?.stop()
        await watchManager?.shutdown()
        await appLinkPool?.shutdownAll()
        await principalAppLink?.shutdown()
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    // MARK: - Contract

    /// Register, then a SEPARATE unlock, both verified by the real app verifier with a software P-256
    /// credential. Registration alone never grants; only the verified assertion opens protected
    /// runtime frames, and every ceremony call carries the connection's own dynamic generation.
    func testRegistrationThenSeparateUnlockGrantsProtectedAccessThroughRealAppVerifier() async throws {
        let socket = try await openPairedSocket()
        defer { socket.close() }
        let ackHello = try await socket.hello()
        XCTAssertEqual(ackHello.type, "hello_ack")
        XCTAssertEqual(ackHello.payload?.objectValue?["locked"]?.boolValue, true)

        // Locked: an ordinary runtime frame is settled content-free and never reaches the app.
        try await assertLockedSettlement(socket, type: "list_sessions", requestID: "req-list-locked")
        let callsWhileLocked = await poolConnector.toolNames(for: device.deviceID)
        XCTAssertTrue(callsWhileLocked.isEmpty, "A locked frame never executed on the app: \(callsWhileLocked)")

        let authenticatorKey = SoftwareAuthenticator()
        try await register(socket, using: authenticatorKey, requestID: "req-register")
        let credential = try await MainActor.run { try app.store.device(id: device.deviceID)?.passkey.credential }
        XCTAssertNotNil(credential, "The real app verifier enrolled the software credential")
        let enrolledPolicy = try await currentGatewayPolicy()
        XCTAssertEqual(enrolledPolicy?.state, .required)
        XCTAssertEqual(enrolledPolicy?.enrolled, true, "The post-registration refresh applied the enrolled state")

        // Registration alone does not grant.
        let hasGrantAfterRegistration = await authenticator.hasGrant(forDevice: device.deviceID)
        XCTAssertFalse(hasGrantAfterRegistration)
        try await assertLockedSettlement(socket, type: "list_sessions", requestID: "req-list-after-register")

        try await unlock(socket, using: authenticatorKey, requestID: "req-unlock")
        let hasGrantAfterUnlock = await authenticator.hasGrant(forDevice: device.deviceID)
        XCTAssertTrue(hasGrantAfterUnlock)

        let listed = try await socket.request(type: "list_sessions", requestID: "req-list-unlocked")
        XCTAssertEqual(listed.type, "command_result")
        XCTAssertEqual(listed.requestID, "req-list-unlocked")
        let callsAfterUnlock = await poolConnector.toolNames(for: device.deviceID)
        XCTAssertFalse(callsAfterUnlock.isEmpty, "The unlocked list executed on the per-device app link")

        // The generation is the gateway's own per-connection value, carried on the wire and echoed by
        // the app — identical for every ceremony call on this one connection.
        let ceremonyCalls = await principalConnection.passkeyCalls()
        XCTAssertEqual(ceremonyCalls.map(\.op), [
            "passkey_register_begin", "passkey_register_complete",
            "passkey_unlock_begin", "passkey_unlock_complete"
        ])
        let generations = Set(ceremonyCalls.compactMap(\.requestGeneration))
        XCTAssertEqual(generations.count, 1, "One connection, one generation: \(ceremonyCalls)")
        for call in ceremonyCalls where call.op.hasSuffix("_complete") {
            XCTAssertEqual(call.responseGeneration, call.requestGeneration, "The app echoed the request's generation")
        }
    }

    /// Two tabs of one paired identity: registration on tab A and unlock on tab B are each bound to
    /// their OWN connection generation (read from the actual relay arguments), and the one verified
    /// assertion opens the shared device grant for both tabs.
    func testSharedTabsUseOneGrantWhileEachCeremonyBindsItsOwnConnectionGeneration() async throws {
        let tabA = try await openPairedSocket()
        defer { tabA.close() }
        let tabB = try await openPairedSocket()
        defer { tabB.close() }
        _ = try await tabA.hello()
        _ = try await tabB.hello()

        let authenticatorKey = SoftwareAuthenticator()
        try await register(tabA, using: authenticatorKey, requestID: "req-register-a")
        try await unlock(tabB, using: authenticatorKey, requestID: "req-unlock-b")

        let calls = await principalConnection.passkeyCalls()
        let registrationGenerations = Set(calls.filter { $0.op.hasPrefix("passkey_register") }.compactMap(\.requestGeneration))
        let unlockGenerations = Set(calls.filter { $0.op.hasPrefix("passkey_unlock") }.compactMap(\.requestGeneration))
        XCTAssertEqual(registrationGenerations.count, 1)
        XCTAssertEqual(unlockGenerations.count, 1)
        XCTAssertNotEqual(registrationGenerations, unlockGenerations, "Each connection carries its own generation")

        let listedA = try await tabA.request(type: "list_sessions", requestID: "req-list-a")
        let listedB = try await tabB.request(type: "list_sessions", requestID: "req-list-b")
        XCTAssertEqual(listedA.type, "command_result", "The shared grant opened tab A too")
        XCTAssertEqual(listedB.type, "command_result")
    }

    /// The app VERIFIES the assertion, but its completion is held on the principal link while the
    /// phone sends a signed Lock. The late verified result must not revive access: the gateway
    /// reports a stale ceremony and the connection stays locked.
    func testSignedLockDuringHeldVerifiedAssertionNeverRevivesTheGrant() async throws {
        let socket = try await openPairedSocket()
        defer { socket.close() }
        _ = try await socket.hello()
        let authenticatorKey = SoftwareAuthenticator()
        try await register(socket, using: authenticatorKey, requestID: "req-register")

        let challenge = try await socket.request(type: "passkey_unlock_begin", requestID: "req-unlock")
        XCTAssertEqual(challenge.type, "passkey_challenge")
        let options = try XCTUnwrap(challenge.payload?.objectValue)
        let ceremonyID = try XCTUnwrap(options["ceremony_id"]?.stringValue)
        let challengeBytes = try Self.challengeBytes(options)

        let hold = RecordingAppLinkResponseGate()
        await principalConnection.holdResponse(forOp: "passkey_unlock_complete", gate: hold)
        try await socket.send(type: "passkey_unlock_complete", requestID: "req-unlock-complete", payload: .object([
            "ceremony_id": .string(ceremonyID),
            "credential": .string(String(decoding: authenticatorKey.assertionJSON(challenge: challengeBytes), as: UTF8.self))
        ]))
        await hold.waitUntilEntered()
        let callsAtHold = await principalConnection.passkeyCalls()
        let heldCall = try XCTUnwrap(callsAtHold.last)
        XCTAssertEqual(heldCall.op, "passkey_unlock_complete")
        XCTAssertEqual(heldCall.responseVerified, true, "The real app verifier accepted the assertion")

        try await socket.send(type: "lock")
        let lockState = try await socket.receive()
        XCTAssertEqual(lockState.type, "lock_state")
        XCTAssertEqual(lockState.payload?.objectValue?["reason"]?.stringValue, "passkey_locked")

        await hold.release()
        let stale = try await socket.receive()
        XCTAssertEqual(stale.type, "command_error")
        XCTAssertEqual(stale.requestID, "req-unlock-complete")
        XCTAssertEqual(stale.payload?.objectValue?["code"]?.stringValue, "passkey_stale_ceremony")
        let hasGrant = await authenticator.hasGrant(forDevice: device.deviceID)
        XCTAssertFalse(hasGrant, "A verified-but-superseded assertion never installs a grant")
        try await assertLockedSettlement(socket, type: "list_sessions", requestID: "req-list-after-lock")
    }

    /// While locked, subscribe and get_log are each settled with the fixed content-free lock code and
    /// never reach the app; a syntactically-valid UNKNOWN frame type still signature/counter-verifies
    /// and hits the SAME generic locked deny (correlated to the client's request id, never a raw
    /// decoder rejection), leaving the connection open and still locked. An app-rejected (tampered)
    /// assertion surfaces only the fixed sanitized failure, never the app's code, and does not grant.
    func testLockedFramesAndAppRejectedAssertionAreSanitizedWithoutAppExecution() async throws {
        let socket = try await openPairedSocket()
        defer { socket.close() }
        _ = try await socket.hello()

        try await assertLockedSettlement(socket, type: "subscribe", requestID: "req-subscribe", sessionID: "session-a")
        // A syntactically-valid but UNKNOWN frame type on a ready paired connection is NOT refused at
        // the decoder: it signature/counter-verifies and then hits the generic locked deny, correlated
        // to the client's own request id and leaking no decoder/raw text. The connection stays open and
        // locked, so the get_log below still settles on the same socket.
        try await assertLockedSettlement(socket, type: "frobnicate_unknown", requestID: "req-unknown")
        try await assertLockedSettlement(
            socket,
            type: "get_log",
            requestID: "req-get-log",
            sessionID: "session-a",
            payload: .object(["offset": .int(0), "limit": .int(20)])
        )

        let authenticatorKey = SoftwareAuthenticator()
        try await register(socket, using: authenticatorKey, requestID: "req-register")
        let challenge = try await socket.request(type: "passkey_unlock_begin", requestID: "req-unlock")
        let options = try XCTUnwrap(challenge.payload?.objectValue)
        let ceremonyID = try XCTUnwrap(options["ceremony_id"]?.stringValue)
        let tampered = try authenticatorKey.assertionJSON(challenge: Self.challengeBytes(options), tamperSignature: true)
        let rejected = try await socket.request(type: "passkey_unlock_complete", requestID: "req-unlock-complete", payload: .object([
            "ceremony_id": .string(ceremonyID),
            "credential": .string(String(decoding: tampered, as: UTF8.self))
        ]))
        XCTAssertEqual(rejected.type, "command_error")
        XCTAssertEqual(rejected.payload?.objectValue?["code"]?.stringValue, "authentication_failed")
        XCTAssertEqual(rejected.payload?.objectValue?["message"]?.stringValue, "The request was rejected.")
        let callsAfterRejection = await principalConnection.passkeyCalls()
        let appResponse = try XCTUnwrap(callsAfterRejection.last)
        XCTAssertEqual(appResponse.responseOK, false, "The real app verifier rejected the tampered signature")
        let appCode = try XCTUnwrap(appResponse.responseCode)
        let encoded = try String(decoding: RemoteWireProtocol.encodeServerFrame(rejected), as: UTF8.self)
        XCTAssertFalse(encoded.contains(appCode), "The app's rejection code never reaches the browser")
        let hasGrant = await authenticator.hasGrant(forDevice: device.deviceID)
        XCTAssertFalse(hasGrant)

        let runtimeCalls = await poolConnector.toolNames(for: device.deviceID)
        XCTAssertTrue(runtimeCalls.isEmpty, "No locked frame executed on the per-device app link: \(runtimeCalls)")
    }

    /// The grant is idle-bounded on the gateway's injected monotonic clock: still open just before the
    /// deadline, then the delayed expiry tells every tab and relocks protected frames.
    func testGrantIdleExpiryOnInjectedClockRelocksEveryTab() async throws {
        let tabA = try await openPairedSocket()
        defer { tabA.close() }
        let tabB = try await openPairedSocket()
        defer { tabB.close() }
        _ = try await tabA.hello()
        _ = try await tabB.hello()
        let authenticatorKey = SoftwareAuthenticator()
        try await register(tabA, using: authenticatorKey, requestID: "req-register")
        try await unlock(tabA, using: authenticatorKey, requestID: "req-unlock")

        // S3-I03: a successful unlock proactively notifies EVERY tab of the device with the current
        // unlocked metadata (so a locked-connected browser can build a `passkey_activity` payload and
        // siblings learn the unlocked state). Drain those notices before driving the idle-expiry ones.
        for tab in [tabA, tabB] {
            let unlocked = try await tab.receiveUnlockedNotice()
            XCTAssertNotNil(
                unlocked.payload?.objectValue?["grant_id"]?.stringValue,
                "The unlocked notice carries the shared grant reference"
            )
        }

        clock.advance(by: GatewayAccessTiming.idleGrantLifetime - .seconds(1))
        let beforeDeadline = try await tabB.request(type: "list_sessions", requestID: "req-list-before")
        XCTAssertEqual(beforeDeadline.type, "command_result")

        clock.advance(by: .seconds(1))
        for tab in [tabA, tabB] {
            let expired = try await tab.receive()
            XCTAssertEqual(expired.type, "lock_state")
            XCTAssertEqual(expired.payload?.objectValue?["reason"]?.stringValue, "passkey_expired")
        }
        try await assertLockedSettlement(tabA, type: "list_sessions", requestID: "req-list-after-a")
        try await assertLockedSettlement(tabB, type: "list_sessions", requestID: "req-list-after-b")
    }

    /// S3-I04: a client that obeys `hello_ack` may send its first command before the gateway publishes
    /// `.ready` (watch registration still completing). The frame must be BUFFERED and drained on
    /// readiness, never rejected `hello_in_progress`. Here the frame is pushed immediately after the
    /// hello, so it arrives while `.authenticating`; it is processed after readiness (locked, so settled
    /// content-free) carrying its OWN request id — proving it was buffered, not rejected.
    func testCommandRightAfterHelloIsBufferedThenProcessedNotRejected() async throws {
        let socket = try await openPairedSocket()
        defer { socket.close() }
        try await socket.sendHello()
        try await socket.send(type: "list_sessions", requestID: "req-immediate")

        let ack = try await socket.receive()
        XCTAssertEqual(ack.type, "hello_ack")
        let settled = try await socket.receive()
        XCTAssertEqual(settled.type, "command_error", "The buffered frame was processed, not rejected")
        XCTAssertEqual(settled.requestID, "req-immediate", "The SAME buffered frame was drained and settled")
        XCTAssertEqual(
            settled.payload?.objectValue?["code"]?.stringValue, "passkey_locked",
            "A locked connection settles the buffered frame content-free, never hello_in_progress"
        )
    }

    /// S3-I07: a protected command that ARRIVES WHILE LOCKED is denied at admission (after verification)
    /// and must never execute, even though an assertion for the SAME lock generation unlocks moments
    /// later. The command is injected while the app's verify is held (verified but not yet committed, so
    /// still locked); after release the connection unlocks, yet the locked-admitted command never
    /// reaches the app.
    func testProtectedFrameDuringHeldAssertionStaysDeniedAfterUnlock() async throws {
        let socket = try await openPairedSocket()
        defer { socket.close() }
        _ = try await socket.hello()
        let key = SoftwareAuthenticator()
        try await register(socket, using: key, requestID: "req-register")

        let challenge = try await socket.request(type: "passkey_unlock_begin", requestID: "req-unlock")
        XCTAssertEqual(challenge.type, "passkey_challenge")
        let options = try XCTUnwrap(challenge.payload?.objectValue)
        let ceremonyID = try XCTUnwrap(options["ceremony_id"]?.stringValue)
        let challengeBytes = try Self.challengeBytes(options)

        let hold = RecordingAppLinkResponseGate()
        await principalConnection.holdResponse(forOp: "passkey_unlock_complete", gate: hold)
        try await socket.send(type: "passkey_unlock_complete", requestID: "req-unlock-complete", payload: .object([
            "ceremony_id": .string(ceremonyID),
            "credential": .string(String(decoding: key.assertionJSON(challenge: challengeBytes), as: UTF8.self))
        ]))
        await hold.waitUntilEntered()

        // Verified by the app, NOT yet committed by the gateway → still locked. A protected command
        // arriving now must be denied at admission (I07), not merely at the runtime head.
        let deniedWhileLocked = try await socket.request(type: "list_sessions", requestID: "req-during-hold")
        XCTAssertEqual(deniedWhileLocked.type, "command_error")
        XCTAssertEqual(deniedWhileLocked.requestID, "req-during-hold")
        XCTAssertEqual(deniedWhileLocked.payload?.objectValue?["code"]?.stringValue, "passkey_locked")

        await hold.release()
        let complete = try await socket.receiveCorrelated()
        XCTAssertEqual(complete.type, "passkey_ceremony_complete", "The held assertion still unlocks")

        let callsAfterUnlock = await poolConnector.toolNames(for: device.deviceID)
        XCTAssertTrue(callsAfterUnlock.isEmpty, "The locked-admitted command never reached the app: \(callsAfterUnlock)")

        let listed = try await socket.request(type: "list_sessions", requestID: "req-after-unlock")
        XCTAssertEqual(listed.type, "command_result", "A fresh command admitted while unlocked executes")
        let callsAfterFreshList = await poolConnector.toolNames(for: device.deviceID)
        XCTAssertEqual(callsAfterFreshList.count, 1, "Only the post-unlock list executed: \(callsAfterFreshList)")
    }

    /// S3-I03: after a successful unlock the browser can renew purely from WebSocket-delivered metadata.
    /// The signed `passkey_activity` payload is built ONLY from the unlock `lock_state` notice (grant id,
    /// epoch, lock generation); the renewal publishes a fresh notice with an EXTENDED deadline, and
    /// protected frames keep delivering past the ORIGINAL deadline.
    func testSignedActivityRenewsUsingOnlyWebSocketDeliveredMetadata() async throws {
        let socket = try await openPairedSocket()
        defer { socket.close() }
        _ = try await socket.hello()
        let key = SoftwareAuthenticator()
        try await register(socket, using: key, requestID: "req-register")
        try await unlock(socket, using: key, requestID: "req-unlock")

        let unlockedNotice = try await socket.receiveUnlockedNotice()
        let access = try XCTUnwrap(unlockedNotice.payload?.objectValue)
        let grantID = try XCTUnwrap(access["grant_id"]?.stringValue)
        let epoch = try XCTUnwrap(access["epoch"]?.stringValue)
        let lockGeneration = try XCTUnwrap(access["lock_generation"]?.stringValue)

        // Partway through the idle window, renew using ONLY the delivered references.
        clock.advance(by: .seconds(10 * 60))
        try await socket.send(type: "passkey_activity", requestID: "req-activity", payload: .object([
            "grant_id": .string(grantID),
            "epoch": .string(epoch),
            "lock_generation": .string(lockGeneration)
        ]))

        // A renewal first runs its own trust refresh, which now re-emits the CURRENT (pre-renewal)
        // unlocked metadata — the exact-revision notice fix no longer suppresses an unchanged refresh,
        // so a refresh that overtook an in-flight transition can never leave the browser without current
        // grant refs. THEN the renewal commits and emits the EXTENDED-deadline notice. Read unlocked
        // notices (all carrying the same shared grant) until the renewed longer deadline arrives.
        var renewedRemaining: Double?
        for _ in 0 ..< 8 {
            let renewed = try await socket.receiveUnlockedNotice()
            let renewedAccess = try XCTUnwrap(renewed.payload?.objectValue)
            XCTAssertEqual(renewedAccess["grant_id"]?.stringValue, grantID, "Every unlocked notice keeps the same shared grant")
            if let remaining = Self.deadlineRemaining(renewedAccess), remaining > 29 * 60 {
                renewedRemaining = remaining
                break
            }
        }
        XCTAssertNotNil(renewedRemaining, "Renewal reset the idle window to ~full lifetime")

        // Past the ORIGINAL 30-minute deadline but within the renewed window, protected frames deliver.
        clock.advance(by: .seconds(25 * 60))
        let listed = try await socket.request(type: "list_sessions", requestID: "req-list-after-renewal")
        XCTAssertEqual(listed.type, "command_result", "Delivery continues past the original deadline after renewal")
    }

    private static func deadlineRemaining(_ access: [String: JSONValue]) -> Double? {
        switch access["deadline_seconds_remaining"] {
        case let .double(value): value
        case let .int(value): Double(value)
        default: nil
        }
    }

    /// S3-A-11: a connection-management op that still EXECUTES while locked (here a heartbeat `ping`)
    /// gets its own fixed, content-free result (`pong`), NOT a `passkey_locked` command_error a client
    /// would read as a failure. The connection stays locked and open.
    func testManagementPingWhileLockedReturnsPongNotLocked() async throws {
        let socket = try await openPairedSocket()
        defer { socket.close() }
        _ = try await socket.hello()

        let pong = try await socket.request(type: "ping", requestID: "req-ping")
        XCTAssertEqual(pong.type, "pong", "A heartbeat executed while locked gets a pong, not passkey_locked")
        XCTAssertEqual(pong.requestID, "req-ping")

        // Still locked: an ordinary protected frame is withheld, proving ping did not unlock anything.
        try await assertLockedSettlement(socket, type: "list_sessions", requestID: "req-list-after-ping")
    }

    /// S3-R1-02: a connection-management op that EXECUTES while locked but FAILS must be reported to
    /// the browser as a FAILURE, not a fixed empty success. `push_subscribe` runs while locked (it is
    /// in the locked-management allowlist and the device holds the observe scope), but this gateway has
    /// no push subscription store, so the runtime returns `push_unavailable`. The browser must receive a
    /// sanitized `command_error` carrying that closed-set code and the FIXED message — never an empty
    /// `command_result` implying the subscription was stored, and never the runtime's own message text.
    func testLockedPushSubscribeFailureIsReportedAsFailureNotEmptySuccess() async throws {
        let socket = try await openPairedSocket()
        defer { socket.close() }
        _ = try await socket.hello()

        let result = try await socket.request(type: "push_subscribe", requestID: "req-push", payload: .object([
            "subscription": .object([
                "endpoint": .string("https://push.example.com/abc"),
                "keys": .object(["p256dh": .string("key"), "auth": .string("auth")])
            ])
        ]))
        XCTAssertEqual(result.type, "command_error", "A failed locked management op is a failure, not success: \(result)")
        XCTAssertEqual(result.payload?.objectValue?["code"]?.stringValue, "push_unavailable")
        XCTAssertEqual(
            result.payload?.objectValue?["message"]?.stringValue, "The request was rejected.",
            "The runtime's own message text is not forwarded on the sanitized failure path"
        )
        XCTAssertNotEqual(
            result.payload?.objectValue?["code"]?.stringValue, "passkey_locked",
            "It executed and failed; it was not withheld pre-execution as a lock settlement"
        )

        // The runtime's own failure text ("Web Push is not available...") must never reach the browser.
        let encoded = try String(decoding: RemoteWireProtocol.encodeServerFrame(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("not available"), "Raw runtime error text must not ride the sanitized failure path")

        // Still locked: an ordinary protected frame is withheld, proving push_subscribe did not unlock.
        try await assertLockedSettlement(socket, type: "list_sessions", requestID: "req-list-after-push")
    }

    // MARK: - Ceremony steps

    private func register(_ socket: PasskeyE2ESocket, using key: SoftwareAuthenticator, requestID: String) async throws {
        let challenge = try await socket.request(type: "passkey_register_begin", requestID: requestID)
        XCTAssertEqual(challenge.type, "passkey_challenge")
        let options = try XCTUnwrap(challenge.payload?.objectValue)
        XCTAssertEqual(options["kind"]?.stringValue, "registration")
        XCTAssertEqual(options["device_id"]?.stringValue, device.deviceID)
        let ceremonyID = try XCTUnwrap(options["ceremony_id"]?.stringValue)
        let registration = try key.registrationJSON(challenge: Self.challengeBytes(options))
        // S3-I05: the gateway now completes its post-registration trust refresh (adopting the new
        // epoch) BEFORE it sends `passkey_ceremony_complete`. The helper therefore relies ONLY on the
        // browser-observable completion — never on the hidden principal `acknowledge_trust` ACK the
        // browser cannot see — so the immediately-following separate assertion sees the new epoch.
        let completion = try await socket.request(type: "passkey_register_complete", requestID: "\(requestID)-complete", payload: .object([
            "ceremony_id": .string(ceremonyID),
            "credential": .string(String(decoding: registration, as: UTF8.self))
        ]))
        XCTAssertEqual(completion.type, "passkey_ceremony_complete", "Registration: \(completion)")
        XCTAssertEqual(completion.payload?.objectValue?["kind"]?.stringValue, "registration")
    }

    private func unlock(_ socket: PasskeyE2ESocket, using key: SoftwareAuthenticator, requestID: String) async throws {
        let challenge = try await socket.request(type: "passkey_unlock_begin", requestID: requestID)
        XCTAssertEqual(challenge.type, "passkey_challenge", "Unlock begin: \(challenge)")
        let options = try XCTUnwrap(challenge.payload?.objectValue)
        XCTAssertEqual(options["kind"]?.stringValue, "assertion")
        let ceremonyID = try XCTUnwrap(options["ceremony_id"]?.stringValue)
        let assertion = try key.assertionJSON(challenge: Self.challengeBytes(options))
        let completion = try await socket.request(type: "passkey_unlock_complete", requestID: "\(requestID)-complete", payload: .object([
            "ceremony_id": .string(ceremonyID),
            "credential": .string(String(decoding: assertion, as: UTF8.self))
        ]))
        XCTAssertEqual(completion.type, "passkey_ceremony_complete", "Unlock: \(completion)")
        XCTAssertEqual(completion.payload?.objectValue?["kind"]?.stringValue, "assertion")
    }

    private func assertLockedSettlement(
        _ socket: PasskeyE2ESocket,
        type: String,
        requestID: String,
        sessionID: String? = nil,
        payload: JSONValue? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let response = try await socket.request(type: type, requestID: requestID, sessionID: sessionID, payload: payload)
        XCTAssertEqual(response.type, "command_error", "\(type) while locked", file: file, line: line)
        XCTAssertEqual(response.requestID, requestID, file: file, line: line)
        XCTAssertEqual(response.payload?.objectValue?["code"]?.stringValue, "passkey_locked", file: file, line: line)
        XCTAssertEqual(
            response.payload?.objectValue?["message"]?.stringValue,
            "This connection is locked and requires passkey verification.",
            file: file,
            line: line
        )
        XCTAssertNil(response.sessionID, "A lock settlement carries no session identity", file: file, line: line)
    }

    // MARK: - Fixture helpers

    private func openPairedSocket() async throws -> PasskeyE2ESocket {
        let ticket = try GatewayAuthTestSupport.mintTicket(
            hostSigner: hostSigner,
            deviceID: device.deviceID,
            scopes: [GatewayRemoteScope.sessionsObserve]
        )
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port!)/ws")!)
        task.resume()
        return PasskeyE2ESocket(task: task, ticket: ticket, signer: device.signer)
    }

    private func appliedPolicy(_ receipt: GatewayCapabilityTrustRefreshReceipt) throws -> GatewayDevicePasskeyPolicy? {
        guard case let .applied(snapshot) = receipt else {
            XCTFail("Expected an applied strict trust refresh, got \(receipt)")
            return nil
        }
        return snapshot.devices[device.deviceID]?.policy
    }

    private func currentGatewayPolicy() async throws -> GatewayDevicePasskeyPolicy? {
        guard case let .valid(snapshot) = await authenticator.accessTrustAvailability() else { return nil }
        return snapshot.devices[device.deviceID]?.policy
    }

    private static func challengeBytes(_ challengeFrame: [String: JSONValue]) throws -> [UInt8] {
        let options = try XCTUnwrap(challengeFrame["options"]?.objectValue)
        let encoded = try XCTUnwrap(options["challenge"]?.stringValue)
        var normalized = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized += "="
        }
        return try Array(XCTUnwrap(Data(base64Encoded: normalized)))
    }
}

// MARK: - App side (real provider, coordinator, verifier)

@MainActor
private final class PasskeyE2EApp {
    private final class NoopApprovalRouter: RemotePairingApprovalRouting {
        func requestApproval(
            deviceID _: String,
            displayName _: String,
            devicePublicKeyFingerprint _: String,
            requestedScopes _: Set<RemoteScope>,
            hostFingerprint _: String
        ) async throws -> Set<RemoteScope>? {
            nil
        }
    }

    let store: RemotePairingIdentityStore
    let coordinator: RemotePasskeyCoordinator
    /// Dispatches the gateway's actual `remote_pairing` arguments into the real provider, as the
    /// verified gateway-principal connection.
    let execute: @Sendable ([String: Value]) async throws -> Value

    init(directory: URL, hostSigner: P256.Signing.PrivateKey, device: GatewayAuthTestSupport.TestDeviceIdentity) throws {
        let (_, keychain) = RemotePairingTestSupport.hostKeychain(signingIdentity: hostSigner)
        let store = RemotePairingIdentityStore(url: RemotePairingTestSupport.registryURL(in: directory), keychain: keychain)
        var record = RemotePairingTestSupport.deviceRecord(id: device.deviceID, scopes: [.sessionsObserve])
        record.publicKeyRawRepresentation = device.publicKeyRaw
        try store.upsertDevice(record)
        self.store = store

        let principalConnectionID = UUID()
        let principal = principalConnectionID.uuidString
        let coordinator = RemotePasskeyCoordinator(
            identityStore: store,
            verifier: WebAuthnRemotePasskeyVerifier(),
            now: { ContinuousClock.now },
            originSnapshot: {
                .init(origin: RemotePasskeyOrigin(httpsURLString: "https://example.com"), generation: 1, discoverable: true)
            },
            buildLabel: "RepoPrompt Passkey E2E",
            // The live-principal query is the app's own ServerNetworkManager lookup; here the single
            // principal is the provider's metadata connection.
            isPrincipalLive: { candidate in candidate == principal }
        )
        self.coordinator = coordinator
        let metadata = MCPServerViewModel.RequestMetadata(
            connectionID: principalConnectionID,
            clientName: "repoprompt-gateway",
            windowID: 1,
            actorRoutedRunTab: nil
        )
        let dependencies = MCPRemotePairingToolProvider.ExecutionDependencies(
            captureRequestMetadata: { metadata },
            isGatewayPrincipalConnection: { candidate in candidate == principalConnectionID },
            identityStore: store,
            approvalRouter: NoopApprovalRouter(),
            passkeyCoordinator: coordinator
        )
        let context = MCPWindowToolContext(toolName: MCPWindowToolName.remotePairing, windowID: 1)
        execute = { arguments in
            // The app's MCP CallTool handler normalizes arguments before dispatching the provider.
            let normalized = MCPToolArgsNormalizer.normalize(
                params: arguments,
                originalToolName: MCPWindowToolName.remotePairing,
                canonicalToolName: MCPWindowToolName.remotePairing
            )
            return try await MCPRemotePairingToolProvider.execute(args: normalized.payload, context: context, dependencies: dependencies)
        }
    }
}

/// The principal app-link connection. `remote_pairing` calls run the REAL app provider with the
/// gateway's actual arguments; results are rendered through the app's own result formatter (success)
/// or tool-error envelope (thrown), exactly as the app's MCP CallTool handler returns them. Records
/// each passkey call's request/response generation so tests read the wire values, never constants.
private actor ProviderBackedPrincipalConnection: AppLinkConnection {
    struct PasskeyCall: CustomStringConvertible {
        let op: String
        let requestGeneration: Int?
        let responseGeneration: Int?
        let responseOK: Bool?
        let responseVerified: Bool?
        let responseCode: String?

        var description: String {
            "\(op)(req=\(requestGeneration.map(String.init) ?? "nil"), resp=\(responseGeneration.map(String.init) ?? "nil"), ok=\(responseOK.map(String.init) ?? "nil"))"
        }
    }

    private let execute: @Sendable ([String: Value]) async throws -> Value
    private var calls: [PasskeyCall] = []
    private var completedCounts: [String: Int] = [:]
    private var completionWaiters: [(op: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var heldResponses: [String: RecordingAppLinkResponseGate] = [:]

    init(execute: @escaping @Sendable ([String: Value]) async throws -> Value) {
        self.execute = execute
    }

    func passkeyCalls() -> [PasskeyCall] {
        calls
    }

    func completedCount(op: String) -> Int {
        completedCounts[op, default: 0]
    }

    func waitForCompleted(op: String, count: Int) async {
        if completedCounts[op, default: 0] >= count { return }
        await withCheckedContinuation { completionWaiters.append((op, count, $0)) }
    }

    /// Hold the NEXT response for `op` (after the app has fully executed it) until the gate opens.
    func holdResponse(forOp op: String, gate: RecordingAppLinkResponseGate) {
        heldResponses[op] = gate
    }

    func callTool(name: String, arguments: [String: Value], timeout _: TimeInterval?) async throws -> MCPToolResult {
        guard name == "remote_pairing" else {
            throw GatewayTestError(message: "Unexpected principal tool \(name)")
        }
        let op = arguments["op"]?.stringValue ?? ""
        let value: Value?
        let result: MCPToolResult
        do {
            let returned = try await execute(arguments)
            value = returned
            result = CallTool.Result(
                content: ToolOutputFormatter.buildContentBlocks(
                    toolName: MCPWindowToolName.remotePairing,
                    args: arguments,
                    result: returned,
                    emitResources: false
                ),
                isError: false
            )
        } catch {
            value = nil
            result = ServerNetworkManager.toolErrorResult(rawJSON: false, error: error)
        }
        if op.hasPrefix("passkey_") {
            let object = value?.objectValue
            calls.append(PasskeyCall(
                op: op,
                requestGeneration: arguments["connection_generation"]?.intValue,
                responseGeneration: object?["connection_generation"]?.intValue,
                responseOK: object?["ok"]?.boolValue,
                responseVerified: object?["verified"]?.boolValue,
                responseCode: object?["code"]?.stringValue
            ))
        }
        if let gate = heldResponses.removeValue(forKey: op) {
            await gate.enterAndWaitForRelease()
        }
        completedCounts[op, default: 0] += 1
        let ready = completionWaiters.filter { completedCounts[$0.op, default: 0] >= $0.count }
        completionWaiters.removeAll { completedCounts[$0.op, default: 0] >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return result
    }

    func disconnect() async {}
}

private struct ProviderBackedPrincipalConnector: AppLinkConnecting {
    let connection: ProviderBackedPrincipalConnection

    func connect(configuration _: GatewayConfiguration, clientName _: String, logger _: Logger) async throws -> any AppLinkConnection {
        connection
    }
}

/// Per-device runtime links: a recording connection per paired device, so a test can prove a
/// locked frame never executed on the app.
private final class PasskeyE2EPoolConnector: AppLinkConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [String: RecordingAppLinkConnection] = [:]

    func toolNames(for clientName: String) async -> [String] {
        guard let connection = lock.withLock({ connections[clientName] }) else { return [] }
        return await connection.calls.map(\.name)
    }

    func connect(configuration _: GatewayConfiguration, clientName: String, logger _: Logger) async throws -> any AppLinkConnection {
        let connection = RecordingAppLinkConnection()
        lock.withLock { connections[clientName] = connection }
        return connection
    }
}

// MARK: - Signed WebSocket client

private final class PasskeyE2ESocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let ticket: RemoteTicket
    private let signer: P256.Signing.PrivateKey
    private var counter: UInt64 = 0

    init(task: URLSessionWebSocketTask, ticket: RemoteTicket, signer: P256.Signing.PrivateKey) {
        self.task = task
        self.ticket = ticket
        self.signer = signer
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    func hello() async throws -> RemoteServerFrame {
        try await sendHello()
        return try await receive()
    }

    /// Sends ONLY the hello frame without awaiting the ack, so a test can push an immediate follow-up
    /// command that races the gateway's `.authenticating` → `.ready` transition (S3-I04).
    func sendHello() async throws {
        try await send(object: GatewayAuthTestSupport.helloObject(ticketJSON: ticket.jsonValue))
    }

    func send(type: String, requestID: String? = nil, sessionID: String? = nil, payload: JSONValue? = nil) async throws {
        try await send(object: GatewayAuthTestSupport.frameObject(type: type, requestID: requestID, sessionID: sessionID, payload: payload))
    }

    func request(type: String, requestID: String, sessionID: String? = nil, payload: JSONValue? = nil) async throws -> RemoteServerFrame {
        try await send(type: type, requestID: requestID, sessionID: sessionID, payload: payload)
        return try await receiveCorrelated()
    }

    /// Receives the next correlated/non-notice frame, skipping any unsolicited `lock_state` access-state
    /// notices. The gateway now proactively publishes these on unlock, renewal, and policy/enrollment
    /// changes (S3-I03); a correlated `request` must not mistake one for its own response.
    func receiveCorrelated() async throws -> RemoteServerFrame {
        for _ in 0 ..< 8 {
            let frame = try await receive()
            if frame.type == "lock_state" { continue }
            return frame
        }
        throw GatewayTestError(message: "Only lock_state notices received; no correlated response")
    }

    /// Receives `lock_state` notices until one reports `locked == false` (an unlocked/renewed
    /// access-state notice), returning it. Skips interim LOCKED notices — e.g. an enrollment-change
    /// notice a sibling tab received earlier — without masking a missing unlocked notice (a timeout
    /// still fails). Any non-`lock_state` frame is unexpected.
    func receiveUnlockedNotice() async throws -> RemoteServerFrame {
        for _ in 0 ..< 8 {
            let frame = try await receive()
            guard frame.type == "lock_state" else {
                throw GatewayTestError(message: "Expected a lock_state notice, got \(frame.type)")
            }
            if frame.payload?.objectValue?["locked"]?.boolValue == false { return frame }
        }
        throw GatewayTestError(message: "No unlocked lock_state notice arrived")
    }

    private func send(object: [String: JSONValue]) async throws {
        counter += 1
        let data = try GatewayAuthTestSupport.signedFrameData(
            object: object,
            ticketID: ticket.ticketID,
            deviceID: ticket.deviceID,
            counter: counter,
            deviceKey: signer
        )
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Receives the next server frame. The timeout only bounds a hung test; ordering is established by
    /// the protocol, never by waiting.
    func receive(timeout: TimeInterval = 10) async throws -> RemoteServerFrame {
        let task = task
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GatewayTestError(message: "Timed out waiting for a server frame")
            }
            guard let first = try await group.next() else {
                throw GatewayTestError(message: "No server frame")
            }
            group.cancelAll()
            return first
        }
        let data: Data = switch message {
        case let .string(text): Data(text.utf8)
        case let .data(payload): payload
        @unknown default: Data()
        }
        return try RemoteWireProtocol.decodeServerFrame(from: data)
    }
}
