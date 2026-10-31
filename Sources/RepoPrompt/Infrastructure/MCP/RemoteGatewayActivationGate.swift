import Foundation

actor RemoteGatewayActivationGate {
    enum GateError: Error, Equatable {
        case staleGeneration
        case processNotCurrent
    }

    private let authority: RemotePairingDiscoveryAuthority
    private let authorityMutationLock = RemoteGatewayAuthorityMutationLock()
    private var generation: UInt64 = 0

    init(authority: RemotePairingDiscoveryAuthority) {
        self.authority = authority
    }

    func begin() async -> UInt64 {
        generation &+= 1
        let candidate = generation
        await authorityMutationLock.acquire()
        await authority.clear()
        await authorityMutationLock.release()
        return candidate
    }

    func ensureCurrent(_ candidate: UInt64) throws {
        guard candidate == generation else { throw GateError.staleGeneration }
    }

    func activate(
        _ configuration: RemotePairingDiscoveryAuthority.Configuration,
        generation candidate: UInt64,
        processIsCurrent: @escaping @Sendable () async -> Bool
    ) async throws {
        await authorityMutationLock.acquire()
        do {
            try ensureCurrent(candidate)
            guard await processIsCurrent() else { throw GateError.processNotCurrent }
            try ensureCurrent(candidate)
            await authority.configure(configuration)
            do {
                try ensureCurrent(candidate)
                guard await processIsCurrent() else { throw GateError.processNotCurrent }
                try ensureCurrent(candidate)
            } catch {
                await authority.clear(ifLaunchID: configuration.launchID)
                throw error
            }
            await authorityMutationLock.release()
        } catch {
            await authorityMutationLock.release()
            throw error
        }
    }

    @discardableResult
    func invalidate() async -> UInt64 {
        generation &+= 1
        let candidate = generation
        await authorityMutationLock.acquire()
        await authority.clear()
        await authorityMutationLock.release()
        return candidate
    }

    /// Invalidates only while `candidate` is current. Returns the invalidation generation
    /// (for fenced status publication) when it is still current afterwards, else nil.
    @discardableResult
    func invalidate(ifGeneration candidate: UInt64) async -> UInt64? {
        guard candidate == generation else { return nil }
        generation &+= 1
        let invalidationGeneration = generation
        await authorityMutationLock.acquire()
        await authority.clear()
        await authorityMutationLock.release()
        return invalidationGeneration == generation ? invalidationGeneration : nil
    }

    func currentGenerationForTesting() -> UInt64 {
        generation
    }
}

private actor RemoteGatewayAuthorityMutationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}
