import Foundation
import RepoPromptWorkspace

// MARK: - Agent Session Error

package enum AgentSessionError: Error, LocalizedError {
    case emptySession
    case invalidFilename(String)
    case decodingFailed(DecodingError)
    case loadFailed(Error)
    case noActiveWorkspace
    case invalidHandoffCutoff
    case remoteManaged(String)

    var localizedDescription: String {
        switch self {
        case .emptySession:
            "Cannot save an empty agent session"
        case let .invalidFilename(name):
            "Invalid agent session filename: \(name)"
        case let .decodingFailed(error):
            "Failed to decode agent session: \(error.localizedDescription)"
        case let .loadFailed(error):
            "Failed to load agent session: \(error.localizedDescription)"
        case .noActiveWorkspace:
            "No active workspace for agent session"
        case .invalidHandoffCutoff:
            "The selected handoff point is no longer available in this session transcript."
        case let .remoteManaged(reason):
            reason
        }
    }

    package var errorDescription: String? {
        localizedDescription
    }
}

package struct AgentTokenUsagePersist: Codable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    package let contextUsedTokens: Int?
    let estimatedUserInputTokens: Int
    let estimatedToolInputTokens: Int
    let estimatedToolOutputTokens: Int
    let timestamp: Date

    init(
        promptTokens: Int,
        completionTokens: Int,
        contextUsedTokens: Int? = nil,
        estimatedUserInputTokens: Int = 0,
        estimatedToolInputTokens: Int = 0,
        estimatedToolOutputTokens: Int = 0,
        timestamp: Date = Date()
    ) {
        self.promptTokens = max(0, promptTokens)
        self.completionTokens = max(0, completionTokens)
        if let contextUsedTokens {
            let normalized = max(0, contextUsedTokens)
            self.contextUsedTokens = normalized > 0 ? normalized : nil
        } else {
            self.contextUsedTokens = nil
        }
        self.estimatedUserInputTokens = max(0, estimatedUserInputTokens)
        self.estimatedToolInputTokens = max(0, estimatedToolInputTokens)
        self.estimatedToolOutputTokens = max(0, estimatedToolOutputTokens)
        self.timestamp = timestamp
    }

    var estimatedInputTokens: Int {
        estimatedUserInputTokens + estimatedToolInputTokens + estimatedToolOutputTokens
    }

    var providerTotalTokens: Int {
        promptTokens + completionTokens
    }

    var totalTokens: Int {
        if let contextUsedTokens, contextUsedTokens > 0 {
            return contextUsedTokens
        }
        let provider = providerTotalTokens
        if provider > 0 {
            return provider
        }
        return estimatedInputTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens
        case completionTokens
        case contextUsedTokens
        case estimatedUserInputTokens
        case estimatedToolInputTokens
        case estimatedToolOutputTokens
        case timestamp
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try max(0, container.decode(Int.self, forKey: .promptTokens))
        completionTokens = try max(0, container.decode(Int.self, forKey: .completionTokens))
        if let decodedContext = try container.decodeIfPresent(Int.self, forKey: .contextUsedTokens) {
            let normalized = max(0, decodedContext)
            contextUsedTokens = normalized > 0 ? normalized : nil
        } else {
            contextUsedTokens = nil
        }
        estimatedUserInputTokens = try max(0, container.decodeIfPresent(Int.self, forKey: .estimatedUserInputTokens) ?? 0)
        estimatedToolInputTokens = try max(0, container.decodeIfPresent(Int.self, forKey: .estimatedToolInputTokens) ?? 0)
        estimatedToolOutputTokens = try max(0, container.decodeIfPresent(Int.self, forKey: .estimatedToolOutputTokens) ?? 0)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encodeIfPresent(contextUsedTokens, forKey: .contextUsedTokens)
        try container.encode(estimatedUserInputTokens, forKey: .estimatedUserInputTokens)
        try container.encode(estimatedToolInputTokens, forKey: .estimatedToolInputTokens)
        try container.encode(estimatedToolOutputTokens, forKey: .estimatedToolOutputTokens)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

// MARK: - Remote Session Binding

package struct AgentSessionRemoteHostBinding: Codable, Equatable {
    package var hostID: String
    package var hostDisplayName: String
    package var remoteSessionID: String
    var lastAppliedSeq: UInt64
    var seqEpoch: String?
    var nextLogOffset: Int

    package var normalizedRemoteSessionID: String? {
        let trimmed = remoteSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    package init(
        hostID: String,
        hostDisplayName: String,
        remoteSessionID: String,
        lastAppliedSeq: UInt64 = 0,
        seqEpoch: String? = nil,
        nextLogOffset: Int = 0
    ) {
        self.hostID = hostID
        self.hostDisplayName = hostDisplayName
        self.remoteSessionID = remoteSessionID
        self.lastAppliedSeq = lastAppliedSeq
        self.seqEpoch = seqEpoch
        self.nextLogOffset = nextLogOffset
    }
}

// MARK: - Agent Session

// swiftformat:disable:next redundantSendable
package struct PersistedRemoteResendPayload: Codable, Sendable, Equatable {
    package let providerText: String
    package let wasStart: Bool
    package let modelSelectionRaw: String?
    package let sessionName: String?
    package let workspaceName: String?
    package let windowID: Int?
    package let workspaceID: String?

    package init(
        providerText: String,
        wasStart: Bool,
        modelSelectionRaw: String?,
        sessionName: String?,
        workspaceName: String?,
        windowID: Int? = nil,
        workspaceID: String? = nil
    ) {
        self.providerText = providerText
        self.wasStart = wasStart
        self.modelSelectionRaw = modelSelectionRaw
        self.sessionName = sessionName
        // A window ID is the routing authority. For mixed legacy input, prefer
        // that explicit target and discard the name rather than ANDing conflicting selectors.
        let normalizedWorkspaceID = workspaceID.flatMap { $0.isEmpty ? nil : $0 }
        if let windowID {
            self.workspaceName = nil
            self.windowID = windowID
            self.workspaceID = normalizedWorkspaceID
        } else {
            self.workspaceName = workspaceName
            self.windowID = nil
            self.workspaceID = nil
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerText: container.decode(String.self, forKey: .providerText),
            wasStart: container.decode(Bool.self, forKey: .wasStart),
            modelSelectionRaw: container.decodeIfPresent(String.self, forKey: .modelSelectionRaw),
            sessionName: container.decodeIfPresent(String.self, forKey: .sessionName),
            workspaceName: container.decodeIfPresent(String.self, forKey: .workspaceName),
            windowID: container.decodeIfPresent(Int.self, forKey: .windowID),
            workspaceID: container.decodeIfPresent(String.self, forKey: .workspaceID)
        )
    }
}

/// Persisted agent mode session containing the chat transcript and configuration
package struct AgentSession: Codable, Identifiable {
    static let currentSerializationVersion = 7
    static let legacyUnversionedSerializationVersion = 0
    /// Envelopes this build may normalize or rewrite: legacy unversioned through current. Future
    /// and negative versions are preserved untouched and never receive editable authority.
    static let supportedSerializationVersions = legacyUnversionedSerializationVersion ... currentSerializationVersion

    package let id: UUID
    package var serializationVersion: Int
    package var workspaceID: UUID?
    package var composeTabID: UUID?
    package var name: String
    package var savedAt: Date
    package var fileURL: URL?

    /// Last user interaction timestamp (user message or answered question)
    package var lastUserMessageAt: Date?

    /// Mutable full-detail working suffix retained for runtime compatibility and legacy decode.
    /// Newly persisted sessions store this empty and rebuild it from the transcript when needed.
    package var items: [AgentChatItemPersist]

    /// Bounded, UI-only Oracle identity payloads keyed by tool-result row ID.
    /// These are never embedded in the agent-facing transcript or handoff serialization.
    package var uiToolResultPayloadsByItemID: [String: String]

    /// Structured transcript source of truth. Compacted turns may retain only summary shells.
    package var transcript: AgentTranscript?

    /// Optional lightweight item count for sessions where transcript/items are unloaded.
    package var itemCount: Int?

    /// Snapshot of canonical vs default-presented transcript counts.
    var transcriptProjectionCounts: AgentTranscriptProjectionCounts?

    /// Agent kind used for this session (e.g., "claudeCode", "codexExec", "openCode")
    package var agentKind: String?

    /// Model used for this session (e.g., "sonnet", "opus", "codexMedium")
    package var agentModel: String?

    /// Destination-owned OMP thinking selections for this tab/session.
    package var ohMyPiThinkingSelections: OhMyPiThinkingSelections?

    /// User-selected reasoning effort (Codex-only)
    package var agentReasoningEffort: String?

    /// State of the last run
    package var lastRunState: String?

    /// Provider-specific resumable session identifier (e.g., Claude CLI session_id)
    /// Used to resume conversations with --resume instead of replaying history
    package var providerSessionID: String?

    /// Remote host/session binding for client-projected gateway sessions.
    package var remoteHost: AgentSessionRemoteHostBinding?

    /// Safe resend recovery data for undelivered remote user turns.
    package var remoteResendPayloadsByItemID: [String: PersistedRemoteResendPayload]

    /// Optimistic item whose locally successful remote start produced the adopted session.
    package var locallyAttributedStartItemID: UUID?

    package var autoEditEnabled: Bool

    /// Persisted per-turn token usage for non-Codex providers.
    /// Used to rebuild context usage after reopen/resume when tool payloads are pruned.
    package var providerTokenUsageByTurn: [AgentTokenUsagePersist]

    /// Field-local provider accounting (plan §3.3). `nil` means absent/unavailable and is omitted on
    /// encode; a present member (explicit `null`, unsupported, malformed or future values included)
    /// is preserved as raw bytes in `.opaque`. Persisted data must be read and written through
    /// `AgentSessionDataCodec`, which captures and re-inserts those bytes; the generic `Codable`
    /// path below only accepts the lossless subset (absent, `null`, strict typed v1) and fails
    /// explicitly otherwise.
    package var providerUsage: AgentProviderUsagePersist?

    /// Codex native session identifiers (v2 thread and rollout path)
    package var codexConversationID: String?
    package var codexRolloutPath: String?

    /// Codex native session metadata
    package var codexModel: String?
    package var codexReasoningEffort: String?
    package var codexContextWindow: Int?
    package var codexLastTotalTokens: Int?
    package var codexTotalTotalTokens: Int?
    package var codexMcpSessionKey: String?

    /// Parent session ID for thread nesting (child sessions spawned from another session)
    package var parentSessionID: UUID?

    /// Whether this session was originally created by an MCP client (vs the user in the UI).
    /// Used to scope cleanup operations to MCP-originated sessions only.
    /// Legacy compatibility flag — derived from `origin` and kept serialized so
    /// older builds keep decoding it (plan §6.4).
    package var isMCPOriginated: Bool

    /// Session provenance (plan §6.4): `.user`, `.mcp(clientID:)`, or
    /// `.remote(deviceID:)`. Source of truth for `isMCPOriginated`.
    package var origin: AgentSessionOrigin

    /// Stable top-level behavior profile selected for this session.
    package var profile: AgentSessionProfile

    /// Persisted per-session logical-root to worktree bindings.
    /// Runtime cwd/path projection is resolved by downstream worktree-system layers.
    package var worktreeBindings: [AgentSessionWorktreeBinding]

    /// Persisted resumable worktree-merge operations for this Agent session.
    /// Patch contents live in merge preview artifacts, not in the session JSON.
    package var worktreeMergeOperations: [AgentSessionWorktreeMergeOperation]

    /// Pending handoff payload (injected into the provider-facing text on the destination tab's
    /// first user send, then cleared). Persisted so it survives close/reopen.
    package var pendingHandoffPayload: String?
    package var pendingHandoffCreatedAt: Date?
    package var pendingHandoffSourceItemID: UUID?
    /// Durable identity of the pending payload (`AgentPendingHandoffState.payloadID`). Optional v7
    /// member: absent on legacy payloads, which are assigned an ID before any dispatch.
    package var pendingHandoffPayloadID: UUID?
    package var pendingHandoffDefersProviderLockUntilSend: Bool

    /// Pending delayed send and the most recent accepted scheduled dispatch.
    package var scheduledSend: AgentScheduledSendMember?
    package var lastScheduledDispatch: AgentScheduledSendProvenance?

    /// Durable lifecycle authority (incarnation and reset identity). A missing member is a legacy
    /// session awaiting migration; explicit `null` or unknown content is `.unreadable` and is
    /// never writable. Only `AgentSessionDataService` assigns or advances typed values.
    package var lifecycle: AgentSessionLifecycleMember?

    /// Provider-history reconciliation ledger and latest import receipt (lossless restart Phase 4).
    /// Optional v7 member, absent when empty; committed only through
    /// `AgentSessionDataService.commitProviderHistoryImport`, and an older snapshot can never replace
    /// a newer committed import (`AgentSessionDataService` stale-import guard).
    package var providerHistoryRecovery: AgentSessionProviderHistoryRecovery?

    package init(
        id: UUID = UUID(),
        serializationVersion: Int = AgentSession.currentSerializationVersion,
        workspaceID: UUID? = nil,
        composeTabID: UUID? = nil,
        name: String = "Agent Session",
        savedAt: Date = Date(),
        fileURL: URL? = nil,
        items: [AgentChatItemPersist] = [],
        uiToolResultPayloadsByItemID: [String: String] = [:],
        transcript: AgentTranscript? = nil,
        itemCount: Int? = nil,
        transcriptProjectionCounts: AgentTranscriptProjectionCounts? = nil,
        lastUserMessageAt: Date? = nil,
        agentKind: String? = nil,
        agentModel: String? = nil,
        ohMyPiThinkingSelections: OhMyPiThinkingSelections? = nil,
        agentReasoningEffort: String? = nil,
        lastRunState: String? = nil,
        providerSessionID: String? = nil,
        remoteHost: AgentSessionRemoteHostBinding? = nil,
        remoteResendPayloadsByItemID: [String: PersistedRemoteResendPayload] = [:],
        locallyAttributedStartItemID: UUID? = nil,
        autoEditEnabled: Bool = true,
        providerTokenUsageByTurn: [AgentTokenUsagePersist] = [],
        providerUsage: AgentProviderUsagePersist? = nil,
        codexConversationID: String? = nil,
        codexRolloutPath: String? = nil,
        codexModel: String? = nil,
        codexReasoningEffort: String? = nil,
        codexContextWindow: Int? = nil,
        codexLastTotalTokens: Int? = nil,
        codexTotalTotalTokens: Int? = nil,
        codexMcpSessionKey: String? = nil,
        parentSessionID: UUID? = nil,
        pendingHandoffPayload: String? = nil,
        pendingHandoffCreatedAt: Date? = nil,
        pendingHandoffSourceItemID: UUID? = nil,
        pendingHandoffPayloadID: UUID? = nil,
        pendingHandoffDefersProviderLockUntilSend: Bool = false,
        scheduledSend: AgentScheduledSendMember? = nil,
        lastScheduledDispatch: AgentScheduledSendProvenance? = nil,
        isMCPOriginated: Bool = false,
        origin: AgentSessionOrigin? = nil,
        profile: AgentSessionProfile = .standard,
        worktreeBindings: [AgentSessionWorktreeBinding] = [],
        worktreeMergeOperations: [AgentSessionWorktreeMergeOperation] = [],
        lifecycle: AgentSessionLifecycleMember? = nil,
        providerHistoryRecovery: AgentSessionProviderHistoryRecovery? = nil
    ) {
        self.providerHistoryRecovery = providerHistoryRecovery?.nilIfEmpty
        self.id = id
        self.serializationVersion = serializationVersion
        self.workspaceID = workspaceID
        self.composeTabID = composeTabID
        self.name = name
        self.savedAt = savedAt
        self.fileURL = fileURL
        self.items = items
        self.uiToolResultPayloadsByItemID = uiToolResultPayloadsByItemID
        self.transcript = transcript
        self.itemCount = itemCount
        self.transcriptProjectionCounts = transcriptProjectionCounts
        self.lastUserMessageAt = lastUserMessageAt
        self.agentKind = agentKind
        self.agentModel = agentModel
        self.ohMyPiThinkingSelections = ohMyPiThinkingSelections?.nilIfEmpty
        self.agentReasoningEffort = agentReasoningEffort
        self.lastRunState = lastRunState
        self.providerSessionID = providerSessionID
        self.remoteHost = remoteHost
        self.remoteResendPayloadsByItemID = remoteResendPayloadsByItemID
        self.locallyAttributedStartItemID = locallyAttributedStartItemID
        self.autoEditEnabled = autoEditEnabled
        self.providerTokenUsageByTurn = providerTokenUsageByTurn
        self.providerUsage = providerUsage
        self.codexConversationID = codexConversationID
        self.codexRolloutPath = codexRolloutPath
        self.codexModel = codexModel
        self.codexReasoningEffort = codexReasoningEffort
        self.codexContextWindow = codexContextWindow
        self.codexLastTotalTokens = codexLastTotalTokens
        self.codexTotalTotalTokens = codexTotalTotalTokens
        self.codexMcpSessionKey = codexMcpSessionKey
        self.parentSessionID = parentSessionID
        self.pendingHandoffPayload = pendingHandoffPayload
        self.pendingHandoffCreatedAt = pendingHandoffCreatedAt
        self.pendingHandoffSourceItemID = pendingHandoffSourceItemID
        self.pendingHandoffPayloadID = pendingHandoffPayloadID
        self.pendingHandoffDefersProviderLockUntilSend = pendingHandoffDefersProviderLockUntilSend
        self.scheduledSend = scheduledSend
        self.lastScheduledDispatch = lastScheduledDispatch
        let resolvedOrigin = origin ?? AgentSessionOrigin(legacyIsMCPOriginated: isMCPOriginated)
        self.origin = resolvedOrigin
        self.isMCPOriginated = resolvedOrigin.isMCPOriginated
        self.profile = profile
        self.worktreeBindings = worktreeBindings
        self.worktreeMergeOperations = worktreeMergeOperations
        self.lifecycle = lifecycle
    }

    enum CodingKeys: String, CodingKey {
        case id
        case serializationVersion
        case workspaceID
        case composeTabID
        case name
        case savedAt
        case fileURL
        case items
        case uiToolResultPayloadsByItemID
        case transcript
        case itemCount
        case transcriptProjectionCounts
        case lastUserMessageAt
        case agentKind
        case agentModel
        case ohMyPiThinkingSelections
        case agentReasoningEffort
        case lastRunState
        case providerSessionID
        case remoteHost
        case remoteResendPayloadsByItemID
        case locallyAttributedStartItemID
        case autoEditEnabled
        case providerTokenUsageByTurn
        case providerUsage
        case codexConversationID
        case codexRolloutPath
        case codexModel
        case codexReasoningEffort
        case codexContextWindow
        case codexLastTotalTokens
        case codexTotalTotalTokens
        case codexMcpSessionKey
        case parentSessionID
        case pendingHandoffPayload
        case pendingHandoffCreatedAt
        case pendingHandoffSourceItemID
        case pendingHandoffPayloadID
        case pendingHandoffDefersProviderLockUntilSend
        case scheduledSend
        case lastScheduledDispatch
        case isMCPOriginated
        case origin
        case profile
        case worktreeBindings
        case worktreeMergeOperations
        case lifecycle
        case providerHistoryRecovery
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        serializationVersion = try container.decodeIfPresent(Int.self, forKey: .serializationVersion)
            ?? Self.legacyUnversionedSerializationVersion
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
        name = try container.decode(String.self, forKey: .name)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
        items = try container.decodeIfPresent([AgentChatItemPersist].self, forKey: .items) ?? []
        uiToolResultPayloadsByItemID = try container.decodeIfPresent(
            [String: String].self,
            forKey: .uiToolResultPayloadsByItemID
        ) ?? [:]
        transcript = try container.decodeIfPresent(AgentTranscript.self, forKey: .transcript)
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
        transcriptProjectionCounts = try container.decodeIfPresent(AgentTranscriptProjectionCounts.self, forKey: .transcriptProjectionCounts)
        lastUserMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt)
        agentKind = try container.decodeIfPresent(String.self, forKey: .agentKind)
        agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
        ohMyPiThinkingSelections = try container.decodeIfPresent(
            OhMyPiThinkingSelections.self,
            forKey: .ohMyPiThinkingSelections
        )?.nilIfEmpty
        agentReasoningEffort = try container.decodeIfPresent(String.self, forKey: .agentReasoningEffort)
        lastRunState = try container.decodeIfPresent(String.self, forKey: .lastRunState)
        providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
        remoteHost = try container.decodeIfPresent(AgentSessionRemoteHostBinding.self, forKey: .remoteHost)
        remoteResendPayloadsByItemID = try container.decodeIfPresent(
            [String: PersistedRemoteResendPayload].self,
            forKey: .remoteResendPayloadsByItemID
        ) ?? [:]
        locallyAttributedStartItemID = try container.decodeIfPresent(UUID.self, forKey: .locallyAttributedStartItemID)
        autoEditEnabled = try container.decode(Bool.self, forKey: .autoEditEnabled)
        providerTokenUsageByTurn = try container.decodeIfPresent([AgentTokenUsagePersist].self, forKey: .providerTokenUsageByTurn) ?? []
        // Absent stays absent. `AgentSessionDataCodec` strips this member before decoding and
        // re-attaches the captured bytes; a member reaching this generic path is limited to the
        // lossless subset and fails explicitly outside it.
        providerUsage = container.contains(.providerUsage)
            ? try container.decode(AgentProviderUsagePersist.self, forKey: .providerUsage)
            : nil
        codexConversationID = try container.decodeIfPresent(String.self, forKey: .codexConversationID)
        codexRolloutPath = try container.decodeIfPresent(String.self, forKey: .codexRolloutPath)
        codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel)
        codexReasoningEffort = try container.decodeIfPresent(String.self, forKey: .codexReasoningEffort)
        codexContextWindow = try container.decodeIfPresent(Int.self, forKey: .codexContextWindow)
        codexLastTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexLastTotalTokens)
        codexTotalTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexTotalTotalTokens)
        codexMcpSessionKey = try container.decodeIfPresent(String.self, forKey: .codexMcpSessionKey)
        parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        pendingHandoffPayload = try container.decodeIfPresent(String.self, forKey: .pendingHandoffPayload)
        pendingHandoffCreatedAt = try container.decodeIfPresent(Date.self, forKey: .pendingHandoffCreatedAt)
        pendingHandoffSourceItemID = try container.decodeIfPresent(UUID.self, forKey: .pendingHandoffSourceItemID)
        pendingHandoffPayloadID = try container.decodeIfPresent(UUID.self, forKey: .pendingHandoffPayloadID)
        pendingHandoffDefersProviderLockUntilSend = try container.decodeIfPresent(Bool.self, forKey: .pendingHandoffDefersProviderLockUntilSend) ?? false
        scheduledSend = try container.decodeIfPresent(AgentScheduledSendMember.self, forKey: .scheduledSend)
        lastScheduledDispatch = try container.decodeIfPresent(
            AgentScheduledSendProvenance.self,
            forKey: .lastScheduledDispatch
        )
        let legacyIsMCPOriginated = try container.decodeIfPresent(Bool.self, forKey: .isMCPOriginated) ?? false
        let decodedOrigin = try container.decodeIfPresent(AgentSessionOrigin.self, forKey: .origin)
            ?? AgentSessionOrigin(legacyIsMCPOriginated: legacyIsMCPOriginated)
        origin = decodedOrigin
        isMCPOriginated = decodedOrigin.isMCPOriginated
        if container.contains(.profile) {
            guard try !container.decodeNil(forKey: .profile) else {
                throw DecodingError.valueNotFound(
                    AgentSessionProfile.self,
                    .init(
                        codingPath: container.codingPath + [CodingKeys.profile],
                        debugDescription: "Agent session profile cannot be null"
                    )
                )
            }
            profile = try container.decode(AgentSessionProfile.self, forKey: .profile)
        } else {
            profile = .standard
        }
        worktreeBindings = try container.decodeIfPresent([AgentSessionWorktreeBinding].self, forKey: .worktreeBindings) ?? []
        worktreeMergeOperations = try container.decodeIfPresent([AgentSessionWorktreeMergeOperation].self, forKey: .worktreeMergeOperations) ?? []
        lifecycle = try Self.decodeLifecycleMember(from: container, forKey: .lifecycle)
        providerHistoryRecovery = try container.decodeIfPresent(
            AgentSessionProviderHistoryRecovery.self,
            forKey: .providerHistoryRecovery
        )?.nilIfEmpty
    }

    /// Key-presence decoding: absent is legacy (`nil`); explicit `null` is unreadable.
    static func decodeLifecycleMember<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> AgentSessionLifecycleMember? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) {
            return .unreadable(.null)
        }
        return try container.decode(AgentSessionLifecycleMember.self, forKey: key)
    }

    /// Coalesces whitespace and falls back to "Agent Session" when empty.
    package static func validatedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.isEmpty ? "Agent Session" : collapsed
    }
}

