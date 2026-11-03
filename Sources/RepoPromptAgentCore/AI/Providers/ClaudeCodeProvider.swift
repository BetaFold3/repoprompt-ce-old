import Foundation
import RepoPromptPlatform

struct ClaudeCodeCLIModelSelection: Equatable {
    let modelArgument: String?
    let effortLevel: ClaudeCodeEffortLevel?
}

struct ClaudeCLIOptions {
    var printMode: Bool = true
    var verbose: Bool = false
    var maxTurns: Int?
    var allowedTools: [String] = []
    var disallowedTools: [String] = []
    var permissionMode: String?
    var permissionPromptToolName: String?
    var model: String?
    var effortLevel: ClaudeCodeEffortLevel?
    var mcpConfigPath: String?
    var systemPromptOverride: String?
    var timeout: TimeInterval?
    var environmentOverrides: [String: String] = [:]
    var removedEnvironmentKeys: Set<String> = []
    /// The actual Claude provider this launch reaches (runtime ownership only; never an argument).
    var runtimeVariant: ClaudeCodeRuntimeVariant = .standard

    var additionalEnvironment: [String: String] {
        var environment = environmentOverrides
        if let effortLevel {
            environment["CLAUDE_CODE_EFFORT_LEVEL"] = effortLevel.envValue
        }
        return environment
    }

    func toTokens() -> [String] {
        var tokens: [String] = []
        if printMode { tokens.append("-p") }
        if verbose { tokens.append("--verbose") }
        if let maxTurns { tokens.append(contentsOf: ["--max-turns", String(maxTurns)]) }
        if !allowedTools.isEmpty { tokens.append(contentsOf: ["--allowedTools", allowedTools.joined(separator: ",")]) }
        if !disallowedTools.isEmpty { tokens.append(contentsOf: ["--disallowedTools", disallowedTools.joined(separator: ",")]) }
        if let permissionPromptToolName { tokens.append(contentsOf: ["--permission-prompt-tool", permissionPromptToolName]) }
        if let permissionMode { tokens.append(contentsOf: ["--permission-mode", permissionMode]) }
        if let model { tokens.append(contentsOf: ["--model", model]) }
        if let systemPromptOverride { tokens.append(contentsOf: ["--system-prompt", systemPromptOverride]) }
        if let mcpConfigPath {
            tokens.append(contentsOf: ["--mcp-config", mcpConfigPath])
            // Use strict mode to ignore project-level MCP configs from ~/.claude.json
            // This prevents the CLI from trying to start stale MCP servers based on working directory
            tokens.append("--strict-mcp-config")
        }
        return tokens
    }
}

