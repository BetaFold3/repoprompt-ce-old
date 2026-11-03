import Foundation

/// OMP CLI provider for non-agent use (chat, Oracle, AI queries) backed by ACP.
///
/// Each request warms the persisted ACP registry, resolves the selected model to the
/// registry's canonical wire ID, and starts a fresh tool-free OMP session.
package final class OhMyPiCLIProvider: AIProvider {
    typealias HeadlessProviderFactory = @Sendable (_ config: OhMyPiAgentConfig, _ workspacePath: String?) -> AnyHeadlessAgentProvider
    typealias ModelSnapshotResolver = @Sendable () async -> ACPDiscoveredSessionModels?
    package typealias ConnectionStateProvider = @Sendable () -> Bool

    private let activeProviders = ActiveHeadlessAgentProviderStore<AnyHeadlessAgentProvider>()
    private let headlessProviderFactory: HeadlessProviderFactory
    private let modelSnapshotResolver: ModelSnapshotResolver
    private let connectionStateProvider: ConnectionStateProvider

    init(
        mcpHost: any AgentMCPHosting,
        routingWaiter: MCPRoutingWaiter,
        headlessProviderFactory: HeadlessProviderFactory? = nil,
        modelSnapshotResolver: @escaping ModelSnapshotResolver = {
            await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .ohMyPi)
        },
        connectionStateProvider: @escaping ConnectionStateProvider
    ) {
        self.headlessProviderFactory = headlessProviderFactory ?? { config, workspacePath in
            AnyHeadlessAgentProvider(
                OhMyPiACPHeadlessAgentProvider(
                    config: config,
                    mcpHost: mcpHost,
                    routingWaiter: routingWaiter,
                    workspacePath: workspacePath
                )
            )
        }
        self.modelSnapshotResolver = modelSnapshotResolver
        self.connectionStateProvider = connectionStateProvider
    }

    #if DEBUG
        static func test_makeHeadlessConfig(
            modelName: String,
            additionalConfigOptionValues: [ACPConfigOptionAssignment] = []
        ) -> OhMyPiAgentConfig {
            makeHeadlessConfig(
                modelName: modelName,
                additionalConfigOptionValues: additionalConfigOptionValues
            )
        }

        func test_makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
            makeAgentMessage(from: aiMessage)
        }
    #endif

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens _: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let snapshot = await modelSnapshotResolver()
        guard connectionStateProvider() else {
            throw AIProviderError.invalidConfiguration(
                detail: "Oh My Pi is disconnected. Connect Oh My Pi in Settings before using this Oracle model."
            )
        }

        let requestedModel = try requestedModelName(for: model)
        guard let canonicalOption = snapshot?.options.first(where: {
            $0.rawValue.caseInsensitiveCompare(requestedModel) == .orderedSame
        }) else {
            throw AIProviderError.invalidConfiguration(
                detail: "Oh My Pi model '\(requestedModel)' is no longer available upstream. Refresh models or choose another Oracle model."
            )
        }

        let canonicalModel = canonicalOption.rawValue
        let provider = headlessProviderFactory(
            Self.makeHeadlessConfig(
                modelName: canonicalModel,
                additionalConfigOptionValues: aiMessage.executionMetadata.additionalACPConfigOptionValues
            ),
            nil
        )
        let message = makeAgentMessage(from: aiMessage)
        let stream = try await HeadlessCLIStreamBridge.startStream(
            provider: provider,
            activeProviders: activeProviders,
            makeUpstream: {
                try await provider.streamAgentMessage(message, runID: nil)
            },
            dispose: { provider in
                await provider.dispose()
            }
        )
        return Self.validatedStream(stream)
    }

    func completeMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int? = nil
    ) async throws -> AICompletionResult {
        let stream = try await streamMessage(aiMessage, model: model, maxTokens: maxTokens)
        return try await HeadlessCLIStreamBridge.complete(
            stream: stream,
            providerName: "Oh My Pi",
            acceptance: .terminalRequired
        )
    }

    func dispose() async {
        await HeadlessCLIStreamBridge.disposeAll(
            activeProviders: activeProviders,
            dispose: { provider in
                await provider.dispose()
            }
        )
    }

    private static func validatedStream(
        _ upstream: AsyncThrowingStream<AIStreamResult, Error>
    ) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let validationTask = Task {
                var sawMessageStop = false
                do {
                    for try await result in upstream {
                        switch result.type {
                        case "message_stop":
                            sawMessageStop = true
                            continuation.yield(result)
                        case "error":
                            throw AIProviderError.invalidConfiguration(
                                detail: result.text ?? "Oh My Pi ACP reported an error"
                            )
                        case "tool_call", "tool_result", "tool_progress":
                            throw AIProviderError.invalidResponse(
                                detail: HeadlessCLIStreamBridge.toolEventRejectedDetail
                            )
                        default:
                            continuation.yield(result)
                        }
                    }
                    guard sawMessageStop else {
                        throw AIProviderError.invalidResponse(
                            detail: "Oh My Pi returned no successful completion"
                        )
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                validationTask.cancel()
            }
        }
    }

    private static func makeHeadlessConfig(
        modelName: String,
        additionalConfigOptionValues: [ACPConfigOptionAssignment]
    ) -> OhMyPiAgentConfig {
        OhMyPiAgentConfig(
            modelString: modelName,
            additionalConfigOptionValues: additionalConfigOptionValues,
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false
        )
    }

    private static let noToolsSuffix = "IMPORTANT: Do not use any tools, function calls, or external commands. Respond with text only. Any tool invocation will cause task failure."

    private func makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
        let systemPrompt = aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolFreeSystemPrompt = systemPrompt.isEmpty
            ? Self.noToolsSuffix
            : systemPrompt + "\n\n" + Self.noToolsSuffix
        return AgentMessage(
            systemPrompt: toolFreeSystemPrompt,
            userMessage: buildPrompt(from: aiMessage),
            resumeSessionID: nil
        ).withRuntimeSession(.sessionless) // Chat (Oracle) work is not an Agent Mode session.
    }

    private func buildPrompt(from aiMessage: AIMessage) -> String {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        var conversation = ""
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        for (index, message) in aiMessage.conversationMessages.enumerated() {
            var text = message.content
            if message.role == .user,
               index == lastUserIndex,
               !tail.isEmpty
            {
                text = tail + "\n\n" + text
            }
            let prefix = message.role == .user ? "User" : "Assistant"
            if !conversation.isEmpty {
                conversation += "\n\n"
            }
            conversation += "\(prefix): \(text)"
        }
        if aiMessage.conversationMessages.isEmpty, !tail.isEmpty {
            conversation = "User: \(tail)"
        }
        return conversation
    }

    private func requestedModelName(for model: AIModel) throws -> String {
        guard case let .ohMyPiCustom(name) = model else {
            throw AIProviderError.invalidConfiguration(
                detail: "The selected Oracle model is not an Oh My Pi model."
            )
        }
        guard !name.isEmpty else {
            throw AIProviderError.invalidConfiguration(
                detail: "The selected Oh My Pi Oracle model is empty."
            )
        }
        return name
    }
}
