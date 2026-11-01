import Foundation
import Logging
import RepoPromptAgentCore
import RepoPromptRemoteWire

private let gatewayLaunchLog = Logger(label: "com.repoprompt.mcp.gateway.launch")

struct RemoteGatewayLaunchConfiguration: Equatable {
    let bindHost: String
    let port: Int
    let appSupportRoot: String
    /// The browser HTTPS origin served by the owner's `tailscale serve` listener, or nil. The
    /// gateway also accepts its authority as a request Host. A change relaunches the gateway.
    var browserOrigin: RemoteGatewayOrigin?
    /// The passkey policy version the launched gateway MUST understand, or nil when no device
    /// requires a passkey (remote passkey unlock, Step 2 — decision 8). When non-nil, the app
    /// passes `--passkey-policy-version=<v>` to the gateway. A gateway that does not recognize the
    /// flag refuses to start (fail-closed), so an incompatible gateway can never serve a registry
    /// with a required policy. This is part of `Equatable`, so a change in required-ness retires a
    /// running process before a replacement starts.
    var requiredPasskeyPolicyVersion: Int?

    /// CLI arguments passed to the gateway process. Empty unless a passkey policy is required.
    var gatewayProcessArguments: [String] {
        guard let version = requiredPasskeyPolicyVersion else { return [] }
        return ["--passkey-policy-version=\(version)"]
    }

    static func production(
        bindHost: String,
        browserOrigin: RemoteGatewayOrigin? = nil,
        buildIdentity: RemoteControlBuildIdentity = .current,
        requiredPasskeyPolicyVersion: Int? = nil
    ) -> Self {
        .init(
            bindHost: bindHost,
            port: buildIdentity.fixedPort,
            appSupportRoot: RemoteControlStorageNamespace.gatewayRuntimeRootURL().path,
            browserOrigin: browserOrigin,
            requiredPasskeyPolicyVersion: requiredPasskeyPolicyVersion
        )
    }

    /// Derive the required passkey policy version from the authoritative paired-device registry.
    /// An unreadable or invalid registry MUST NOT be treated as "no policy": it fails closed to
    /// version 1 so a corrupt or fenced registry cannot silently drop enforcement.
    static func resolveRequiredPasskeyPolicyVersion(
        store: RemotePairingIdentityStore = .shared
    ) -> Int? {
        do {
            let registry = try store.registry()
            return registry.devices.contains { $0.passkey.isRequired } ? 1 : nil
        } catch {
            // Fail closed: an unreadable/fenced/invalid registry may hold a required policy, so the
            // gateway must still be launched with the policy flag. Log the source error so the
            // fail-closed decision is diagnosable rather than silent (it is NOT proof that a policy
            // is actually required).
            gatewayLaunchLog.error("resolveRequiredPasskeyPolicyVersion: registry read failed, failing closed to version 1: \(String(describing: error))")
            return 1
        }
    }
}

/// The paired-browser HTTPS origin: `https://<Self DNS name>:<browser HTTPS port>`, reached
/// through a `tailscale serve` listener the owner runs (the app never configures Tailscale).
enum RemoteGatewayBrowserOrigin {
    /// Nil unless both the Tailscale DNS name and a valid port (not 443) are known.
    static func derive(selfDNSName: String?, port: Int?) -> RemoteGatewayOrigin? {
        guard let selfDNSName, !selfDNSName.isEmpty, let port,
              GlobalScalarPreferences.MCPSettings.isValidBrowserHTTPSPort(port),
              let origin = try? RemoteGatewayOrigin(string: "https://\(selfDNSName):\(port)"),
              origin.scheme == "https", origin.port == port
        else { return nil }
        return origin
    }

