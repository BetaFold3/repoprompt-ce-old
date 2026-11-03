import Foundation
import RepoPromptAgentCore

/// Versioned JSON document stored at
/// `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`.
///
/// Schema v1 contains copy settings, chat settings, and cross-workspace global
/// defaults. Schema v2 adds optional scalar preference groups. Schema v4 adds
/// workspace-scoped Agent Models profiles. Schema v5 protects persisted per-role OMP
/// thinking intent. Schema v6 protects workspace steering grants. Scalar fields stay optional so missing
/// JSON fields fall back through the typed GlobalSettingsStore accessors without
/// losing current default behavior.
struct GlobalSettingsDocument: Codable {
    /// Fixed feature-version constants are permanent compatibility boundaries. Add a new
    /// constant for each schema-requiring feature; never infer an existing feature's minimum
    /// version from `currentSchemaVersion`.
    static let baselineSchemaVersion = 2
    static let workspaceAgentModelsSchemaVersion = 4
    static let mcpAgentRoleOhMyPiThinkingSchemaVersion = 5
    /// Nonempty grants stamp v6 so builds without grant support preserve (never overwrite) them.
    static let workspaceSteeringGrantsSchemaVersion = 6
    static let currentSchemaVersion = 6
    /// Lineage marker for settings files written by this open-source CE schema family.
    ///
    /// CE inherited numeric schema versions from classic/internal builds, so version numbers
    /// alone are not globally meaningful. Unlineaged v1/v2 files are accepted as legacy CE
    /// documents; unlineaged higher versions are treated as foreign/future documents even if
    /// this fork later reaches the same numeric schema version.
    static let schemaLineage = "repoprompt-ce.global-settings"
    /// FROZEN at 2 forever: this is the last schema version OSS CE wrote without
    /// a lineage marker. It must never track `currentSchemaVersion`.
    static let legacyUnlineagedSchemaVersionCeiling = 2

