import Foundation

package struct ClaudeAgentToolPreferences {
    package enum AgentModePromptDelivery: String, CaseIterable {
        case userMessageXML
        case userMessageXMLWithEmptySystemPrompt
        case nativeSystemPrompt

        package var displayName: String {
            switch self {
            case .nativeSystemPrompt:
                "Replace System Prompt"
            case .userMessageXMLWithEmptySystemPrompt:
                "User Message (No Native)"
            case .userMessageXML:
                "User Message (Keep Native)"
            }
        }

        package var detailText: String {
            switch self {
            case .nativeSystemPrompt:
                "RepoPrompt instructions replace Claude Code's native system prompt."
            case .userMessageXMLWithEmptySystemPrompt:
                "RepoPrompt instructions are added to the user message, and Claude Code's native system prompt is removed."
            case .userMessageXML:
                "RepoPrompt instructions are added to the user message, and Claude Code keeps its native prompt."
            }
        }

        var sendsRepoPromptAsUserMessage: Bool {
            ClaudeCompatibleProviderRuntimeBridge.sendsRepoPromptAsUserMessage(delivery: self)
        }

        func nativeSystemPromptOverride(instructions: String) -> String? {
            ClaudeCompatibleProviderRuntimeBridge.nativeSystemPromptOverride(
                instructions: instructions,
                delivery: self
            )
        }
    }

    package enum PermissionLevel: String, CaseIterable {
        case requireApproval
        case autoApproveEdits
        case auto
        case fullAccess

        package var displayName: String {
            switch self {
            case .requireApproval:
                "Require Approval"
            case .autoApproveEdits:
                "Auto-approve Edits"
            case .auto:
                "Auto (Preview)"
            case .fullAccess:
                "Full Access"
            }
        }

        var detailText: String {
            switch self {
            case .requireApproval:
                "Claude prompts for approval before running tools."
            case .autoApproveEdits:
                "Claude auto-approves file edits and common filesystem commands."
            case .auto:
                "Claude auto-approves tool calls that pass background safety checks. Research preview — behavior may change."
            case .fullAccess:
                "Claude runs every tool without prompting. Use only in trusted environments."
            }
        }

        var iconName: String {
            switch self {
            case .requireApproval:
                "lock.shield"
            case .autoApproveEdits:
                "shield"
            case .auto:
                "bolt.shield"
            case .fullAccess:
                "exclamationmark.shield.fill"
            }
        }

        var isWarning: Bool {
            self == .fullAccess
        }

        package var permissionMode: String {
            switch self {
            case .requireApproval:
                "default"
            case .autoApproveEdits:
                "acceptEdits"
            case .auto:
                "auto"
            case .fullAccess:
                "bypassPermissions"
            }
        }

        static func from(permissionMode: String) -> PermissionLevel {
            switch permissionMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "acceptedits":
                .autoApproveEdits
            case "auto":
                .auto
            case "bypasspermissions":
                .fullAccess
            default:
                .requireApproval
            }
        }
    }

    package enum AutoPermissionCandidacy: Equatable {
        case eligible
        case unsupportedModel(String)
        case unknownModel(String?)
        case compatibleBackend(AgentProviderKind)

        var blockingMessage: String? {
            switch self {
            case .eligible:
                nil
            case let .unsupportedModel(model):
                "Claude Auto is unavailable for model '\(model)'. Select an eligible Claude model or choose another permission mode."
            case let .unknownModel(model):
                if let model {
                    "Claude Auto cannot validate model '\(model)'. Select an eligible Claude model or choose another permission mode."
                } else {
                    "Claude Auto requires an explicit eligible Claude model. Select a model or choose another permission mode."
                }
            case let .compatibleBackend(agentKind):
                "Claude Auto is available only with official Claude Code, not the '\(agentKind.rawValue)' compatible backend."
            }
        }
    }

    enum PermissionModeResolutionReason: Equatable {
        case nonAutoPassThrough
        case eligibleAuto
        case blockedAuto(AutoPermissionCandidacy)
    }

    struct PermissionModeResolution: Equatable {
        let requestedMode: String
        let launchMode: String?
        let reason: PermissionModeResolutionReason

        var blockingMessage: String? {
            guard case let .blockedAuto(candidacy) = reason else { return nil }
            return candidacy.blockingMessage
        }
    }

    struct AutoPermissionModeBlockedError: Error, LocalizedError, Equatable {
        let candidacy: AutoPermissionCandidacy

        var errorDescription: String? {
            candidacy.blockingMessage ?? "Claude Auto is unavailable for the resolved launch."
        }
    }

    /// Pure local candidacy authority. This only decides whether RepoPrompt may
    /// request Auto; Claude Code remains the acceptance authority.
    static func autoPermissionCandidacy(
        agentKind: AgentProviderKind,
        selectedModelRaw: String?
    ) -> AutoPermissionCandidacy {
        guard agentKind == .claudeCode else {
            return .compatibleBackend(agentKind)
        }
        guard let baseModel = ClaudeModelSpecifier(raw: selectedModelRaw).baseModel else {
            return .unknownModel(nil)
        }

        let aliases = [
            AgentModel.claudeOpus.rawValue,
            AgentModel.claudeOpus1m.rawValue,
            AgentModel.claudeSonnet.rawValue
        ]
        if aliases.contains(where: { baseModel.caseInsensitiveCompare($0) == .orderedSame }) {
            return .eligible
        }

        let eligibleLegacyIDs: Set = [
            "claude-opus-4-6",
            "claude-opus-4-7",
            "claude-sonnet-4-6"
        ]
        if eligibleLegacyIDs.contains(baseModel) {
            return .eligible
        }

        // Full family IDs deliberately remain case-sensitive. The shared family
        // catalog owns the strict major/minor/date grammar.
        if ClaudeModelFamilyCatalog.cliFamily(for: baseModel) != nil {
            return .eligible
        }

        if baseModel.caseInsensitiveCompare(AgentModel.claudeHaiku.rawValue) == .orderedSame
            || baseModel.hasPrefix("claude-")
        {
            return .unsupportedModel(baseModel)
        }
        return .unknownModel(baseModel)
    }

    static func supportsAutoPermissionMode(
        agentKind: AgentProviderKind,
        selectedModelRaw: String?
    ) -> Bool {
        autoPermissionCandidacy(
            agentKind: agentKind,
            selectedModelRaw: selectedModelRaw
        ) == .eligible
    }

    static func resolvePermissionMode(
        requestedMode: String,
        agentKind: AgentProviderKind,
        selectedModelRaw: String?
    ) -> PermissionModeResolution {
        let trimmedMode = requestedMode.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMode = trimmedMode.isEmpty ? PermissionLevel.requireApproval.permissionMode : trimmedMode
        guard normalizedMode.caseInsensitiveCompare(PermissionLevel.auto.permissionMode) == .orderedSame else {
            return PermissionModeResolution(
                requestedMode: normalizedMode,
                launchMode: normalizedMode,
                reason: .nonAutoPassThrough
            )
        }

        let candidacy = autoPermissionCandidacy(
            agentKind: agentKind,
            selectedModelRaw: selectedModelRaw
        )
        guard candidacy == .eligible else {
            return PermissionModeResolution(
                requestedMode: normalizedMode,
                launchMode: nil,
                reason: .blockedAuto(candidacy)
            )
        }
        return PermissionModeResolution(
            requestedMode: normalizedMode,
            launchMode: PermissionLevel.auto.permissionMode,
            reason: .eligibleAuto
        )
    }

    private static let bashToolEnabledKey = "claudeCodeAllowNativeBashTool"
    private static let permissionModeKey = "claudeCodePermissionMode"
    private static let mcpStrictModeEnabledKey = "claudeCodeMCPStrictModeEnabled"
    private static let toolSearchEnabledKey = "claudeCodeToolSearchEnabled"
    private static let repoPromptToolsModeKey = "claudeCodeRepoPromptToolsMode"
    private static let effortLevelKey = "claudeCodeEffortLevel"
    private static let effortLevelsByModelSlugKey = "claudeCodeEffortLevelsByModelSlug"
    private static let agentModePromptDeliveryKey = "claudeCodeAgentModePromptDelivery"
    private static let nullBuiltInSystemPromptEnabledKey = "claudeCodeNullBuiltInSystemPromptEnabled"

    package static func bashToolEnabled(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> Bool {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.claudePermissions().bashToolEnabled ?? false
        }
        if defaults.object(forKey: bashToolEnabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: bashToolEnabledKey)
    }

    package static func setBashToolEnabled(
        _ isEnabled: Bool,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateClaudePermissions { document in
                document.bashToolEnabled = isEnabled
            }
            return
        }
        defaults.set(isEnabled, forKey: bashToolEnabledKey)
    }

    package static func permissionMode(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> String {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.claudePermissions().permissionMode()
        }
        let raw = defaults.string(forKey: permissionModeKey)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return PermissionLevel.requireApproval.permissionMode
    }

    static func setPermissionMode(
        _ mode: String,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? PermissionLevel.requireApproval.permissionMode : trimmed
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateClaudePermissions { document in
                document.permissionModeRaw = normalized
            }
            return
        }
        defaults.set(normalized, forKey: permissionModeKey)
    }

    package static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.claudePermissions().permissionLevel()
        }
        return PermissionLevel.from(permissionMode: permissionMode(defaults: defaults))
    }

    package static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setClaudePermissionLevel(level)
            return
        }
        setPermissionMode(level.permissionMode, defaults: defaults)
    }

    // MARK: - MCP Strict Mode

    /// When enabled (default), Claude Code launches with `--strict-mcp-config` so only the
    /// RepoPrompt MCP server is active.
    /// When disabled, other MCP servers from the user's config are allowed.
    package static func mcpStrictModeEnabled(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> Bool {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            return secureStore.claudePermissions().mcpStrictModeEnabled ?? true
        }
        if defaults.object(forKey: mcpStrictModeEnabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: mcpStrictModeEnabledKey)
    }

    package static func setMCPStrictModeEnabled(
        _ isEnabled: Bool,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.updateClaudePermissions { document in
                document.mcpStrictModeEnabled = isEnabled
            }
            return
        }
        defaults.set(isEnabled, forKey: mcpStrictModeEnabledKey)
    }

    // MARK: - Tool Search

    /// When enabled, Claude Code is allowed to discover and use tools beyond the built-in set
    /// and configured MCP servers. Off by default to keep agent behaviour predictable.
    package static func toolSearchEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: toolSearchEnabledKey) == nil {
            return false
        }
        return defaults.bool(forKey: toolSearchEnabledKey)
    }

    package static func setToolSearchEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: toolSearchEnabledKey)
    }

    // MARK: - RepoPrompt tools mode

    /// How RepoPrompt tools are offered to official Claude Code Agent Mode runs. Defaults to
    /// `.native` (direct tools only); `.directCodeMode` additionally offers `code_mode` beside the
    /// direct tools. Read once per run at launch; a missing or unknown value is `.native`.
    package static func repoPromptToolsMode(defaults: UserDefaults = .standard) -> RepoPromptToolsMode {
        defaults.string(forKey: repoPromptToolsModeKey).flatMap(RepoPromptToolsMode.init(rawValue:)) ?? .native
    }

    package static func setRepoPromptToolsMode(_ mode: RepoPromptToolsMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: repoPromptToolsModeKey)
    }

    // MARK: - Claude Code native prompt mode

    package static func agentModePromptDelivery(defaults: UserDefaults = .standard) -> AgentModePromptDelivery {
        if let rawValue = defaults.string(forKey: agentModePromptDeliveryKey),
           let value = AgentModePromptDelivery(rawValue: rawValue)
        {
            return value
        }
        if defaults.bool(forKey: nullBuiltInSystemPromptEnabledKey) {
            return .userMessageXMLWithEmptySystemPrompt
        }
        return .nativeSystemPrompt
    }

    package static func setAgentModePromptDelivery(_ delivery: AgentModePromptDelivery, defaults: UserDefaults = .standard) {
        defaults.set(delivery.rawValue, forKey: agentModePromptDeliveryKey)
        defaults.set(delivery == .userMessageXMLWithEmptySystemPrompt, forKey: nullBuiltInSystemPromptEnabledKey)
    }

    /// Compatibility helper for tests and existing defaults. Prefer `agentModePromptDelivery()`
    /// for new Agent Mode code.
    static func nullBuiltInSystemPromptEnabled(defaults: UserDefaults = .standard) -> Bool {
        agentModePromptDelivery(defaults: defaults) == .userMessageXMLWithEmptySystemPrompt
    }

    static func setNullBuiltInSystemPromptEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        setAgentModePromptDelivery(isEnabled ? .userMessageXMLWithEmptySystemPrompt : .userMessageXML, defaults: defaults)
    }

    // MARK: - Effort Level

    static func effortLevel(defaults: UserDefaults = .standard) -> ClaudeCodeEffortLevel {
        guard let raw = defaults.string(forKey: effortLevelKey) else { return .high }
        return ClaudeCodeEffortLevel.parse(raw) ?? .high
    }

    package static func setEffortLevel(_ level: ClaudeCodeEffortLevel, defaults: UserDefaults = .standard) {
        defaults.set(level.rawValue, forKey: effortLevelKey)
    }

    static func storedEffortLevel(
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind,
        defaults: UserDefaults = .standard,
        includeLegacyFallback: Bool = true
    ) -> ClaudeCodeEffortLevel? {
        guard let concreteModelRaw = concreteEffortModelRaw(modelRaw) else {
            return includeLegacyFallback ? effortLevel(defaults: defaults) : nil
        }
        let key = effortPreferenceKey(forModelRaw: concreteModelRaw, agentKind: agentKind)
        if let rawValue = defaults.dictionary(forKey: effortLevelsByModelSlugKey)?[key] as? String,
           let effort = ClaudeCodeEffortLevel.parse(rawValue),
           isEffort(effort, supportedForModelRaw: concreteModelRaw, agentKind: agentKind)
        {
            return effort
        }
        guard includeLegacyFallback,
              let legacyRaw = defaults.string(forKey: effortLevelKey),
              let legacyEffort = ClaudeCodeEffortLevel.parse(legacyRaw),
              isEffort(legacyEffort, supportedForModelRaw: concreteModelRaw, agentKind: agentKind)
        else {
            return nil
        }
        return legacyEffort
    }

    static func effortLevel(
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind,
        defaults: UserDefaults = .standard
    ) -> ClaudeCodeEffortLevel {
        if let stored = storedEffortLevel(forModelRaw: modelRaw, agentKind: agentKind, defaults: defaults) {
            return stored
        }
        let supportedEfforts = AgentModelCatalog.supportedClaudeEfforts(
            forSelectedModelRaw: effectiveEffortModelRaw(modelRaw),
            agentKind: agentKind
        )
        if supportedEfforts.contains(.high) {
            return .high
        }
        if supportedEfforts.contains(.medium) {
            return .medium
        }
        return supportedEfforts.first ?? .high
    }

    package static func setEffortLevel(
        _ level: ClaudeCodeEffortLevel,
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind,
        defaults: UserDefaults = .standard
    ) {
        guard let concreteModelRaw = concreteEffortModelRaw(modelRaw) else {
            setEffortLevel(level, defaults: defaults)
            return
        }
        let key = effortPreferenceKey(forModelRaw: concreteModelRaw, agentKind: agentKind)
        var stored = rawEffortLevelsByModelSlug(defaults: defaults)
        stored[key] = level.rawValue
        defaults.set(stored, forKey: effortLevelsByModelSlugKey)
        setEffortLevel(level, defaults: defaults)
    }

    static func effortLevelsByModelSlug(
        defaults: UserDefaults = .standard
    ) -> [String: ClaudeCodeEffortLevel] {
        rawEffortLevelsByModelSlug(defaults: defaults).reduce(into: [:]) { result, entry in
            if let effort = ClaudeCodeEffortLevel.parse(entry.value) {
                result[entry.key] = effort
            }
        }
    }

    private static func rawEffortLevelsByModelSlug(defaults: UserDefaults) -> [String: String] {
        guard let dictionary = defaults.dictionary(forKey: effortLevelsByModelSlugKey) else { return [:] }
        return dictionary.reduce(into: [:]) { result, entry in
            guard let rawValue = entry.value as? String else { return }
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = rawValue
        }
    }

    private static func effortPreferenceKey(
        forModelRaw modelRaw: String?,
        agentKind: AgentProviderKind
    ) -> String {
        let specifier = ClaudeModelSpecifier(raw: modelRaw)
        let rawFallback = concreteEffortModelRaw(modelRaw)
        let slug = specifier.baseModel ?? rawFallback ?? AgentModel.defaultModel.rawValue
        return "\(agentKind.rawValue)|\(slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func concreteEffortModelRaw(_ modelRaw: String?) -> String? {
        let trimmed = modelRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed,
              !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        return trimmed
    }

    private static func effectiveEffortModelRaw(_ modelRaw: String?) -> String {
        concreteEffortModelRaw(modelRaw) ?? AgentModel.defaultModel.rawValue
    }

    private static func isEffort(
        _ effort: ClaudeCodeEffortLevel,
        supportedForModelRaw modelRaw: String?,
        agentKind: AgentProviderKind
    ) -> Bool {
        AgentModelCatalog.supportedClaudeEfforts(
            forSelectedModelRaw: effectiveEffortModelRaw(modelRaw),
            agentKind: agentKind
        ).contains(effort)
    }

    private static func resolvedSecureStore(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore?
    ) -> AgentPermissionSecureStore? {
        if let secureStore {
            return secureStore
        }
        return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
    }
}

// MARK: - Claude Code Effort Level

package enum ClaudeCodeEffortLevel: String, CaseIterable {
    // Ordered highest → lowest so UI pickers and variant menus list the
    // strongest effort first. `allCases` drives both `AgentInputBar`'s Claude
    // effort picker and `claudeEffortSortRank` in `AgentModelCatalog`.
    case max
    case xhigh
    case high
    case medium
    case low

    static func parse(_ raw: String?) -> ClaudeCodeEffortLevel? {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        switch normalized {
        case "low":
            return .low
        case "medium":
            return .medium
        case "high":
            return .high
        case "max":
            return .max
        case "xhigh", "x-high":
            return .xhigh
        default:
            return nil
        }
    }

    package var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        case .xhigh: "XHigh"
        }
    }

    /// Value passed to the `CLAUDE_CODE_EFFORT_LEVEL` environment variable.
    var envValue: String {
        rawValue
    }
}
