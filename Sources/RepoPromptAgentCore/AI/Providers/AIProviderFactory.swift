import Foundation

class AIProviderFactory {
    static func createProvider(
        for providerType: AIProviderType,
        keyManager: KeyManager,
        mcpHost: any AgentMCPHosting,
        routingWaiter: MCPRoutingWaiter,
        codexAuthRecovery: any CodexManagedAuthRecovering,
        modelOverrides: any AIModelOverrideReading,
        ohMyPiConnectionState: @escaping OhMyPiCLIProvider.ConnectionStateProvider,
        ollamaURL: URL? = nil,
        azureConfiguration: AzureOpenAIConfiguration? = nil
    ) async throws -> AIProvider {
        // If Azure config is provided, skip key fetching
        if providerType == .azure, let config = azureConfiguration {
            return try await createProvider(
                for: providerType,
                key: "",
                mcpHost: mcpHost,
                routingWaiter: routingWaiter,
                codexAuthRecovery: codexAuthRecovery,
                modelOverrides: modelOverrides,
                ohMyPiConnectionState: ohMyPiConnectionState,
                ollamaURL: ollamaURL,
                azureConfiguration: config
            )
        }

        // CLI providers don't need API keys - they leverage existing authentication
        if providerType == .claudeCode || providerType == .codex || providerType == .openCode || providerType == .cursor || providerType == .ohMyPi {
            return try await createProvider(
                for: providerType,
                key: "",
                mcpHost: mcpHost,
                routingWaiter: routingWaiter,
                codexAuthRecovery: codexAuthRecovery,
                modelOverrides: modelOverrides,
                ohMyPiConnectionState: ohMyPiConnectionState,
                ollamaURL: ollamaURL,
                azureConfiguration: azureConfiguration
            )
        }

        guard let key = try await keyManager.getAPIKey(for: providerType) else {
            throw AIProviderError.missingAPIKey
        }
        return try await createProvider(
            for: providerType,
            key: key,
            mcpHost: mcpHost,
            routingWaiter: routingWaiter,
            codexAuthRecovery: codexAuthRecovery,
            modelOverrides: modelOverrides,
            ohMyPiConnectionState: ohMyPiConnectionState,
            ollamaURL: ollamaURL,
            azureConfiguration: azureConfiguration
        )
    }

