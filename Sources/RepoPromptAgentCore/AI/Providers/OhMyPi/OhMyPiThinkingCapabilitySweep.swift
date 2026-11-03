import Foundation

package struct OhMyPiThinkingSweepLimits {
    var startupSeconds: TimeInterval = 30
    var perSwitchSeconds: TimeInterval = 8
    var workBudgetSeconds: TimeInterval = 45
    var maxBackgroundTargets = 24
    var consecutiveFailureLimit = 3
    var sweepFailureCooldown: TimeInterval = 60
}

package enum OhMyPiThinkingSwitchResult: Equatable {
    case loaded
    case cached
    case unsupported
    case failed(String)
}

package enum OhMyPiThinkingSweepCancellationReason: Equatable {
    case appTermination
    case availabilityLost
    case runtimeVersionChanged
    case startupDeadline
    case switchDeadline
    case workBudgetExpired
}

package enum OhMyPiThinkingSweepTerminal: Equatable {
    case completed
    case preflightFailed(String)
    case bootstrapFailed(String)
    case cancelled(OhMyPiThinkingSweepCancellationReason)
    case sessionFatal(current: String?, reason: String)
    case workBudgetExpired(current: String?)
}

package enum OhMyPiThinkingSweepEvent: Equatable {
    case bootstrapped(ompVersion: String)
    case willSwitch(String)
    case switched(String, OhMyPiThinkingSwitchResult, elapsed: TimeInterval)
    case terminal(OhMyPiThinkingSweepTerminal)
}

enum OhMyPiThinkingSweepAbort: Error, Equatable {
    case terminal(OhMyPiThinkingSweepTerminal)
}

package enum OhMyPiThinkingControllerFailureClassification {
    case modelLocal
    case sessionFatal
}

package protocol OhMyPiThinkingCapabilitySweepController: Sendable {
    func start() async throws
    func setSessionModel(_ modelID: String) async throws
    func normalizedErrorDescription(_ error: Error) async -> String
    func classifyConfigurationMutationFailure(
        _ error: Error
    ) async -> OhMyPiThinkingControllerFailureClassification
    func shutdown() async
}

extension ACPAgentSessionController: OhMyPiThinkingCapabilitySweepController {
    package func start() async throws {
        _ = try await bootstrap()
    }

    package func normalizedErrorDescription(_ error: Error) async -> String {
        normalizeError(error).localizedDescription
    }

    package func classifyConfigurationMutationFailure(
        _ error: Error
    ) async -> OhMyPiThinkingControllerFailureClassification {
        switch classifyConfigurationMutationFailureForSweep(error) {
        case .modelLocal: .modelLocal
        case .sessionFatal: .sessionFatal
        }
    }
}

package protocol OhMyPiThinkingCapabilityPreparedSession: Sendable {
    var ompVersion: String { get }
    func makeController(
        publisher: @escaping OhMyPiThinkingCapabilityPublisher
    ) throws -> any OhMyPiThinkingCapabilitySweepController
}

package protocol OhMyPiThinkingCapabilitySessionFactory: Sendable {
    func prepare(
        workspacePath: String?,
        limits: OhMyPiThinkingSweepLimits
    ) async throws -> any OhMyPiThinkingCapabilityPreparedSession
}

package struct OhMyPiThinkingCapabilityControllerSessionFactory:
    OhMyPiThinkingCapabilitySessionFactory
{
    package typealias ProviderFactory = @Sendable (OhMyPiAgentConfig) -> any ACPAgentProvider
    package typealias ControllerFactory = @Sendable (
        any ACPAgentProvider,
        ACPRunRequest,
        ACPAgentSessionController.RequestTimeouts,
        @escaping OhMyPiThinkingCapabilityPublisher
    ) throws -> ACPAgentSessionController

    private struct Prepared: OhMyPiThinkingCapabilityPreparedSession {
        let ompVersion: String
        let provider: any ACPAgentProvider
        let request: ACPRunRequest
        let timeouts: ACPAgentSessionController.RequestTimeouts
        let controllerFactory: ControllerFactory

        func makeController(
            publisher: @escaping OhMyPiThinkingCapabilityPublisher
        ) throws -> any OhMyPiThinkingCapabilitySweepController {
            try controllerFactory(provider, request, timeouts, publisher)
        }
    }

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory
    private let runtimeVersion: @Sendable () -> String?
    private let now: @Sendable () -> Date

    package init(
        mcpHost: any AgentMCPHosting,
        providerFactory: @escaping ProviderFactory = { OhMyPiACPAgentProvider(config: $0) },
        controllerFactory: ControllerFactory? = nil,
        runtimeVersion: @escaping @Sendable () -> String? = {
            OhMyPiRuntimeVersionRegistry.shared.currentVersion
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory ?? { provider, request, timeouts, publisher in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                mcpHost: mcpHost,
                requestTimeouts: timeouts,
                dynamicModelPublicationPolicy: .capabilityOnly,
                ohMyPiThinkingCapabilityPublisher: publisher
            )
        }
        self.runtimeVersion = runtimeVersion
        self.now = now
    }

    package func prepare(
        workspacePath: String?,
        limits: OhMyPiThinkingSweepLimits
    ) async throws -> any OhMyPiThinkingCapabilityPreparedSession {
        let config = OhMyPiAgentConfig(
            modelString: nil,
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false
        )
        let request = ACPRunRequest(
            agentKind: .ohMyPi,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil,
            runtimeSession: .sessionless
        )
        let provider = providerFactory(config)
        let startedAt = now()
        do {
            let support = try await provider.support(for: request)
            guard support == .supported else {
                throw AIProviderError.invalidConfiguration(
                    detail: support.reason ?? "Oh My Pi ACP is not available."
                )
            }
        } catch {
            throw provider.normalizeError(error)
        }

        guard let version = runtimeVersion(), !version.isEmpty else {
            throw AIProviderError.invalidConfiguration(
                detail: "Oh My Pi runtime version was not observed during preflight."
            )
        }
        let elapsed = now().timeIntervalSince(startedAt)
        guard elapsed < limits.startupSeconds else {
            throw OhMyPiThinkingSweepAbort.terminal(.cancelled(.startupDeadline))
        }
        return Prepared(
            ompVersion: version,
            provider: provider,
            request: request,
            timeouts: .init(
                bootstrapSeconds: max(0.001, limits.startupSeconds - elapsed),
                setConfigOptionSeconds: limits.perSwitchSeconds
            ),
            controllerFactory: controllerFactory
        )
    }
}