package final class ClaudeCodeProvider: AIProvider {
    /// Output format for every print-mode launch. The configured Claude executable or shim
    /// classifies `-p` + `--output-format stream-json` without a session ID as managed new
    /// work; any other print shape may take a different authentication path.
    static let printModeOutputFormat: CLIOutputFormat = .streamJson

    /// Flags that would route a print-mode launch to a different branch of a configured
    /// Claude executable or shim (session resumption, continuation, bare mode, or
    /// stream-json input). Oracle print-mode launches never pass them.
    static let forbiddenPrintModeFlags: Set<String> = [
        "--session-id",
        "--resume",
        "-r",
        "--continue",
        "-c",
        "--fork-session",
        "--bare",
        "--input-format"
    ]

    private let runner: CLIProcessRunner
    private let decoder: JSONDecoder
    private let configService = MCPConfigExportService.shared
    private let commandSelection: CLICommandSelection
    private let launchEnvironmentResolverOverride: (any ClaudeCodeLaunchEnvironmentResolving)?
    private let disallowedTools: [String] = [
        "Bash",
        "BashOutput",
        "KillShell",
        "Monitor",
        "Read",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "Task",
        // `Agent` is Claude Code's native child-agent tool; `Task` is its legacy alias.
        "Agent",
        "TaskOutput",
        "TaskStop",
        "WebFetch",
        "WebSearch",
        "SlashCommand",
        "NotebookEdit",
        "TodoWrite",
        "EnterPlanMode",
        "ExitPlanMode",
        "EnterWorktree",
        "ExitWorktree",
        "Skill",
        "CronCreate",
        "CronDelete",
        "CronList",
        "RemoteTrigger",
        "AskUserQuestion",
        "ScheduleWakeup",
        "PushNotification"
    ]

    private let defaultRequestTimeout: TimeInterval
    private let testRequestTimeout: TimeInterval
    private let maxRetries: Int
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval = 8.0
    /// R6 launch ownership for print-mode launches (a managed AgentCore provider caller).
    private let launchAuthority: AgentRuntimeLaunchAuthority
    private let launchWorktreePath: String?

    /// - Parameters:
    ///   - launchEnvironmentResolver: Resolves compatible-backend launch environments. `nil`
    ///     builds the production resolver lazily, only when a compatible backend is used.
    ///   - initialRetryBackoff: First transient-failure backoff in seconds (default 1).
    package init(
        workingDirectory: String? = nil,
        enableDebugLogging: Bool = false,
        defaultRequestTimeout: TimeInterval? = nil,
        testRequestTimeout: TimeInterval? = nil,
        maxRetries: Int? = nil,
        logCollector: CLIProcessLogCollector? = nil,
        defaults: UserDefaults = .standard,
        launchEnvironmentResolver: (any ClaudeCodeLaunchEnvironmentResolving)? = nil,
        initialRetryBackoff: TimeInterval? = nil,
        launchAuthority: AgentRuntimeLaunchAuthority = .production
    ) throws {
        self.launchAuthority = launchAuthority
        launchWorktreePath = workingDirectory
        let commandSelection = try CLIExecutableOverrideStore.effectiveCommand(
            for: CLILaunchProfiles.claudeCode,
            defaults: defaults
        )
        self.commandSelection = commandSelection
        launchEnvironmentResolverOverride = launchEnvironmentResolver
        initialBackoff = max(0, initialRetryBackoff ?? 1.0)
        var config = CLIProcessConfiguration(
            command: commandSelection.command,
            validationCommandName: CLILaunchProfiles.claudeCode.commandName,
            commandSelection: commandSelection,
            workingDirectory: workingDirectory,
            captureStdoutTailBytes: 128 * 1024,
            captureStderrTailBytes: 256 * 1024
        )
        config.enableDebugLogging = enableDebugLogging
        config.logCollector = logCollector
        config.ensureAdditionalPaths(CLIPathHints.claudeCode)
        runner = CLIProcessRunner(config: config)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let resolvedDefaultTimeout = defaultRequestTimeout ?? 6000
        let resolvedTestTimeout = testRequestTimeout ?? 30
        let resolvedRetries = maxRetries ?? 2

        self.defaultRequestTimeout = resolvedDefaultTimeout
        self.testRequestTimeout = resolvedTestTimeout
        self.maxRetries = resolvedRetries
    }

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let completion = try await completeMessage(aiMessage, model: model, maxTokens: maxTokens)
        return AsyncThrowingStream { continuation in
            continuation.yield(AIStreamResult(type: "content", text: completion.text))
            continuation.yield(
                AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    reasoning: nil,
                    promptTokens: completion.promptTokens,
                    completionTokens: completion.completionTokens,
                    cost: completion.cost
                )
            )
            continuation.finish()
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
        let nativePromptMode = ClaudeAgentToolPreferences.agentModePromptDelivery()
        let basePrompt = buildPrompt(from: aiMessage)
        let prompt = nativePromptMode.sendsRepoPromptAsUserMessage
            ? ClaudeCodePromptDelivery.decoratedUserMessage(basePrompt, instructions: aiMessage.systemPrompt)
            : basePrompt
        let emptyConfigLease = try await configService.prepareEmptyLaunchConfig()
        defer { emptyConfigLease.release() }
        var options = try await makeOptions(for: aiMessage, model: model, emptyConfigURL: emptyConfigLease.url)
        options.systemPromptOverride = nativePromptMode.nativeSystemPromptOverride(instructions: aiMessage.systemPrompt)
        if options.timeout == nil {
            options.timeout = defaultRequestTimeout
        }

        var attempt = 0
        var delay = initialBackoff

        while true {
            // A cancelled request never starts another attempt.
            try Task.checkCancellation()
            let result = try await runPrintMode(
                options: options,
                stdin: prompt,
                additionalEnvironment: options.additionalEnvironment,
                removedEnvironmentKeys: options.removedEnvironmentKeys
            )

            if result.status == 0 {
                guard !result.stdout.isEmpty else {
                    throw AIProviderError.invalidResponse(detail: "Claude CLI returned no output")
                }
                let output: PrintModeOutput
                do {
                    output = try decodePrintModeOutput(result.stdout)
                } catch let error as AIProviderError {
                    throw error
                } catch {
                    throw AIProviderError.apiError(source: error)
                }
                switch output {
                case let .completion(completion):
                    return completion
                case let .errorResult(detail):
                    // An error result is surfaced immediately and never retried.
                    throw Self.stdoutRefusalError(detail, commandSelection: commandSelection)
                        ?? AIProviderError.invalidConfiguration(detail: detail)
                }
            }

            // Errors the CLI reports on stdout are surfaced immediately and never retried.
            if let humanMessage = extractCLIErrorDetail(fromStdout: result.stdout) {
                throw Self.stdoutRefusalError(humanMessage, commandSelection: commandSelection)
                    ?? Self.cliReportedError(humanMessage)
            }

            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            let failureKind = Self.classifyPrintFailure(stderr: stderrString, timedOut: result.timedOut)

            if failureKind.isRetryable, attempt < maxRetries {
                let jitter = Double.random(in: 0.8 ... 1.2)
                let sleepSeconds = max(0, min(delay, maxBackoff) * jitter)
                // Propagates cancellation: a request cancelled during backoff ends here.
                try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                delay = min(delay * 2, maxBackoff)
                attempt += 1
                continue
            }

            throw mapProcessFailure(exitCode: result.status, stderr: stderrString, timedOut: result.timedOut, timeoutValue: options.timeout)
        }
    }

    package func dispose() async {
        await runner.cancelAll()
    }

    // MARK: - Print-mode launch

    /// Arguments shared by every print-mode launch: Oracle completion, the standard connection
    /// test, and the compatible-backend connection test. They must match so "Test connection"
    /// exercises the same authentication path Oracle uses. The runner appends
    /// `--output-format stream-json`; the prompt always travels on stdin as plain text.
    static func printModeArguments(for options: ClaudeCLIOptions) -> [String] {
        var options = options
        options.printMode = true
        // The Claude CLI rejects `--output-format stream-json` in print mode without `--verbose`.
        options.verbose = true
        return options.toTokens()
    }

    private func runPrintMode(
        options: ClaudeCLIOptions,
        stdin: String,
        additionalEnvironment: [String: String],
        removedEnvironmentKeys: Set<String>
    ) async throws -> CLIProcessRunner.Result {
        // Each attempt is its own runtime; print mode never resumes a provider conversation.
        // Oracle and connection tests are not Agent Mode sessions: explicitly sessionless.
        let launch = launchAuthority.makeLaunch(AgentRuntimeLaunchContext(
            family: .claudeHeadless,
            provider: .claude(options.runtimeVariant),
            session: .sessionless,
            worktreePath: launchWorktreePath,
            permission: .claude(permissionMode: options.permissionMode)
        ))
        let result: CLIProcessRunner.Result
        do {
            result = try await runner.run(
                args: Self.printModeArguments(for: options),
                stdin: stdin,
                outputMode: .auto(Self.printModeOutputFormat),
                timeout: options.timeout,
                additionalEnvironment: additionalEnvironment,
                // Managed launch boundary: an inherited runtime marker never reaches the child.
                additionalRemovedKeys: removedEnvironmentKeys.union([ProcessLauncher.runtimeMarkerEnvironmentKey]),
                cancelChildOnTaskCancellation: true,
                launchOwnership: launch
            )
        } catch {
            throw mapProcessError(error)
        }
        // R6: the fresh conversation the CLI reports is recorded for this runtime; a failure is
        // reported by the launch and never changes the result.
        if let launch, let observed = Self.observedPrintModeSessionID(result.stdout) {
            await launch.recordObservedConversation(observed)
        }
        return result
    }

    /// The Claude session the print-mode output reports (`session_id` on its stream-json lines).
    static func observedPrintModeSessionID(_ data: Data) -> String? {
        for object in cliJSONObjects(from: data).objects.reversed() {
            let dictionary = object.dictionary
            let raw = dictionary["session_id"] as? String ?? dictionary["sessionId"] as? String
            if let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func launchEnvironmentResolver() -> any ClaudeCodeLaunchEnvironmentResolving {
        launchEnvironmentResolverOverride ?? ClaudeCodeLaunchEnvironmentResolver()
    }

    // MARK: - Private Helpers

    static func resolveCLIModelSelection(for model: AIModel) throws -> ClaudeCodeCLIModelSelection {
        guard model.providerType == .claudeCode else {
            throw AIProviderError.invalidModel
        }
        if case .claudeCodeModel = model,
           AIModel.fromModelName(model.rawValue) != model
        {
            throw AIProviderError.invalidModel
        }
        guard let rawSpecifier = model.claudeCodeRuntimeSpecifierRaw else {
            return ClaudeCodeCLIModelSelection(modelArgument: nil, effortLevel: nil)
        }
        let specifier = ClaudeModelSpecifier(raw: rawSpecifier)
        guard let runtimeModel = specifier.runtimeModelParam else {
            throw AIProviderError.invalidModel
        }
        return ClaudeCodeCLIModelSelection(
            modelArgument: runtimeModel,
            effortLevel: specifier.explicitEffortLevel
        )
    }

    private func makeOptions(for aiMessage: AIMessage, model: AIModel, emptyConfigURL: URL) async throws -> ClaudeCLIOptions {
        var options = ClaudeCLIOptions()
        options.disallowedTools = disallowedTools
        // Use empty MCP config to prevent CLI from loading user's default config (which may include RepoPrompt)
        options.mcpConfigPath = emptyConfigURL.path
        if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) {
            let launchEnvironment = try await launchEnvironmentResolver().resolve(
                variant: Self.runtimeVariant(for: descriptor.backendID),
                requestedModel: descriptor.requestedModelRaw
            )
            options.model = launchEnvironment.effectiveModel
            options.environmentOverrides = launchEnvironment.environmentOverrides
            options.removedEnvironmentKeys = launchEnvironment.removedEnvironmentKeys
            options.runtimeVariant = Self.runtimeVariant(for: descriptor.backendID)
            options.timeout = defaultRequestTimeout
            return options
        }
        let selection = try Self.resolveCLIModelSelection(for: model)
        options.model = selection.modelArgument
        options.effortLevel = selection.effortLevel
        options.timeout = defaultRequestTimeout
        return options
    }

    private func mapProcessError(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if let runnerError = error as? CLIProcessRunnerError {
            switch runnerError {
            case .explicitCommandNotLaunchable:
                return AIProviderError.invalidConfiguration(detail: runnerError.localizedDescription)
            case let .commandNotFound(command):
                return AIProviderError.invalidConfiguration(detail: "Command not found: \(command)")
            case let .spawnFailed(message):
                return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
            case .inputEncodingFailed:
                return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode prompt for Claude CLI"]))
            case let .inputWriteFailed(message):
                return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -3, userInfo: [NSLocalizedDescriptionKey: message]))
            case let .waitFailed(message):
                return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -4, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
        return AIProviderError.apiError(source: error)
    }

    // MARK: - Failure classification

    /// Classification of a non-zero print-mode exit whose stdout carried no CLI error.
    enum PrintFailureKind: Equatable {
        case timedOut
        /// The configured executable or shim refused to admit the request (for example, a
        /// rotator shim failing closed because no managed account is eligible).
        case admissionRefused
        case authentication
        case missingExecutable
        case rateLimited
        case overloaded
        /// Server (5xx/gateway) or network failures.
        case transient
        case unclassified

        var isRetryable: Bool {
            switch self {
            case .timedOut, .rateLimited, .overloaded, .transient:
                true
            case .admissionRefused, .authentication, .missingExecutable, .unclassified:
                false
            }
        }
    }

    private static let admissionRefusalMarkers = [
        "claude-rotator",
        "rotator shim",
        "not eligible",
        "no eligible",
        "is eligible",
        "eligible for new work",
        "usage limit",
        "usage credits",
        "credits are exhausted",
        "overage spend",
        "fail closed",
        "fails closed",
        "failed closed",
        "failing closed",
        "not managed",
        "managed account",
        "account is blocked",
        "accounts are blocked"
    ]

    private static let authenticationMarkers = [
        "unauthorized",
        "not authenticated",
        "authentication",
        "invalid api key",
        "invalid x-api-key",
        "not logged in",
        "run /login",
        "login required",
        "oauth token",
        "invalid bearer",
        "forbidden",
        "credential"
    ]

    private static let missingExecutableMarkers = [
        "no such file or directory",
        "command not found"
    ]

    private static let rateLimitMarkers = [
        "429",
        "rate limit",
        "rate-limit",
        "ratelimit",
        "too many requests"
    ]

    private static let overloadMarkers = [
        "overload",
        "busy",
        "529"
    ]

    private static let transientMarkers = [
        "500 internal",
        "internal server error",
        "502",
        "503",
        "504",
        "bad gateway",
        "service unavailable",
        "gateway",
        "timeout",
        "timed out",
        "etimedout",
        "context deadline exceeded",
        "econnreset",
        "connection reset",
        "socket hang up",
        "network",
        "unreachable"
    ]

    /// Classifies a failed print-mode launch from its stderr. Explicit admission and
    /// authentication refusals take precedence over transient substrings, so a shim that fails
    /// closed (stderr, exit 1) is surfaced at once even if its text mentions limits or 429s.
    /// There is no blanket exit-code retry: unmatched failures are not retried.
    static func classifyPrintFailure(stderr: String, timedOut: Bool) -> PrintFailureKind {
        if timedOut { return .timedOut }
        let lower = stderr.lowercased()
        func matches(_ markers: [String]) -> Bool {
            markers.contains { lower.contains($0) }
        }
        if matches(admissionRefusalMarkers) { return .admissionRefused }
        if matches(authenticationMarkers) { return .authentication }
        if matches(missingExecutableMarkers) { return .missingExecutable }
        if matches(rateLimitMarkers) { return .rateLimited }
        if matches(overloadMarkers) { return .overloaded }
        if matches(transientMarkers) { return .transient }
        return .unclassified
    }

    private func mapProcessFailure(exitCode: Int32, stderr: String, timedOut: Bool, timeoutValue: TimeInterval?) -> Error {
        Self.processFailureError(
            exitCode: exitCode,
            stderr: stderr,
            timedOut: timedOut,
            timeoutSeconds: Int(timeoutValue ?? defaultRequestTimeout),
            commandSelection: commandSelection
        )
    }

    /// Maps a failed print-mode launch to a user-facing error. When the executable came from an
    /// override, authentication, admission, and launch failures name that executable and show a
    /// short redacted stderr excerpt; they never suggest a separate `claude login`. Every stderr
    /// fragment surfaced here is a bounded, credential-redacted excerpt.
    static func processFailureError(
        exitCode: Int32,
        stderr: String,
        timedOut: Bool,
        timeoutSeconds: Int,
        commandSelection: CLICommandSelection
    ) -> Error {
        let executable = configuredExecutable(in: commandSelection)
        let kind = classifyPrintFailure(stderr: stderr, timedOut: timedOut)
        if let executable,
           let refusal = configuredExecutableRefusal(kind, executable: executable, diagnostic: stderr)
        {
            return refusal
        }
        switch kind {
        case .timedOut:
            return AIProviderError.invalidConfiguration(detail: "Claude Code timed out after \(timeoutSeconds)s. Servers may be busy—please try again.")
        case .admissionRefused:
            return AIProviderError.invalidConfiguration(detail: "Claude Code refused the request: \(diagnosticExcerpt(stderr))")
        case .authentication:
            return AIProviderError.invalidConfiguration(detail: "Claude Code is not authenticated. Please run `claude login` in your terminal.")
        case .missingExecutable:
            if let executable {
                return AIProviderError.invalidConfiguration(detail: "The configured Claude executable (\(executable)) failed to run: \(diagnosticExcerpt(stderr))")
            }
            return AIProviderError.invalidConfiguration(detail: "Claude CLI is not installed or not in PATH. Install it and run `claude login`.")
        case .rateLimited:
            return AIProviderError.invalidConfiguration(detail: "Rate limited by Anthropic. We tried retries—please wait a moment and try again.")
        case .overloaded:
            return AIProviderError.invalidConfiguration(detail: "Anthropic servers look overloaded. We attempted automatic retries; please try again shortly.")
        case .transient, .unclassified:
            let description = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Claude Code failed (exit \(exitCode))."
                : diagnosticExcerpt(stderr)
            return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: description]))
        }
    }

    /// The executable path or command from a CLI override, or nil for automatic resolution.
    private static func configuredExecutable(in commandSelection: CLICommandSelection) -> String? {
        switch commandSelection {
        case let .configuredExactPath(path):
            path
        case let .programmaticOverride(command):
            command
        case .automatic:
            nil
        }
    }

    /// Override-aware copy for an authentication or admission refusal from a configured executable,
    /// whether the refusal arrived on stderr or as a stdout error. It names the executable, shows
    /// only a bounded redacted excerpt, and never suggests a separate `claude login`. Nil for any
    /// other failure kind.
    private static func configuredExecutableRefusal(
        _ kind: PrintFailureKind,
        executable: String,
        diagnostic: String
    ) -> AIProviderError? {
        switch kind {
        case .admissionRefused:
            .invalidConfiguration(detail: "The configured Claude executable (\(executable)) refused the request: \(diagnosticExcerpt(diagnostic))")
        case .authentication:
            .invalidConfiguration(detail: "Claude Code could not authenticate through the configured executable (\(executable)): \(diagnosticExcerpt(diagnostic)) Oracle and Agent Mode both sign in through this executable; check its own account setup.")
        case .timedOut, .missingExecutable, .rateLimited, .overloaded, .transient, .unclassified:
            nil
        }
    }

    /// A positively classified authentication or admission refusal the CLI reported on stdout (the
    /// error text of a non-zero exit, or an `is_error` result at any exit status), else nil. With an
    /// override it gets the same configured-executable copy as a stderr refusal; otherwise the
    /// CLI's own credential-redacted text is kept. Callers surface it once: no retry, and no
    /// connection-test fallback model.
    static func stdoutRefusalError(_ detail: String, commandSelection: CLICommandSelection) -> AIProviderError? {
        let kind = classifyPrintFailure(stderr: detail, timedOut: false)
        guard kind == .authentication || kind == .admissionRefused else { return nil }
        if let executable = configuredExecutable(in: commandSelection) {
            return configuredExecutableRefusal(kind, executable: executable, diagnostic: detail)
        }
        return .invalidConfiguration(detail: redactingCredentials(detail))
    }

    private static let diagnosticExcerptLimit = 300

    private struct TextRedaction {
        let pattern: NSRegularExpression
        let template: String

        func apply(to text: String) -> String {
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
    }

    /// Credential-shaped substrings only: Anthropic keys and OAuth tokens, bearer values, and
    /// secret-named assignments whose value looks like a token (8+ token characters).
    private static let credentialRedactions: [TextRedaction] = [
        TextRedaction(
            pattern: try! NSRegularExpression(pattern: #"sk-ant-[A-Za-z0-9_\-]+"#),
            template: "sk-ant-<redacted>"
        ),
        TextRedaction(
            pattern: try! NSRegularExpression(pattern: #"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=\-]+"#),
            template: "$1 <redacted>"
        ),
        TextRedaction(
            pattern: try! NSRegularExpression(
                pattern: #"(?i)\b([A-Za-z0-9_]*(?:token|secret|password|api_key|apikey)[A-Za-z0-9_]*)\s*[=:]\s*["']?[A-Za-z0-9._~+/=\-]{8,}["']?"#
            ),
            template: "$1=<redacted>"
        )
    ]

    /// Long opaque runs; applied only to short diagnostic excerpts, never to stdout error text that
    /// is surfaced as supplied.
    private static let opaqueRunRedaction = TextRedaction(
        pattern: try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-+=]{40,}"#),
        template: "<redacted>"
    )

    /// Returns `text` as supplied except for credential-shaped substrings.
    static func redactingCredentials(_ text: String) -> String {
        credentialRedactions.reduce(text) { partial, redaction in redaction.apply(to: partial) }
    }

    /// A short, single-line diagnostic excerpt with credential-like values and long opaque runs
    /// redacted. Every raw stderr/stdout fragment surfaced in an error goes through this.
    static func diagnosticExcerpt(_ diagnostic: String) -> String {
        var text = diagnostic
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return "(no error output)" }
        text = opaqueRunRedaction.apply(to: redactingCredentials(text))
        if text.count > diagnosticExcerptLimit {
            text = String(text.prefix(diagnosticExcerptLimit)) + "…"
        }
        return text
    }

    static func diagnosticExcerpt(_ diagnostic: Data) -> String {
        diagnosticExcerpt(String(decoding: diagnostic, as: UTF8.self))
    }

    /// Maps a human-readable error the CLI reported on stdout.
    private static func cliReportedError(_ humanMessage: String) -> AIProviderError {
        let lowerMessage = humanMessage.lowercased()
        if lowerMessage.contains("credit balance") || lowerMessage.contains("balance too low") || lowerMessage.contains("api balance") {
            return AIProviderError.invalidConfiguration(detail: "Credit balance is too low. To use Claude Code with your Max plan via RepoPrompt, remove the ANTHROPIC_API_KEY from your environment variables and restart the app. The CLI will then use your Max plan subscription instead of the API key.")
        }
        return AIProviderError.invalidConfiguration(detail: humanMessage)
    }

    private func buildPrompt(from aiMessage: AIMessage) -> String {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        var prompt = ""
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        for (index, message) in aiMessage.conversationMessages.enumerated() {
            if !prompt.isEmpty {
                prompt += "\n\n"
            }
            if message.role == .user {
                if index == lastUserIndex, !tail.isEmpty {
                    prompt += "User: \(tail)\n\n\(message.content)"
                } else {
                    prompt += "User: \(message.content)"
                }
            } else {
                prompt += "Assistant: \(message.content)"
            }
        }
        if aiMessage.conversationMessages.isEmpty, !tail.isEmpty {
            prompt = "User: \(tail)"
        }
        return prompt
    }

    // MARK: - Output parsing

    /// One top-level JSON object from Claude CLI stdout. `data` holds the exact bytes of a
    /// stream-json line or whole-buffer object so the typed decoder can run on them.
    struct CLIJSONObject {
        let dictionary: [String: Any]
        let data: Data?
    }

    enum CLIOutputDocument {
        /// The whole buffer parsed as one JSON value (legacy `--output-format json`).
        case document(Any)
        /// Newline-delimited stream-json; only lines that parsed as JSON objects are kept.
        case lines
    }

    /// Splits fully buffered Claude CLI stdout into top-level JSON objects. A buffer that parses
    /// as one JSON object or array (legacy output, including pretty-printed fixtures) is kept as a
    /// document. Otherwise it is read as stream-json: split on LF (CRLF-tolerant), and every
    /// non-empty line that parses as a JSON object is kept. Unparseable lines are skipped.
    static func cliJSONObjects(from data: Data) -> (objects: [CLIJSONObject], document: CLIOutputDocument) {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let dictionary = json as? [String: Any] {
                return ([CLIJSONObject(dictionary: dictionary, data: data)], .document(json))
            }
            if let array = json as? [Any] {
                let objects = array.compactMap { element in
                    (element as? [String: Any]).map { CLIJSONObject(dictionary: $0, data: nil) }
                }
                return (objects, .document(json))
            }
            return ([], .document(json))
        }
        var objects: [CLIJSONObject] = []
        for rawLine in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var line = Data(rawLine)
            while let last = line.last, last == UInt8(ascii: "\r") || last == UInt8(ascii: " ") || last == UInt8(ascii: "\t") {
                line.removeLast()
            }
            guard line.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }),
                  let dictionary = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else {
                continue
            }
            objects.append(CLIJSONObject(dictionary: dictionary, data: line))
        }
        return (objects, .lines)
    }

    /// Parsed print-mode stdout: a completion, or the error text of an error result. Launch paths
    /// map an error result themselves so stdout refusals keep configured-executable context.
    enum PrintModeOutput {
        case completion(AICompletionResult)
        case errorResult(String)
    }

    /// Parses print-mode stdout. The last `type == "result"` object is authoritative: its usage
    /// is the request total (intermediate usage is never summed), and an error result throws.
    /// Legacy single-object and array JSON without a result object keep their previous parsing.
    /// Internal so root-target tests can exercise the real typed/fallback dispatch.
    func parseCompletionPayload(_ data: Data) throws -> AICompletionResult {
        switch try decodePrintModeOutput(data) {
        case let .completion(completion):
            return completion
        case let .errorResult(detail):
            throw AIProviderError.invalidConfiguration(detail: detail)
        }
    }

    /// `parseCompletionPayload` without mapping an error result to an error, so each launch path
    /// can classify it. Malformed and result-less output still throws `invalidResponse`.
    func decodePrintModeOutput(_ data: Data) throws -> PrintModeOutput {
        let parsed = Self.cliJSONObjects(from: data)
        if let resultObject = parsed.objects.last(where: { ($0.dictionary["type"] as? String) == "result" }) {
            if let errorDetail = Self.resultErrorDetail(resultObject.dictionary) {
                return .errorResult(errorDetail)
            }
            return .completion(completion(from: resultObject))
        }
        switch parsed.document {
        case .lines:
            throw Self.noResultMessageError
        case let .document(json):
            if json is [String: Any], let object = parsed.objects.first {
                // A single typed non-result line (for example only `system/init`) is stream-json
                // output that never produced a result; untyped legacy objects keep legacy parsing.
                if object.dictionary["type"] is String {
                    throw Self.noResultMessageError
                }
                return .completion(completion(from: object))
            }
            if json is [Any] {
                for object in parsed.objects.reversed() {
                    let completion = parseCompletionDictionary(object.dictionary)
                    if !completion.text.isEmpty {
                        return .completion(completion)
                    }
                }
                throw AIProviderError.invalidResponse(detail: "Claude CLI returned JSON array without completion payload")
            }
            throw AIProviderError.invalidResponse(detail: "Claude CLI returned unsupported JSON payload")
        }
    }

    private static var noResultMessageError: AIProviderError {
        AIProviderError.invalidResponse(detail: "stream-json output contained no result message")
    }

    private func completion(from object: CLIJSONObject) -> AICompletionResult {
        if let data = object.data,
           let message = try? decoder.decode(ClaudeResultMessage.self, from: data)
        {
            return AICompletionResult(
                text: message.result ?? "",
                promptTokens: message.usage.map { usage in
                    Self.cacheInclusiveInputTokens(
                        input: usage.inputTokens,
                        cacheRead: usage.cacheReadInputTokens,
                        cacheCreation: usage.cacheCreationInputTokens
                    )
                },
                completionTokens: message.usage?.outputTokens,
                cost: message.totalCostUsd
            )
        }
        return parseCompletionDictionary(object.dictionary)
    }

    /// Error text for a result object with `is_error == true` or an `error*` subtype, else nil.
    static func resultErrorDetail(_ dictionary: [String: Any]) -> String? {
        let isError = (dictionary["is_error"] as? Bool) == true || (dictionary["isError"] as? Bool) == true
        let subtype = (dictionary["subtype"] as? String) ?? ""
        guard isError || subtype.lowercased().hasPrefix("error") else { return nil }
        if let text = errorDetailText(in: dictionary) {
            return text
        }
        return subtype.isEmpty
            ? "Claude CLI reported an error result."
            : "Claude CLI reported an error result (\(subtype))."
    }

    /// The `result`, `error`, or `message` text of one CLI JSON object, if it has one. The text is
    /// used as supplied except that credential-shaped substrings are redacted.
    static func errorDetailText(in dictionary: [String: Any]) -> String? {
        func nonEmpty(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else {
                return nil
            }
            return Self.redactingCredentials(text)
        }
        if let text = nonEmpty(dictionary["result"]) { return text }
        if let text = nonEmpty(dictionary["error"]) { return text }
        if let nested = dictionary["error"] as? [String: Any], let text = nonEmpty(nested["message"]) { return text }
        if let text = nonEmpty(dictionary["message"]) { return text }
        if let errors = dictionary["errors"] as? [Any] {
            let texts = errors.compactMap { nonEmpty($0) }
            if !texts.isEmpty { return texts.joined(separator: "; ") }
        }
        return nil
    }

    private func parseCompletionDictionary(_ dict: [String: Any]) -> AICompletionResult {
        let usageDict = dict["usage"] as? [String: Any]
        let usage = parseUsage(usageDict)
        let text = extractString(dict["result"]) ?? extractString(dict["content"]) ?? ""
        let cost = dict["total_cost_usd"] as? Double
        return AICompletionResult(
            text: text,
            promptTokens: usage?.inputTokens,
            completionTokens: usage?.outputTokens,
            cost: cost
        )
    }

    private func extractString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let dict as [String: Any]:
            if let text = dict["text"] as? String { return text }
            return nil
        case let array as [Any]:
            return array.compactMap { extractString($0) }.joined(separator: "")
        default:
            return nil
        }
    }

    private func parseUsage(_ value: [String: Any]?) -> TokenUsage? {
        guard let value else { return nil }
        let input = numberToInt(value["input_tokens"]) ?? numberToInt(value["inputTokens"])
        let cacheRead = numberToInt(value["cache_read_input_tokens"])
            ?? numberToInt(value["cacheReadInputTokens"])
        let cacheCreation = numberToInt(value["cache_creation_input_tokens"])
            ?? numberToInt(value["cacheCreationInputTokens"])
        let output = numberToInt(value["output_tokens"]) ?? numberToInt(value["outputTokens"])
        if let input, let output {
            return TokenUsage(
                inputTokens: Self.cacheInclusiveInputTokens(
                    input: input,
                    cacheRead: cacheRead ?? 0,
                    cacheCreation: cacheCreation ?? 0
                ),
                outputTokens: output
            )
        }
        return nil
    }

    /// Claude's raw `input_tokens` excludes prompt-cache reads and writes. The chat UI's
    /// input total represents all input processed for the request, so include every
    /// component while rejecting negative counters and avoiding integer overflow.
    private static func cacheInclusiveInputTokens(
        input: Int,
        cacheRead: Int,
        cacheCreation: Int
    ) -> Int {
        var total = 0
        for value in [input, cacheRead, cacheCreation] {
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            if overflow {
                return Int.max
            }
            total = sum
        }
        return total
    }

    private func numberToInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            guard double.isFinite else { return nil }
            if double >= Double(Int.max) { return Int.max }
            if double <= Double(Int.min) { return Int.min }
            return Int(double)
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    package func testCompatibleBackendConnection(
        _ backendID: ClaudeCodeCompatibleBackendID,
        timeout: TimeInterval? = nil
    ) async throws -> Bool {
        let launchEnvironment = try await launchEnvironmentResolver().resolve(
            variant: Self.runtimeVariant(for: backendID),
            requestedModel: Self.compatibleBackendTestRequestedModel(for: backendID)
        )
        let emptyConfigLease = try await configService.prepareEmptyLaunchConfig()
        defer { emptyConfigLease.release() }
        var options = ClaudeCLIOptions()
        options.disallowedTools = disallowedTools
        options.mcpConfigPath = emptyConfigLease.url.path
        options.model = launchEnvironment.effectiveModel
        options.runtimeVariant = Self.runtimeVariant(for: backendID)
        options.systemPromptOverride = ClaudeAgentToolPreferences.agentModePromptDelivery().nativeSystemPromptOverride(instructions: "")
        options.timeout = timeout ?? testRequestTimeout
        let additionalEnvironment = options.additionalEnvironment.merging(
            launchEnvironment.environmentOverrides
        ) { _, resolverValue in resolverValue }

        let result = try await runPrintMode(
            options: options,
            stdin: "User: Say OK\n",
            additionalEnvironment: additionalEnvironment,
            removedEnvironmentKeys: launchEnvironment.removedEnvironmentKeys
        )
        if result.status != 0 {
            if let humanMessage = extractCLIErrorDetail(fromStdout: result.stdout) {
                throw Self.stdoutRefusalError(humanMessage, commandSelection: commandSelection)
                    ?? AIProviderError.invalidConfiguration(detail: humanMessage)
            }
            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            throw mapProcessFailure(exitCode: result.status, stderr: stderrString, timedOut: result.timedOut, timeoutValue: options.timeout)
        }
        switch try decodeConnectionTestOutput(result) {
        case let .completion(completion):
            return !completion.text.isEmpty
        case let .errorResult(detail):
            throw Self.stdoutRefusalError(detail, commandSelection: commandSelection)
                ?? AIProviderError.invalidConfiguration(detail: detail)
        }
    }

    /// Decodes a connection test's exit-zero stdout. Empty or undecodable output surfaces only
    /// bounded, redacted stdout/stderr excerpts.
    private func decodeConnectionTestOutput(_ result: CLIProcessRunner.Result) throws -> PrintModeOutput {
        guard !result.stdout.isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Claude Code CLI returned empty output. STDERR: \(Self.diagnosticExcerpt(result.stderr))")
        }
        do {
            return try decodePrintModeOutput(result.stdout)
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidResponse(detail: "Failed to decode Claude Code CLI response: \(error.localizedDescription). STDOUT: \(Self.diagnosticExcerpt(result.stdout)). STDERR: \(Self.diagnosticExcerpt(result.stderr))")
        }
    }

    private static func runtimeVariant(for backendID: ClaudeCodeCompatibleBackendID) -> ClaudeCodeRuntimeVariant {
        switch backendID {
        case .glmZAI:
            .glm
        case .kimi:
            .kimi
        case .custom:
            .customCompatible
        }
    }

    private static func compatibleBackendTestRequestedModel(for backendID: ClaudeCodeCompatibleBackendID) -> String? {
        let config = ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized
        switch config.modelBehavior {
        case .noModel:
            return nil
        case .claudeSlotMapping:
            return AgentModel.claudeSonnet.rawValue
        }
    }

    /// Carries a positively classified authentication or admission refusal out of
    /// `testConnectionWithModel` so `testConnection` surfaces it without the no-model fallback.
    /// Never escapes `testConnection`.
    private struct ConnectionTestRefusal: Error {
        let error: Error
    }

    package func testConnection(timeout: TimeInterval? = nil) async throws -> Bool {
        // First try with a specific model (haiku - fast and cheap)
        do {
            return try await testConnectionWithModel(.claudeCodeHaiku, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let refusal as ConnectionTestRefusal {
            // Explicit authentication and admission refusals surface immediately, as they do for
            // Oracle sends; another model cannot change the configured executable's answer.
            throw refusal.error
        } catch {
            // A cancelled test never launches the fallback attempt.
            try Task.checkCancellation()
            // If the first attempt fails, retry without specifying a model
            // This supports users with custom CLI configurations that may not have
            // the standard models available
            do {
                return try await testConnectionWithModel(.claudeCode, timeout: timeout)
            } catch let refusal as ConnectionTestRefusal {
                throw refusal.error
            }
        }
    }

    private func testConnectionWithModel(_ model: AIModel, timeout: TimeInterval?) async throws -> Bool {
        let emptyConfigLease = try await configService.prepareEmptyLaunchConfig()
        defer { emptyConfigLease.release() }
        var options = try await makeOptions(
            for: AIMessage(systemPrompt: "", userMessage: ""),
            model: model,
            emptyConfigURL: emptyConfigLease.url
        )
        options.systemPromptOverride = ClaudeAgentToolPreferences.agentModePromptDelivery().nativeSystemPromptOverride(instructions: "")
        options.timeout = timeout ?? testRequestTimeout
        let result = try await runPrintMode(
            options: options,
            stdin: "User: Say OK\n",
            additionalEnvironment: options.additionalEnvironment,
            removedEnvironmentKeys: options.removedEnvironmentKeys
        )
        if result.status != 0 {
            if let humanMessage = extractCLIErrorDetail(fromStdout: result.stdout) {
                // A stdout authentication/admission refusal ends the test like a stderr one.
                if let refusal = Self.stdoutRefusalError(humanMessage, commandSelection: commandSelection) {
                    throw ConnectionTestRefusal(error: refusal)
                }
                throw Self.cliReportedError(humanMessage)
            }
            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            let failure = mapProcessFailure(exitCode: result.status, stderr: stderrString, timedOut: result.timedOut, timeoutValue: options.timeout)
            switch Self.classifyPrintFailure(stderr: stderrString, timedOut: result.timedOut) {
            case .authentication, .admissionRefused:
                throw ConnectionTestRefusal(error: failure)
            case .timedOut, .missingExecutable, .rateLimited, .overloaded, .transient, .unclassified:
                throw failure
            }
        }
        // Handles stream-json plus legacy single-object and array output.
        switch try decodeConnectionTestOutput(result) {
        case let .completion(completion):
            return !completion.text.isEmpty
        case let .errorResult(detail):
            // An exit-zero `is_error` refusal also skips the no-model fallback.
            if let refusal = Self.stdoutRefusalError(detail, commandSelection: commandSelection) {
                throw ConnectionTestRefusal(error: refusal)
            }
            throw AIProviderError.invalidConfiguration(detail: detail)
        }
    }

    /// Attempts to decode a human-readable error exposed by the Claude CLI when it exits non-zero.
    /// Returns nil if stdout is empty or decoding fails.
    /// Internal so root-target tests can exercise stream-json and legacy error extraction.
    func extractCLIErrorDetail(fromStdout data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        // First pass: structured JSON errors. Uses the same splitter as the completion parser and
        // returns the text from the last object that has one.
        for object in Self.cliJSONObjects(from: data).objects.reversed() {
            if let text = Self.errorDetailText(in: object.dictionary) {
                return text
            }
        }

        // Second pass: if no JSON found, return plain-text diagnostics (common when CLI fails before JSON mode)
        if let plainText = String(data: data, encoding: .utf8) {
            let cleaned = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty strings and JSON noise
            if !cleaned.isEmpty, !cleaned.hasPrefix("{"), !cleaned.hasPrefix("[") {
                return Self.redactingCredentials(cleaned)
            }
        }
        return nil
    }
}