    static func createProvider(
        for providerType: AIProviderType,
        key: String,
        mcpHost: any AgentMCPHosting,
        routingWaiter: MCPRoutingWaiter,
        codexAuthRecovery: any CodexManagedAuthRecovering,
        modelOverrides: any AIModelOverrideReading,
        ohMyPiConnectionState: @escaping OhMyPiCLIProvider.ConnectionStateProvider,
        ollamaURL: URL? = nil,
        azureConfiguration: AzureOpenAIConfiguration? = nil,
        model: String? = nil
    ) async throws -> AIProvider {
        switch providerType {
        case .anthropic:
            return AnthropicProvider(apiKey: key, modelOverrides: modelOverrides)
        case .openAI:
            let raw = UserDefaults.standard.string(forKey: "customBaseURLOpenAI")
            let split = OpenAIURLHelper.splitBaseURLAndVersion(raw)
            let baseURL = split.base
            let storedVersion = UserDefaults.standard.string(forKey: "customOpenAIVersionOverride")
            let finalVersion = storedVersion ?? split.version
            let serviceTier = UserDefaults.standard.string(forKey: "openAIServiceTier")
            return OpenAIProvider(apiKey: key, baseURL: baseURL, configuredMaxTokens: nil, overrideVersion: finalVersion, serviceTier: serviceTier, modelOverrides: modelOverrides)
        case .ollama:
            let baseURL = ollamaURL ?? URL(string: "http://localhost:11434")!
            return OllamaProvider(baseURL: baseURL, modelOverrides: modelOverrides)
        case .azure:
            guard let config = azureConfiguration else {
                return BlankProvider()
            }
            return AzureOpenAIProvider(configuration: config, modelOverrides: modelOverrides)
        case .openRouter:
            return OpenRouterProvider(apiKey: key, modelOverrides: modelOverrides)
        case .gemini:
            return GeminiProvider(apiKey: key, modelOverrides: modelOverrides)
        case .deepseek:
            return DeepSeekProvider(apiKey: key, modelOverrides: modelOverrides)
        case .fireworks: // <-- Add Fireworks case
            return FireworksProvider(apiKey: key, modelOverrides: modelOverrides)
        case .grok: // <-- Add Grok case
            return GrokProvider(apiKey: key, modelOverrides: modelOverrides)
        case .groq: // <-- Add Groq case
            return GroqProvider(apiKey: key, modelOverrides: modelOverrides)
        case .zAI:
            return ZAIProvider(apiKey: key, modelOverrides: modelOverrides)
        case .claudeCode: // <-- Add Claude Code case
            return try ClaudeCodeProvider()
        case .codex:
            // Standard non-agent Codex chat owns a fresh app-server client per request.
            return CodexCLIProvider(mcpHost: mcpHost, authRecovery: codexAuthRecovery)
        case .openCode:
            return OpenCodeCLIProvider(mcpHost: mcpHost)
        case .cursor:
            return CursorCLIProvider(mcpHost: mcpHost)
        case .ohMyPi:
            return OhMyPiCLIProvider(
                mcpHost: mcpHost,
                routingWaiter: routingWaiter,
                connectionStateProvider: ohMyPiConnectionState
            )
        case .customProvider:
            let config = try CustomProviderConfiguration.load()

            // The config should already have base URL (without version) and apiVersion split
            // Only do regex split as fallback for legacy configs
            let baseStr: String
            let version: String?

            if let storedVersion = config.apiVersion {
                // New config format: URL and version already split
                baseStr = config.url.hasSuffix("/") ? String(config.url.dropLast()) : config.url
                version = storedVersion
            } else {
                // Legacy fallback: config might still have version in URL
                let split = OpenAIURLHelper.splitBaseURLAndVersion(config.url)
                baseStr = split.base?.absoluteString ?? config.url
                version = split.version
            }

            // Read the configured maxTokens, defaulting as before
            var configuredMaxTokens = config.maxTokens ?? 8192
            if configuredMaxTokens == 0 {
                configuredMaxTokens = 2048
            }

            // Prefer the SwiftOpenAI-backed OpenAIProvider for any OpenAI-style API version: ^v\d+(...)? (e.g., v1, v1-beta, v4, v4.1, etc.)
            let openAIStyleVersion: Bool = {
                guard let v = version?.lowercased() else { return false }
                return v.range(of: #"^v\d+([A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil
            }()

            if openAIStyleVersion {
                guard let baseURL = URL(string: baseStr) else {
                    throw AIProviderError.missingURL
                }
                return OpenAIProvider(
                    apiKey: key,
                    baseURL: baseURL,
                    configuredMaxTokens: configuredMaxTokens,
                    overrideVersion: version,
                    includeUsageInStream: false,
                    modelOverrides: modelOverrides
                )
            }

            // Fallback: manual HTTP provider for exotic/custom formats
            return CustomOpenAIProvider(
                baseURL: baseStr,
                apiKey: key,
                defaultModel: config.defaultModel,
                defaultTemperature: 0, // Keep deterministic by default; configurable later if needed
                customHeaders: config.headers,
                configuredMaxTokens: configuredMaxTokens,
                includeContentTypeHeader: config.includeContentTypeHeader,
                apiVersion: version,
                modelOverrides: modelOverrides
            )
        }
    }
}

/// A minimal provider that always throws .providerNotConfigured
class BlankProvider: AIProvider {
    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIProviderError.providerNotConfigured)
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AICompletionResult {
        throw AIProviderError.providerNotConfigured
    }

    func dispose() async {}
}

package enum AIProviderType: Codable, Equatable {
    case anthropic
    case openAI
    case ollama
    case azure
    case openRouter
    case gemini
    case deepseek // <-- New deepseek provider case
    case customProvider
    case fireworks // <-- New fireworks provider case
    case grok // <-- New grok provider case
    case groq // <-- New groq provider case
    case zAI // <-- New Z.AI provider case
    case claudeCode // <-- New Claude Code provider case
    case codex // <-- New Codex CLI provider case
    case openCode // OpenCode CLI provider case
    case cursor // Cursor CLI provider case
    case ohMyPi // Oh My Pi CLI provider case
}

