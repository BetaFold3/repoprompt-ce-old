import Foundation
import OSLog

package enum CursorACPParameterRefreshOutcome: Equatable {
    case disabled
    case live
    case unsupported
    case stale(CursorModelParameterCatalog.FailureKind)
    case cancelled
}

package enum CursorACPModelDiscoveryOutcome: Equatable, @unchecked Sendable {
    case completed(
        models: ACPDiscoveredSessionModels?,
        parameterRefresh: CursorACPParameterRefreshOutcome
    )
    case failed(CursorModelParameterCatalog.FailureKind)
    case cancelled
}

package protocol CursorACPModelDiscoveryClient: Sendable {
    var parameterCatalog: CursorModelParameterCatalog { get }

    func discoverModels(workspacePath: String?) async -> CursorACPModelDiscoveryOutcome
}

enum CursorACPModelFailureClassifier {
    enum Stage {
        case discovery
        case `extension`
    }

    static func classify(_ error: Error, stage: Stage) -> CursorModelParameterCatalog.FailureKind? {
        if error is CancellationError || Task.isCancelled {
            return nil
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return .authentication
            case .timedOut where stage == .extension:
                return .timeout
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.code == 401 || nsError.code == 403 {
            return .authentication
        }

        let lowered = error.localizedDescription.lowercased()
        if authenticationPhrases.contains(where: lowered.contains) {
            return .authentication
        }
        if stage == .extension, timeoutPhrases.contains(where: lowered.contains) {
            return .timeout
        }
        return stage == .discovery ? .discovery : .extension
    }

    static func isMethodNotFound(_ error: Error) -> Bool {
        ACPAgentSessionController.isProviderExtensionMethodNotFoundError(error)
    }

    private static let authenticationPhrases = [
        "unauthenticated",
        "unauthorized",
        "not authenticated",
        "authentication required",
        "login required",
        "requires login",
        "please log in",
        "not logged in",
        "token expired",
        "expired token"
    ]

    private static let timeoutPhrases = [
        "timed out",
        "timeout"
    ]
}

private struct CursorACPModelDiscoveryFailure: LocalizedError {
    let kind: CursorModelParameterCatalog.FailureKind

    var errorDescription: String? {
        switch kind {
        case .authentication:
            "Cursor model discovery requires authentication."
        case .timeout:
            "Cursor model parameter discovery timed out."
        case .malformedResponse:
            "Cursor returned malformed model parameter metadata."
        case .discovery:
            "Cursor model discovery failed."
        case .extension:
            "Cursor model parameter discovery failed."
        }
    }
}

package struct CursorACPControllerModelDiscoveryClient: CursorACPModelDiscoveryClient {
    package typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) -> (any ACPAgentProvider)?
    package typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory
    package let parameterCatalog: CursorModelParameterCatalog
    private let parameterizedModelsEnabled: @Sendable () -> Bool
    private let extensionTimeoutSeconds: TimeInterval

    package init(
        mcpHost: any AgentMCPHosting,
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .cursor {
                return CursorACPAgentProvider(
                    config: CursorAgentConfig(
                        enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                        modelString: modelString,
                        includeRepoPromptMCPServer: false,
                        cleanupProjectMCPApproval: false
                    )
                )
            }
            return ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
        },
        controllerFactory: ControllerFactory? = nil,
        parameterCatalog: CursorModelParameterCatalog = .shared,
        parameterizedModelsEnabled: @escaping @Sendable () -> Bool = {
            CursorParameterizedModels.isEnabled
        },
        extensionTimeoutSeconds: TimeInterval = 10
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory ?? { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest, mcpHost: mcpHost)
        }
        self.parameterCatalog = parameterCatalog
        self.parameterizedModelsEnabled = parameterizedModelsEnabled
        self.extensionTimeoutSeconds = extensionTimeoutSeconds
    }

    package func discoverModels(workspacePath: String?) async -> CursorACPModelDiscoveryOutcome {
        let extensionEnabled = parameterizedModelsEnabled()
        let preferredModel = AgentModel.cursorAuto.rawValue
        let request = ACPRunRequest(
            agentKind: .cursor,
            modelString: preferredModel,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil,
            runtimeSession: .sessionless
        )

        guard let provider = providerFactory(.cursor, preferredModel) else {
            return .failed(.discovery)
        }

        do {
            let support = try await provider.support(for: request)
            guard support == .supported else {
                return .failed(.discovery)
            }

            let controller = try controllerFactory(provider, request)
            do {
                _ = try await controller.bootstrap()
                let parameterRefresh = await parameterRefreshOutcome(
                    controller: controller,
                    enabled: extensionEnabled
                )
                guard parameterRefresh != .cancelled else {
                    await controller.shutdown()
                    return .cancelled
                }
                let snapshot = await controller.currentDiscoveredSessionModels()
                await controller.shutdown()
                return .completed(models: snapshot, parameterRefresh: parameterRefresh)
            } catch {
                await controller.shutdown()
                guard let kind = CursorACPModelFailureClassifier.classify(error, stage: .discovery) else {
                    return .cancelled
                }
                return .failed(kind)
            }
        } catch {
            guard let kind = CursorACPModelFailureClassifier.classify(error, stage: .discovery) else {
                return .cancelled
            }
            return .failed(kind)
        }
    }

    private func parameterRefreshOutcome(
        controller: ACPAgentSessionController,
        enabled: Bool
    ) async -> CursorACPParameterRefreshOutcome {
        guard enabled else { return .disabled }

        do {
            let response = try await controller.sendProviderExtensionRequest(
                method: "cursor/list_available_models",
                params: [:],
                timeoutSeconds: extensionTimeoutSeconds
            )
            let result: CursorModelParameterCatalog.ApplyResult = parameterCatalog.apply(response: response)
            switch result {
            case .applied:
                return .live
            case .rejectedMalformed:
                return .stale(.malformedResponse)
            }
        } catch {
            if CursorACPModelFailureClassifier.isMethodNotFound(error) {
                return .unsupported
            }
            guard let kind = CursorACPModelFailureClassifier.classify(error, stage: .extension) else {
                return .cancelled
            }
            return .stale(kind)
        }
    }
}