package protocol OhMyPiThinkingCapabilitySweepClient: Sendable {
    func run(
        workspacePath: String?,
        limits: OhMyPiThinkingSweepLimits,
        nextTarget: @escaping @Sendable () async -> String?,
        report: @escaping @Sendable (OhMyPiThinkingSweepEvent) async -> Void
    ) async throws
}

package struct OhMyPiThinkingCapabilityControllerSweepClient: OhMyPiThinkingCapabilitySweepClient {
    private let sessionFactory: any OhMyPiThinkingCapabilitySessionFactory
    private let registry: OhMyPiThinkingCapabilityRegistry
    private let runtimeVersionRegistry: OhMyPiRuntimeVersionRegistry
    private let isAvailable: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    package init(
        registry: OhMyPiThinkingCapabilityRegistry = .shared,
        runtimeVersionRegistry: OhMyPiRuntimeVersionRegistry = .shared,
        sessionFactory: any OhMyPiThinkingCapabilitySessionFactory,
        isAvailable: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.runtimeVersionRegistry = runtimeVersionRegistry
        self.sessionFactory = sessionFactory
        self.isAvailable = isAvailable
        self.now = now
    }

    package func run(
        workspacePath: String?,
        limits: OhMyPiThinkingSweepLimits,
        nextTarget: @escaping @Sendable () async -> String?,
        report: @escaping @Sendable (OhMyPiThinkingSweepEvent) async -> Void
    ) async throws {
        guard isAvailable() else {
            try await terminate(.cancelled(.availabilityLost), report: report)
        }

        let prepared: any OhMyPiThinkingCapabilityPreparedSession
        do {
            prepared = try await sessionFactory.prepare(
                workspacePath: workspacePath,
                limits: limits
            )
        } catch let abort as OhMyPiThinkingSweepAbort {
            if case let .terminal(terminal) = abort {
                try await terminate(terminal, report: report)
            }
            throw abort
        } catch {
            try await terminate(.preflightFailed(error.localizedDescription), report: report)
        }

        let capturedVersion = prepared.ompVersion
        guard runtimeVersionRegistry.currentVersion == capturedVersion else {
            try await terminate(.cancelled(.runtimeVersionChanged), report: report)
        }
        guard let firstTarget = await nextTarget() else {
            try await terminate(.completed, report: report)
        }

        let controller: any OhMyPiThinkingCapabilitySweepController
        do {
            controller = try prepared.makeController { record in
                _ = runtimeVersionRegistry.recordCapabilityIfCurrent(
                    record,
                    expectedVersion: capturedVersion
                )
            }
        } catch {
            try await terminate(.preflightFailed(error.localizedDescription), report: report)
        }

        var terminalReported = false
        do {
            do {
                try await controller.start()
            } catch {
                let reason = await controller.normalizedErrorDescription(error)
                terminalReported = true
                await report(.terminal(.bootstrapFailed(reason)))
                throw OhMyPiThinkingSweepAbort.terminal(.bootstrapFailed(reason))
            }

            guard runtimeVersionRegistry.currentVersion == capturedVersion else {
                terminalReported = true
                await report(.terminal(.cancelled(.runtimeVersionChanged)))
                throw OhMyPiThinkingSweepAbort.terminal(.cancelled(.runtimeVersionChanged))
            }
            await report(.bootstrapped(ompVersion: capturedVersion))

            let workStartedAt = now()
            var target: String? = firstTarget
            var consecutiveFailures = 0
            while let modelID = target {
                try Task.checkCancellation()
                guard isAvailable() else {
                    terminalReported = true
                    await report(.terminal(.cancelled(.availabilityLost)))
                    throw OhMyPiThinkingSweepAbort.terminal(.cancelled(.availabilityLost))
                }
                guard runtimeVersionRegistry.currentVersion == capturedVersion else {
                    terminalReported = true
                    await report(.terminal(.cancelled(.runtimeVersionChanged)))
                    throw OhMyPiThinkingSweepAbort.terminal(.cancelled(.runtimeVersionChanged))
                }
                guard now().timeIntervalSince(workStartedAt) < limits.workBudgetSeconds else {
                    terminalReported = true
                    await report(.terminal(.workBudgetExpired(current: modelID)))
                    throw OhMyPiThinkingSweepAbort.terminal(.workBudgetExpired(current: modelID))
                }

                if registry.snapshot(for: modelID)?.ompVersion == capturedVersion {
                    await report(.willSwitch(modelID))
                    await report(.switched(modelID, .cached, elapsed: 0))
                    consecutiveFailures = 0
                    target = await nextTarget()
                    continue
                }

                await report(.willSwitch(modelID))
                let switchStartedAt = now()
                do {
                    try await controller.setSessionModel(modelID)
                    guard runtimeVersionRegistry.currentVersion == capturedVersion else {
                        terminalReported = true
                        await report(.terminal(.cancelled(.runtimeVersionChanged)))
                        throw OhMyPiThinkingSweepAbort.terminal(.cancelled(.runtimeVersionChanged))
                    }
                    let result: OhMyPiThinkingSwitchResult =
                        registry.snapshot(for: modelID)?.ompVersion == capturedVersion
                            ? .loaded
                            : .unsupported
                    await report(.switched(
                        modelID,
                        result,
                        elapsed: now().timeIntervalSince(switchStartedAt)
                    ))
                    consecutiveFailures = 0
                } catch let abort as OhMyPiThinkingSweepAbort {
                    throw abort
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = await controller.normalizedErrorDescription(error)
                    await report(.switched(
                        modelID,
                        .failed(reason),
                        elapsed: now().timeIntervalSince(switchStartedAt)
                    ))
                    consecutiveFailures += 1
                    let classification = await controller.classifyConfigurationMutationFailure(error)
                    if classification == .sessionFatal ||
                        consecutiveFailures >= limits.consecutiveFailureLimit
                    {
                        terminalReported = true
                        await report(.terminal(.sessionFatal(current: modelID, reason: reason)))
                        throw OhMyPiThinkingSweepAbort.terminal(
                            .sessionFatal(current: modelID, reason: reason)
                        )
                    }
                }
                target = await nextTarget()
            }

            terminalReported = true
            await report(.terminal(.completed))
        } catch {
            if !terminalReported {
                await report(.terminal(.cancelled(.availabilityLost)))
            }
            await Self.shutdownOutsideCancellationSensitiveScope(controller)
            throw error
        }
        await Self.shutdownOutsideCancellationSensitiveScope(controller)
    }

    private func terminate(
        _ terminal: OhMyPiThinkingSweepTerminal,
        report: @escaping @Sendable (OhMyPiThinkingSweepEvent) async -> Void
    ) async throws -> Never {
        await report(.terminal(terminal))
        throw OhMyPiThinkingSweepAbort.terminal(terminal)
    }

    private static func shutdownOutsideCancellationSensitiveScope(
        _ controller: any OhMyPiThinkingCapabilitySweepController
    ) async {
        await runCancellationShielded {
            await controller.shutdown()
        }
    }

    private static func runCancellationShielded(
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        await Task.detached(priority: .utility, operation: operation).value
    }

    #if DEBUG
        static func testRunCancellationShieldedShutdown(
            _ operation: @escaping @Sendable () async -> Void
        ) async {
            await runCancellationShielded(operation)
        }
    #endif
}