package extension AIProviderType {
    static func displayName(for provider: AIProviderType) -> String {
        switch provider {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .azure: "Azure"
        case .openRouter: "OpenRouter"
        case .ollama: "Local"
        case .deepseek: "DeepSeek"
        case .fireworks: "Fireworks"
        case .customProvider: "Custom"
        case .grok: "Grok (xAI)"
        case .groq: "Groq"
        case .zAI: "Z.AI"
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .openCode: "OpenCode"
        case .cursor: "Cursor CLI"
        case .ohMyPi: "Oh My Pi"
        }
    }

    var displayName: String {
        Self.displayName(for: self)
    }
}

package enum AIProviderError: Error {
    case missingOllamaURL
    case missingAzureConfiguration
    case missingAPIKey
    case missingURL
    case providerNotConfigured
    case invalidModel
    case invalidSystemPrompt
    case messageCreationFailed
    case invalidResponse(detail: String) // Add associated value 'detail'
    case invalidConfiguration(detail: String) // Added for configuration issues
    case apiError(source: Error?) // Added for underlying API errors
    case unknown(source: Error?) // Added for other unexpected errors
}

extension AIProviderError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .missingOllamaURL:
            "Missing Ollama URL."
        case .missingAzureConfiguration:
            "Missing Azure OpenAI configuration."
        case .missingAPIKey:
            "Missing API key."
        case .missingURL:
            "Missing provider URL."
        case .providerNotConfigured:
            "Provider is not configured."
        case .invalidModel:
            "Invalid model."
        case .invalidSystemPrompt:
            "Invalid system prompt."
        case .messageCreationFailed:
            "Failed to create provider message."
        case let .invalidResponse(detail), let .invalidConfiguration(detail):
            detail
        case let .apiError(source), let .unknown(source):
            source?.localizedDescription ?? String(describing: self)
        }
    }
}

/// Core-owned, optional-preserving raw usage observation carried alongside `AIStreamResult`.
///
/// Mirrors the provider observation without normalization: missing counts stay `nil` (never
/// zero), identity fields are copied from the raw envelope only, the raw cumulative cost
/// remains on `AIStreamResult.cost`, and the provider message id remains on the carrier's
/// `AIStreamResult.contentMessageID`. Legacy `promptTokens`/`completionTokens`/`contextUsedTokens`
/// semantics are unchanged by this companion.
struct AgentProviderUsageObservation: Equatable {
    enum Source: String, Equatable {
        case messageStart = "message_start"
        case messageDelta = "message_delta"
        case assistant
        case result
    }

    let source: Source
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    /// Reported model when the envelope carried one.
    let model: String?
    /// Top-level provider envelope id (Claude SDK `uuid`) when present.
    let envelopeID: String?
    /// Literal provider `request_id` when present; distinct from `envelopeID` and `contentMessageID`.
    let requestID: String?
    /// Non-null parent tool use id marks a sidechain/subagent observation.
    let parentToolUseID: String?
    /// Result subtype evidence for `.result` observations.
    let resultSubtype: String?
    /// Result error evidence for `.result` observations when reported.
    let resultIsError: Bool?
    /// Provider `result_index` (zero-based dispatch ordinal within the provider process) for
    /// `.result` observations. Transport evidence only; ownership is decided by the runtime.
    let resultIndex: Int?
    /// Provider `queued_turn_count` for `.result` observations when reported.
    let queuedTurnCount: Int?

    init(
        source: Source,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        model: String? = nil,
        envelopeID: String? = nil,
        requestID: String? = nil,
        parentToolUseID: String? = nil,
        resultSubtype: String? = nil,
        resultIsError: Bool? = nil,
        resultIndex: Int? = nil,
        queuedTurnCount: Int? = nil
    ) {
        self.source = source
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.model = model
        self.envelopeID = envelopeID
        self.requestID = requestID
        self.parentToolUseID = parentToolUseID
        self.resultSubtype = resultSubtype
        self.resultIsError = resultIsError
        self.resultIndex = resultIndex
        self.queuedTurnCount = queuedTurnCount
    }
}

