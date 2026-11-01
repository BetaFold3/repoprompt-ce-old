import Foundation

/// The outcome of one serialized strict capability-1 trust refresh.
enum GatewayCapabilityTrustRefreshReceipt: Equatable {
    /// This freshly fetched snapshot was applied: the access authority's publication barriers settled,
    /// legacy consumers and connection cleanup completed, and an acknowledgement was ATTEMPTED. ACK
    /// success is not required; a failed ACK never undoes enforcement.
    case applied(GatewayCapabilityTrustSnapshot)
    /// The trust answer was invalid or its failure provenance was uncertain. Trust was invalidated,
    /// barriers settled, and every access-denied connection was closed. Nothing was acknowledged.
    case invalid
    /// A positively identified outage, timeout, or superseded call occurred. Authority state, grants,
    /// and deadlines were preserved unchanged; nothing was applied, created, or acknowledged.
    case transportFailure
}

/// The side effects one refresh performs, injected so the ordering contract is testable without a
/// network, an event loop, or the full gateway graph. Production uses `production(...)`.
struct GatewayTrustRefreshOperations {
    /// The single strict capability-1 fetch. Throws only on cancellation.
    var fetchTrust: @Sendable () async throws -> GatewayCapabilityTrustFetch
    /// Apply the strict snapshot to the access authority AND await every publication barrier.
    var applyAuthority: @Sendable (GatewayCapabilityTrustSnapshot) async -> Void
    /// Invalidate the access authority AND await every publication barrier.
    var invalidateAuthority: @Sendable () async -> Void
    /// Feed the legacy consumers (ticket admission, app-link pool, revocation teardown, push) with the
    /// same validated snapshot, projected to `GatewayTrustSnapshot`.
    var applyLegacySnapshot: @Sendable (GatewayTrustSnapshot) async -> Void
    /// Close every live connection the CURRENT authority denies (static while static access is not
    /// allowed; paired while trust is not valid or the device is absent/revoked). Required-policy
    /// paired connections that are merely locked stay open so they can unlock.
    var closeAccessDeniedConnections: @Sendable () async -> Void
    /// Acknowledge the exact applied revision. Returns whether the app accepted it.
    var acknowledge: @Sendable (GatewayCapabilityTrustSnapshot.Revision) async -> Bool

    static func production(
        relay: GatewayPasskeyRelay,
        authenticator: DeviceAuthenticator,
        applyLegacySnapshot: @escaping @Sendable (GatewayTrustSnapshot) async -> Void,
        closeAccessDeniedConnections: @escaping @Sendable () async -> Void
    ) -> GatewayTrustRefreshOperations {
        GatewayTrustRefreshOperations(
            fetchTrust: { try await relay.fetchCapabilityTrust() },
            applyAuthority: { snapshot in
                let barrier = await authenticator.applyCapabilityTrust(snapshot)
                await barrier.settle()
            },
            invalidateAuthority: {
                let barrier = await authenticator.invalidateTrust()
                await barrier.settle()
            },
            applyLegacySnapshot: applyLegacySnapshot,
            closeAccessDeniedConnections: closeAccessDeniedConnections,
            acknowledge: { revision in
                await relay.acknowledgeTrust(
                    launch: revision.launch,
                    revision: revision.revision,
                    issuance: revision.issuance
                )
            }
        )
    }
}

extension GatewayTrustSnapshot {
    /// Projects a validated strict snapshot onto the legacy shape consumed by ticket admission, the
    /// app-link pool, revocation teardown, and push cleanup. Never parsed leniently on its own.
    init(capabilityTrust snapshot: GatewayCapabilityTrustSnapshot) {
        var devices: [String: GatewayTrustedDevice] = [:]
        for (deviceID, device) in snapshot.devices {
            devices[deviceID] = GatewayTrustedDevice(
                deviceID: device.deviceID,
                displayName: device.displayName,
                publicKeyRawRepresentation: device.publicKeyRawRepresentation,
                isRevoked: device.isRevoked,
                counterFloor: device.counterFloor
            )
        }
        self.init(
            hostPublicKeyRawRepresentation: snapshot.hostPublicKeyRawRepresentation,
            hostFingerprint: snapshot.hostFingerprint,
            devices: devices
        )
    }
}

/// Serializes strict trust refreshes from the periodic poll, post-pairing, and passkey-ceremony
/// triggers. Fetch, authority apply/invalidate and barrier settlement, legacy consumers, connection
/// cleanup, and ACK all run in ONE slot, so an older poll can never publish or acknowledge after a
/// newer refresh. Cancellation or `stop()` before enforcement begins publishes nothing; once
/// enforcement begins it runs to completion (fail-closed), and the ACK is skipped if the refresh was
/// cancelled or stopped meanwhile.
actor GatewayTrustRefreshCoordinator {
    private let operations: GatewayTrustRefreshOperations
    private var refreshInProgress = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    #if DEBUG
        private var queueObservationWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    init(operations: GatewayTrustRefreshOperations) {
        self.operations = operations
    }

    @discardableResult
    func refresh() async throws -> GatewayCapabilityTrustRefreshReceipt {
        await acquireRefreshSlot()
        defer { releaseRefreshSlot() }

        try checkPublishable()
        let fetch = try await operations.fetchTrust()
        try checkPublishable()

        switch fetch {
        case .transportFailure:
            return .transportFailure
        case .invalid:
            await operations.invalidateAuthority()
            await operations.closeAccessDeniedConnections()
            return .invalid
        case let .valid(snapshot):
            await operations.applyAuthority(snapshot)
            await operations.applyLegacySnapshot(GatewayTrustSnapshot(capabilityTrust: snapshot))
            await operations.closeAccessDeniedConnections()
            try checkPublishable()
            _ = await operations.acknowledge(snapshot.trustRevision)
            return .applied(snapshot)
        }
    }

    /// Prevents queued or in-flight refreshes from publishing after gateway termination. In-flight
    /// app-link calls are left to normal app-link shutdown rather than delaying process teardown.
    func stop() {
        stopped = true
        refreshInProgress = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        #if DEBUG
            let observationWaiters = queueObservationWaiters
            queueObservationWaiters.removeAll()
            observationWaiters.forEach { $0.resume() }
        #endif
    }

    #if DEBUG
        func waitUntilRefreshIsQueuedForTesting() async {
            if !waiters.isEmpty || stopped { return }
            await withCheckedContinuation { queueObservationWaiters.append($0) }
        }
    #endif

    private func checkPublishable() throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
    }

    private func acquireRefreshSlot() async {
        guard !stopped else { return }
        if !refreshInProgress {
            refreshInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            #if DEBUG
                queueObservationWaiters.forEach { $0.resume() }
                queueObservationWaiters.removeAll()
            #endif
        }
    }

    private func releaseRefreshSlot() {
        guard !stopped else {
            refreshInProgress = false
            return
        }
        if waiters.isEmpty {
            refreshInProgress = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Actor wrapper for the stateful revocation transition tracker used by the
/// sendable trust-application closure in gateway startup wiring.
actor GatewayRevokedDeviceTransitionState {
    private var tracker = GatewayRevokedDeviceTransitionTracker()

    func devicesRequiringTeardown(
        revoked: Set<String>,
        tornDown: Set<String>,
        snapshot: GatewayTrustSnapshot
    ) -> [String] {
        tracker.devicesRequiringTeardown(revoked: revoked, tornDown: tornDown, snapshot: snapshot)
    }
}