package enum OhMyPiThinkingSweepTargets {
    package static func compute(
        wireIDs: [String],
        selectedRawModel: String?,
        recentlyInvalidated: Set<String> = []
    ) -> [String] {
        var seen = Set<String>()
        let normalized = wireIDs.compactMap { raw -> String? in
            let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty,
                  modelID.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame,
                  seen.insert(modelID).inserted
            else {
                return nil
            }
            return modelID
        }
        guard !normalized.isEmpty else { return [] }

        let inputs = normalized.enumerated().map {
            OhMyPiModelMenuProjector.Input(
                sourceID: "\($0.offset):\($0.element)",
                wireID: $0.element,
                displayName: $0.element
            )
        }
        let eligible = OhMyPiModelMenuProjector.project(inputs).allLeaves
            .filter(\.allowsThinkingAccessory)
            .map(\.wireID)
        let eligibleSet = Set(eligible)
        var ordered: [String] = []
        if let selected = selectedRawModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           eligibleSet.contains(selected)
        {
            ordered.append(selected)
        }
        ordered.append(contentsOf: eligible.filter {
            recentlyInvalidated.contains($0) && !ordered.contains($0)
        })
        ordered.append(contentsOf: eligible.filter { !ordered.contains($0) })
        return ordered
    }
}
