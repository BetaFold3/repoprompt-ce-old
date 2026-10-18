import Foundation

enum CodexOverrides {
    private static let forcedDisabledConfig: [String: Bool] = [
        "features.apps": false,
        "features.js_repl": false,
        "features.js_repl_tools_only": false,
        "features.memories": false,
        "features.goals": false,
        "features.computer_use": false,
        "features.plugins": false,
        "features.tool_search": false,
        // Disable MCP elicitation until RepoPrompt supports the mcpServer/elicitation/request
        // server request and its {action, content, _meta} response contract. Without this,
        // Codex routes MCP tool approvals through elicitation by default (ToolCallMcpElicitation
        // is stable + enabled), which RepoPrompt treats as unsupported and fails the run.
        "features.tool_call_mcp_elicitation": false,
        "features.tool_suggest": false,
        "memories.generate_memories": false,
        "memories.use_memories": false
    ]

    private static let computerUseEnabledConfig: [String: Bool] = [
        "features.computer_use": true,
        "features.plugins": true,
        "features.tool_search": true,
        "features.tool_call_mcp_elicitation": true,
        "features.tool_search_always_defer_mcp_tools": true,
        "features.tool_suggest": true
    ]

    enum ReasoningSummary: String {
        case auto
        case concise
        case detailed
        case none
    }

    struct FeaturePolicy: Equatable {
        var goalsEnabled: Bool
        var computerUseEnabled: Bool

        static let defaultDisabled = FeaturePolicy(goalsEnabled: false, computerUseEnabled: false)
        static let enabledForGoals = FeaturePolicy(goalsEnabled: true, computerUseEnabled: false)
        static let enabledForComputerUse = FeaturePolicy(goalsEnabled: false, computerUseEnabled: true)

        static func resolved(goalsEnabled: Bool, computerUseEnabled: Bool) -> FeaturePolicy {
            FeaturePolicy(goalsEnabled: goalsEnabled, computerUseEnabled: computerUseEnabled)
        }
    }

    struct ToolPolicy {
        var toolOutputTokenLimit: Int
        var shellToolEnabled: Bool?
        var webSearchRequestEnabled: Bool?
        var viewImageToolEnabled: Bool?
        /// Best-effort only in the current Codex stack: shipped model metadata can still expose
        /// built-in patching, and shell/unified-exec can still route patch activity when enabled.
        var includeApplyPatchTool: Bool?
        var parallelToolCallsEnabled: Bool?
        var multiAgentEnabled: Bool?
        var experimentalSteeringEnabled: Bool?
        /// Keep reasoning summaries enabled for newer Codex models that now default them off.
        var modelReasoningSummary: ReasoningSummary? = .auto
    }

    enum MCPPolicy {
        case disableAll(exceptBroken: Set<String>)
        case enableOnlyRepoPrompt(repoPromptNormalizedName: String, exceptBroken: Set<String>)
        case enableSelected(
            enabledNormalizedNames: Set<String>,
            repoPromptNormalizedName: String,
            exceptBroken: Set<String>
        )
    }

    /// Thread-level Codex key listing namespaces whose tools stay direct (outside Codex's own
    /// code mode). Plan §6 D3 `direct + code_mode`; inert unless a direct server name is supplied.
    static let directOnlyToolNamespacesKey = "features.code_mode.direct_only_tool_namespaces"

    /// Codex MCP tool namespace for a configured server name: `mcp__` plus the exact name with
    /// `-` turned into `_`, case preserved. Nil for an empty name (fail closed: no override).
    static func directOnlyToolNamespace(forServerName serverName: String?) -> String? {
        guard let serverName, !serverName.isEmpty else { return nil }
        return "mcp__" + serverName.replacingOccurrences(of: "-", with: "_")
    }

