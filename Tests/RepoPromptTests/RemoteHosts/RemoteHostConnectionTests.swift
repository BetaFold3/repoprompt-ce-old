import CryptoKit
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptGateway
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class RemoteHostConnectionTests: XCTestCase {
    func testUnknownDeviceIsRetryableAuthenticationFailure() {
        let error = RemoteClientError.fromCommandError(
            code: "unknown_device",
            message: "The gateway trust snapshot has not observed this device yet."
        )

        guard case let .authentication(commandError) = error else {
            return XCTFail("Expected unknown_device to remain a nonsticky authentication failure, got \(error)")
        }
        XCTAssertEqual(commandError.code, "unknown_device")
    }

    func testTicketHTTPErrorRequiresStructuredDeviceRevokedCode() throws {
        let unstructured = try XCTUnwrap(
            #"{"error":"Device remote:11223344 is revoked."}"#.data(using: .utf8)
        )
        let unstructuredError = RemoteHostConnection.classifyTicketHTTPError(statusCode: 403, data: unstructured)
        guard case .transport = unstructuredError else {
            return XCTFail("Expected revocation-like free text to remain nonsticky, got \(unstructuredError)")
        }

        let unknownDevice = try XCTUnwrap(
            #"{"code":"unknown_device","error":"No paired device exists."}"#.data(using: .utf8)
        )
        let unknownDeviceError = RemoteHostConnection.classifyTicketHTTPError(statusCode: 404, data: unknownDevice)
        guard case let .authentication(commandError) = unknownDeviceError else {
            return XCTFail("Expected structured unknown_device to remain retryable, got \(unknownDeviceError)")
        }
        XCTAssertEqual(commandError.code, "unknown_device")

        let revoked = try XCTUnwrap(
            #"{"code":"device_revoked","error":"The host revoked this device."}"#.data(using: .utf8)
        )
        let revokedError = RemoteHostConnection.classifyTicketHTTPError(statusCode: 403, data: revoked)
        guard case let .revoked(commandError) = revokedError else {
            return XCTFail("Expected explicit device_revoked to be definitive, got \(revokedError)")
        }
        XCTAssertEqual(commandError.code, "device_revoked")
    }

    private var root: URL!
    private var configuration: GatewayConfiguration!
    private var hostSigner: P256.Signing.PrivateKey!
    private var device: GatewayAuthTestSupport.TestDeviceIdentity!
    private var authenticator: DeviceAuthenticator!
    private var appConnection: RecordingAppLinkConnection!
    private var appLink: AppLinkSession!
    private var watchManager: SessionWatchManager!
    private var server: GatewayHTTPServer!
    private var port: Int!
    private var registry: RemoteHostRegistry!
    private var keyStore: RemoteClientKeyStore!

    override func setUp() async throws {
        try await super.setUp()
        root = try GatewayTestHelpers.temporaryRoot("remote-host-connection")
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
        hostSigner = P256.Signing.PrivateKey()
        device = GatewayAuthTestSupport.makeDevice(deviceID: "remote:11223344")
        authenticator = try DeviceAuthenticator(
            usedTicketStore: GatewayAuthTestSupport.makeUsedTicketStore(root: root),
            trust: GatewayAuthTestSupport.trustSnapshot(
                hostSigner: hostSigner,
                devices: [(device, false)]
            )
        )
        // Step 3 flip: paired connections bind through the access authority and lock unless a valid
        // capability-1 snapshot authorizes them. These connection tests predate passkey policy, so
        // apply an all-off snapshot (paired `.unprotected`) to preserve their behavior.
        _ = await authenticator.applyCapabilityTrust(
            GatewayAuthTestSupport.capabilityOffSnapshot(hostSigner: hostSigner, devices: [device])
        )

        appConnection = RecordingAppLinkConnection()
        appLink = AppLinkSession(
            config: configuration,
            connector: StaticAppLinkConnector(connection: appConnection)
        )
        try await appLink.connect()

        watchManager = SessionWatchManager(appLink: appLink)
        let auditLog = try RemoteAuditLog(directoryURL: configuration.auditDirectoryURL)
        let runtime = try RemoteGatewayRuntime(
            appLink: appLink,
            ledger: CommandLedger(),
            watchManager: watchManager,
            auditLog: auditLog
        )
        let pairingRelay = GatewayPairingRelay(appLink: appLink, auditLog: auditLog)
        server = GatewayHTTPServer(
            configuration: configuration,
            runtime: runtime,
            authenticator: authenticator,
            auditLog: auditLog,
            pairingRelay: pairingRelay,
            hostName: "N3 Test Host"
        )
        try await server.start()
        port = try XCTUnwrap(server.localAddress?.port)

        let registryDirectory = root.appendingPathComponent("client-registry", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        registry = RemoteHostRegistry(url: RemoteHostTestSupport.registryURL(in: registryDirectory))
        keyStore = RemoteClientKeyStore(
            keychain: InMemoryRemoteClientKeychain(),
            accessMode: .nonInteractive(reason: .test)
        )
    }

    override func tearDown() async throws {
        if let server {
            await server.shutdown()
        }
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    func testConnectionMintsTicketHelloPingsAndDisconnects() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        let result = try await connection.testConnection(timeout: 5)

        XCTAssertEqual(result.hostID, record.id)
        XCTAssertEqual(result.hostName, "N3 Test Host")
        XCTAssertEqual(result.scopes, record.grantedScopes)
        XCTAssertEqual(result.pongPayload.objectValue?["probe"]?.stringValue, "settings_test_connection")
        let disconnectedState = await connection.currentState()
        XCTAssertEqual(disconnectedState, .idle)
        let persisted = try XCTUnwrap(registry.host(id: record.id))
        XCTAssertNotNil(persisted.lastConnectedAt)
        XCTAssertGreaterThan(persisted.lastCounter, 0)
    }

    func testTicketMintDoesNotSendVolatileHostWindowID() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        let result = try await connection.testConnection(timeout: 5)

        XCTAssertEqual(result.hostID, record.id)
        let calls = await appConnection.calls
        let ticketCall = try XCTUnwrap(calls.first { call in
            call.name == "remote_pairing" && call.arguments["op"]?.stringValue == "mint_ticket"
        })
        XCTAssertNil(ticketCall.arguments["_windowID"])
        XCTAssertNil(ticketCall.arguments["window_id"])
    }

    func testUsedTicketAtHelloRetriesWithFreshTicket() async throws {
        let record = try upsertClientRecord()
        let firstTicket = await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        try await connection.ensureConnected()
        await connection.disconnect()

        await enqueueTicket(firstTicket)
        let freshTicket = await enqueueTicket()
        try await connection.ensureConnected()

        guard case let .connected(scopes) = await connection.currentState() else {
            XCTFail("Expected connection to recover with a fresh ticket")
            return
        }
        XCTAssertEqual(scopes, record.grantedScopes)
        XCTAssertNotEqual(firstTicket.ticketID, freshTicket.ticketID)
        await connection.disconnect()
    }

    func testSubscribeRearmsAfterReconnect() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        try await connection.subscribe(sessionIDs: ["session-a"])
        guard case let .connected(initialScopes) = await connection.currentState() else {
            XCTFail("Expected subscribe to leave the channel connected")
            return
        }
        XCTAssertEqual(initialScopes, record.grantedScopes)

        await connection.disconnect()
        await enqueueTicket()
        try await connection.ensureConnected()
        guard case let .connected(rearmedScopes) = await connection.currentState() else {
            XCTFail("Expected reconnect with subscription re-arm to leave the channel connected")
            return
        }
        XCTAssertEqual(rearmedScopes, record.grantedScopes)

        await connection.disconnect()
    }

    func testSequentialSubscribeSendsOnlyDeltaAndReconnectReplaysFullDesiredSet() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        try await connection.ensureConnected()
        let attempts = SubscribeAttemptRecorder()
        await connection.setSubscribeCommandHandlerForTesting { sessionIDs in
            await attempts.record(sessionIDs)
            return .object([:])
        }

        try await connection.subscribe(sessionIDs: ["session-a"])
        try await connection.subscribe(sessionIDs: ["session-b"])
        try await connection.subscribe(sessionIDs: ["session-a"])

        var subscribeAttempts = await attempts.all()
        let acknowledged = await connection.acknowledgedSubscriptionsForTesting()
        XCTAssertEqual(subscribeAttempts, [["session-a"], ["session-b"]])
        XCTAssertEqual(acknowledged, ["session-a", "session-b"])

        await connection.disconnect()
        await enqueueTicket()
        try await connection.ensureConnected()

        subscribeAttempts = await attempts.all()
        XCTAssertEqual(subscribeAttempts.last, ["session-a", "session-b"])
        XCTAssertEqual(subscribeAttempts.count, 3)
        await connection.disconnect()
    }

    func testSubscribeBindingRequiredFallsBackPerSessionAndPrunesFailures() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        try await connection.ensureConnected()
        let attempts = SubscribeAttemptRecorder()
        await connection.setSubscribeCommandHandlerForTesting { sessionIDs in
            await attempts.record(sessionIDs)
            if sessionIDs.count > 1 || sessionIDs == ["bad-session"] {
                throw RemoteClientError.fromCommandError(
                    code: "binding_required",
                    message: "bind first"
                )
            }
            return .object([:])
        }

        do {
            try await connection.subscribe(sessionIDs: ["bad-session", "good-session"])
            XCTFail("Expected subscribe to surface the failing requested session")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "binding_required")
        }

        let desired = await connection.desiredSubscriptionsForTesting()
        let parked = await connection.parkedSubscriptionsForTesting()
        XCTAssertEqual(desired, ["good-session"])
        XCTAssertEqual(parked, ["bad-session"])
        let subscribeAttempts = await attempts.all()
        XCTAssertEqual(subscribeAttempts, [["bad-session", "good-session"], ["bad-session"], ["good-session"]])
        guard case .connected = await connection.currentState() else {
            XCTFail("Expected binding_required fallback to keep the socket connected")
            return
        }
        await connection.disconnect()
    }

    func testConnectTimeSubscribeBindingRequiredDoesNotDisconnectSocket() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        await connection.setDesiredSubscriptionsForTesting(["stale-session"])
        await connection.setSubscribeCommandHandlerForTesting { _ in
            throw RemoteClientError.fromCommandError(
                code: "binding_required",
                message: "bind first"
            )
        }
        await enqueueTicket()

        try await connection.ensureConnected()

        guard case .connected = await connection.currentState() else {
            XCTFail("Expected connect-time command-level subscribe failure to leave the socket connected")
            return
        }
        let desired = await connection.desiredSubscriptionsForTesting()
        let parked = await connection.parkedSubscriptionsForTesting()
        XCTAssertTrue(desired.isEmpty)
        XCTAssertEqual(parked, ["stale-session"])
        await connection.disconnect()
    }

    func testSubscribeBindingRequiredDuringConnectStillThrowsForRequestedID() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        await connection.setSubscribeCommandHandlerForTesting { _ in
            throw RemoteClientError.fromCommandError(
                code: "binding_required",
                message: "bind first"
            )
        }
        await enqueueTicket()

        do {
            try await connection.subscribe(sessionIDs: ["bad-session"])
            XCTFail("Expected requested subscribe failure to be surfaced")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "binding_required")
        }

        let desired = await connection.desiredSubscriptionsForTesting()
        let parked = await connection.parkedSubscriptionsForTesting()
        XCTAssertTrue(desired.isEmpty)
        XCTAssertEqual(parked, ["bad-session"])
        guard case .connected = await connection.currentState() else {
            XCTFail("Expected requested command failure to leave the socket connected")
            return
        }
        await connection.disconnect()
    }

    func testInterleavedSubscribeSurvivesBindingRequiredFallback() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        try await connection.ensureConnected()
        let attempts = SubscribeAttemptRecorder()
        let gate = OneShotAsyncGate()
        await connection.setSubscribeCommandHandlerForTesting { sessionIDs in
            await attempts.record(sessionIDs)
            if sessionIDs.count > 1 {
                throw RemoteClientError.fromCommandError(code: "binding_required", message: "bind first")
            }
            if sessionIDs == ["bad-session"] {
                if await gate.claim() {
                    Task {
                        try? await connection.subscribe(sessionIDs: ["late-session"])
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                throw RemoteClientError.fromCommandError(code: "binding_required", message: "bind first")
            }
            return .object([:])
        }

        do {
            try await connection.subscribe(sessionIDs: ["bad-session", "good-session"])
            XCTFail("Expected bad requested session to fail")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "binding_required")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let desired = await connection.desiredSubscriptionsForTesting()
        let parked = await connection.parkedSubscriptionsForTesting()
        XCTAssertEqual(desired, ["good-session", "late-session"])
        XCTAssertEqual(parked, ["bad-session"])
        let subscribeAttempts = await attempts.all()
        XCTAssertTrue(subscribeAttempts.contains(["late-session"]) || subscribeAttempts.contains(["bad-session", "good-session", "late-session"]))
        await connection.disconnect()
    }

    func testInterleavedUnsubscribeIsNotResurrectedByBindingRequiredFallback() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        try await connection.ensureConnected()
        let gate = OneShotAsyncGate()
        await connection.setSubscribeCommandHandlerForTesting { sessionIDs in
            if sessionIDs.count > 1 {
                throw RemoteClientError.fromCommandError(code: "binding_required", message: "bind first")
            }
            if sessionIDs == ["bad-session"] {
                if await gate.claim() {
                    Task {
                        try? await connection.unsubscribe(sessionIDs: ["good-session"])
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                throw RemoteClientError.fromCommandError(code: "binding_required", message: "bind first")
            }
            return .object([:])
        }

        do {
            try await connection.subscribe(sessionIDs: ["bad-session", "good-session"])
            XCTFail("Expected bad requested session to fail")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "binding_required")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let desired = await connection.desiredSubscriptionsForTesting()
        let parked = await connection.parkedSubscriptionsForTesting()
        XCTAssertTrue(desired.isEmpty)
        XCTAssertEqual(parked, ["bad-session"])
        await connection.disconnect()
    }

    func testParkedSubscribeRetriesAndRecoversOnReconnect() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let attempts = SubscribeAttemptRecorder()
        let acceptance = SubscribeAcceptanceSwitch()
        await connection.setSubscribeCommandHandlerForTesting { sessionIDs in
            await attempts.record(sessionIDs)
            if await acceptance.isAccepting() {
                return .object([:])
            }
            throw RemoteClientError.fromCommandError(code: "binding_required", message: "bind first")
        }

        do {
            try await connection.subscribe(sessionIDs: ["recover-session"])
            XCTFail("Expected first subscribe to park the session")
        } catch let error as RemoteClientError {
            XCTAssertEqual(error.commandError?.code, "binding_required")
        }
        var desired = await connection.desiredSubscriptionsForTesting()
        var parked = await connection.parkedSubscriptionsForTesting()
        XCTAssertTrue(desired.isEmpty)
        XCTAssertEqual(parked, ["recover-session"])

        await connection.disconnect()
        await acceptance.setAccepting(true)
        await enqueueTicket()
        try await connection.ensureConnected()

        desired = await connection.desiredSubscriptionsForTesting()
        parked = await connection.parkedSubscriptionsForTesting()
        let recoverAttemptCount = await attempts.count(of: ["recover-session"])
        XCTAssertEqual(desired, ["recover-session"])
        XCTAssertTrue(parked.isEmpty)
        XCTAssertGreaterThanOrEqual(recoverAttemptCount, 2)
        await connection.disconnect()
    }

    func testRevocationDuringHelloMarksRegistryAndStopsRetrying() async throws {
        let record = try upsertClientRecord()
        _ = await authenticator.updateTrust(GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: [(device, true)]
        ))
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        do {
            try await connection.ensureConnected()
            XCTFail("Expected revoked host credentials to fail connection")
        } catch let error as RemoteClientError {
            guard case .revoked = error else {
                XCTFail("Expected revoked error, got \(error)")
                return
            }
        }

        XCTAssertNotNil(try registry.host(id: record.id)?.revokedByHostAt)
        let revokedState = await connection.currentState()
        XCTAssertEqual(revokedState, .revoked)
    }

    func testUnknownDeviceDuringHelloDoesNotPersistRevocationAndCanRetry() async throws {
        let record = try upsertClientRecord()
        _ = await authenticator.updateTrust(GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: []
        ))
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)

        do {
            try await connection.ensureConnected()
            XCTFail("Expected the stale trust snapshot to reject an unknown device")
        } catch let error as RemoteClientError {
            guard case let .authentication(commandError) = error else {
                XCTFail("Expected a retryable authentication error, got \(error)")
                return
            }
            XCTAssertEqual(commandError.code, "unknown_device")
        }

        XCTAssertNil(try registry.host(id: record.id)?.revokedByHostAt)
        let stateAfterDenial = await connection.currentState()
        XCTAssertNotEqual(stateAfterDenial, .revoked)

        _ = await authenticator.updateTrust(GatewayAuthTestSupport.trustSnapshot(
            hostSigner: hostSigner,
            devices: [(device, false)]
        ))
        await enqueueTicket()
        try await connection.ensureConnected()

        guard case .connected = await connection.currentState() else {
            XCTFail("Expected retry to connect after gateway trust caught up")
            return
        }
        XCTAssertNil(try registry.host(id: record.id)?.revokedByHostAt)
        await connection.disconnect()
    }

    func testUnknownServerFramesAreIgnored() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let inboundFrames = await connection.inboundFramesStream()
        let frameTask = nextFrameTask(from: inboundFrames, timeout: 0.2)

        await connection.handleServerFrameForTesting(RemoteServerFrame(type: "future_frame"))

        do {
            _ = try await frameTask.value
            XCTFail("Unknown server frame should not be yielded to inbound consumers")
        } catch RemoteClientError.timeout {
            // Expected.
        } catch {
            throw error
        }
    }

    func testInboundStreamYieldsKnownServerFrames() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let inboundFrames = await connection.inboundFramesStream()
        let frameTask = nextFrameTask(from: inboundFrames, ofType: "session_update", timeout: 1)

        await connection.handleServerFrameForTesting(RemoteServerFrame(
            type: "session_update",
            sessionID: "session-a",
            seq: 1,
            payload: GatewayTestHelpers.snapshot(sessionID: "session-a", status: "running")
        ))

        let frame = try await frameTask.value
        XCTAssertEqual(frame.type, "session_update")
        XCTAssertEqual(frame.sessionID, "session-a")
    }

    func testInboundFramesMulticastToAllSubscribers() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let firstFrames = await connection.inboundFramesStream()
        let secondFrames = await connection.inboundFramesStream()
        let firstFrameTask = nextFrameTask(from: firstFrames, ofType: "session_update", timeout: 1)
        let secondFrameTask = nextFrameTask(from: secondFrames, ofType: "session_update", timeout: 1)
        let expectedFrame = RemoteServerFrame(
            type: "session_update",
            sessionID: "session-a",
            seq: 1,
            payload: GatewayTestHelpers.snapshot(sessionID: "session-a", status: "running")
        )

        await connection.handleServerFrameForTesting(expectedFrame)

        let firstFrame = try await firstFrameTask.value
        let secondFrame = try await secondFrameTask.value
        XCTAssertEqual(firstFrame.type, expectedFrame.type)
        XCTAssertEqual(firstFrame.sessionID, expectedFrame.sessionID)
        XCTAssertEqual(firstFrame.seq, expectedFrame.seq)
        XCTAssertEqual(secondFrame.type, expectedFrame.type)
        XCTAssertEqual(secondFrame.sessionID, expectedFrame.sessionID)
        XCTAssertEqual(secondFrame.seq, expectedFrame.seq)
    }

    func testStateEventsReplayCurrentStateAndMulticastTransitions() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let firstStates = await connection.stateEventsStream()
        let secondStates = await connection.stateEventsStream()
        let firstStateTask = nextConnectedStateTask(from: firstStates, timeout: 5)
        let secondStateTask = nextConnectedStateTask(from: secondStates, timeout: 5)

        try await connection.ensureConnected()

        let firstObservation = try await firstStateTask.value
        let secondObservation = try await secondStateTask.value
        XCTAssertEqual(firstObservation.initial, .idle)
        XCTAssertEqual(secondObservation.initial, .idle)
        XCTAssertEqual(firstObservation.connected, .connected(scopes: record.grantedScopes))
        XCTAssertEqual(secondObservation.connected, .connected(scopes: record.grantedScopes))

        let lateStates = await connection.stateEventsStream()
        var lateIterator = lateStates.makeAsyncIterator()
        let replayedState = await lateIterator.next()
        XCTAssertEqual(replayedState, .connected(scopes: record.grantedScopes))
        await connection.disconnect()
    }

    func testCancelledInboundSubscriberIsRemovedAndRemainingSubscriberReceivesFrames() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(hostID: record.id, registry: registry, keyStore: keyStore)
        let cancelledFrames = await connection.inboundFramesStream()
        let remainingFrames = await connection.inboundFramesStream()
        let cancelledStates = await connection.stateEventsStream()
        let cancelledTask = Task {
            var iterator = cancelledFrames.makeAsyncIterator()
            return await iterator.next()
        }
        let cancelledStateTask = Task {
            var iterator = cancelledStates.makeAsyncIterator()
            _ = await iterator.next()
            return await iterator.next()
        }
        await Task.yield()

        cancelledTask.cancel()
        cancelledStateTask.cancel()
        let cancelledFrame = await cancelledTask.value
        let cancelledState = await cancelledStateTask.value
        XCTAssertNil(cancelledFrame)
        XCTAssertNil(cancelledState)
        await waitForInboundSubscriberCount(1, connection: connection)
        await waitForStateSubscriberCount(0, connection: connection)

        let remainingTask = nextFrameTask(from: remainingFrames, ofType: "session_update", timeout: 1)
        await connection.handleServerFrameForTesting(RemoteServerFrame(
            type: "session_update",
            sessionID: "session-a",
            seq: 1,
            payload: GatewayTestHelpers.snapshot(sessionID: "session-a", status: "running")
        ))

        let remainingFrame = try await remainingTask.value
        XCTAssertEqual(remainingFrame.sessionID, "session-a")
        XCTAssertEqual(remainingFrame.seq, 1)
    }

    func testConnectionDeinitFinishesSubscriberStreams() async throws {
        let record = try upsertClientRecord()
        var connection: RemoteHostConnection? = RemoteHostConnection(
            hostID: record.id,
            registry: registry,
            keyStore: keyStore
        )
        let inboundFrames = try await requiredInboundFramesStream(from: connection)
        let frameTask = nextFrameTask(from: inboundFrames, timeout: 1)

        connection = nil

        do {
            _ = try await frameTask.value
            XCTFail("Connection deinit should finish inbound subscriber streams")
        } catch RemoteClientError.connectionClosed {
            // Expected.
        } catch {
            throw error
        }
    }

    @MainActor
    func testManagerReusesSingleConnectionPerHost() throws {
        let record = try upsertClientRecord()
        let manager = RemoteHostConnectionManager(registry: registry, keyStore: keyStore)

        let first = try manager.connection(for: record.id)
        let second = try manager.connection(for: record.id)

        XCTAssertTrue(first === second)
    }

    func testCounterPersistenceCoalescesUntilFlush() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(
            hostID: record.id,
            registry: registry,
            keyStore: keyStore,
            counterWriteCoalescingDelay: 60
        )

        await connection.persistCounterForTesting(10)
        await connection.persistCounterForTesting(7)
        await connection.persistCounterForTesting(25)

        XCTAssertEqual(try registry.host(id: record.id)?.lastCounter, 0)
        await connection.flushPendingCounterForTesting()
        XCTAssertEqual(try registry.host(id: record.id)?.lastCounter, 25)
    }

    func testDisconnectFlushesPendingCounterWrite() async throws {
        let record = try upsertClientRecord()
        let connection = RemoteHostConnection(
            hostID: record.id,
            registry: registry,
            keyStore: keyStore,
            counterWriteCoalescingDelay: 60
        )

        await connection.persistCounterForTesting(33)
        await connection.disconnect()

        XCTAssertEqual(try registry.host(id: record.id)?.lastCounter, 33)
    }

    func testChannelClosingSchedulesSingleReconnectLoopForMultipleSubscriptions() async throws {
        let record = try upsertClientRecord()
        await enqueueTicket()
        let connection = RemoteHostConnection(
            hostID: record.id,
            registry: registry,
            keyStore: keyStore,
            initialReconnectBackoff: 60
        )

        try await connection.subscribe(sessionIDs: ["session-a", "session-b"])
        await connection.handleServerFrameForTesting(RemoteServerFrame(
            type: "channel_closing",
            payload: .object([
                "reason": .string("app_link_unavailable"),
                "message": .string("App link unavailable")
            ])
        ))
        await connection.handleServerFrameForTesting(RemoteServerFrame(
            type: "channel_closing",
            payload: .object([
                "reason": .string("app_link_unavailable"),
                "message": .string("App link unavailable")
            ])
        ))

        let reconnectScheduleCount = await connection.reconnectScheduleCountForTesting()
        let hasReconnectTask = await connection.hasReconnectTaskForTesting()
        XCTAssertEqual(reconnectScheduleCount, 1)
        XCTAssertTrue(hasReconnectTask)
        await connection.disconnect()
    }

    @discardableResult
    private func upsertClientRecord(
        scopes: Set<String> = [GatewayRemoteScope.sessionsObserve, GatewayRemoteScope.sessionsOperate]
    ) throws -> PairedHostRecord {
        let record = PairedHostRecord(
            id: GatewayAuthTestSupport.fingerprint(hostSigner.publicKey),
            displayName: "N3 Test Host",
            gatewayURL: URL(string: "http://127.0.0.1:\(port!)")!,
            hostPublicKey: hostSigner.publicKey.rawRepresentation,
            deviceID: device.deviceID,
            grantedScopes: scopes,
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try registry.upsertHost(record)
        try keyStore.save(device.signer, forHostID: record.id)
        return record
    }

    private actor SubscribeAttemptRecorder {
        private var attempts: [[String]] = []

        func record(_ sessionIDs: [String]) {
            attempts.append(sessionIDs)
        }

        func all() -> [[String]] {
            attempts
        }

        func count(of sessionIDs: [String]) -> Int {
            attempts.count { $0 == sessionIDs }
        }
    }

    private actor OneShotAsyncGate {
        private var didClaim = false

        func claim() -> Bool {
            guard !didClaim else { return false }
            didClaim = true
            return true
        }
    }

    private actor SubscribeAcceptanceSwitch {
        private var accepting = false

        func setAccepting(_ value: Bool) {
            accepting = value
        }

        func isAccepting() -> Bool {
            accepting
        }
    }

    @discardableResult
    private func enqueueTicket(
        _ existing: RemoteTicket? = nil,
        scopes: Set<String> = [GatewayRemoteScope.sessionsObserve, GatewayRemoteScope.sessionsOperate]
    ) async -> RemoteTicket {
        let ticket: RemoteTicket = if let existing {
            existing
        } else {
            try! GatewayAuthTestSupport.mintTicket(
                hostSigner: hostSigner,
                deviceID: device.deviceID,
                scopes: scopes
            )
        }
        await appConnection.enqueue(.result(GatewayTestHelpers.toolResult(json: .object([
            "ok": .bool(true),
            "ticket": ticket.jsonValue
        ]))))
        return ticket
    }

    private func requiredInboundFramesStream(
        from connection: RemoteHostConnection?
    ) async throws -> AsyncStream<RemoteServerFrame> {
        guard let connection else { throw RemoteClientError.connectionClosed }
        return await connection.inboundFramesStream()
    }

    private func waitForInboundSubscriberCount(
        _ expectedCount: Int,
        connection: RemoteHostConnection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if await connection.inboundSubscriberCountForTesting() == expectedCount {
                return
            }
            await Task.yield()
        }
        let actualCount = await connection.inboundSubscriberCountForTesting()
        XCTAssertEqual(actualCount, expectedCount, "Timed out waiting for inbound subscriber cleanup", file: file, line: line)
    }

    private func waitForStateSubscriberCount(
        _ expectedCount: Int,
        connection: RemoteHostConnection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if await connection.stateSubscriberCountForTesting() == expectedCount {
                return
            }
            await Task.yield()
        }
        let actualCount = await connection.stateSubscriberCountForTesting()
        XCTAssertEqual(actualCount, expectedCount, "Timed out waiting for state subscriber cleanup", file: file, line: line)
    }

    private func nextConnectedStateTask(
        from stream: AsyncStream<RemoteHostConnection.State>,
        timeout: TimeInterval
    ) -> Task<(initial: RemoteHostConnection.State?, connected: RemoteHostConnection.State), Error> {
        Task {
            try await withThrowingTaskGroup(
                of: (initial: RemoteHostConnection.State?, connected: RemoteHostConnection.State).self
            ) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    let initial = await iterator.next()
                    while let state = await iterator.next() {
                        if case .connected = state {
                            return (initial, state)
                        }
                    }
                    throw RemoteClientError.connectionClosed
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    throw RemoteClientError.timeout(operation: "connection state", seconds: timeout)
                }
                guard let first = try await group.next() else {
                    throw RemoteClientError.connectionClosed
                }
                group.cancelAll()
                return first
            }
        }
    }

    private func nextFrameTask(
        from stream: AsyncStream<RemoteServerFrame>,
        ofType type: String? = nil,
        timeout: TimeInterval
    ) -> Task<RemoteServerFrame, Error> {
        Task {
            try await withThrowingTaskGroup(of: RemoteServerFrame.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    while let frame = await iterator.next() {
                        if let type, frame.type != type {
                            continue
                        }
                        return frame
                    }
                    throw RemoteClientError.connectionClosed
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    throw RemoteClientError.timeout(operation: "inbound frame", seconds: timeout)
                }
                guard let first = try await group.next() else {
                    throw RemoteClientError.connectionClosed
                }
                group.cancelAll()
                return first
            }
        }
    }
}
