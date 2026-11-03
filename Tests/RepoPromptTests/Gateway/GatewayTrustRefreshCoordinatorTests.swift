import Foundation
@testable import RepoPromptGateway
import XCTest

final class GatewayTrustRefreshCoordinatorTests: XCTestCase {
    func testRefreshesSerializeFetchApplyCleanupAndAckWithoutStaleOverwrite() async throws {
        let firstFetchGate = TrustRefreshTestGate()
        let probe = TrustRefreshProbe(fetchGates: [1: firstFetchGate])
        let coordinator = GatewayTrustRefreshCoordinator(operations: probe.operations())

        let first = Task { try await coordinator.refresh() }
        await firstFetchGate.waitUntilArrived()
        let second = Task { try await coordinator.refresh() }
        await coordinator.waitUntilRefreshIsQueuedForTesting()

        let eventsWhileBlocked = await probe.events
        XCTAssertEqual(eventsWhileBlocked, [.fetch(1)], "A second refresh must not overlap an older one")
        await firstFetchGate.open()
        let firstReceipt = try await first.value
        let secondReceipt = try await second.value

        XCTAssertEqual(firstReceipt, .applied(TrustRefreshProbe.snapshot(1)))
        XCTAssertEqual(secondReceipt, .applied(TrustRefreshProbe.snapshot(2)))
        let maximumConcurrentFetches = await probe.maximumConcurrentFetches
        XCTAssertEqual(maximumConcurrentFetches, 1)
        // The newer fetch starts only after the older refresh fully enforced AND acknowledged.
        let events = await probe.events
        XCTAssertEqual(events, [
            .fetch(1), .applyAuthority(1), .legacy("host-1"), .closeDenied, .ack(TrustRefreshProbe.revision(1)),
            .fetch(2), .applyAuthority(2), .legacy("host-2"), .closeDenied, .ack(TrustRefreshProbe.revision(2))
        ])
    }