// MARK: - AgentSession Extensions

extension AgentSession {
    /// Canonical item count for UI and sorting when `items` may be unloaded.
    package var effectiveItemCount: Int {
        effectiveCanonicalItemCount
    }

    var effectiveCanonicalItemCount: Int {
        if let transcriptProjectionCounts {
            return transcriptProjectionCounts.canonicalVisibleRowCount
        }
        if let itemCount {
            return itemCount
        }
        if let transcript {
            return AgentTranscriptProjectionBuilder.projectionCounts(for: transcript).canonicalVisibleRowCount
        }
        return items.count
    }

    var effectiveDefaultPresentedItemCount: Int {
        if let transcriptProjectionCounts {
            return transcriptProjectionCounts.defaultPresentedRowCount
        }
        if let transcript {
            return AgentTranscriptProjectionBuilder.projectionCounts(for: transcript).defaultPresentedRowCount
        }
        if let itemCount {
            return itemCount
        }
        return items.count
    }

    func visibleItemCount(showCompressedHistory: Bool) -> Int {
        showCompressedHistory ? effectiveCanonicalItemCount : effectiveDefaultPresentedItemCount
    }

    var hasItems: Bool {
        effectiveItemCount > 0
    }

    /// Returns true if this session is a lightweight stub (items unloaded)
    var isListStub: Bool {
        items.isEmpty && transcript == nil && itemCount != nil
    }