    /// The exact Serve command that forwards `browserPort` to this build's gateway port on
    /// `127.0.0.1`. Serve dials its backend outside the tailnet, so it targets the loopback
    /// companion listener the gateway adds while a browser origin is set, not the direct tailnet
    /// address (which stays the paired apps' origin).
    static func serveCommand(browserPort: Int, gatewayOrigin: RemoteGatewayOrigin) -> String {
        "tailscale serve --bg --https=\(browserPort) http://127.0.0.1:\(gatewayOrigin.port)"
    }
}

struct RemoteGatewayProcessIdentity: Equatable, Hashable {
    let token: UUID
    let pid: Int32
}

final class RemoteGatewayProcessHandle: @unchecked Sendable {
    let identity: RemoteGatewayProcessIdentity
    private let running: () -> Bool
    private let terminateProcess: () -> Void

    init(
        identity: RemoteGatewayProcessIdentity,
        isRunning: @escaping () -> Bool,
        terminate: @escaping () -> Void
    ) {
        self.identity = identity
        running = isRunning
        terminateProcess = terminate
    }

    var isRunning: Bool {
        running()
    }

    func terminate() {
        terminateProcess()
    }
}

actor RemoteGatewayProcessLifecycle {
    enum LifecycleError: Error, Equatable {
        case staleGeneration
    }

    struct Dependencies: @unchecked Sendable {
        let generateCredential: () throws -> String
        let setCredential: (String?) async -> Void
        let findOrphan: (RemoteGatewayLaunchConfiguration) -> Int32?
        let launch: (
            RemoteGatewayLaunchConfiguration,
            String,
            UUID,
            @escaping @Sendable (RemoteGatewayProcessIdentity) -> Void
        ) throws -> RemoteGatewayProcessHandle
        let terminateOrphan: (Int32) -> Void
        let forceKill: (Int32) -> Void
        let isProcessRunning: (Int32) -> Bool
        let removeLease: (RemoteGatewayLaunchConfiguration, Int32) -> Void
        let waitForTermination: () async -> Void
        let now: () -> Date
    }

    struct Termination: Equatable {
        let generation: UInt64
        let launchedAt: Date
    }

    struct Snapshot: Equatable {
        let generation: UInt64
        let processIdentity: RemoteGatewayProcessIdentity?
        let processConfiguration: RemoteGatewayLaunchConfiguration?
        let processGeneration: UInt64?
        let credentialGeneration: UInt64?
    }

    private let dependencies: Dependencies
    private let mutationLock = RemoteGatewayLifecycleMutationLock()
    private var generation: UInt64 = 0
    private var process: RemoteGatewayProcessHandle?
    private var processConfiguration: RemoteGatewayLaunchConfiguration?
    private var processGeneration: UInt64?
    private var credentialGeneration: UInt64?
    private var launchedAt: Date?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func selectGeneration(_ candidate: UInt64) {
        generation = max(generation, candidate)
    }

    func startIfNeeded(
        _ configuration: RemoteGatewayLaunchConfiguration,
        generation candidate: UInt64,
        didTerminate: @escaping @Sendable (RemoteGatewayProcessIdentity) -> Void
    ) async throws -> RemoteGatewayProcessIdentity {
        await mutationLock.acquire()
        do {
            let identity = try await performStartIfNeeded(
                configuration,
                generation: candidate,
                didTerminate: didTerminate
            )
            await mutationLock.release()
            return identity
        } catch {
            await mutationLock.release()
            throw error
        }
    }

    func stop(generation candidate: UInt64) async throws {
        await mutationLock.acquire()
        do {
            try ensureCurrent(candidate)
            try await stopSelectedProcess(generation: candidate)
            await mutationLock.release()
        } catch {
            await mutationLock.release()
            throw error
        }
    }

    func didTerminate(_ identity: RemoteGatewayProcessIdentity) async -> Termination? {
        await mutationLock.acquire()
        guard process?.identity == identity,
              let ownerGeneration = processGeneration,
              let processLaunchDate = launchedAt
        else {
            await mutationLock.release()
            return nil
        }

        process = nil
        processConfiguration = nil
        processGeneration = nil
        launchedAt = nil
        if credentialGeneration == ownerGeneration {
            credentialGeneration = nil
            await dependencies.setCredential(nil)
        }
        let isCurrent = ownerGeneration == generation
        await mutationLock.release()
        guard isCurrent else { return nil }
        return Termination(generation: ownerGeneration, launchedAt: processLaunchDate)
    }

    func isCurrent(
        _ identity: RemoteGatewayProcessIdentity,
        configuration: RemoteGatewayLaunchConfiguration,
        generation candidate: UInt64
    ) -> Bool {
        candidate == generation
            && process?.identity == identity
            && process?.isRunning == true
            && processConfiguration == configuration
            && processGeneration == candidate
    }

    func snapshotForTesting() -> Snapshot {
        Snapshot(
            generation: generation,
            processIdentity: process?.identity,
            processConfiguration: processConfiguration,
            processGeneration: processGeneration,
            credentialGeneration: credentialGeneration
        )
    }

    private func performStartIfNeeded(
        _ configuration: RemoteGatewayLaunchConfiguration,
        generation candidate: UInt64,
        didTerminate: @escaping @Sendable (RemoteGatewayProcessIdentity) -> Void
    ) async throws -> RemoteGatewayProcessIdentity {
        try ensureCurrent(candidate)
        if let process,
           process.isRunning,
           processConfiguration == configuration
        {
            processGeneration = candidate
            if credentialGeneration != nil {
                credentialGeneration = candidate
            }
            return process.identity
        }

        try await stopSelectedProcess(generation: candidate)
        try ensureCurrent(candidate)

        if let orphanPID = dependencies.findOrphan(configuration) {
            dependencies.terminateOrphan(orphanPID)
            await dependencies.waitForTermination()
            if dependencies.isProcessRunning(orphanPID) {
                dependencies.forceKill(orphanPID)
            }
            dependencies.removeLease(configuration, orphanPID)
            try ensureCurrent(candidate)
        }

        try ensureCurrent(candidate)
        let credential = try dependencies.generateCredential()
        credentialGeneration = candidate
        await dependencies.setCredential(credential)
        do {
            try ensureCurrent(candidate)
        } catch {
            await clearCredential(ifOwnedBy: candidate)
            throw error
        }

        let token = UUID()
        do {
            try ensureCurrent(candidate)
            let launchedProcess = try dependencies.launch(
                configuration,
                credential,
                token,
                didTerminate
            )
            process = launchedProcess
            processConfiguration = configuration
            processGeneration = candidate
            launchedAt = dependencies.now()
            return launchedProcess.identity
        } catch {
            await clearCredential(ifOwnedBy: candidate)
            throw error
        }
    }

    private func stopSelectedProcess(generation candidate: UInt64) async throws {
        try ensureCurrent(candidate)
        let selectedProcess = process
        let selectedConfiguration = processConfiguration
        process = nil
        processConfiguration = nil
        processGeneration = nil
        launchedAt = nil
        selectedProcess?.terminate()

        if credentialGeneration != nil {
            credentialGeneration = nil
            await dependencies.setCredential(nil)
        }

        guard let selectedProcess else {
            try ensureCurrent(candidate)
            return
        }
        if selectedProcess.isRunning {
            await dependencies.waitForTermination()
        }
        if selectedProcess.isRunning {
            dependencies.forceKill(selectedProcess.identity.pid)
        }
        if let selectedConfiguration {
            dependencies.removeLease(selectedConfiguration, selectedProcess.identity.pid)
        }
        try ensureCurrent(candidate)
    }

    private func clearCredential(ifOwnedBy candidate: UInt64) async {
        guard credentialGeneration == candidate else { return }
        credentialGeneration = nil
        await dependencies.setCredential(nil)
    }

    private func ensureCurrent(_ candidate: UInt64) throws {
        guard candidate == generation else {
            throw LifecycleError.staleGeneration
        }
    }
}

private actor RemoteGatewayLifecycleMutationLock {
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
