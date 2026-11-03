import Foundation

/// Cursor CLI provider for non-agent use (chat, Oracle, AI queries) backed by ACP.
/// Runs a fresh ACP session per request, switches to Cursor's official `ask` mode (prompt-only/no tools), and never injects RepoPrompt MCP/tools.
final class CursorCLIProvider: AIProvider {
    typealias HeadlessProviderFactory = @Sendable (_ config: CursorAgentConfig, _ workspacePath: String?) -> AnyHeadlessAgentProvider

    private let activeProviders = ActiveHeadlessAgentProviderStore<AnyHeadlessAgentProvider>()
    private let headlessProviderFactory: HeadlessProviderFactory

    init(
        mcpHost: any AgentMCPHosting,
        headlessProviderFactory: HeadlessProviderFactory? = nil
    ) {
        self.headlessProviderFactory = headlessProviderFactory ?? { config, workspacePath in
            AnyHeadlessAgentProvider(
                CursorACPHeadlessAgentProvider(config: config, mcpHost: mcpHost, workspacePath: workspacePath)
            )
        }
    }

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> CursorAgentConfig {
            makeHeadlessConfig(modelName: modelName)
        }

        func test_makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
            makeAgentMessage(from: aiMessage)
        }
    #endif

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens _: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let provider = headlessProviderFactory(
            Self.makeHeadlessConfig(modelName: cursorModelName(for: model)),
            nil
        )
        let message = makeAgentMessage(from: aiMessage)
        return try await HeadlessCLIStreamBridge.startStream(
            provider: provider,
            activeProviders: activeProviders,
            makeUpstream: {
                try await provider.streamAgentMessage(message, runID: nil)
            },
            dispose: { provider in
                await provider.dispose()
            }
        )
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
        let stream = try await streamMessage(aiMessage, model: model, maxTokens: maxTokens)
        return try await HeadlessCLIStreamBridge.complete(
            stream: stream,
            providerName: "Cursor",
            acceptance: .terminalOrNonemptyText,
            missingSuccessDetail: "Cursor returned no completion"
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

    private static func makeHeadlessConfig(modelName: String?) -> CursorAgentConfig {
        CursorAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            modelString: modelName,
            includeRepoPromptMCPServer: false,
            cleanupProjectMCPApproval: true,
            sessionModeID: CursorAgentConfig.promptOnlySessionModeID
        )
    }

    private static let noToolsSuffix = "\n\nIMPORTANT: Do not use any tools, function calls, or external commands. Respond with text only. Any tool invocation will cause task failure."

    private func makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
        let systemPrompt = aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentMessage(
            systemPrompt: systemPrompt.isEmpty ? systemPrompt : systemPrompt + Self.noToolsSuffix,
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

    private func cursorModelName(for model: AIModel) -> String? {
        guard model.providerType == .cursor else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