    /// Returns a lightweight copy suitable for session lists (drops heavy payloads)
    func listStub() -> AgentSession {
        var copy = self
        copy.itemCount = effectiveCanonicalItemCount
        copy.items = []
        copy.transcript = nil
        return copy
    }

    /// Converts the session into renderable chat rows, including compacted transcript summaries.
    func toLiveItems() -> [AgentChatItem] {
        if let transcript {
            let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
            return (projection.archivedRows + projection.workingRows).sorted { lhs, rhs in
                if lhs.sequenceIndex == rhs.sequenceIndex {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
        }
        return items.map { $0.toItem() }
    }

    /// Returns only the mutable full-detail suffix used by runtime/live refresh logic.
    func workingSourceItems() -> [AgentChatItem] {
        if let transcript {
            return AgentTranscriptIO.workingSourceItems(from: transcript)
        }
        return items.map { $0.toItem() }
    }

    /// Creates a new session with updated items from live chat items
    func withItems(_ liveItems: [AgentChatItem]) -> AgentSession {
        var copy = self
        copy.items = liveItems.map { AgentChatItemPersist(from: $0) }
        let transcript = AgentTranscriptIO.buildTranscript(
            from: liveItems,
            nextSequenceIndex: (liveItems.map(\.sequenceIndex).max() ?? -1) + 1,
            policy: .canonical
        )
        copy.transcript = transcript
        let projectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
        copy.itemCount = projectionCounts.canonicalVisibleRowCount
        copy.transcriptProjectionCounts = projectionCounts
        copy.lastUserMessageAt = AgentTranscriptIO.lastUserInteractionDate(in: transcript)
        copy.savedAt = Date()
        return copy
    }
}

// MARK: - Conversation History Builder

extension AgentSession {
    /// Builds a conversation history string suitable for sending to an agent on session resume.
    /// This allows the agent to continue where it left off.
    func buildConversationHistory() -> String {
        if let transcript {
            return AgentTranscriptIO.buildConversationHistory(from: transcript)
        }
        return AgentTranscriptIO.buildConversationHistory(
            from: AgentTranscriptIO.buildTranscript(
                from: items.map { $0.toItem() },
                nextSequenceIndex: (items.map(\.sequenceIndex).max() ?? -1) + 1,
                policy: .canonical,
                compact: false
            )
        )
    }
}