    func testStopReleasesQueuedRefreshesWithoutPublishing() async throws {
        let firstFetchGate = TrustRefreshTestGate()
        let probe = TrustRefreshProbe(fetchGates: [1: firstFetchGate])
        let coordinator = GatewayTrustRefreshCoordinator(operations: probe.operations())

        let first = Task { try await coordinator.refresh() }
        await firstFetchGate.waitUntilArrived()
        let second = Task { try await coordinator.refresh() }
        await coordinator.waitUntilRefreshIsQueuedForTesting()
        await coordinator.stop()
        await firstFetchGate.open()

        do {
            _ = try await first.value
            XCTFail("An in-flight refresh must not publish after stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            _ = try await second.value
            XCTFail("A queued refresh must not run after stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let events = await probe.events
        XCTAssertEqual(events, [.fetch(1)], "Stop before enforcement must not apply, clean up, or ACK")
    }

    func testCancellationDuringFetchPublishesNothing() async throws {
        let fetchGate = TrustRefreshTestGate()
        let probe = TrustRefreshProbe(fetchGates: [1: fetchGate])
        let coordinator = GatewayTrustRefreshCoordinator(operations: probe.operations())

        let refresh = Task { try await coordinator.refresh() }
        await fetchGate.waitUntilArrived()
        refresh.cancel()
        await fetchGate.open()

        do {
            _ = try await refresh.value
            XCTFail("A cancelled refresh must not publish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let events = await probe.events
        XCTAssertEqual(events, [.fetch(1)])
    }

    func testAuthoritativeInvalidInvalidatesAwaitsBarrierAndClosesWithoutAck() async throws {
        let invalidateGate = TrustRefreshTestGate()
        let probe = TrustRefreshProbe(outcomes: [1: .invalid], invalidateGate: invalidateGate)
        let coordinator = GatewayTrustRefreshCoordinator(operations: probe.operations())

        let refresh = Task { try await coordinator.refresh() }
        await invalidateGate.waitUntilArrived()
        let eventsBeforeBarrier = await probe.events
        XCTAssertEqual(eventsBeforeBarrier, [.fetch(1)], "Connections must not close before the invalidation barrier settles")
        await invalidateGate.open()

        let receipt = try await refresh.value
        XCTAssertEqual(receipt, .invalid)
        let events = await probe.events
        XCTAssertEqual(events, [.fetch(1), .invalidateAuthority, .closeDenied])
    }

    func testTransportFailurePreservesAuthorityAndNeverAcknowledges() async throws {
        let probe = TrustRefreshProbe(outcomes: [2: .transportFailure])
        let coordinator = GatewayTrustRefreshCoordinator(operations: probe.operations())

        let applied = try await coordinator.refresh()
        XCTAssertEqual(applied, .applied(TrustRefreshProbe.snapshot(1)))
        let outage = try await coordinator.refresh()
        XCTAssertEqual(outage, .transportFailure)

        let events = await probe.events
        XCTAssertEqual(events, [
            .fetch(1), .applyAuthority(1), .legacy("host-1"), .closeDenied, .ack(TrustRefreshProbe.revision(1)),
            .fetch(2)
        ], "An outage must not apply, invalidate, close, or acknowledge anything")
    }

    func testAckWaitsForAuthorityBarrierLegacyConsumersAndCleanup() async throws {
        let authorityGate = TrustRefreshTestGate()
        let probe = TrustRefreshProbe(authorityGate: authorityGate)
        let coordinator = GatewayTrustRefreshCoordinator(operations: probe.operations())

        let refresh = Task { try await coordinator.refresh() }
        await authorityGate.waitUntilArrived()
        let eventsBeforeBarrier = await probe.events
        XCTAssertEqual(eventsBeforeBarrier, [.fetch(1)], "Nothing may follow the authority apply until its barrier settles")
        await authorityGate.open()

        let receipt = try await refresh.value
        XCTAssertEqual(receipt, .applied(TrustRefreshProbe.snapshot(1)))
        let events = await probe.events
        XCTAssertEqual(events, [
            .fetch(1), .applyAuthority(1), .legacy("host-1"), .closeDenied, .ack(TrustRefreshProbe.revision(1))
        ])
    }

    func testAckFailureDoesNotUndoEnforcement() async throws {
        let probe = TrustRefreshProbe(ackResult: false)
        let coordinator = GatewayTrustRefreshCoordinator(operations: probe.operations())

        let receipt = try await coordinator.refresh()

        XCTAssertEqual(receipt, .applied(TrustRefreshProbe.snapshot(1)), "Applied means an ACK was attempted, not accepted")
        let events = await probe.events
        XCTAssertEqual(events, [
            .fetch(1), .applyAuthority(1), .legacy("host-1"), .closeDenied, .ack(TrustRefreshProbe.revision(1))
        ])
    }

    func testStopDuringEnforcementCompletesCleanupButSkipsAck() async throws {
        let authorityGate = TrustRefreshTestGate()
        let probe = TrustRefreshProbe(authorityGate: authorityGate)
        let coordinator = GatewayTrustRefreshCoordinator(operations: probe.operations())

        let refresh = Task { try await coordinator.refresh() }
        await authorityGate.waitUntilArrived()
        await coordinator.stop()
        await authorityGate.open()

        do {
            _ = try await refresh.value
            XCTFail("A refresh stopped mid-enforcement must not report an ACK attempt")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let events = await probe.events
        XCTAssertEqual(events, [.fetch(1), .applyAuthority(1), .legacy("host-1"), .closeDenied])
    }

    func testLegacyProjectionCarriesTheSameValidatedDevices() {
        let policy = GatewayDevicePasskeyPolicy(
            version: 1,
            state: .required,
            enrolled: true,
            epoch: 4,
            enrollmentOpen: false,
            needsReenrollment: false
        )
        let device = GatewayCapabilityTrustedDevice(
            deviceID: "device-a",
            displayName: "Phone",
            publicKeyRawRepresentation: Data([9, 8, 7]),
            counterFloor: 42,
            isRevoked: true,
            scopes: ["sessions.read"],
            policy: policy
        )
        let snapshot = GatewayCapabilityTrustSnapshot(
            hostPublicKeyRawRepresentation: Data([1, 2, 3]),
            hostFingerprint: "host-fp",
            trustRevision: TrustRefreshProbe.revision(7),
            authoritativeOrigin: nil,
            originRevision: 3,
            devices: ["device-a": device]
        )

        let legacy = GatewayTrustSnapshot(capabilityTrust: snapshot)

        XCTAssertEqual(legacy, GatewayTrustSnapshot(
            hostPublicKeyRawRepresentation: Data([1, 2, 3]),
            hostFingerprint: "host-fp",
            devices: ["device-a": GatewayTrustedDevice(
                deviceID: "device-a",
                displayName: "Phone",
                publicKeyRawRepresentation: Data([9, 8, 7]),
                isRevoked: true,
                counterFloor: 42
            )]
        ))
    }
}

/// A one-shot gate: callers `pass()` and suspend until `open()`. `waitUntilArrived()` observes the
/// first arrival deterministically, so tests never sleep.
private actor TrustRefreshTestGate {
    private var isOpen = false
    private var arrived = false
    private var passWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { passWaiters.append($0) }
    }

    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        passWaiters.forEach { $0.resume() }
        passWaiters.removeAll()
    }
}

private actor TrustRefreshProbe {
    enum Event: Equatable {
        case fetch(Int)
        case applyAuthority(UInt64)
        case invalidateAuthority
        case legacy(String)
        case closeDenied
        case ack(GatewayCapabilityTrustSnapshot.Revision)
    }

    private(set) var events: [Event] = []
    private(set) var maximumConcurrentFetches = 0
    private var concurrentFetches = 0
    private var fetchCount = 0
    private let outcomes: [Int: GatewayCapabilityTrustFetch]
    private let fetchGates: [Int: TrustRefreshTestGate]
    private let authorityGate: TrustRefreshTestGate?
    private let invalidateGate: TrustRefreshTestGate?
    private let ackResult: Bool

    init(
        outcomes: [Int: GatewayCapabilityTrustFetch] = [:],
        fetchGates: [Int: TrustRefreshTestGate] = [:],
        authorityGate: TrustRefreshTestGate? = nil,
        invalidateGate: TrustRefreshTestGate? = nil,
        ackResult: Bool = true
    ) {
        self.outcomes = outcomes
        self.fetchGates = fetchGates
        self.authorityGate = authorityGate
        self.invalidateGate = invalidateGate
        self.ackResult = ackResult
    }

    static func revision(_ ordinal: UInt64) -> GatewayCapabilityTrustSnapshot.Revision {
        GatewayCapabilityTrustSnapshot.Revision(launch: "launch-a", revision: ordinal, issuance: "issuance-\(ordinal)")
    }

    static func snapshot(_ ordinal: Int) -> GatewayCapabilityTrustSnapshot {
        GatewayCapabilityTrustSnapshot(
            hostPublicKeyRawRepresentation: Data([1]),
            hostFingerprint: "host-\(ordinal)",
            trustRevision: revision(UInt64(ordinal)),
            authoritativeOrigin: nil,
            originRevision: 0,
            devices: [:]
        )
    }

    nonisolated func operations() -> GatewayTrustRefreshOperations {
        GatewayTrustRefreshOperations(
            fetchTrust: { await self.fetch() },
            applyAuthority: { snapshot in await self.applyAuthority(snapshot) },
            invalidateAuthority: { await self.invalidateAuthority() },
            applyLegacySnapshot: { snapshot in await self.record(.legacy(snapshot.hostFingerprint)) },
            closeAccessDeniedConnections: { await self.record(.closeDenied) },
            acknowledge: { revision in await self.acknowledge(revision) }
        )
    }

    private func fetch() async -> GatewayCapabilityTrustFetch {
        fetchCount += 1
        let ordinal = fetchCount
        events.append(.fetch(ordinal))
        concurrentFetches += 1
        maximumConcurrentFetches = max(maximumConcurrentFetches, concurrentFetches)
        if let gate = fetchGates[ordinal] {
            await gate.pass()
        }
        concurrentFetches -= 1
        return outcomes[ordinal] ?? .valid(Self.snapshot(ordinal))
    }

    private func applyAuthority(_ snapshot: GatewayCapabilityTrustSnapshot) async {
        // Models `applyCapabilityTrust` + `settle()`: the event is recorded only once the barrier passes.
        if let authorityGate {
            await authorityGate.pass()
        }
        events.append(.applyAuthority(snapshot.trustRevision.revision))
    }

    private func invalidateAuthority() async {
        if let invalidateGate {
            await invalidateGate.pass()
        }
        events.append(.invalidateAuthority)
    }

    private func acknowledge(_ revision: GatewayCapabilityTrustSnapshot.Revision) -> Bool {
        events.append(.ack(revision))
        return ackResult
    }

    private func record(_ event: Event) {
        events.append(event)
    }
}