    var schemaVersion: Int
    var schemaLineage: String?
    var updatedAt: Date
    var copySettingsByWorkspaceID: [String: CopyGlobalSettings]
    var chatSettingsByWorkspaceID: [String: ChatGlobalSettings]
    var agentModelsSettingsByWorkspaceID: [String: WorkspaceAgentModelsSettings]?
    var globalDefaults: GlobalDefaults
    var scalarPreferences: GlobalScalarPreferences?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date = Date(),
        copySettings: [UUID: CopyGlobalSettings] = [:],
        chatSettings: [UUID: ChatGlobalSettings] = [:],
        agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] = [:],
        globalDefaults: GlobalDefaults = GlobalDefaults(discoverAgentRaw: nil, discoverModelsByAgent: nil),
        scalarPreferences: GlobalScalarPreferences? = nil
    ) {
        self.schemaVersion = schemaVersion
        schemaLineage = Self.schemaLineage
        self.updatedAt = updatedAt
        copySettingsByWorkspaceID = Self.encodeUUIDKeyedDictionary(copySettings)
        chatSettingsByWorkspaceID = Self.encodeUUIDKeyedDictionary(chatSettings)
        agentModelsSettingsByWorkspaceID = agentModelsSettings.isEmpty
            ? nil
            : Self.encodeUUIDKeyedDictionary(agentModelsSettings)
        var normalizedGlobalDefaults = globalDefaults
        normalizedGlobalDefaults.mcpAgentRoleOhMyPiThinkingSelections =
            AgentModelsSettingsProfile.normalizedRoleThinkingSelections(
                globalDefaults.mcpAgentRoleOhMyPiThinkingSelections
            )
        self.globalDefaults = normalizedGlobalDefaults
        self.scalarPreferences = scalarPreferences
    }

    var copySettings: [UUID: CopyGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(copySettingsByWorkspaceID)
    }

    var chatSettings: [UUID: ChatGlobalSettings] {
        Self.decodeUUIDKeyedDictionary(chatSettingsByWorkspaceID)
    }

    var agentModelsSettings: [UUID: WorkspaceAgentModelsSettings] {
        Self.decodeUUIDKeyedDictionary(agentModelsSettingsByWorkspaceID ?? [:])
    }

    /// Lowest CE schema version that can faithfully represent this document's content.
    ///
    /// Each feature contributes its own fixed introduction version. Future schema bumps must
    /// add another feature constant and participate in this maximum; they must not change the
    /// minimum version of content that existing features already know how to represent.
    var requiredSchemaVersion: Int {
        var requiredVersion = Self.baselineSchemaVersion
        if let agentModelsSettingsByWorkspaceID, !agentModelsSettingsByWorkspaceID.isEmpty {
            requiredVersion = max(requiredVersion, Self.workspaceAgentModelsSchemaVersion)
        }
        let hasGlobalRoleThinking = globalDefaults.mcpAgentRoleOhMyPiThinkingSelections?
            .values.contains(where: { !$0.isEmpty }) == true
        let hasWorkspaceRoleThinking = agentModelsSettingsByWorkspaceID?.values.contains { settings in
            settings.profile?.mcpAgentRoleOhMyPiThinkingSelections?
                .values.contains(where: { !$0.isEmpty }) == true
        } == true
        if hasGlobalRoleThinking || hasWorkspaceRoleThinking {
            requiredVersion = max(requiredVersion, Self.mcpAgentRoleOhMyPiThinkingSchemaVersion)
        }
        if scalarPreferences?.workspaceSteeringGrants?.isEmpty == false {
            requiredVersion = max(requiredVersion, Self.workspaceSteeringGrantsSchemaVersion)
        }
        return requiredVersion
    }

    func replacing(
        copySettings: [UUID: CopyGlobalSettings],
        chatSettings: [UUID: ChatGlobalSettings],
        agentModelsSettings: [UUID: WorkspaceAgentModelsSettings],
        globalDefaults: GlobalDefaults,
        scalarPreferences: GlobalScalarPreferences? = nil,
        updatedAt: Date = Date()
    ) -> GlobalSettingsDocument {
        GlobalSettingsDocument(
            schemaVersion: Self.currentSchemaVersion,
            updatedAt: updatedAt,
            copySettings: copySettings,
            chatSettings: chatSettings,
            agentModelsSettings: agentModelsSettings,
            globalDefaults: globalDefaults,
            scalarPreferences: scalarPreferences ?? self.scalarPreferences
        )
    }

    private static func encodeUUIDKeyedDictionary<Value>(_ values: [UUID: Value]) -> [String: Value] {
        values.reduce(into: [String: Value]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
    }

    private static func decodeUUIDKeyedDictionary<Value>(_ values: [String: Value]) -> [UUID: Value] {
        values.reduce(into: [UUID: Value]()) { result, entry in
            guard let uuid = UUID(uuidString: entry.key) else { return }
            result[uuid] = entry.value
        }
    }
}

// MARK: - Scoped Agent Models Settings

enum AgentModelsInheritanceMode: String, Codable, Equatable {
    case useGlobalSettings
    case useWorkspaceOverrides
}

enum AgentModelsEditingScope: Hashable {
    case global
    case workspace(UUID)
}

/// Stable identity for one Agent Models operation. The source workspace drives
/// workspace-local wizard bookkeeping while `scope` is the exact durable profile
/// the operation may read or mutate.
struct AgentModelsOperationIdentity: Hashable {
    let sourceWorkspaceID: UUID
    let scope: AgentModelsEditingScope

    init(sourceWorkspaceID: UUID, scope: AgentModelsEditingScope) {
        self.sourceWorkspaceID = sourceWorkspaceID
        self.scope = scope
    }

    init(sourceWorkspaceID: UUID, inheritanceMode: AgentModelsInheritanceMode) {
        self.sourceWorkspaceID = sourceWorkspaceID
        scope = inheritanceMode == .useWorkspaceOverrides ? .workspace(sourceWorkspaceID) : .global
    }

    func matches(sourceWorkspaceID: UUID, inheritanceMode: AgentModelsInheritanceMode) -> Bool {
        self == AgentModelsOperationIdentity(
            sourceWorkspaceID: sourceWorkspaceID,
            inheritanceMode: inheritanceMode
        )
    }
}

enum ContextBuilderSettingsWriteIntent {
    case preserveExistingOwnership
    case userInitiated
    case automaticSeed
}

