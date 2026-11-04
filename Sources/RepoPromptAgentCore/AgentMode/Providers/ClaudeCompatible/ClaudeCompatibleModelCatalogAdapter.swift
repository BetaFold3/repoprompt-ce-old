import Foundation

/// Model-catalog seam for the Claude-compatible plugin path.
///
/// The provider package owns Claude-compatible catalog strings/DTO metadata. This
/// adapter maps those DTOs back onto RepoPrompt's stable `AgentModel` raw values,
/// option DTOs, defaults, and validation semantics.
package enum ClaudeCompatibleModelCatalogAdapter {
    static func catalogSnapshot(
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        includeClaudeEffortVariants: Bool = true,
        store: AnthropicDiscoveredModelStore = .shared,
        cliStore: ClaudeCLIDiscoveredModelStore = .shared
    ) -> ClaudeCompatiblePluginModelCatalogSnapshot? {
        guard let pluginID = ClaudeCompatiblePluginBridge.pluginID(for: agentKind) else { return nil }
        let snapshot = pluginCatalogSnapshot(
            pluginID: pluginID,
            agentKind: agentKind,
            includeClaudeEffortVariants: includeClaudeEffortVariants
        )
        let splicedOptions = agentKind == .claudeCode
            ? optionsSplicingDynamicClaudePointReleases(
                into: snapshot.options,
                includeClaudeEffortVariants: includeClaudeEffortVariants,
                store: store,
                cliStore: cliStore
            )
            : snapshot.options
        let mappedOptions = AgentModelCatalog.isAgentAvailable(agentKind, availability: availability)
            ? splicedOptions.map { canonicalPluginModelOption($0, for: agentKind) }
            : []
        return ClaudeCompatiblePluginModelCatalogSnapshot(
            pluginID: snapshot.pluginID,
            defaultModelRaw: canonicalModelRaw(snapshot.defaultModelRaw, for: agentKind),
            options: mappedOptions
        )
    }

    static func defaultModelRaw(
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current
    ) -> String? {
        guard let pluginID = ClaudeCompatiblePluginBridge.pluginID(for: agentKind) else { return nil }
        return canonicalModelRaw(
            pluginCatalogSnapshot(
                pluginID: pluginID,
                agentKind: agentKind,
                includeClaudeEffortVariants: false
            ).defaultModelRaw,
            for: agentKind
        )
    }

    static func options(
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        includeClaudeEffortVariants: Bool = true,
        store: AnthropicDiscoveredModelStore = .shared,
        cliStore: ClaudeCLIDiscoveredModelStore = .shared
    ) -> [AgentModelOption]? {
        catalogSnapshot(
            for: agentKind,
            availability: availability,
            includeClaudeEffortVariants: includeClaudeEffortVariants,
            store: store,
            cliStore: cliStore
        ).map { modelOptions(from: $0.options, for: agentKind) }
    }

    static func modelOptions(
        from pluginOptions: [ClaudeCompatiblePluginModelOption],
        for agentKind: AgentProviderKind
    ) -> [AgentModelOption] {
        pluginOptions.map { modelOption(from: $0, for: agentKind) }
    }

    static func pluginModelOption(from option: AgentModelOption) -> ClaudeCompatiblePluginModelOption {
        ClaudeCompatiblePluginModelOption(
            rawValue: option.rawValue,
            displayName: option.displayName,
            description: option.description,
            isPlaceholderDefault: option.isPlaceholderDefault,
            isProviderDefault: option.isProviderDefault,
            supportedEffortLevels: []
        )
    }

    static func compatibleBackendModelBehavior(
        for agentKind: AgentProviderKind
    ) -> ClaudeCodeCompatibleBackendConfig.ModelBehavior? {
        compatibleBackendConfig(for: agentKind)?.modelBehavior
    }

    static func compatibleBackendDisplayName(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> String? {
        optionMetadata(forRequestedModelRaw: rawModel, agentKind: agentKind)?.displayName
    }

    static func compatibleBackendDescription(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> String? {
        optionMetadata(forRequestedModelRaw: rawModel, agentKind: agentKind)?.description
    }

    package static func contextWindowTokens(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> Int? {
        guard let config = compatibleBackendConfig(for: agentKind),
              let baseRaw = canonicalCompatibleBackendBaseRaw(rawModel, for: agentKind) else { return nil }
        let backendModelID = directBackendModelID(forCanonicalBaseRaw: baseRaw, agentKind: agentKind)
            ?? backendModelID(forCanonicalSlotRaw: baseRaw, config: config)
        return ClaudeCompatibleProviderRuntimeBridge.contextWindowTokens(forGLMBackendModelID: backendModelID)
    }

    static func canonicalCompatibleBackendBaseRaw(_ rawModel: String?, for agentKind: AgentProviderKind) -> String? {
        guard let id = compatibleBackendID(for: agentKind),
              let config = compatibleBackendConfig(for: agentKind) else { return nil }
        switch config.modelBehavior {
        case .noModel:
            let specifier = ClaudeModelSpecifier(raw: rawModel)
            guard specifier.effortLevel == nil else { return nil }
            let base = specifier.baseModel ?? noModelRawValue(for: id)
            return base.caseInsensitiveCompare(noModelRawValue(for: id)) == .orderedSame ? noModelRawValue(for: id) : nil
        case .claudeSlotMapping:
            let specifier = ClaudeModelSpecifier(raw: rawModel)
            let base = specifier.baseModel
            if id == .glmZAI,
               let base,
               ClaudeCompatibleProviderRuntimeBridge.isDirectSelectableGLMModel(base)
            {
                return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            return ClaudeCodeGLMIntegration.normalizedSlotModel(
                base,
                config: config
            )
        }
    }

    static func canonicalCompatibleBackendModelRaw(_ rawModel: String?, for agentKind: AgentProviderKind) -> String? {
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        guard let base = canonicalCompatibleBackendBaseRaw(specifier.baseModel, for: agentKind) else { return rawModel }
        if let effort = specifier.effortLevel {
            return ClaudeModelSpecifier.encodedRaw(baseModelRaw: base, effort: effort)
        }
        return base
    }

    static func canonicalClaudeGLMModelRaw(_ rawModel: String?) -> String? {
        guard let rawModel = normalizedRawModel(rawModel) else {
            return ClaudeCodeGLMIntegration.normalizedGLMModel(nil)
        }
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        guard let baseModel = specifier.baseModel else {
            return rawModel
        }
        if ClaudeCompatibleProviderRuntimeBridge.isDirectSelectableGLMModel(baseModel) {
            let directBase = baseModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let effort = specifier.effortLevel {
                return ClaudeModelSpecifier.encodedRaw(baseModelRaw: directBase, effort: effort)
            }
            return directBase
        }
        guard let mappedBaseModel = ClaudeCodeGLMIntegration.normalizedGLMModel(baseModel) else {
            return rawModel
        }
        if let effort = specifier.effortLevel {
            return ClaudeModelSpecifier.encodedRaw(baseModelRaw: mappedBaseModel, effort: effort)
        }
        return mappedBaseModel
    }

    static func isValid(
        rawModel: String,
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> Bool? {
        guard ClaudeCompatiblePluginBridge.pluginID(for: agentKind) != nil else { return nil }
        guard AgentModelCatalog.isAgentAvailable(agentKind, availability: availability) else { return false }
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if compatibleBackendID(for: agentKind) != nil {
            return isValidCompatibleBackendModel(normalized, for: agentKind, availability: availability)
        }

        let specifier = ClaudeModelSpecifier(raw: normalized)
        guard let baseModel = specifier.baseModel else {
            if let effort = specifier.effortLevel {
                return claudeEffort(effort, isSupportedForBaseModelRaw: nil, agentKind: agentKind)
            }
            return agentKind == .claudeCode
        }
        if let effort = specifier.effortLevel,
           !claudeEffort(effort, isSupportedForBaseModelRaw: baseModel, agentKind: agentKind)
        {
            return false
        }
        guard let known = AgentModel.resolvedModel(forRaw: baseModel, agentKind: agentKind) else {
            return agentKind == .claudeCode && isSupportedClaudeCodePointRelease(rawModel: normalized)
        }
        guard known.isValidFor(agentKind) else { return false }
        return known.isAvailable
    }

    /// Grammar-valid same-family point releases stay runnable on the first-party Claude Code
    /// path even when no static `AgentModel` case exists. Recognition is deliberately
    /// registry-independent so stored selections survive withdrawal: `true` only when the base
    /// has no static resolution, parses through `ClaudeModelFamilyCatalog.cliPointRelease`
    /// (strict family/major/minor/date grammar plus the CLI `[1m]` qualifier), and any effort
    /// suffix is supported by that family. Shared by `isValid` and Claude `code_mode`
    /// eligibility so both read one authority.
    static func isSupportedClaudeCodePointRelease(rawModel: String) -> Bool {
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        guard let baseModel = specifier.baseModel,
              AgentModel.resolvedModel(forRaw: baseModel, agentKind: .claudeCode) == nil,
              let pointRelease = ClaudeModelFamilyCatalog.cliPointRelease(baseModel)
        else {
            return false
        }
        guard let effort = specifier.effortLevel else { return true }
        return claudeEffort(effort, isSupportedForBaseModelRaw: baseModel, agentKind: .claudeCode)
            && pointRelease.family.supportedEfforts.contains(effort)
    }

    static func claudeEffort(
        _ effort: ClaudeCodeEffortLevel,
        isSupportedForBaseModelRaw baseModelRaw: String?,
        agentKind: AgentProviderKind?
    ) -> Bool {
        if let agentKind, compatibleBackendModelBehavior(for: agentKind) == .noModel {
            return false
        }
        guard effort == .xhigh else { return true }
        if let agentKind, compatibleBackendID(for: agentKind) != nil {
            guard let baseModelRaw,
                  let config = compatibleBackendConfig(for: agentKind),
                  let canonicalBase = canonicalCompatibleBackendBaseRaw(baseModelRaw, for: agentKind)
            else {
                return false
            }
            let backendModelID = directBackendModelID(forCanonicalBaseRaw: canonicalBase, agentKind: agentKind)
                ?? backendModelID(forCanonicalSlotRaw: canonicalBase, config: config)
            return ClaudeCompatibleProviderRuntimeBridge.supportsGLMXHighEffort(backendModelID: backendModelID)
        }
        guard let baseModelRaw else { return false }
        let normalized = baseModelRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if claudeXHighEligibleBaseRaws.contains(normalized) {
            return true
        }
        // Grammar-based xhigh eligibility shares the `.claudeCode` gate with the
        // grammar branch in `isValid`; every caller with dynamic-model access
        // passes a concrete agent kind, so nil never unlocks the grammar path.
        guard agentKind == .claudeCode else { return false }
        return ClaudeModelFamilyCatalog.cliPointRelease(normalized)?.family.xhighEligible == true
    }

    /// Splices API-registry and verified CLI point releases into standard Claude
    /// Code only. Exact IDs and CLI context qualifiers are retained; family
    /// grammar still owns effort metadata. Compatible backends never receive
    /// these entries, and the provider package snapshot remains static.
    private static func optionsSplicingDynamicClaudePointReleases(
        into pluginOptions: [ClaudeCompatiblePluginModelOption],
        includeClaudeEffortVariants: Bool,
        store: AnthropicDiscoveredModelStore,
        cliStore: ClaudeCLIDiscoveredModelStore
    ) -> [ClaudeCompatiblePluginModelOption] {
        let staticBaseRaws = Set(pluginOptions.compactMap { option -> String? in
            ClaudeModelSpecifier(raw: option.rawValue).baseModel?.lowercased()
        })
        let dynamicDefinitions = ClaudeCodeAIModelCatalog.effectiveDefinitions(store: store, cliStore: cliStore)
            .compactMap { definition -> (ClaudeModelFamilyCatalog.PointRelease, ClaudeCodeAIModelCatalog.ModelDefinition)? in
                guard let pointRelease = ClaudeModelFamilyCatalog.cliPointRelease(definition.runtimeModelRaw),
                      AgentModel.resolvedModel(forRaw: definition.runtimeModelRaw, agentKind: .claudeCode) == nil,
                      !staticBaseRaws.contains(definition.runtimeModelRaw.lowercased())
                else {
                    return nil
                }
                return (pointRelease, definition)
            }
        guard !dynamicDefinitions.isEmpty else { return pluginOptions }

        var options = pluginOptions
        for (pointRelease, definition) in dynamicDefinitions {
            options.insert(
                contentsOf: dynamicPluginOptions(
                    for: definition,
                    includeEffortVariants: includeClaudeEffortVariants
                ),
                at: dynamicSpliceIndex(for: pointRelease, in: options)
            )
        }
        return options
    }

    private static func dynamicSpliceIndex(
        for pointRelease: ClaudeModelFamilyCatalog.PointRelease,
        in options: [ClaudeCompatiblePluginModelOption]
    ) -> Int {
        for (index, option) in options.enumerated() {
            guard let base = ClaudeModelSpecifier(raw: option.rawValue).baseModel else { continue }
            if base.caseInsensitiveCompare(pointRelease.family.anchor) == .orderedSame {
                return index
            }
            guard let existing = ClaudeModelFamilyCatalog.cliPointRelease(base.lowercased()),
                  existing.family.anchor == pointRelease.family.anchor,
                  ClaudeModelFamilyCatalog.pointReleasePrecedes(pointRelease, existing)
            else {
                continue
            }
            return index
        }
        return options.count
    }

    private static func dynamicPluginOptions(
        for definition: ClaudeCodeAIModelCatalog.ModelDefinition,
        includeEffortVariants: Bool
    ) -> [ClaudeCompatiblePluginModelOption] {
        let description = "Discovered Claude Code point release, listed automatically from verified model metadata."
        guard includeEffortVariants, !definition.supportedEfforts.isEmpty else {
            return [ClaudeCompatiblePluginModelOption(
                rawValue: definition.runtimeModelRaw,
                displayName: definition.displayName,
                description: description,
                isPlaceholderDefault: false,
                isProviderDefault: false,
                supportedEffortLevels: definition.supportedEfforts.map(\.rawValue)
            )]
        }
        return definition.supportedEfforts.map { effort in
            ClaudeCompatiblePluginModelOption(
                rawValue: "\(definition.runtimeModelRaw):\(effort.rawValue)",
                displayName: "\(definition.displayName) \(effort.displayName)",
                description: description,
                isPlaceholderDefault: false,
                isProviderDefault: false,
                supportedEffortLevels: []
            )
        }
    }

    private static func pluginCatalogSnapshot(
        pluginID: ClaudeCompatiblePluginID,
        agentKind: AgentProviderKind,
        includeClaudeEffortVariants: Bool
    ) -> ClaudeCompatiblePluginModelCatalogSnapshot {
        ClaudeCompatibleProviderRuntimeBridge.modelCatalogSnapshot(
            pluginID: pluginID,
            backendConfig: compatibleBackendConfig(for: agentKind),
            includeEffortVariants: includeClaudeEffortVariants
        )
    }

    private static func canonicalPluginModelOption(
        _ option: ClaudeCompatiblePluginModelOption,
        for agentKind: AgentProviderKind
    ) -> ClaudeCompatiblePluginModelOption {
        ClaudeCompatiblePluginModelOption(
            rawValue: canonicalModelRaw(option.rawValue, for: agentKind),
            displayName: option.displayName,
            description: option.description,
            isPlaceholderDefault: option.isPlaceholderDefault,
            isProviderDefault: option.isProviderDefault,
            supportedEffortLevels: option.supportedEffortLevels
        )
    }

    private static func modelOption(from option: ClaudeCompatiblePluginModelOption, for agentKind: AgentProviderKind) -> AgentModelOption {
        AgentModelOption(
            rawValue: canonicalModelRaw(option.rawValue, for: agentKind),
            displayName: option.displayName,
            description: option.description,
            isPlaceholderDefault: option.isPlaceholderDefault,
            isProviderDefault: option.isProviderDefault
        )
    }

    private static func optionMetadata(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> ClaudeCompatiblePluginModelOption? {
        guard let pluginID = ClaudeCompatiblePluginBridge.pluginID(for: agentKind),
              let canonical = canonicalCompatibleBackendBaseRaw(rawModel, for: agentKind) else { return nil }
        let snapshot = pluginCatalogSnapshot(
            pluginID: pluginID,
            agentKind: agentKind,
            includeClaudeEffortVariants: false
        )
        return snapshot.options.first {
            canonicalModelRaw($0.rawValue, for: agentKind).caseInsensitiveCompare(canonical) == .orderedSame
        }
    }

    private static func canonicalModelRaw(_ rawValue: String, for agentKind: AgentProviderKind) -> String {
        let specifier = ClaudeModelSpecifier(raw: rawValue)
        guard let baseModel = specifier.baseModel else {
            return AgentModel.defaultModel.rawValue
        }
        let canonicalBase = canonicalBaseModelRaw(baseModel, for: agentKind) ?? baseModel
        if let effort = specifier.effortLevel {
            return ClaudeModelSpecifier.encodedRaw(baseModelRaw: canonicalBase, effort: effort)
        }
        return canonicalBase
    }

    private static func canonicalBaseModelRaw(_ rawValue: String, for agentKind: AgentProviderKind) -> String? {
        if let compatible = canonicalCompatibleBackendBaseRaw(rawValue, for: agentKind) {
            return compatible
        }
        if rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame {
            return AgentModel.defaultModel.rawValue
        }
        if let known = AgentModel(rawValue: rawValue) {
            return known.rawValue
        }
        if agentKind == .claudeCodeGLM,
           let mapped = ClaudeCodeGLMIntegration.normalizedGLMModel(rawValue)
        {
            return mapped
        }
        return nil
    }

    private static func isValidCompatibleBackendModel(
        _ rawModel: String,
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> Bool {
        guard AgentModelCatalog.isAgentAvailable(agentKind, availability: availability) else { return false }
        guard let config = compatibleBackendConfig(for: agentKind) else { return false }
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        switch config.modelBehavior {
        case .noModel:
            guard specifier.effortLevel == nil,
                  let base = specifier.baseModel else { return false }
            return compatibleBackendID(for: agentKind).map { base.caseInsensitiveCompare(noModelRawValue(for: $0)) == .orderedSame } ?? false
        case .claudeSlotMapping:
            guard let canonical = canonicalCompatibleBackendModelRaw(rawModel, for: agentKind) else { return false }
            let canonicalSpecifier = ClaudeModelSpecifier(raw: canonical)
            guard let base = canonicalSpecifier.baseModel else { return false }
            let validSlotBase = [AgentModel.claudeHaiku.rawValue, AgentModel.claudeSonnet.rawValue, AgentModel.claudeOpus.rawValue].contains(base)
            let validDirectBase = directBackendModelID(forCanonicalBaseRaw: base, agentKind: agentKind) != nil
            guard validSlotBase || validDirectBase else { return false }
            if let effort = canonicalSpecifier.effortLevel {
                return claudeEffort(effort, isSupportedForBaseModelRaw: base, agentKind: agentKind)
            }
            return true
        }
    }

    private static func directBackendModelID(
        forCanonicalBaseRaw baseRaw: String,
        agentKind: AgentProviderKind
    ) -> String? {
        guard agentKind == .claudeCodeGLM,
              ClaudeCompatibleProviderRuntimeBridge.isDirectSelectableGLMModel(baseRaw)
        else { return nil }
        return baseRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func backendModelID(
        forCanonicalSlotRaw slotRaw: String,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> String? {
        guard case let .claudeSlotMapping(mapping) = config.modelBehavior else { return nil }
        let normalized = mapping.normalized
        switch slotRaw {
        case AgentModel.claudeHaiku.rawValue:
            return normalized.haiku
        case AgentModel.claudeSonnet.rawValue:
            return normalized.sonnet
        case AgentModel.claudeOpus.rawValue:
            return normalized.opus
        default:
            return nil
        }
    }

    private static func compatibleBackendID(for agentKind: AgentProviderKind) -> ClaudeCodeCompatibleBackendID? {
        switch agentKind {
        case .claudeCodeGLM:
            .glmZAI
        case .kimiCode:
            .kimi
        case .customClaudeCompatible:
            .custom
        case .claudeCode, .codexExec, .openCode, .cursor, .ohMyPi:
            nil
        }
    }

    private static func compatibleBackendConfig(for agentKind: AgentProviderKind) -> ClaudeCodeCompatibleBackendConfig? {
        compatibleBackendID(for: agentKind).map { ClaudeCodeCompatibleBackendStore.shared.config(for: $0).normalized }
    }

    private static func noModelRawValue(for id: ClaudeCodeCompatibleBackendID) -> String {
        ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: id)
    }

    private static func normalizedRawModel(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Exact static base model raw values (lowercased) that support XHigh.
    static let claudeXHighEligibleBaseRaws: Set<String> = [
        AgentModel.claudeFable51.rawValue.lowercased(),
        AgentModel.claudeFable5.rawValue.lowercased(),
        AgentModel.claudeSonnet5.rawValue.lowercased(),
        AgentModel.claudeOpus.rawValue.lowercased(),
        AgentModel.claudeOpus1m.rawValue.lowercased(),
        AgentModel.claudeOpus55.rawValue.lowercased(),
        AgentModel.claudeOpus5.rawValue.lowercased(),
        AgentModel.claudeOpus47.rawValue.lowercased(),
        AgentModel.claudeOpus46.rawValue.lowercased(),
        AgentModel.claudeOpus45.rawValue.lowercased()
    ]
}
