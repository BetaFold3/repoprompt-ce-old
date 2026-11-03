import Foundation

package protocol OhMyPiACPModelDiscoveryClient: Sendable {
    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels?
}

package struct OhMyPiACPControllerModelDiscoveryClient: OhMyPiACPModelDiscoveryClient {
    package typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) -> (any ACPAgentProvider)?
    package typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory

    package init(
        mcpHost: any AgentMCPHosting,
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .ohMyPi {
                return OhMyPiACPAgentProvider(
                    config: OhMyPiAgentConfig(
                        modelString: modelString,
                        enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                        includeRepoPromptMCPServer: false
                    )
                )
            }
            return ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
        },
        controllerFactory: ControllerFactory? = nil
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory ?? { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest, mcpHost: mcpHost)
        }
    }

    package func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels? {
        let request = ACPRunRequest(
            agentKind: .ohMyPi,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil,
            runtimeSession: .sessionless
        )
        guard let provider = providerFactory(.ohMyPi, nil) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Oh My Pi ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: .ohMyPi)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw provider.normalizeError(error)
        }
    }
}

/// Centralized OMP ACP dynamic-model polling. OMP models come exclusively from ACP
/// configOptions; this service never manufactures static provider/model identifiers.
package actor OhMyPiACPModelPollingService {
    package struct Snapshot: Equatable {
        package let models: ACPDiscoveredSessionModels
        let fetchedAt: Date
        package let isLiveDiscovery: Bool
    }

    private struct DiscoveryResult {
        let generation: UInt64
        let models: ACPDiscoveredSessionModels?
    }

    private let client: any OhMyPiACPModelDiscoveryClient
    private let intervalNanos: UInt64
    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<DiscoveryResult, Error>?
    private var inFlightToken: UUID?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var latest: Snapshot?
    private var preferredWorkspacePath: String?
    private var refreshGeneration: UInt64 = 0
    private var isShutdown = false

    package init(
        client: any OhMyPiACPModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        self.intervalNanos = intervalNanos
    }

    package func latestSnapshot() async -> Snapshot? {
        if let latest { return latest }
        guard let models = await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .ohMyPi) else {
            return nil
        }
        return Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: false)
    }

    package func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        let result = try await coalescedDiscovery(workspacePath: preferredWorkspacePath)
        guard isCurrent(result), let discovered = result.models else { return nil }
        apply(discovered, generation: result.generation)
        return latest
    }

    package func subscribe(workspacePath: String?) async -> AsyncStream<Snapshot> {
        guard !isShutdown else {
            return AsyncStream { $0.finish() }
        }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        if latest == nil, let cached = await latestSnapshot() {
            latest = cached
        }
        if let latest {
            continuation.yield(latest)
        }
        startPollingIfNeeded()
        return stream
    }

    @discardableResult
    package func refreshNow(workspacePath: String?) async -> Bool {
        guard !isShutdown else { return false }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        do {
            let result = try await coalescedDiscovery(workspacePath: preferredWorkspacePath)
            guard isCurrent(result), let discovered = result.models else { return false }
            apply(discovered, generation: result.generation)
            return true
        } catch {
            return false
        }
    }

    /// Clears all OMP discovery state and invalidates any result already in flight.
    /// Subscribers are finished so a stale task cannot re-emit after reset.
    package func reset() {
        refreshGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        inFlightToken = nil
        latest = nil
        preferredWorkspacePath = nil
        finishSubscribers()
        AgentACPModelRegistry.shared.reset(providerID: .ohMyPi)
    }

    func shutdown(finishSubscribers shouldFinishSubscribers: Bool = true) {
        isShutdown = true
        refreshGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        inFlightToken = nil
        latest = nil
        if shouldFinishSubscribers {
            finishSubscribers()
        }
    }

    private func coalescedDiscovery(workspacePath: String?) async throws -> DiscoveryResult {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }

        let generation = refreshGeneration
        let token = UUID()
        let client = client
        let task = Task<DiscoveryResult, Error> {
            let models = try await client.discoverModels(workspacePath: workspacePath)
            try Task.checkCancellation()
            return DiscoveryResult(generation: generation, models: models)
        }
        inFlightRefresh = task
        inFlightToken = token

        do {
            let result = try await task.value
            clearInFlight(token: token)
            return result
        } catch {
            clearInFlight(token: token)
            throw error
        }
    }

    private func clearInFlight(token: UUID) {
        guard inFlightToken == token else { return }
        inFlightRefresh = nil
        inFlightToken = nil
    }

    private func startPollingIfNeeded() {
        guard !isShutdown, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let workspacePath = await preferredWorkspacePath
                _ = await refreshNow(workspacePath: workspacePath)
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private func finishSubscribers() {
        let current = continuations.values
        continuations.removeAll()
        for continuation in current {
            continuation.finish()
        }
    }

    private func isCurrent(_ result: DiscoveryResult) -> Bool {
        !isShutdown && result.generation == refreshGeneration && !Task.isCancelled
    }

    private func apply(_ discovered: ACPDiscoveredSessionModels, generation: UInt64) {
        guard !isShutdown, generation == refreshGeneration else { return }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(discovered, for: .ohMyPi)
        guard generation == refreshGeneration,
              let normalized = AgentACPModelRegistry.shared.resolvedSnapshot(for: .ohMyPi)
        else {
            return
        }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func normalizedWorkspacePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