struct AgentModelsSettingsProfile: Codable, Equatable {
    var planningModelRaw: String?
    var preferredComposeModelRaw: String?
    var planningModelOhMyPiThinkingSelections: OhMyPiThinkingSelections
    var preferredComposeOhMyPiThinkingSelections: OhMyPiThinkingSelections
    var syncChatModelWithOracle: Bool
    var contextBuilderAgentRaw: String?
    var contextBuilderOhMyPiThinkingSelections: OhMyPiThinkingSelections
    var contextBuilderModelsByAgent: [String: String]?
    var mcpAgentRoleOverrides: [String: String]?
    var mcpAgentRoleOhMyPiThinkingSelections: [String: OhMyPiThinkingSelections]?
    var restrictMCPAgentDiscoveryToRoleLabels: Bool

    init(
        planningModelRaw: String? = nil,
        preferredComposeModelRaw: String? = nil,
        planningModelOhMyPiThinkingSelections: OhMyPiThinkingSelections = .empty,
        preferredComposeOhMyPiThinkingSelections: OhMyPiThinkingSelections = .empty,
        syncChatModelWithOracle: Bool = false,
        contextBuilderAgentRaw: String? = nil,
        contextBuilderOhMyPiThinkingSelections: OhMyPiThinkingSelections = .empty,
        contextBuilderModelsByAgent: [String: String]? = nil,
        mcpAgentRoleOverrides: [String: String]? = nil,
        mcpAgentRoleOhMyPiThinkingSelections: [String: OhMyPiThinkingSelections]? = nil,
        restrictMCPAgentDiscoveryToRoleLabels: Bool = false
    ) {
        self.planningModelRaw = Self.normalizedChatModelRaw(planningModelRaw)
        self.preferredComposeModelRaw = Self.normalizedChatModelRaw(preferredComposeModelRaw)
        self.planningModelOhMyPiThinkingSelections = planningModelOhMyPiThinkingSelections
        self.preferredComposeOhMyPiThinkingSelections = preferredComposeOhMyPiThinkingSelections
        self.syncChatModelWithOracle = syncChatModelWithOracle
        self.contextBuilderAgentRaw = Self.normalizedAgentRaw(contextBuilderAgentRaw)
        self.contextBuilderOhMyPiThinkingSelections = contextBuilderOhMyPiThinkingSelections
        self.contextBuilderModelsByAgent = Self.normalizedContextBuilderModelsByAgent(contextBuilderModelsByAgent)
        self.mcpAgentRoleOverrides = Self.normalizedStringMap(mcpAgentRoleOverrides)
        self.mcpAgentRoleOhMyPiThinkingSelections = Self.normalizedRoleThinkingSelections(
            mcpAgentRoleOhMyPiThinkingSelections
        )
        self.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
    }

