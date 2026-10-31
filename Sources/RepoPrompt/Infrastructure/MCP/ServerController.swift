//
//  ServerController.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//

import AppKit
import Darwin
import Foundation
import Logging
import OSLog
import RepoPromptAgentCore
import RepoPromptRemoteWire
import RepoPromptShared
import SwiftUI

#if DEBUG
    private var serverControllerDebugLoggingEnabled = false
    private func serverControllerDebugLog(_ message: @autoclosure () -> String) {
        guard serverControllerDebugLoggingEnabled else { return }
        print("[ServerController] \(message())")
    }
#else
    private func serverControllerDebugLog(_ message: @autoclosure () -> String) {}
#endif

private let log = Logger(label: "com.repoprompt.mcp.servercontroller")

/// ---------------------------------------------------------------------
///  SwiftUI facing controller – own instance lives at the app level
/// ---------------------------------------------------------------------
/// Controller visible from SwiftUI
final actor ServerController: ObservableObject {
    /// ──────────  Singleton  ──────────
    static let shared = ServerController()

    // –––––  Internal state (no longer @Published since we're not on @MainActor)  –––––
    private var serverStatus: String = "Starting…"
    private var pendingConnectionID: String?
    weak var mcpService: MCPService?

    /// ──────────  NEW: persistent allow-list of client IDs  ──────────
    private static let alwaysAllowedKey = "mcp.alwaysAllowedClients"
    /// Built-in always-allowed clients (do not require manual approval).
    ///
    /// RepoPrompt CLI client names are intentionally excluded: those names are
    /// spoofable via MCP initialize metadata and must be verified by bundled
    /// executable path before auto-approval.
    private static let defaultAlwaysAllowedClients: Set<String> = [
        "claude-code",
        "codex-mcp-client",
        "gemini-cli-mcp-client",
        "opencode",
        "cursor",
        "cursor-mcp-client",
        "claude-ai"
    ]
    /// In-memory copy (always mutate on MainActor)
    private var alwaysAllowedClients: Set<String> = ServerController.loadSanitizedAlwaysAllowedClients()

    // –––––  Private implementation helpers  –––––
    private let networkManager = ServerNetworkManager.shared
    private var activeApprovalDialogs: Set<String> = []
    private var pendingApprovals: [(String, () -> Void, () -> Void)] = []

    // –––––  Injected callbacks for approval flow  –––––
    nonisolated(unsafe) var onApprovalRequest: ((String) async -> Void)?
    nonisolated(unsafe) var onApprovalResolved: ((Bool) -> Void)?

    /// Activity token used to disable App Nap while the server runs.
    private var powerActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private var remoteGatewayRestartAttempts = 0
    private let remoteGatewayActivationGate: RemoteGatewayActivationGate
    private let remoteGatewayProcessLifecycle: RemoteGatewayProcessLifecycle
    private let tailscaleStatusProvider: any TailscaleStatusProviding
    private let remoteGatewayHealthClient: RemoteHostHTTPClient
    private let discoveryAuthority: RemotePairingDiscoveryAuthority
    private static let remoteGatewayMaxRestartAttempts = 6
    private static let remoteGatewayStableUptimeSeconds: TimeInterval = 60
    static let remoteGatewayStoppedWithServerReason = "Stopped with the MCP server."

    /// Set the approval callback
    func setApprovalCallback(_ callback: @escaping (String) async -> Void) {
        onApprovalRequest = callback
    }

    func setMCPService(_ service: MCPService?) {
        mcpService = service
    }

    /// –––––  Init: wire approval-flow & kick off the listener  –––––
    init(
        tailscaleStatusProvider: any TailscaleStatusProviding = TailscaleStatusClient(),
        remoteGatewayHealthClient: RemoteHostHTTPClient = .shared,
        discoveryAuthority: RemotePairingDiscoveryAuthority = .shared
    ) {
        self.tailscaleStatusProvider = tailscaleStatusProvider
        self.remoteGatewayHealthClient = remoteGatewayHealthClient
        self.discoveryAuthority = discoveryAuthority
        remoteGatewayActivationGate = RemoteGatewayActivationGate(authority: discoveryAuthority)
        remoteGatewayProcessLifecycle = RemoteGatewayProcessLifecycle(
            dependencies: Self.remoteGatewayProcessDependencies(networkManager: ServerNetworkManager.shared)
        )
        Task { [weak self] in
            await self?.bootstrapCallbacks()
        }
    }

    private func bootstrapCallbacks() async {
        // Wire up dashboard update callback to notify MCPService
        await ServerNetworkManager.shared.setOnDashboardUpdate { [weak self] in
            guard let self else { return }
            Task {
                guard let service = await self.mcpService else { return }
                await service.notifyDashboardUpdate()
            }
        }

        // Wire up identity escalation callback
        await ServerNetworkManager.shared.setOnIdentityEscalation { [weak self] reason in
            guard let self else { return }
            Task {
                guard let service = await self.mcpService else { return }
                let diag = MCPDiagnostics(
                    issue: .identityRecoveryDegraded(message: reason),
                    lastEventAt: Date(),
                    listenerStateDescription: "Bootstrap socket connection issue"
                )
                await service.updateDiagnostics(diag)
            }
        }

        // Set up approval handler
        await networkManager.setConnectionApprovalHandler { [weak self]
            connectionID, client in
                guard let self else { return false }

                serverControllerDebugLog("Approval handler called for client: '\(client.name)' connectionID: \(connectionID)")

                // Reserve a slot BEFORE any UI to avoid stampedes
                guard await networkManager.tryReserveConnectionSlot(
                    connectionID: connectionID, clientID: client.name
                ) else {
                    log.warning("Failed to reserve connection slot for '\(client.name)'")
                    return false
                }

                let route = await Self.connectionApprovalRoute(
                    clientName: client.name,
                    autoApproveAllClients: autoApproveAllClients,
                    // The app-spawned gateway (and every per-device `remote:<device8>` app
                    // link it carries) is trusted only through the bootstrap principal
                    // established by a launch-scoped environment credential. Pairing
                    // consent is the authorization event; never trust the client-asserted
                    // name alone and never prompt per connection or reconnect.
                    isGatewayPrincipal: networkManager.isGatewayPrincipalConnection(connectionID),
                    isVerifiedBundledRepoPromptCLI: {
                        await self.isBundledRepoPromptCLIConnection(connectionID: connectionID)
                    },
                    isAllowListed: {
                        await self.isClientAlwaysAllowed(clientID: client.name)
                    }
                )

                switch route {
                case .autoApproveAllClients:
                    serverControllerDebugLog("Auto-approving '\(client.name)' (global auto-approve enabled)")
                    if let service = await mcpService {
                        await service.clientConnectedSuccessfully(name: client.name)
                    }
                    return true
                case .autoApproveGatewayPrincipal:
                    serverControllerDebugLog("Auto-approving '\(client.name)' (verified gateway principal)")
                    if let service = await mcpService {
                        await service.clientConnectedSuccessfully(name: client.name)
                    }
                    return true
                case .autoApproveVerifiedRepoPromptCLI:
                    serverControllerDebugLog("Auto-approving '\(client.name)' (RepoPrompt bundled CLI verified)")
                    if let service = await mcpService {
                        await service.clientConnectedSuccessfully(name: client.name)
                    }
                    return true
                case .autoApproveAllowListed:
                    serverControllerDebugLog("Auto-approving '\(client.name)' (in allow-list)")
                    if let service = await mcpService {
                        await service.clientConnectedSuccessfully(name: client.name)
                    }
                    return true
                case .promptUserUnverifiedRepoPromptCLI:
                    log.warning("RepoPrompt CLI name matched but executable path verification failed for connectionID=\(connectionID)")
                case .promptUser:
                    break
                }

                // Otherwise request approval through the callback
                let approved = await withCheckedContinuation { c in
                    Task {
                        await self.requestApproval(
                            clientID: client.name,
                            approve: { c.resume(returning: true) },
                            deny: { c.resume(returning: false) }
                        )
                    }
                }
                if !approved {
                    await networkManager.terminateConnection(
                        connectionID,
                        reason: .approvalDenied,
                        message: "Denied by user"
                    )
                } else {
                    // Client manually approved - clear any previous errors for this client
                    if let service = await mcpService {
                        await service.clientConnectedSuccessfully(name: client.name)
                    }
                }
                return approved
        }

        await applyRemoteGatewaySettings()

        // Register wake observer if not already registered
        guard wakeObserver == nil else { return }
        let networkMgr = networkManager
        let observer = await MainActor.run {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                Task {
                    await networkMgr.ensureBootstrapHealthy(force: true)
                }
            }
        }
        wakeObserver = observer
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: – Allow-list helpers –

    /// Checks if a client is in the always-allowed list.
    ///
    /// Supports both exact matches and prefix matches. Prefix matching allows entries
    /// like "gemini-cli" to match "gemini-cli-mcp-client" or versioned variants.
    ///
    /// NOTE: Prefix matching broadens what gets auto-approved. Consider making this
    /// opt-in per entry if stricter control is needed in the future.
    private func isClientAlwaysAllowed(clientID: String) -> Bool {
        if isDefaultAlwaysAllowed(clientID) {
            return true
        }
        if alwaysAllowedClients.contains(where: { MCPClientIdentity.matches($0, clientID) }) {
            return true
        }
        return false
    }

    private func isDefaultAlwaysAllowed(_ clientID: String) -> Bool {
        Self.isBuiltInAlwaysAllowedClient(clientID)
    }

    /// Whether the client name (or a same-family variant) is one of the built-in
    /// always-trusted defaults, which cannot be removed from the allow-list.
    static func isBuiltInAlwaysAllowedClient(_ clientID: String) -> Bool {
        defaultAlwaysAllowedClients.contains(where: { MCPClientIdentity.matches($0, clientID) })
    }

    private static func loadSanitizedAlwaysAllowedClients() -> Set<String> {
        let saved = UserDefaults.standard.stringArray(forKey: alwaysAllowedKey) ?? []
        let sanitizedSaved = sanitizedAlwaysAllowedClients(Set(saved))
        if Set(saved) != sanitizedSaved {
            UserDefaults.standard.set(Array(sanitizedSaved), forKey: alwaysAllowedKey)
        }
        return sanitizedSaved.union(defaultAlwaysAllowedClients)
    }

    private static func sanitizedAlwaysAllowedClients(_ clients: Set<String>) -> Set<String> {
        clients.filter { !isRepoPromptCLIClientName($0) }
    }

    private static func isRepoPromptCLIClientName(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("RepoPrompt CLI")
    }

    /// Connection-approval decision for a new MCP client connection.
    ///
    /// Ordering contract:
    /// 1. Global auto-approve skips UI for everyone.
    /// 2. A verified gateway principal (launch-scoped credential; includes every
    ///    per-device `remote:<device8>` app link the gateway carries) auto-admits with
    ///    no per-connection prompt — pairing consent is the authorization event.
    /// 3. RepoPrompt CLI names require executable verification and never consult the
    ///    generic allow-list.
    /// 4. Allow-listed clients auto-approve.
    /// 5. Everything else prompts the user.
    enum ConnectionApprovalRoute: Equatable {
        case autoApproveAllClients
        case autoApproveGatewayPrincipal
        case autoApproveVerifiedRepoPromptCLI
        case promptUserUnverifiedRepoPromptCLI
        case autoApproveAllowListed
        case promptUser
    }

    static func connectionApprovalRoute(
        clientName: String,
        autoApproveAllClients: Bool,
        isGatewayPrincipal: Bool,
        isVerifiedBundledRepoPromptCLI: () async -> Bool,
        isAllowListed: () async -> Bool
    ) async -> ConnectionApprovalRoute {
        if autoApproveAllClients {
            return .autoApproveAllClients
        }
        if isGatewayPrincipal {
            return .autoApproveGatewayPrincipal
        }
        if isRepoPromptCLIClientName(clientName) {
            return await isVerifiedBundledRepoPromptCLI()
                ? .autoApproveVerifiedRepoPromptCLI
                : .promptUserUnverifiedRepoPromptCLI
        }
        if await isAllowListed() {
            return .autoApproveAllowListed
        }
        return .promptUser
    }

    #if DEBUG
        static var test_defaultAlwaysAllowedClients: Set<String> {
            defaultAlwaysAllowedClients
        }

        static func test_isRepoPromptCLIClientName(_ value: String) -> Bool {
            isRepoPromptCLIClientName(value)
        }

        static func test_sanitizedAlwaysAllowedClients(_ clients: Set<String>) -> Set<String> {
            sanitizedAlwaysAllowedClients(clients)
        }
    #endif

    /// Returns true iff the connecting process matches the app-bundled `repoprompt-mcp` executable.
    private func isBundledRepoPromptCLIConnection(connectionID: UUID) async -> Bool {
        guard let expectedURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp") else {
            return false
        }
        guard let peerPID = await networkManager.peerPID(for: connectionID) else {
            return false
        }
        guard let actualPath = Self.executablePath(forPID: peerPID) else {
            return false
        }
        let expected = expectedURL.resolvingSymlinksInPath().standardizedFileURL.path
        let actual = URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().standardizedFileURL.path
        return actual == expected
    }

    private nonisolated static func executablePath(forPID pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private func addAlwaysAllowed(clientID: String) {
        guard !Self.isRepoPromptCLIClientName(clientID) else { return }
        guard !alwaysAllowedClients.contains(where: { MCPClientIdentity.matches($0, clientID) }) else { return }
        alwaysAllowedClients.insert(clientID)
        UserDefaults.standard.set(
            Array(alwaysAllowedClients),
            forKey: Self.alwaysAllowedKey
        )
    }

    // MARK: - Dashboard & Auto-Approve Management

    /// Returns the list of always-allowed client IDs
    func alwaysAllowedClientIDs() -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for clientID in alwaysAllowedClients.sorted() {
            let dedupeKey = MCPClientIdentity.storageKey(clientID) ?? clientID
            guard seen.insert(dedupeKey).inserted else { continue }
            values.append(clientID)
        }
        return values
    }

    /// Add or remove a client from the persistent allow-list
    func setAlwaysAllowed(clientID: String, allowed: Bool) async {
        if !allowed, isDefaultAlwaysAllowed(clientID) {
            return
        }
        if allowed {
            addAlwaysAllowed(clientID: clientID)
        } else {
            alwaysAllowedClients = alwaysAllowedClients.filter {
                !MCPClientIdentity.matches($0, clientID) || isDefaultAlwaysAllowed($0)
            }
            UserDefaults.standard.set(
                Array(alwaysAllowedClients),
                forKey: Self.alwaysAllowedKey
            )
        }
        // Notify dashboard to refresh the UI
        await mcpService?.notifyDashboardUpdate()
    }

    /// Key for auto-approve all clients setting
    private static let autoApproveAllClientsKey = "mcpAutoApproveAllClients"

    /// Whether to auto-approve all new clients without user confirmation
    private var autoApproveAllClients: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoApproveAllClientsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoApproveAllClientsKey) }
    }

    func getAutoApproveAllClients() -> Bool {
        autoApproveAllClients
    }

    func setAutoApproveAllClients(_ enabled: Bool) async {
        autoApproveAllClients = enabled
        // Notify dashboard to refresh the UI
        await mcpService?.notifyDashboardUpdate()
    }

    /// Forcefully disconnect a specific connection (legacy - use terminateConnection instead)
    func bootConnection(id: UUID) async {
        await terminateConnection(id: id, reason: .userBootFromDashboard)
    }

    /// Terminates a connection with explicit kill semantics.
    /// CLI will exit without retrying.
    func terminateConnection(id: UUID, reason: TerminationReason, message: String? = nil) async {
        await networkManager.terminateConnection(id, reason: reason, message: message)
    }

    /// Snapshot of the server state for dashboard display
    struct ServerDashboardSnapshot {
        let serverStatus: String
        let diagnostics: MCPDiagnostics
        let connections: NetworkDashboardSnapshot
        let alwaysAllowedClients: [String]
        let autoApproveAllClients: Bool
    }

    /// Returns a complete dashboard snapshot
    func dashboardSnapshot(currentDiagnostics: MCPDiagnostics) async -> ServerDashboardSnapshot {
        let connSnapshot = await networkManager.dashboardSnapshot()
        return ServerDashboardSnapshot(
            serverStatus: serverStatus,
            diagnostics: currentDiagnostics,
            connections: connSnapshot,
            alwaysAllowedClients: alwaysAllowedClientIDs(),
            autoApproveAllClients: autoApproveAllClients
        )
    }

    // MARK: – public API –

    func applyRemoteGatewaySettings() async {
        let generation = await remoteGatewayActivationGate.begin()
        await remoteGatewayProcessLifecycle.selectGeneration(generation)
        let (enabled, browserHTTPSPort) = await MainActor.run {
            (
                GlobalSettingsStore.shared.mcpRemoteGatewayEnabled(),
                GlobalSettingsStore.shared.mcpRemoteGatewayBrowserHTTPSPort()
            )
        }

        guard enabled else {
            await Self.stopRemoteGateway(
                .disabled,
                generation: generation,
                statusStore: .shared,
                lifecycle: remoteGatewayProcessLifecycle
            )
            return
        }

        await publishRemoteGatewayStatus(.resolvingTailscale, generation: generation)
        var configuredLaunchID: UUID?
        do {
            let snapshot = try await tailscaleStatusProvider.status()
            try await ensureRemoteGatewayGeneration(generation)
            guard let bindHost = snapshot.selectedSelfIPv4 else {
                throw TailscaleStatusError.noEligibleSelfIPv4
            }
            let buildIdentity = RemoteControlBuildIdentity.current
            let origin = try RemoteGatewayOrigin(tailscaleIPv4: bindHost, channel: buildIdentity.channel)
            let browserOrigin = RemoteGatewayBrowserOrigin.derive(
                selfDNSName: snapshot.selfDNSName,
                port: browserHTTPSPort
            )
            let launchConfiguration = RemoteGatewayLaunchConfiguration.production(
                bindHost: bindHost,
                browserOrigin: browserOrigin,
                buildIdentity: buildIdentity
            )
            await publishRemoteGatewayStatus(.starting(origin), browserOrigin: browserOrigin, generation: generation)
            try await ensureRemoteGatewayGeneration(generation)
            let processIdentity = try await remoteGatewayProcessLifecycle.startIfNeeded(
                launchConfiguration,
                generation: generation,
                didTerminate: { [weak self] identity in
                    Task { await self?.remoteGatewayDidTerminate(identity) }
                }
            )
            try await waitForRemoteGatewayReadiness(origin: origin, generation: generation)
            try await ensureRemoteGatewayGeneration(generation)
            guard await remoteGatewayProcessLifecycle.isCurrent(
                processIdentity,
                configuration: launchConfiguration,
                generation: generation
            ) else {
                throw CancellationError()
            }
            let launchID = UUID()
            configuredLaunchID = launchID
            let authorityConfiguration = RemotePairingDiscoveryAuthority.Configuration(
                launchID: launchID,
                origin: origin,
                buildIdentity: buildIdentity,
                hostName: Self.remoteGatewayHostName()
            )
            do {
                try await remoteGatewayActivationGate.activate(
                    authorityConfiguration,
                    generation: generation,
                    processIsCurrent: { [weak self] in
                        guard let self else { return false }
                        return await remoteGatewayProcessLifecycle.isCurrent(
                            processIdentity,
                            configuration: launchConfiguration,
                            generation: generation
                        )
                    }
                )
            } catch {
                throw CancellationError()
            }
            await publishRemoteGatewayStatus(.discoverable(origin), browserOrigin: browserOrigin, generation: generation)
        } catch is CancellationError {
            if let configuredLaunchID {
                await discoveryAuthority.clear(ifLaunchID: configuredLaunchID)
            }
            return
        } catch {
            if let configuredLaunchID {
                await discoveryAuthority.clear(ifLaunchID: configuredLaunchID)
            }
            do {
                try await remoteGatewayActivationGate.ensureCurrent(generation)
            } catch {
                return
            }
            log.error("Failed to apply remote gateway settings: \(String(describing: error))")
            do {
                try await remoteGatewayProcessLifecycle.stop(generation: generation)
            } catch {
                return
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if error is TailscaleStatusError {
                await publishRemoteGatewayStatus(.unavailable(message), generation: generation)
            } else {
                await publishRemoteGatewayStatus(.failed(message), generation: generation)
            }
        }
    }

    private func ensureRemoteGatewayGeneration(_ generation: UInt64) async throws {
        do {
            try await remoteGatewayActivationGate.ensureCurrent(generation)
        } catch {
            throw CancellationError()
        }
    }

    private func waitForRemoteGatewayReadiness(
        origin: RemoteGatewayOrigin,
        generation: UInt64
    ) async throws {
        let endpoint = origin.endpoint(path: "/readyz")
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error?
        while Date() < deadline {
            try await ensureRemoteGatewayGeneration(generation)
            do {
                let response = try await remoteGatewayHealthClient.get(
                    endpoint,
                    timeout: 0.75,
                    maximumResponseBytes: 4 * 1024
                )
                if response.statusCode == 200, response.finalURL == endpoint {
                    return
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw lastError ?? RemoteHostHTTPClientError.invalidResponse
    }

    /// Status publication is fenced by the activation-gate generation, so a publication that
    /// lost a race with a newer apply, stop, or exit is dropped.
    private func publishRemoteGatewayStatus(
        _ status: RemoteGatewayStatusStore.Status,
        browserOrigin: RemoteGatewayOrigin? = nil,
        generation: UInt64
    ) async {
        await MainActor.run {
            _ = RemoteGatewayStatusStore.shared.publish(status, browserOrigin: browserOrigin, generation: generation)
        }
    }

    /// Every gateway stop withdraws the published status (and with it the active browser link)
    /// for its generation first, then runs `beforeStop`, then awaits process termination, which
    /// can take seconds. Alerts admitted meanwhile are text-only.
    static func stopRemoteGateway(
        _ stop: RemoteGatewayStatusStore.Stop,
        generation: UInt64,
        statusStore: RemoteGatewayStatusStore,
        lifecycle: RemoteGatewayProcessLifecycle,
        beforeStop: @Sendable () async -> Void = {}
    ) async {
        await MainActor.run {
            _ = statusStore.publishStop(stop, generation: generation)
        }
        await beforeStop()
        try? await lifecycle.stop(generation: generation)
    }

    private nonisolated static func remoteGatewayHostName() -> String {
        let candidates = [Host.current().localizedName, Host.current().name, ProcessInfo.processInfo.hostName]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "RepoPrompt Host"
    }

    private nonisolated static func remoteGatewayProcessDependencies(
        networkManager: ServerNetworkManager
    ) -> RemoteGatewayProcessLifecycle.Dependencies {
        .init(
            generateCredential: { try RemoteGatewayTokenStore.generateToken() },
            setCredential: { credential in
                await networkManager.setGatewayLaunchCredential(credential)
            },
            findOrphan: { configuration in
                guard let executableURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-gateway") else {
                    return nil
                }
                let leaseFileURL = remoteGatewayProcessLeaseFileURL(for: configuration)
                guard let lease = try? RemoteGatewayProcessLeaseFile.read(from: leaseFileURL),
                      lease.matches(
                          bindHost: configuration.bindHost,
                          port: configuration.port,
                          appSupportRoot: configuration.appSupportRoot,
                          executablePath: executableURL.path
                      ),
                      isProcessRunning(pid: lease.pid)
                else { return nil }

                let expectedExecutablePath = executableURL.standardizedFileURL.path
                guard let actualExecutablePath = executablePath(forPID: lease.pid),
                      URL(fileURLWithPath: actualExecutablePath).standardizedFileURL.path == expectedExecutablePath
                else {
                    log.warning(
                        "Remote gateway process lease exists but pid \(lease.pid) no longer resolves to bundled gateway; leaving it untouched"
                    )
                    return nil
                }
                return lease.pid
            },
            launch: { configuration, credential, token, didTerminate in
                guard let executableURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-gateway") else {
                    log.error("Cannot start remote gateway: bundled repoprompt-gateway executable not found")
                    throw CocoaError(.fileNoSuchFile)
                }
                let process = Process()
                process.executableURL = executableURL
                var environment = ProcessInfo.processInfo.environment
                environment["REPOPROMPT_GATEWAY_BIND_HOST"] = configuration.bindHost
                environment["REPOPROMPT_GATEWAY_PORT"] = String(configuration.port)
                environment["REPOPROMPT_GATEWAY_APP_SUPPORT_ROOT"] = configuration.appSupportRoot
                environment["REPOPROMPT_GATEWAY_BOOTSTRAP_TOKEN"] = "gateway-\(UUID().uuidString)"
                environment["REPOPROMPT_GATEWAY_APP_LEG_CREDENTIAL"] = credential
                environment["REPOPROMPT_GATEWAY_PARENT_PID"] = String(getpid())
                environment["REPOPROMPT_GATEWAY_PROCESS_LEASE_FILE"] = remoteGatewayProcessLeaseFileURL(for: configuration).path
                environment["REPOPROMPT_GATEWAY_APP_LINK_MAX_RECONNECT_ATTEMPTS"] = "24"
                // Always set (empty when unset) so an inherited value never widens the Host allowlist.
                environment["REPOPROMPT_GATEWAY_BROWSER_ORIGIN"] = configuration.browserOrigin?.string ?? ""
                process.environment = environment
                let diagnostics = RemoteGatewayProcessDiagnosticsCapture(
                    runtimeRootURL: URL(fileURLWithPath: configuration.appSupportRoot),
                    generation: token
                )
                if let diagnostics {
                    process.standardOutput = diagnostics.stdoutPipe
                    process.standardError = diagnostics.stderrPipe
                }
                process.terminationHandler = { process in
                    diagnostics?.finish()
                    didTerminate(.init(token: token, pid: process.processIdentifier))
                }
                try process.run()
                let identity = RemoteGatewayProcessIdentity(token: token, pid: process.processIdentifier)
                serverControllerDebugLog("Started repoprompt-gateway pid=\(identity.pid)")
                return RemoteGatewayProcessHandle(
                    identity: identity,
                    isRunning: { process.isRunning },
                    terminate: { process.terminate() }
                )
            },
            terminateOrphan: { pid in
                log.notice("Stopping orphaned repoprompt-gateway pid=\(pid) before relaunch")
                kill(pid, SIGTERM)
            },
            forceKill: { pid in kill(pid, SIGKILL) },
            isProcessRunning: { pid in isProcessRunning(pid: pid) },
            removeLease: { configuration, pid in
                RemoteGatewayProcessLeaseFile.removeIfOwned(
                    fileURL: remoteGatewayProcessLeaseFileURL(for: configuration),
                    pid: pid
                )
            },
            waitForTermination: { try? await Task.sleep(for: .seconds(2)) },
            now: { Date() }
        )
    }

    private nonisolated static func remoteGatewayProcessLeaseFileURL(
        for launchConfiguration: RemoteGatewayLaunchConfiguration
    ) -> URL {
        RemoteGatewayProcessLeaseFile.defaultURL(
            appSupportRoot: URL(fileURLWithPath: launchConfiguration.appSupportRoot)
        )
    }

    private nonisolated static func isProcessRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private nonisolated static func executablePath(forPID pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private func remoteGatewayDidTerminate(_ identity: RemoteGatewayProcessIdentity) async {
        guard let termination = await remoteGatewayProcessLifecycle.didTerminate(identity),
              let exitGeneration = await remoteGatewayActivationGate.invalidate(ifGeneration: termination.generation)
        else { return }
        await publishRemoteGatewayStatus(.unavailable("Gateway process exited."), generation: exitGeneration)
        let shouldRestart = await MainActor.run {
            GlobalSettingsStore.shared.mcpRemoteGatewayEnabled()
        }
        guard shouldRestart else {
            remoteGatewayRestartAttempts = 0
            return
        }
        if Date().timeIntervalSince(termination.launchedAt) >= Self.remoteGatewayStableUptimeSeconds {
            // A stable run resets the crash-loop budget; this exit is treated as the first failure.
            remoteGatewayRestartAttempts = 0
        }
        remoteGatewayRestartAttempts += 1
        guard remoteGatewayRestartAttempts <= Self.remoteGatewayMaxRestartAttempts else {
            log.error(
                """
                repoprompt-gateway exited \(Self.remoteGatewayMaxRestartAttempts) times without a stable run; \
                pausing automatic restarts until remote gateway settings are re-applied
                """
            )
            return
        }
        let backoffSeconds = min(pow(2.0, Double(remoteGatewayRestartAttempts - 1)), 30.0)
        serverControllerDebugLog(
            "repoprompt-gateway pid=\(identity.pid) exited; restart attempt \(remoteGatewayRestartAttempts)/"
                + "\(Self.remoteGatewayMaxRestartAttempts) in \(backoffSeconds)s"
        )
        try? await Task.sleep(for: .seconds(backoffSeconds))
        await applyRemoteGatewaySettings()
    }

    /// Request to start (or re-enable) the MCP listener.
    func startServer() async {
        if await networkManager.isRunning() {
            await networkManager.setEnabled(true) // expose tools only
            await networkManager.ensureBootstrapHealthy(force: true)
        } else {
            await networkManager.start() // cold start once
            await networkManager.ensureBootstrapHealthy(force: true)
        }
        beginPowerActivity()
        updateServerStatus("Running")
    }

    /// Disable the listener.
    func stopServer() async {
        let generation = await remoteGatewayActivationGate.invalidate()
        await remoteGatewayProcessLifecycle.selectGeneration(generation)
        let networkManager = networkManager
        await Self.stopRemoteGateway(
            .stopped(reason: Self.remoteGatewayStoppedWithServerReason),
            generation: generation,
            statusStore: .shared,
            lifecycle: remoteGatewayProcessLifecycle,
            beforeStop: { await networkManager.setEnabled(false) }
        )
        endPowerActivity()
        updateServerStatus("Disabled")
    }

    /// Completely shut down the listener.
    func fullShutdown() async {
        let generation = await remoteGatewayActivationGate.invalidate()
        await remoteGatewayProcessLifecycle.selectGeneration(generation)
        let networkManager = networkManager
        await Self.stopRemoteGateway(
            .stopped(reason: Self.remoteGatewayStoppedWithServerReason),
            generation: generation,
            statusStore: .shared,
            lifecycle: remoteGatewayProcessLifecycle,
            beforeStop: { await networkManager.stop() }
        )
        endPowerActivity()
        updateServerStatus("Stopped")
    }

    /// This method will be used to enable/disable all tools at once.
    func setEnabled(_ enabled: Bool) async {
        await networkManager.setEnabled(enabled)
        if enabled {
            beginPowerActivity()
            await networkManager.ensureBootstrapHealthy(force: true)
        } else {
            endPowerActivity()
        }
        updateServerStatus(enabled ? "Running" : "Disabled")
    }

    // This is no longer needed as there are no individual service toggles.
    // func updateServiceBindings(_ b: [String: Binding<Bool>]) async {
    //     await networkManager.updateServiceBindings(b)
    // }

    // MARK: – helpers ––––––––––––––––––––––––––––––––––––––––––––––––––

    /// Timeout for approval dialogs (auto-deny after this duration)
    private let approvalTimeout: TimeInterval = 300
    /// Monotonic generation for the active approval request.
    /// Prevents stale timeout tasks from auto-denying a newer request.
    private var approvalGeneration: UInt64 = 0
    /// Timeout watchdog for the currently active approval request.
    /// Cancelled when approval resolves or is superseded.
    private var approvalTimeoutTask: Task<Void, Never>?

    private func updateServerStatus(_ s: String) {
        serverControllerDebugLog("Server status ➜ \(s)")
        serverStatus = s
    }

    private func beginPowerActivity() {
        guard powerActivity == nil else { return }
        powerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Maintain realtime MCP server connection"
        )
    }

    private func endPowerActivity() {
        guard let activity = powerActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        powerActivity = nil
    }

    /// Request approval through the callback system instead of showing NSAlert directly.
    /// Approval requests are handled in strict FIFO order: exactly one active request at a time.
    private func requestApproval(
        clientID: String,
        approve: @escaping () -> Void,
        deny: @escaping () -> Void
    ) async {
        // Single-flight guard: queue while another approval is active.
        if currentApprovalCallbacks != nil {
            pendingApprovals.append((clientID, approve, deny))
            return
        }
        await beginApprovalRequest(clientID: clientID, approve: approve, deny: deny)
    }

    /// Starts a single active approval request and schedules its timeout watchdog.
    private func beginApprovalRequest(
        clientID: String,
        approve: @escaping () -> Void,
        deny: @escaping () -> Void
    ) async {
        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil
        pendingConnectionID = clientID
        activeApprovalDialogs.insert(clientID)
        currentApprovalCallbacks = (approve, deny)
        approvalGeneration &+= 1

        let expectedClientID = clientID
        let expectedGeneration = approvalGeneration
        let timeout = approvalTimeout
        approvalTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self else { return }
            await handleApprovalTimeout(
                clientID: expectedClientID,
                expectedGeneration: expectedGeneration
            )
        }

        await onApprovalRequest?(clientID)
    }

    /// Starts the next queued approval request, if any.
    private func activateNextQueuedApprovalIfNeeded() async {
        guard currentApprovalCallbacks == nil else { return }
        guard pendingConnectionID == nil else { return }
        guard !pendingApprovals.isEmpty else { return }
        let (nextClientID, approve, deny) = pendingApprovals.removeFirst()
        await beginApprovalRequest(clientID: nextClientID, approve: approve, deny: deny)
    }

    /// Handle approval timeout - auto-deny the active request and any queued duplicates for that client.
    private func handleApprovalTimeout(clientID: String, expectedGeneration: UInt64) async {
        guard let (_, deny) = currentApprovalCallbacks,
              pendingConnectionID == clientID,
              approvalGeneration == expectedGeneration else { return }

        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil
        currentApprovalCallbacks = nil
        pendingConnectionID = nil
        activeApprovalDialogs.remove(clientID)
        deny()

        // Also auto-deny queued requests for the same client to avoid backlog/slot buildup.
        while let idx = pendingApprovals.firstIndex(where: { $0.0 == clientID }) {
            let (_, _, queuedDeny) = pendingApprovals.remove(at: idx)
            queuedDeny()
        }

        onApprovalResolved?(false)

        if let service = mcpService {
            let diag = MCPDiagnostics(
                issue: .lastClientApprovalTimedOut(clientID: clientID),
                lastEventAt: Date(),
                listenerStateDescription: "Last client was auto-denied after approval timeout"
            )
            Task { await service.updateDiagnostics(diag) }
        }

        await activateNextQueuedApprovalIfNeeded()
    }

    /// Store current approval callbacks
    private var currentApprovalCallbacks: (() -> Void, () -> Void)?

    /// Called by MCPService when the UI has made a decision.
    func resolvePendingApproval(allow: Bool, alwaysAllow: Bool = false) async {
        guard let (approve, deny) = currentApprovalCallbacks else { return }
        let resolvedClientID = pendingConnectionID
        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil

        if !allow, let clientID = resolvedClientID, let service = mcpService {
            let diag = MCPDiagnostics(
                issue: .lastClientApprovalDenied(clientID: clientID),
                lastEventAt: Date(),
                listenerStateDescription: "Last client was denied"
            )
            Task { await service.updateDiagnostics(diag) }
        }

        if allow {
            // If user selected "always allow", add to the persistent list
            if alwaysAllow, let clientID = resolvedClientID {
                addAlwaysAllowed(clientID: clientID)
            }
            approve()
        } else {
            deny()
        }

        // Process any queued approvals for the same client.
        // Coalescing same-client decisions prevents continuation leaks on reconnect storms.
        if let clientID = resolvedClientID {
            while let idx = pendingApprovals.firstIndex(where: { $0.0 == clientID }) {
                let (_, a, d) = pendingApprovals.remove(at: idx)
                allow ? a() : d()
            }
            activeApprovalDialogs.remove(clientID)
        }

        currentApprovalCallbacks = nil
        pendingConnectionID = nil

        // Notify resolution callback if needed
        onApprovalResolved?(allow)
        await activateNextQueuedApprovalIfNeeded()
    }
}