// SEARCH-HELPER: Cursor ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for Cursor ACP dynamic model options.
///
/// Cursor can expose model metadata through ACP session bootstrap responses. This mirrors the
/// OpenCode model discovery path while preserving Cursor's static Auto fallback when no
/// dynamic model metadata is available yet.
package actor CursorACPModelPollingService {
    package struct Snapshot: Equatable {
        package let models: ACPDiscoveredSessionModels
        let fetchedAt: Date
        package let isLiveDiscovery: Bool
    }

    private static let logger = Logger(
        subsystem: "com.repoprompt.agents",
        category: "CursorModelPolling"
    )

    private let client: any CursorACPModelDiscoveryClient
    private let parameterCatalog: CursorModelParameterCatalog
    private let intervalNanos: UInt64
    private let retryBaseNanos: UInt64
    private let retryMaximumNanos: UInt64

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<Bool, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    #if DEBUG
        private var testRefreshNowInFlightJoinObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    #endif
    private var latest: Snapshot?
    private var preferredWorkspacePath: String?
    private var isShutdown = false
    private var failureStreak = 0
    private var lastLoggedFailureKind: CursorModelParameterCatalog.FailureKind?

    package init(
        client: any CursorACPModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000,
        retryBaseNanos: UInt64 = 15_000_000_000,
        retryMaximumNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        parameterCatalog = client.parameterCatalog
        self.intervalNanos = intervalNanos
        self.retryBaseNanos = retryBaseNanos
        self.retryMaximumNanos = max(retryBaseNanos, retryMaximumNanos)
    }

    package func latestSnapshot() async -> Snapshot? {
        if let latest { return latest }
        return await registrySnapshotAfterWarmingStore()
    }

    #if DEBUG
        func test_refreshNowInFlightJoinEvents() -> AsyncStream<Void> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            testRefreshNowInFlightJoinObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTestRefreshNowInFlightJoinObserver(id) }
            }
            return stream
        }

        func test_pollingFailureStreak() -> Int {
            failureStreak
        }

        func test_nextPollingDelayNanos() -> UInt64 {
            nextPollingDelayNanos()
        }
    #endif

    package func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        parameterCatalog.markRefreshing()
        let outcome = await client.discoverModels(workspacePath: preferredWorkspacePath)
        guard !isShutdown else {
            if parameterCatalog.status().state == .refreshing {
                parameterCatalog.markIdle()
            }
            return nil
        }

        switch outcome {
        case let .completed(models, parameterRefresh):
            recordParameterOutcome(parameterRefresh)
            guard let models else { return nil }
            applyRefreshResult(models)
            return await latestSnapshot()
        case let .failed(kind):
            recordFailure(kind)
            throw CursorACPModelDiscoveryFailure(kind: kind)
        case .cancelled:
            parameterCatalog.markIdle()
            throw CancellationError()
        }
    }

    package func subscribe(workspacePath: String?) async -> AsyncStream<Snapshot> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }

        if latest == nil, let cached = await registrySnapshotAfterWarmingStore() {
            guard !isShutdown else {
                continuation.finish()
                return stream
            }
            if latest == nil {
                latest = cached
            }
        }
        if let latest {
            continuation.yield(latest)
        }

        guard !isShutdown else { return stream }
        startPollingIfNeeded()
        return stream
    }

    @discardableResult
    package func refreshNow(workspacePath: String?) async -> Bool {
        guard !isShutdown else { return false }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if let existing = inFlightRefresh {
            #if DEBUG
                publishTestRefreshNowInFlightJoin()
            #endif
            return await existing.value
        }
        return await performRefresh()
    }

    package func shutdown(finishSubscribers: Bool = true) async {
        isShutdown = true
        pollingTask?.cancel()
        pollingTask = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        if parameterCatalog.status().state == .refreshing {
            parameterCatalog.markIdle()
        }
        #if DEBUG
            let activeTestJoinObservers = testRefreshNowInFlightJoinObservers
            testRefreshNowInFlightJoinObservers.removeAll()
            for continuation in activeTestJoinObservers.values {
                continuation.finish()
            }
        #endif
        if finishSubscribers {
            let activeContinuations = continuations
            continuations.removeAll()
            for continuation in activeContinuations.values {
                continuation.finish()
            }
        }
    }

    private func startPollingIfNeeded() {
        guard !isShutdown else { return }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await performRefresh()
                do {
                    try await Task.sleep(nanoseconds: nextPollingDelayNanos())
                } catch {
                    break
                }
            }
        }
    }

    private func stopPollingIfIdle() {
        guard continuations.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func removeSubscriber(_ id: UUID) {
        continuations.removeValue(forKey: id)
        stopPollingIfIdle()
    }

    #if DEBUG
        private func publishTestRefreshNowInFlightJoin() {
            for continuation in testRefreshNowInFlightJoinObservers.values {
                continuation.yield(())
            }
        }

        private func removeTestRefreshNowInFlightJoinObserver(_ id: UUID) {
            testRefreshNowInFlightJoinObservers.removeValue(forKey: id)
        }
    #endif

    private func performRefresh() async -> Bool {
        guard !isShutdown else { return false }
        if let existing = inFlightRefresh {
            return await existing.value
        }

        parameterCatalog.markRefreshing()
        let workspacePath = preferredWorkspacePath
        let client = client
        let task = Task<Bool, Never> { [weak self, client, workspacePath] in
            guard let self else { return false }
            let outcome = await client.discoverModels(workspacePath: workspacePath)
            guard !Task.isCancelled else { return false }
            return await handleRefreshOutcome(outcome)
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    private func handleRefreshOutcome(_ outcome: CursorACPModelDiscoveryOutcome) -> Bool {
        guard !isShutdown else { return false }

        switch outcome {
        case let .completed(models, parameterRefresh):
            recordParameterOutcome(parameterRefresh)
            if let models {
                applyRefreshResult(models)
            } else {
                publishLiveReadinessWithoutModels()
            }
            return true
        case let .failed(kind):
            recordFailure(kind)
            return false
        case .cancelled:
            parameterCatalog.markIdle()
            return false
        }
    }

    private func recordParameterOutcome(_ outcome: CursorACPParameterRefreshOutcome) {
        switch outcome {
        case .disabled:
            parameterCatalog.markDisabled()
            resetFailureStreak()
        case .live:
            resetFailureStreak()
        case .unsupported:
            parameterCatalog.clearForMethodNotFound()
            resetFailureStreak()
        case let .stale(kind):
            recordFailure(kind)
        case .cancelled:
            parameterCatalog.markIdle()
        }
    }

    private func recordFailure(_ kind: CursorModelParameterCatalog.FailureKind) {
        parameterCatalog.markStale(kind)
        failureStreak = min(failureStreak + 1, 64)
        let detail = Self.sanitizedDetail(for: kind)
        if lastLoggedFailureKind == kind {
            Self.logger.debug("Cursor model parameter refresh still failing: \(detail, privacy: .public)")
        } else {
            Self.logger.error("Cursor model parameter refresh failed: \(detail, privacy: .public)")
            lastLoggedFailureKind = kind
        }
    }

    private func resetFailureStreak() {
        failureStreak = 0
        lastLoggedFailureKind = nil
    }

    private func nextPollingDelayNanos() -> UInt64 {
        guard failureStreak > 0 else { return intervalNanos }
        var delay = retryBaseNanos
        for _ in 1 ..< failureStreak {
            if delay >= retryMaximumNanos || delay > retryMaximumNanos / 2 {
                return retryMaximumNanos
            }
            delay *= 2
        }
        return min(delay, retryMaximumNanos)
    }

    private static func sanitizedDetail(
        for kind: CursorModelParameterCatalog.FailureKind
    ) -> String {
        switch kind {
        case .authentication:
            "authentication required"
        case .timeout:
            "extension timeout"
        case .malformedResponse:
            "malformed extension response"
        case .discovery:
            "ACP discovery unavailable"
        case .extension:
            "extension request failed"
        }
    }

    private func publishLiveReadinessWithoutModels() {
        guard !isShutdown else { return }
        let models = latest?.models
            ?? AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)
            ?? ACPDiscoveredSessionModels(options: [], currentModelRaw: nil)
        let snapshot = Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func applyRefreshResult(_ discovered: ACPDiscoveredSessionModels) {
        guard !isShutdown else { return }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(discovered, for: .cursor)
        guard let normalized = AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor) else { return }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func registrySnapshotAfterWarmingStore() async -> Snapshot? {
        guard let models = await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .cursor) else {
            return nil
        }
        return Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: false)
    }

    private func normalizedWorkspacePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