    private enum CodingKeys: String, CodingKey {
        case planningModelRaw
        case preferredComposeModelRaw
        case planningModelOhMyPiThinkingSelections
        case preferredComposeOhMyPiThinkingSelections
        case syncChatModelWithOracle
        case contextBuilderAgentRaw
        case contextBuilderOhMyPiThinkingSelections
        case contextBuilderModelsByAgent
        case mcpAgentRoleOverrides
        case mcpAgentRoleOhMyPiThinkingSelections
        case restrictMCPAgentDiscoveryToRoleLabels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            planningModelRaw: container.decodeIfPresent(String.self, forKey: .planningModelRaw),
            preferredComposeModelRaw: container.decodeIfPresent(String.self, forKey: .preferredComposeModelRaw),
            planningModelOhMyPiThinkingSelections: OhMyPiThinkingSelections.decodeIfPresent(
                from: container,
                forKey: .planningModelOhMyPiThinkingSelections
            ),
            preferredComposeOhMyPiThinkingSelections: OhMyPiThinkingSelections.decodeIfPresent(
                from: container,
                forKey: .preferredComposeOhMyPiThinkingSelections
            ),
            syncChatModelWithOracle: container.decodeIfPresent(Bool.self, forKey: .syncChatModelWithOracle) ?? false,
            contextBuilderAgentRaw: container.decodeIfPresent(String.self, forKey: .contextBuilderAgentRaw),
            contextBuilderOhMyPiThinkingSelections: OhMyPiThinkingSelections.decodeIfPresent(
                from: container,
                forKey: .contextBuilderOhMyPiThinkingSelections
            ),
            contextBuilderModelsByAgent: container.decodeIfPresent([String: String].self, forKey: .contextBuilderModelsByAgent),
            mcpAgentRoleOverrides: container.decodeIfPresent([String: String].self, forKey: .mcpAgentRoleOverrides),
            mcpAgentRoleOhMyPiThinkingSelections: container.decodeIfPresent(
                [String: OhMyPiThinkingSelections].self,
                forKey: .mcpAgentRoleOhMyPiThinkingSelections
            ),
            restrictMCPAgentDiscoveryToRoleLabels: container.decodeIfPresent(Bool.self, forKey: .restrictMCPAgentDiscoveryToRoleLabels) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(planningModelRaw, forKey: .planningModelRaw)
        try container.encodeIfPresent(preferredComposeModelRaw, forKey: .preferredComposeModelRaw)
        try planningModelOhMyPiThinkingSelections.encodeIfNonEmpty(
            to: &container,
            forKey: .planningModelOhMyPiThinkingSelections
        )
        try preferredComposeOhMyPiThinkingSelections.encodeIfNonEmpty(
            to: &container,
            forKey: .preferredComposeOhMyPiThinkingSelections
        )
        try container.encode(syncChatModelWithOracle, forKey: .syncChatModelWithOracle)
        try container.encodeIfPresent(contextBuilderAgentRaw, forKey: .contextBuilderAgentRaw)
        try contextBuilderOhMyPiThinkingSelections.encodeIfNonEmpty(
            to: &container,
            forKey: .contextBuilderOhMyPiThinkingSelections
        )
        try container.encodeIfPresent(contextBuilderModelsByAgent, forKey: .contextBuilderModelsByAgent)
        try container.encodeIfPresent(mcpAgentRoleOverrides, forKey: .mcpAgentRoleOverrides)
        try container.encodeIfPresent(
            Self.normalizedRoleThinkingSelections(mcpAgentRoleOhMyPiThinkingSelections),
            forKey: .mcpAgentRoleOhMyPiThinkingSelections
        )
        try container.encode(
            restrictMCPAgentDiscoveryToRoleLabels,
            forKey: .restrictMCPAgentDiscoveryToRoleLabels
        )
    }

    func replacingContextBuilderModel(_ modelRaw: String?, for agentRaw: String?) -> AgentModelsSettingsProfile {
        let resolvedAgentRaw = Self.normalizedAgentRaw(agentRaw) ?? contextBuilderAgentRaw
        guard let resolvedAgentRaw else { return self }

        var next = self
        var modelsByAgent = contextBuilderModelsByAgent ?? [:]
        if let normalizedModelRaw = Self.trimmedNonEmpty(modelRaw) {
            modelsByAgent[resolvedAgentRaw] = normalizedModelRaw
        } else {
            modelsByAgent[resolvedAgentRaw] = nil
        }
        next.contextBuilderModelsByAgent = modelsByAgent.isEmpty ? nil : modelsByAgent
        return next
    }

    private static func normalizedChatModelRaw(_ raw: String?) -> String? {
        trimmedNonEmpty(raw)
    }

    private static func normalizedAgentRaw(_ raw: String?) -> String? {
        trimmedNonEmpty(raw)
    }

    private static func normalizedContextBuilderModelsByAgent(_ values: [String: String]?) -> [String: String]? {
        normalizedStringMap(values)
    }