/// Updated `AIStreamResult` to include optional `reasoning`, token counts, and tool metadata.
package struct AIStreamResult {
    /// Standard type strings for stream results
    package static let lifecycleType = "lifecycle"

    package let type: String // e.g. "content", "message_stop", "tool_call", "tool_result", "final_content", "lifecycle"
    package let text: String? // normal content (like streaming tokens)
    package let reasoning: String? // optional reasoning content
    package let promptTokens: Int? // token usage
    package let completionTokens: Int? // token usage
    let cost: Double?

    // Tool-specific metadata (for type: "tool_call" or "tool_result")
    package let toolName: String? // Name of the tool being called/completed
    package let toolArgs: String? // JSON string of tool arguments (for tool_call)
    package let toolOutput: String? // Tool execution result (for tool_result)
    package let toolInvocationID: UUID?
    package let toolResultJSON: String?
    package let toolArgsJSON: String?
    package let toolIsError: Bool?

    /// Provider-specific session ID for resuming conversations (e.g., Claude CLI session_id)
    package let providerSessionID: String?
    let stopReason: String?
    package let modelContextWindow: Int?
    /// Best-effort estimate of input-side context used for the turn (e.g. Claude input + cache tokens)
    package let contextUsedTokens: Int?
    /// Stable provider message identifier for content chunks when available.
    /// Used by lightweight aggregators to separate whole-message chunks without affecting token deltas.
    /// On `usage`/result `message_stop` carriers it identifies the message the `usageObservation`
    /// belongs to (`nil` when unidentified).
    package let contentMessageID: String?
    /// Raw provider usage observation for `usage` and result `message_stop` events when available.
    let usageObservation: AgentProviderUsageObservation?
    /// Step 4d3b (inactive): transient Claude live-identity evidence, set only by a qualified Claude
    /// native producer (`ClaudeLiveTranscriptProducerState`); `nil` everywhere else. Never encoded,
    /// logged or persisted; a rebuilt result drops it (fails closed: no identity).
    package var claudeLiveTranscriptEvidence: ClaudeLiveTranscriptEvidence?

    init(
        type: String,
        text: String?,
        reasoning: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil,
        toolName: String? = nil,
        toolArgs: String? = nil,
        toolOutput: String? = nil,
        toolInvocationID: UUID? = nil,
        toolResultJSON: String? = nil,
        toolArgsJSON: String? = nil,
        toolIsError: Bool? = nil,
        providerSessionID: String? = nil,
        stopReason: String? = nil,
        modelContextWindow: Int? = nil,
        contextUsedTokens: Int? = nil,
        contentMessageID: String? = nil,
        usageObservation: AgentProviderUsageObservation? = nil
    ) {
        self.type = type
        self.text = text
        self.reasoning = reasoning
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.toolOutput = toolOutput
        self.toolInvocationID = toolInvocationID
        self.toolResultJSON = toolResultJSON
        self.toolArgsJSON = toolArgsJSON
        self.toolIsError = toolIsError
        self.providerSessionID = providerSessionID
        self.stopReason = stopReason
        self.modelContextWindow = modelContextWindow
        self.contextUsedTokens = contextUsedTokens
        self.contentMessageID = contentMessageID
        self.usageObservation = usageObservation
    }
}

/// Result type for non-streaming completions, includes token counts
package struct AICompletionResult {
    package let text: String
    let promptTokens: Int?
    let completionTokens: Int?
    let cost: Double?

    init(text: String, promptTokens: Int? = nil, completionTokens: Int? = nil, cost: Double? = nil) {
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
    }
}

protocol AIProvider {
    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<AIStreamResult, Error>
    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AICompletionResult
    func dispose() async
}

protocol AIModelGetter {
    func getAvailableModels() async throws -> [String]
}

/// Default protocol extensions
extension AIProvider {
    func streamMessage(_ aiMessage: AIMessage, model: AIModel) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await streamMessage(aiMessage, model: model, maxTokens: nil)
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel) async throws -> AICompletionResult {
        try await completeMessage(aiMessage, model: model, maxTokens: nil)
    }

    func dispose() async {}
}