    static func cliConfigArgs(
        toolPolicy: ToolPolicy,
        featurePolicy: FeaturePolicy = .defaultDisabled,
        repoPromptDirectServerName: String? = nil
    ) -> [String] {
        var args: [String] = [
            "-c", "tool_output_token_limit=\(toolPolicy.toolOutputTokenLimit)"
        ]
        if let shellToolEnabled = toolPolicy.shellToolEnabled {
            args.append(contentsOf: ["-c", "features.shell_tool=\(shellToolEnabled)"])
            if shellToolEnabled == false {
                args.append(contentsOf: ["-c", "features.unified_exec=false"])
            }
        }
        if let webSearchRequestEnabled = toolPolicy.webSearchRequestEnabled {
            args.append(contentsOf: ["-c", "web_search=\(webSearchMode(enabled: webSearchRequestEnabled))"])
            args.append(contentsOf: ["-c", "features.web_search_request=\(webSearchRequestEnabled)"])
        }
        if let viewImageToolEnabled = toolPolicy.viewImageToolEnabled {
            args.append(contentsOf: ["-c", "features.view_image_tool=\(viewImageToolEnabled)"])
        }
        if let includeApplyPatchTool = toolPolicy.includeApplyPatchTool {
            args.append(contentsOf: ["-c", "features.apply_patch_freeform=\(includeApplyPatchTool)"])
        }
        if let parallelToolCallsEnabled = toolPolicy.parallelToolCallsEnabled {
            args.append(contentsOf: ["-c", "features.parallel_tool_calls=\(parallelToolCallsEnabled)"])
        }
        if let multiAgentEnabled = toolPolicy.multiAgentEnabled {
            args.append(contentsOf: ["-c", "features.multi_agent=\(multiAgentEnabled)"])
        }
        if let experimentalSteeringEnabled = toolPolicy.experimentalSteeringEnabled {
            args.append(contentsOf: ["-c", "features.steer=\(experimentalSteeringEnabled)"])
        }
        if let modelReasoningSummary = toolPolicy.modelReasoningSummary {
            args.append(contentsOf: ["-c", "model_reasoning_summary=\(modelReasoningSummary.rawValue)"])
        }
        appendForcedConfigOverrideArgs(to: &args, featurePolicy: featurePolicy)
        if let namespace = directOnlyToolNamespace(forServerName: repoPromptDirectServerName) {
            args.append(contentsOf: ["-c", "\(directOnlyToolNamespacesKey)=[\(tomlBasicString(namespace))]"])
        }
        return args
    }

    static func appServerConfigMap(
        toolPolicy: ToolPolicy,
        featurePolicy: FeaturePolicy = .defaultDisabled,
        repoPromptDirectServerName: String? = nil
    ) -> [String: Any] {
        var overrides: [String: Any] = [
            "tool_output_token_limit": toolPolicy.toolOutputTokenLimit
        ]
        if let shellToolEnabled = toolPolicy.shellToolEnabled {
            overrides["features.shell_tool"] = shellToolEnabled
            if shellToolEnabled == false {
                overrides["features.unified_exec"] = false
            }
        }
        if let webSearchRequestEnabled = toolPolicy.webSearchRequestEnabled {
            overrides["web_search"] = webSearchMode(enabled: webSearchRequestEnabled)
            overrides["features.web_search_request"] = webSearchRequestEnabled
        }
        if let viewImageToolEnabled = toolPolicy.viewImageToolEnabled {
            overrides["features.view_image_tool"] = viewImageToolEnabled
        }
        if let includeApplyPatchTool = toolPolicy.includeApplyPatchTool {
            overrides["features.apply_patch_freeform"] = includeApplyPatchTool
        }
        if let parallelToolCallsEnabled = toolPolicy.parallelToolCallsEnabled {
            overrides["features.parallel_tool_calls"] = parallelToolCallsEnabled
        }
        if let multiAgentEnabled = toolPolicy.multiAgentEnabled {
            overrides["features.multi_agent"] = multiAgentEnabled
        }
        if let experimentalSteeringEnabled = toolPolicy.experimentalSteeringEnabled {
            overrides["features.steer"] = experimentalSteeringEnabled
        }
        if let modelReasoningSummary = toolPolicy.modelReasoningSummary {
            overrides["model_reasoning_summary"] = modelReasoningSummary.rawValue
        }
        applyForcedConfigOverrides(to: &overrides, featurePolicy: featurePolicy)
        if let namespace = directOnlyToolNamespace(forServerName: repoPromptDirectServerName) {
            overrides[directOnlyToolNamespacesKey] = [namespace]
        }
        return overrides
    }