    private static func normalizedStringMap(_ values: [String: String]?) -> [String: String]? {
        guard let values else { return nil }
        let normalized = values.keys.sorted().reduce(into: [String: String]()) { result, rawKey in
            guard let key = trimmedNonEmpty(rawKey),
                  let value = trimmedNonEmpty(values[rawKey])
            else {
                return
            }
            result[key] = value
        }
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedRoleThinkingSelections(
        _ values: [String: OhMyPiThinkingSelections]?
    ) -> [String: OhMyPiThinkingSelections]? {
        guard let values else { return nil }
        let normalized = values.keys.sorted().reduce(into: [String: OhMyPiThinkingSelections]()) { result, rawKey in
            guard let key = trimmedNonEmpty(rawKey),
                  let selections = values[rawKey],
                  !selections.isEmpty
            else {
                return
            }
            result[key] = selections
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

struct WorkspaceAgentModelsSettings: Codable, Equatable {
    var inheritanceMode: AgentModelsInheritanceMode
    var profile: AgentModelsSettingsProfile?

    init(
        inheritanceMode: AgentModelsInheritanceMode = .useGlobalSettings,
        profile: AgentModelsSettingsProfile? = nil
    ) {
        self.inheritanceMode = inheritanceMode
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case inheritanceMode, profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inheritanceMode = try container.decodeIfPresent(AgentModelsInheritanceMode.self, forKey: .inheritanceMode)
            ?? .useGlobalSettings
        profile = try container.decodeIfPresent(AgentModelsSettingsProfile.self, forKey: .profile)
    }
}

// MARK: - Worktree Visual Identity

enum WorktreeVisualMarkerStyle: String, Codable, Equatable {
    case dot
    case ring
    case capsule
}

struct WorktreeVisualIdentity: Codable, Equatable {
    static let defaultIconName = "circle.fill"
    static let defaultMarkerStyle = WorktreeVisualMarkerStyle.dot

    var label: String?
    var colorHex: String
    var iconName: String
    var markerStyle: WorktreeVisualMarkerStyle
    var updatedAt: Date?

    init(
        label: String? = nil,
        colorHex: String,
        iconName: String = Self.defaultIconName,
        markerStyle: WorktreeVisualMarkerStyle = Self.defaultMarkerStyle,
        updatedAt: Date? = nil
    ) {
        self.label = label
        self.colorHex = colorHex
        self.iconName = iconName
        self.markerStyle = markerStyle
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case label, colorHex, iconName, markerStyle, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? Self.defaultIconName
        markerStyle = try container.decodeIfPresent(WorktreeVisualMarkerStyle.self, forKey: .markerStyle) ?? Self.defaultMarkerStyle
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct WorktreeVisualIdentityRepositoryBucket: Codable, Equatable {
    var identitiesByWorktreeID: [String: WorktreeVisualIdentity]

    init(identitiesByWorktreeID: [String: WorktreeVisualIdentity] = [:]) {
        self.identitiesByWorktreeID = identitiesByWorktreeID
    }
}

// MARK: - Scalar Preferences

/// Optional scalar preferences stored in schema v2.
///
/// Keep groups and fields optional so missing values continue to use the same
/// defaults as the typed settings accessors.
struct GlobalScalarPreferences: Codable, Equatable {
    var ui: UISettings?
    var promptPackaging: PromptPackagingSettings?
    var modelSelection: ModelSelectionSettings?
    var mcp: MCPSettings?
    var fileSystem: FileSystemSettings?
    var agentMode: AgentModeSettings?
    var telemetry: TelemetrySettings?
    var modelOverrides: ModelOverrideSettingsData?
    /// Telegram attention notifications (enable flag and chat ID only; the bot token lives in
    /// secure storage, never here).
    var telegram: TelegramSettings?
    /// One-way workspace→workspace steering grants; nil (the old-file default) means none.
    /// Nonempty grants require schema v6. Written only through `WorkspaceSteeringGrantStore`.
    var workspaceSteeringGrants: [WorkspaceSteeringGrant]?

    init(
        ui: UISettings? = nil,
        promptPackaging: PromptPackagingSettings? = nil,
        modelSelection: ModelSelectionSettings? = nil,
        mcp: MCPSettings? = nil,
        fileSystem: FileSystemSettings? = nil,
        agentMode: AgentModeSettings? = nil,
        telemetry: TelemetrySettings? = nil,
        modelOverrides: ModelOverrideSettingsData? = nil,
        telegram: TelegramSettings? = nil,
        workspaceSteeringGrants: [WorkspaceSteeringGrant]? = nil
    ) {
        self.ui = ui
        self.promptPackaging = promptPackaging
        self.modelSelection = modelSelection
        self.mcp = mcp
        self.fileSystem = fileSystem
        self.agentMode = agentMode
        self.telemetry = telemetry
        self.modelOverrides = modelOverrides
        self.telegram = telegram
        self.workspaceSteeringGrants = workspaceSteeringGrants
    }

    struct UISettings: Codable, Equatable {
        var appearanceMode: String?
        var useTransparency: Bool?
        var collapseLatestFileChanges: Bool?
        var showTooltips: Bool?
        var experimentalAttributedTextEditor: Bool?
        var fileMentionPickerStyle: String?
        var enableKeyboardShortcuts: Bool?
        var fontScaleBodySize: Double?
        var showDatesInMessageTimestamps: Bool?
        /// Whether normal app quit requests require explicit confirmation.
        var warnBeforeQuit: Bool?
        /// Preferred width of the Agent Mode right utility panel, stored unscaled (at the
        /// `.normal` font preset) so the value stays stable across font-scale changes.
        var agentUtilityPanelWidth: Double?
        /// When true, transcript unified-diff and tool code-block fallbacks wrap lines instead of
        /// scrolling horizontally. Defaults off so today's clipping + h-scroll path stays unchanged.
        var wrapTranscriptDiffLines: Bool?
        /// Optional PostScript face name for transcript code/diff rendering. `nil` keeps today's
        /// system monospaced behavior; invalid/uninstalled faces fall back silently at resolve time.
        var transcriptCodeFontPostScriptName: String?

        init(
            appearanceMode: String? = nil,
            useTransparency: Bool? = nil,
            collapseLatestFileChanges: Bool? = nil,
            showTooltips: Bool? = nil,
            experimentalAttributedTextEditor: Bool? = nil,
            fileMentionPickerStyle: String? = nil,
            enableKeyboardShortcuts: Bool? = nil,
            fontScaleBodySize: Double? = nil,
            showDatesInMessageTimestamps: Bool? = nil,
            warnBeforeQuit: Bool? = nil,
            agentUtilityPanelWidth: Double? = nil,
            wrapTranscriptDiffLines: Bool? = nil,
            transcriptCodeFontPostScriptName: String? = nil
        ) {
            self.appearanceMode = appearanceMode
            self.useTransparency = useTransparency
            self.collapseLatestFileChanges = collapseLatestFileChanges
            self.showTooltips = showTooltips
            self.experimentalAttributedTextEditor = experimentalAttributedTextEditor
            self.fileMentionPickerStyle = fileMentionPickerStyle
            self.enableKeyboardShortcuts = enableKeyboardShortcuts
            self.fontScaleBodySize = fontScaleBodySize
            self.showDatesInMessageTimestamps = showDatesInMessageTimestamps
            self.warnBeforeQuit = warnBeforeQuit
            self.agentUtilityPanelWidth = agentUtilityPanelWidth
            self.wrapTranscriptDiffLines = wrapTranscriptDiffLines
            self.transcriptCodeFontPostScriptName = transcriptCodeFontPostScriptName
        }
    }

    struct PromptPackagingSettings: Codable, Equatable {
        var promptSectionsOrder: String?
        var duplicateUserInstructionsAtTop: Bool?
        var filePathDisplayOption: String?
        var selectedFilesSortMethod: String?
        var fileEditFormat: String?
        var includeDatetimeInUserInstructions: Bool?
        var customPlanningPrompt: String?
        var modelTemperature: Double?
        var setModelTemperature: Bool?
        var complexEditStrategy: String?

        init(
            promptSectionsOrder: String? = nil,
            duplicateUserInstructionsAtTop: Bool? = nil,
            filePathDisplayOption: String? = nil,
            selectedFilesSortMethod: String? = nil,
            fileEditFormat: String? = nil,
            includeDatetimeInUserInstructions: Bool? = nil,
            customPlanningPrompt: String? = nil,
            modelTemperature: Double? = nil,
            setModelTemperature: Bool? = nil,
            complexEditStrategy: String? = nil
        ) {
            self.promptSectionsOrder = promptSectionsOrder
            self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
            self.filePathDisplayOption = filePathDisplayOption
            self.selectedFilesSortMethod = selectedFilesSortMethod
            self.fileEditFormat = fileEditFormat
            self.includeDatetimeInUserInstructions = includeDatetimeInUserInstructions
            self.customPlanningPrompt = customPlanningPrompt
            self.modelTemperature = modelTemperature
            self.setModelTemperature = setModelTemperature
            self.complexEditStrategy = complexEditStrategy
        }
    }

    struct ModelSelectionSettings: Codable, Equatable {
        var preferredComposeModel: String?
        var planningModel: String?
        var preferredComposeOhMyPiThinkingSelections: OhMyPiThinkingSelections?
        var planningModelOhMyPiThinkingSelections: OhMyPiThinkingSelections?
        var syncChatModelWithOracle: Bool?

        init(
            preferredComposeModel: String? = nil,
            planningModel: String? = nil,
            preferredComposeOhMyPiThinkingSelections: OhMyPiThinkingSelections? = nil,
            planningModelOhMyPiThinkingSelections: OhMyPiThinkingSelections? = nil,
            syncChatModelWithOracle: Bool? = nil
        ) {
            self.preferredComposeModel = preferredComposeModel
            self.planningModel = planningModel
            self.preferredComposeOhMyPiThinkingSelections = preferredComposeOhMyPiThinkingSelections?.nilIfEmpty
            self.planningModelOhMyPiThinkingSelections = planningModelOhMyPiThinkingSelections?.nilIfEmpty
            self.syncChatModelWithOracle = syncChatModelWithOracle
        }
    }

    struct MCPSettings: Codable, Equatable {
        /// Suggested `tailscale serve --https` port for the browser remote (Serve's 443 may be taken).
        static let suggestedBrowserHTTPSPort = 8443

        var autoStart: Bool?
        var showModelPresets: Bool?
        var temporarilyDisablePresets: Bool?
        var remoteGatewayEnabled: Bool?
        var remoteGatewayBindAddress: String?
        var remoteGatewayPort: Int?
        var remoteControlShowPairingDetails: Bool?
        /// The owner's `tailscale serve --https=<port>` listener that forwards to this build's
        /// gateway. Missing means unset: no browser HTTPS origin and no Telegram session links.
        var remoteGatewayBrowserHTTPSPort: Int?
        /// `MCPStructuredResultsMode` raw value; nil or unknown reads as `off`.
        var structuredResults: String?

        init(
            autoStart: Bool? = nil,
            showModelPresets: Bool? = nil,
            temporarilyDisablePresets: Bool? = nil,
            remoteGatewayEnabled: Bool? = nil,
            remoteGatewayBindAddress: String? = nil,
            remoteGatewayPort: Int? = nil,
            remoteControlShowPairingDetails: Bool? = nil,
            remoteGatewayBrowserHTTPSPort: Int? = nil,
            structuredResults: String? = nil
        ) {
            self.autoStart = autoStart
            self.showModelPresets = showModelPresets
            self.temporarilyDisablePresets = temporarilyDisablePresets
            self.remoteGatewayEnabled = remoteGatewayEnabled
            self.remoteGatewayBindAddress = remoteGatewayBindAddress
            self.remoteGatewayPort = remoteGatewayPort
            self.remoteControlShowPairingDetails = remoteControlShowPairingDetails
            self.remoteGatewayBrowserHTTPSPort = remoteGatewayBrowserHTTPSPort
            self.structuredResults = structuredResults
        }

        /// A usable browser HTTPS port: 1–65535 and not 443 (left to other Serve configurations).
        static func isValidBrowserHTTPSPort(_ port: Int) -> Bool {
            (1 ... 65535).contains(port) && port != 443
        }
    }

    struct FileSystemSettings: Codable, Equatable {
        var respectRepoIgnore: Bool?
        var respectCursorignore: Bool?
        var globalIgnoreDefaults: String?
        var enableHierarchicalIgnores: Bool?
        var skipSymlinks: Bool?
        var showEmptyFolders: Bool?

        init(
            respectRepoIgnore: Bool? = nil,
            respectCursorignore: Bool? = nil,
            globalIgnoreDefaults: String? = nil,
            enableHierarchicalIgnores: Bool? = nil,
            skipSymlinks: Bool? = nil,
            showEmptyFolders: Bool? = nil
        ) {
            self.respectRepoIgnore = respectRepoIgnore
            self.respectCursorignore = respectCursorignore
            self.globalIgnoreDefaults = globalIgnoreDefaults
            self.enableHierarchicalIgnores = enableHierarchicalIgnores
            self.skipSymlinks = skipSymlinks
            self.showEmptyFolders = showEmptyFolders
        }
    }

    struct TelemetrySettings: Codable, Equatable {
        var enabled: Bool?
        var appHangReportsEnabled: Bool?
        var performanceTracingEnabled: Bool?

        init(
            enabled: Bool? = nil,
            appHangReportsEnabled: Bool? = nil,
            performanceTracingEnabled: Bool? = nil
        ) {
            self.enabled = enabled
            self.appHangReportsEnabled = appHangReportsEnabled
            self.performanceTracingEnabled = performanceTracingEnabled
        }
    }

    struct TelegramSettings: Codable, Equatable {
        static let defaultIdleThresholdMinutes = 5

        var enabled: Bool?
        var chatID: String?
        /// Minimum Mac idle minutes before an automatic notification is sent. Missing (or an
        /// invalid negative stored value) means the default 5; 0 means always notify.
        var idleThresholdMinutes: Int?

        init(enabled: Bool? = nil, chatID: String? = nil, idleThresholdMinutes: Int? = nil) {
            self.enabled = enabled
            self.chatID = chatID
            self.idleThresholdMinutes = idleThresholdMinutes
        }

        /// The idle threshold in effect for a stored settings group (nil group or field: default).
        static func effectiveIdleThresholdMinutes(_ settings: TelegramSettings?) -> Int {
            guard let stored = settings?.idleThresholdMinutes, stored >= 0 else { return defaultIdleThresholdMinutes }
            return stored
        }
    }

    struct ModelOverrideSettingsData: Codable, Equatable {
        var diffOverrides: [String: Bool]?
        var streamOverrides: [String: Bool]?
        var temperatureOverrides: [String: Double]?
        var responsesOverrides: [String: Bool]?

        init(
            diffOverrides: [String: Bool]? = nil,
            streamOverrides: [String: Bool]? = nil,
            temperatureOverrides: [String: Double]? = nil,
            responsesOverrides: [String: Bool]? = nil
        ) {
            self.diffOverrides = diffOverrides
            self.streamOverrides = streamOverrides
            self.temperatureOverrides = temperatureOverrides
            self.responsesOverrides = responsesOverrides
        }
    }

    struct AgentModeSettings: Codable, Equatable {
        var proEditAgentMode: Bool?
        var proEditAgentKind: String?
        var proEditAgentModel: String?
        var proEditAgentModeMigrated: Bool?
        // DEPRECATED: Auto-Expand Tool Cards was removed in 2026-04.
        // Kept temporarily for decode/rollback compatibility only; do not read from UI/runtime.
        var agentAutoExpandToolCards: Bool?
        var maxBackgroundAgentComposeTabs: Int?
        var showBuiltInWorkflowCleanupGuidance: Bool?
        var codexGoalSupportEnabled: Bool?
        var codexComputerUseEnabled: Bool?
        var codexReasoningSummariesEnabled: Bool?
        var restrictMCPAgentDiscoveryToRoleLabels: Bool?

        init(
            proEditAgentMode: Bool? = nil,
            proEditAgentKind: String? = nil,
            proEditAgentModel: String? = nil,
            proEditAgentModeMigrated: Bool? = nil,
            agentAutoExpandToolCards: Bool? = nil,
            maxBackgroundAgentComposeTabs: Int? = nil,
            showBuiltInWorkflowCleanupGuidance: Bool? = nil,
            codexGoalSupportEnabled: Bool? = nil,
            codexComputerUseEnabled: Bool? = nil,
            codexReasoningSummariesEnabled: Bool? = nil,
            restrictMCPAgentDiscoveryToRoleLabels: Bool? = nil
        ) {
            self.proEditAgentMode = proEditAgentMode
            self.proEditAgentKind = proEditAgentKind
            self.proEditAgentModel = proEditAgentModel
            self.proEditAgentModeMigrated = proEditAgentModeMigrated
            self.agentAutoExpandToolCards = agentAutoExpandToolCards
            self.maxBackgroundAgentComposeTabs = maxBackgroundAgentComposeTabs
            self.showBuiltInWorkflowCleanupGuidance = showBuiltInWorkflowCleanupGuidance
            self.codexGoalSupportEnabled = codexGoalSupportEnabled
            self.codexComputerUseEnabled = codexComputerUseEnabled
            self.codexReasoningSummariesEnabled = codexReasoningSummariesEnabled
            self.restrictMCPAgentDiscoveryToRoleLabels = restrictMCPAgentDiscoveryToRoleLabels
        }
    }
}