    /// Adds the read-only companion server (plan §6 D3 Codex row) to one thread start/resume
    /// config: the bundled RepoPrompt MCP client under `serverName`, enabled, with the launch's
    /// companion credential only in that server's environment. Any key the MCP enablement policy
    /// already wrote for the same server is replaced, so suppression of third-party servers never
    /// disables (or duplicates) the companion. A nil credential or empty name leaves the map as is.
    static func mergingReadOnlyCompanionServer(
        into overrides: [String: Any],
        serverName: String,
        server: RepoPromptMCPServerConfiguration,
        credentialEnvironmentKey: String,
        credential: String?
    ) -> [String: Any] {
        guard !serverName.isEmpty, let credential, !credential.isEmpty else { return overrides }
        let component = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: serverName)
        let prefix = "mcp_servers.\(component)"
        var merged = overrides.filter { key, _ in key != prefix && !key.hasPrefix(prefix + ".") }
        var environment = server.environmentDictionary
        environment[credentialEnvironmentKey] = credential
        // Same per-server tool timeout and parallelism as the primary's config.toml entry, so Codex
        // never cuts a companion `code_mode` call off at its own default before the executor's
        // wall budget settles it.
        merged[prefix] = [
            "command": server.command,
            "args": server.args,
            "env": environment,
            "enabled": true,
            "tool_timeout_sec": CodexIntegrationConfiguration.desiredToolTimeoutSeconds,
            "supports_parallel_tool_calls": CodexIntegrationConfiguration.desiredSupportsParallelToolCalls
        ] as [String: Any]
        return merged
    }

    static func cliMCPServerArgs(
        entries: [MCPIntegrationHelper.CodexServerEntry],
        policy: MCPPolicy
    ) -> [String] {
        var args: [String] = []
        for (cliComponent, enabled) in mcpServerOverrideEntries(entries: entries, policy: policy) {
            args.append(contentsOf: ["-c", "mcp_servers.\(cliComponent).enabled=\(enabled)"])
        }
        return args
    }

    static func appServerMCPServerMap(
        entries: [MCPIntegrationHelper.CodexServerEntry],
        policy: MCPPolicy
    ) -> [String: Any] {
        var overrides: [String: Any] = [:]
        for (cliComponent, enabled) in mcpServerOverrideEntries(entries: entries, policy: policy) {
            overrides["mcp_servers.\(cliComponent).enabled"] = enabled
        }
        return overrides
    }

    private static func appendForcedConfigOverrideArgs(
        to args: inout [String],
        featurePolicy: FeaturePolicy
    ) {
        let resolvedConfig = forcedConfig(featurePolicy: featurePolicy)
        for key in resolvedConfig.keys.sorted() {
            guard let enabled = resolvedConfig[key] else { continue }
            args.append(contentsOf: ["-c", "\(key)=\(enabled)"])
        }
    }

    private static func applyForcedConfigOverrides(
        to overrides: inout [String: Any],
        featurePolicy: FeaturePolicy
    ) {
        let resolvedConfig = forcedConfig(featurePolicy: featurePolicy)
        for key in resolvedConfig.keys.sorted() {
            guard let enabled = resolvedConfig[key] else { continue }
            overrides[key] = enabled
        }
    }

    private static func forcedConfig(featurePolicy: FeaturePolicy) -> [String: Bool] {
        var config = forcedDisabledConfig
        if featurePolicy.goalsEnabled {
            config["features.goals"] = true
        }
        guard featurePolicy.computerUseEnabled else {
            return config
        }
        for (key, value) in computerUseEnabledConfig {
            config[key] = value
        }
        return config
    }

    /// TOML basic string literal (quotes, backslashes, and control characters escaped).
    static func tomlBasicString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }

    private static func webSearchMode(enabled: Bool) -> String {
        enabled ? "live" : "disabled"
    }

    private static func mcpServerOverrideEntries(
        entries: [MCPIntegrationHelper.CodexServerEntry],
        policy: MCPPolicy
    ) -> [(String, Bool)] {
        var overrides: [(String, Bool)] = []

        switch policy {
        case let .disableAll(exceptBroken):
            for entry in entries {
                if entry.normalizedName.isEmpty {
                    continue
                }
                if exceptBroken.contains(entry.normalizedName) {
                    continue
                }
                overrides.append((entry.cliPathComponent, false))
            }
        case let .enableOnlyRepoPrompt(repoPromptName, exceptBroken):
            var didEnableRepoPrompt = false
            for entry in entries {
                if entry.normalizedName.isEmpty {
                    continue
                }
                if entry.normalizedName == repoPromptName {
                    overrides.append((entry.cliPathComponent, true))
                    didEnableRepoPrompt = true
                } else {
                    if exceptBroken.contains(entry.normalizedName) {
                        continue
                    }
                    overrides.append((entry.cliPathComponent, false))
                }
            }
            if !didEnableRepoPrompt {
                let cliComponent = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: repoPromptName)
                overrides.append((cliComponent, true))
            }
        case let .enableSelected(enabledNames, repoPromptName, exceptBroken):
            let normalizedEnabled = Set(enabledNames)
            let normalizedBroken = Set(exceptBroken)
            let normalizedRepoPrompt = repoPromptName
            var didEnableRepoPrompt = false

            for entry in entries {
                if entry.normalizedName.isEmpty {
                    continue
                }

                let normalizedName = entry.normalizedName
                let isRepoPrompt = normalizedName == normalizedRepoPrompt
                let shouldEnable = isRepoPrompt || normalizedEnabled.contains(normalizedName)
                if shouldEnable {
                    if isRepoPrompt {
                        didEnableRepoPrompt = true
                    }
                    overrides.append((entry.cliPathComponent, true))
                    continue
                }

                if normalizedBroken.contains(normalizedName) {
                    continue
                }
                overrides.append((entry.cliPathComponent, false))
            }

            if !didEnableRepoPrompt {
                let cliComponent = MCPIntegrationHelper.codexCLIPathComponent(forNormalizedServerName: repoPromptName)
                overrides.append((cliComponent, true))
            }
        }

        return overrides
    }
}
