import Foundation
import MCP
import RepoPromptAgentCore

@MainActor
struct AgentManageMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata

    let toolName: String
    let captureRequestMetadata: () async -> RequestMetadata
    let requireTargetWindow: () throws -> WindowState
    let resolveSpawnSourceTabID: (_ metadata: RequestMetadata) async -> UUID?
    let resolveSpawnParentSessionID: (_ metadata: RequestMetadata, _ targetWindow: WindowState) async -> UUID?
    let bindCurrentRequestToTab: (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void
    let restrictDiscoveryToRoleLabels: @MainActor (_ workspaceID: UUID?) -> Bool
    let cursorParameterMetadataBuilder: CursorAgentParameterMetadataBuilder
    /// Rejects a request that came from an Agent Mode run whose source tab could not be
    /// resolved, so it is never mistaken for an external client outside the delegation ceiling.
    var validateSpawnRouting: (_ metadata: RequestMetadata, _ sourceTabID: UUID?, _ operation: String) async throws -> Void = { _, _, _ in }

    init(
        toolName: String,
        captureRequestMetadata: @escaping () async -> RequestMetadata,
        requireTargetWindow: @escaping () throws -> WindowState,
        resolveSpawnSourceTabID: @escaping (_ metadata: RequestMetadata) async -> UUID?,
        resolveSpawnParentSessionID: @escaping (_ metadata: RequestMetadata, _ targetWindow: WindowState) async -> UUID?,
        bindCurrentRequestToTab: @escaping (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void,
        restrictDiscoveryToRoleLabels: @escaping @MainActor (_ workspaceID: UUID?) -> Bool = { workspaceID in
            GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: workspaceID).restrictMCPAgentDiscoveryToRoleLabels
        },
        cursorParameterMetadataBuilder: CursorAgentParameterMetadataBuilder = CursorAgentParameterMetadataBuilder()
    ) {
        self.toolName = toolName
        self.captureRequestMetadata = captureRequestMetadata
        self.requireTargetWindow = requireTargetWindow
        self.resolveSpawnSourceTabID = resolveSpawnSourceTabID
        self.resolveSpawnParentSessionID = resolveSpawnParentSessionID
        self.bindCurrentRequestToTab = bindCurrentRequestToTab
        self.restrictDiscoveryToRoleLabels = restrictDiscoveryToRoleLabels
        self.cursorParameterMetadataBuilder = cursorParameterMetadataBuilder
    }

    private struct HandoffSessionInfo {
        let sessionID: UUID
        let name: String
        let transcript: AgentTranscript
        let sourceTabID: UUID?
        let sourceTabName: String
        let sourceAgentName: String
        let sourceModelName: String
        let isLive: Bool
    }

    private struct CleanupSessionCandidate {
        let sessionID: UUID
        let name: String
        let tabID: UUID?
        let isLive: Bool
        let isMCPOriginated: Bool
        let origin: AgentSessionOrigin?
        let runStateRaw: String?
        let isEffectivelyActive: Bool
    }

    func execute(args: [String: Value]) async throws -> Value {
        let op = normalizedString(args["op"])?.lowercased() ?? "list_sessions"
        switch op {
        case "list_agents":
            return try await executeListAgents(args: args)
        case "list_sessions":
            return try await executeListSessions(args: args)
        case "get_log":
            return try await executeGetLog(args: args)
        case "extract_handoff", "handoff":
            return try await executeExtractHandoff(args: args)
        case "fork_session":
            return try await executeForkSession(args: args)
        case "create_session":
            return try await executeCreateSession(args: args)
        case "resume_session":
            return try await executeResumeSession(args: args)
        case "list_workflows":
            return try await executeListWorkflows()
        case "stop_session":
            return try await executeStopSession(args: args)
        case "cleanup_sessions":
            return try await executeCleanupSessions(args: args)
        default:
            throw MCPError.invalidParams("Unsupported agent_manage op '\(op)'. Use list_agents, list_sessions, get_log, extract_handoff, fork_session, create_session, resume_session, stop_session, cleanup_sessions, or list_workflows.")
        }
    }

    private func executeListAgents(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let availability = targetWindow.apiSettingsViewModel.agentModeAvailabilityContext
        let workspaceID = targetWindow.workspaceManager.activeWorkspace?.id
        let rolesOnly = try parseBool(args["roles_only"], name: "roles_only", defaultValue: false)
        let includeModelParameters = try parseBool(
            args[CursorAgentParameterMetadataBuilder.includeParametersFlag],
            name: CursorAgentParameterMetadataBuilder.includeParametersFlag,
            defaultValue: false
        )
        let restrictedDiscovery = restrictDiscoveryToRoleLabels(workspaceID)
        let omitAgentCatalog = rolesOnly || restrictedDiscovery
        let agents: [Value] = omitAgentCatalog ? [] : AgentModelCatalog.discoveryAgents(availability: availability).map { entry -> Value in
            // Flatten all models — each start target becomes its own entry.
            //
            // Role-label mappings (explore/engineer/pair/design) are the sole
            // responsibility of the top-level `task_labels` array. Per-agent
            // model entries intentionally omit suitability/role-like tags to
            // prevent clients from inferring role mappings from explicit
            // compound model_id targets.
            var modelObjects: [Value] = []
            for model in entry.models {
                if model.hasMultipleTargets {
                    for target in model.startTargets {
                        modelObjects.append(.object(listAgentsModelObject(
                            agent: entry.agent,
                            model: model,
                            target: target,
                            legacyName: target.name,
                            includeModelParameters: includeModelParameters
                        )))
                    }
                } else if let target = model.startTargets.first {
                    modelObjects.append(.object(listAgentsModelObject(
                        agent: entry.agent,
                        model: model,
                        target: target,
                        legacyName: model.name,
                        includeModelParameters: includeModelParameters
                    )))
                } else {
                    var obj: [String: Value] = [
                        "name": .string(model.name),
                        "agent_id": .string(entry.agent.rawValue),
                        "base_model_id": .string(model.id),
                        "model_display_name": .string(model.name)
                    ]
                    if let modelID = model.modelID {
                        obj["model_id"] = .string(modelID)
                    }
                    modelObjects.append(.object(obj))
                }
            }

            var agentObj: [String: Value] = [
                "name": .string(entry.agent.displayName),
                "available": .bool(entry.available),
                "capabilities": .array(entry.capabilities.map(Value.string)),
                "models": .array(modelObjects)
            ]
            if let selID = entry.defaults.selectionID {
                agentObj["default_model_id"] = .string(selID.rawValue)
            }
            return .object(agentObj)
        }
        // Build task labels with effective workspace/global role defaults. These remain
        // visible even when restricted discovery hides the extra per-agent
        // catalog, because callers need to understand which concrete model each
        // role label resolves to.
        let taskLabelEntries = MCPAgentRoleDefaultsService.resolutions(availability: availability, workspaceID: workspaceID).map { res -> Value in
            let recommendedID = AgentModelSelectionID(
                agentRaw: res.recommended.agent.rawValue,
                modelRaw: res.recommended.modelRaw
            )
            let object: [String: Value] = [
                "label": .string(res.roleLabel),
                "description": .string(res.roleDescription),
                "model_id": .string(res.selectionID.rawValue),
                "name": .string(res.effectiveDisplayName),
                "recommended_model_id": .string(recommendedID.rawValue),
                "recommended_name": .string(res.recommendedDisplayName),
                "has_custom_override": .bool(res.hasCustomOverride),
                "override_unavailable": .bool(res.overrideUnavailable)
            ]
            return .object(object)
        }

        var result: [String: Value] = [
            "task_labels": .array(taskLabelEntries)
        ]
        if !omitAgentCatalog {
            result["agents"] = .array(agents)
        }
        return .object(result)
    }

    private func listAgentsModelObject(
        agent: AgentProviderKind,
        model: AgentModelCatalog.DiscoveryModel,
        target: AgentModelCatalog.DiscoveryStartTarget,
        legacyName: String,
        includeModelParameters: Bool
    ) -> [String: Value] {
        let targetID = target.selectionID.rawValue
        var obj: [String: Value] = [
            "model_id": .string(targetID),
            "name": .string(legacyName),
            "agent_id": .string(agent.rawValue),
            "base_model_id": .string(model.id),
            "model_display_name": .string(model.name),
            "is_default": .bool(target.isDefault)
        ]
        if let effort = listAgentsEffortRaw(agent: agent, modelRaw: target.modelRaw, fallback: target.reasoningEffort) {
            obj["effort"] = .string(effort)
            obj["effort_display_name"] = .string(RemoteHostAgentCatalog.displayName(forEffort: effort))
            obj["reasoning_effort"] = .string(effort)
        }
        if let parameterization = cursorParameterMetadataBuilder.metadata(
            agent: agent,
            targetID: targetID,
            includeParameters: includeModelParameters
        ) {
            obj["parameterization"] = parameterization
        }
        return obj
    }

    private func listAgentsEffortRaw(
        agent: AgentProviderKind,
        modelRaw: String,
        fallback: CodexReasoningEffort?
    ) -> String? {
        if agent.usesClaudeTooling {
            return ClaudeModelSpecifier(raw: modelRaw).effortLevel?.rawValue
        }
        if agent == .codexExec {
            return CodexModelSpecifier(raw: modelRaw).reasoningEffort?.rawValue ?? fallback?.rawValue
        }
        return fallback?.rawValue
    }

    /// Host-generated `workspace_mismatch` failure message for workspace-scoped
    /// `list_sessions`. The gateway has no structured error channel from app
    /// tools, so `RemoteGatewayRuntimeError.code` normalizes this by sniffing
    /// the `workspace_mismatch` marker in the message — keep the
    /// `workspace_mismatch: ` prefix stable. Locked end-to-end by
    /// `GatewayRuntimeBindingTests.testWorkspaceScopedListSessionsNormalizesRealHostWorkspaceMismatchMessage`.
    /// (`AgentRunMCPToolService`'s start-path variant carries the same prefix
    /// with an extra remediation sentence and is not derived from this helper.)
    nonisolated static func workspaceMismatchMessage(
        activeWorkspaceName: String,
        activeWorkspaceID: UUID,
        requestedWorkspaceID: UUID
    ) -> String {
        "workspace_mismatch: the target window's active workspace is '\(activeWorkspaceName)' (\(activeWorkspaceID.uuidString)), not \(requestedWorkspaceID.uuidString)."
    }

    private func executeListSessions(args: [String: Value]) async throws -> Value {
        let metadata = await captureRequestMetadata()
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_manage.list_sessions.")
        }
        if let workspaceIDValue = args["workspace_id"] {
            let requestedWorkspaceID = try requireNonEmptyString(workspaceIDValue, name: "workspace_id")
            guard let requestedUUID = UUID(uuidString: requestedWorkspaceID) else {
                throw MCPError.invalidParams("workspace_id must be a workspace UUID.")
            }
            guard workspace.id == requestedUUID else {
                throw MCPError.invalidParams(
                    Self.workspaceMismatchMessage(
                        activeWorkspaceName: workspace.name,
                        activeWorkspaceID: workspace.id,
                        requestedWorkspaceID: requestedUUID
                    )
                )
            }
        }
        let agentModeVM = targetWindow.agentModeViewModel
        let explicitParentSessionID: UUID?
        if args["parent_session_id"] != nil {
            let rawParentSessionID = try requireNonEmptyString(args["parent_session_id"], name: "parent_session_id")
            guard let parsedParentSessionID = UUID(uuidString: rawParentSessionID) else {
                throw MCPError.invalidParams("parent_session_id must be a valid UUID.")
            }
            explicitParentSessionID = parsedParentSessionID
        } else {
            explicitParentSessionID = nil
        }
        let scopedParentSessionID = await resolveSpawnParentSessionID(metadata, targetWindow)
        let agentFilter = normalizedString(args["agent"])?.lowercased()
        let stateFilter = normalizedString(args["state"])
        let limit = max(1, args["limit"]?.intValue ?? 100)

        let persisted = try await AgentSessionDataService.shared.listAgentSessionsMeta(for: workspace)
        var entriesByID: [UUID: [String: Value]] = [:]
        for meta in persisted {
            entriesByID[meta.id] = sessionSummaryObject(
                sessionID: meta.id,
                name: meta.name,
                lastModified: meta.lastModified,
                itemCount: meta.itemCount,
                agentRaw: meta.agentKind,
                modelRaw: meta.agentModel,
                stateRaw: meta.lastRunState,
                isLive: false,
                parentSessionID: meta.parentSessionID,
                isMCPOriginated: meta.isMCPOriginated,
                origin: meta.origin
            )
        }

        for entry in agentModeVM.sessionIndex.values {
            entriesByID[entry.id] = sessionSummaryObject(
                sessionID: entry.id,
                name: entry.name,
                lastModified: entry.savedAt,
                itemCount: entry.itemCount,
                agentRaw: entry.agentKindRaw,
                modelRaw: entry.agentModelRaw,
                stateRaw: entry.lastRunStateRaw,
                isLive: agentModeVM.sessions[entry.tabID] != nil,
                parentSessionID: entry.parentSessionID,
                isMCPOriginated: entry.isMCPOriginated,
                origin: entry.origin
            )
        }

        for session in agentModeVM.sessions.values {
            guard let activeSessionID = session.activeAgentSessionID else { continue }
            let tabName = targetWindow.workspaceManager.composeTab(with: session.tabID)?.name
            entriesByID[activeSessionID] = sessionSummaryObject(
                sessionID: activeSessionID,
                name: tabName ?? "Agent Session",
                lastModified: session.lastActivityAt,
                itemCount: session.transcriptProjectionCounts.canonicalVisibleRowCount,
                agentRaw: session.selectedAgent.rawValue,
                modelRaw: session.selectedModelRaw,
                stateRaw: session.runState.rawValue,
                isLive: true,
                parentSessionID: session.parentSessionID,
                isMCPOriginated: session.isMCPOriginated,
                origin: session.origin
            )
        }

        // Scope to direct children when called from agent mode. An explicit
        // parent_session_id narrows discovery, but it must never widen a
        // connection-scoped child session: mismatched explicit/scoped parents
        // are treated as an empty intersection.
        let scoped: [[String: Value]] = {
            if let explicitParentSessionID,
               let scopedParentSessionID,
               explicitParentSessionID != scopedParentSessionID
            {
                return []
            }
            guard let parentID = explicitParentSessionID ?? scopedParentSessionID else {
                return Array(entriesByID.values)
            }
            return entriesByID.values.filter { object in
                object["parent_session_id"]?.stringValue == parentID.uuidString
            }
        }()

        let filtered = scoped.filter { object in
            let agentObject = object["agent"]?.objectValue
            let agent = (
                agentObject?["id"]?.stringValue
                    ?? agentObject?["name"]?.stringValue
                    ?? object["agent"]?.stringValue
                    ?? ""
            ).lowercased()
            if let agentFilter, agent != agentFilter {
                return false
            }
            if let stateFilter, !sessionStateMatches(object: object, filter: stateFilter) {
                return false
            }
            return true
        }
        .sorted {
            let lhs = $0["last_modified"]?.stringValue ?? ""
            let rhs = $1["last_modified"]?.stringValue ?? ""
            return lhs > rhs
        }

        return .object([
            "sessions": .array(Array(filtered.prefix(limit)).map(Value.object)),
            "workspace": .object([
                "id": .string(workspace.id.uuidString),
                "name": .string(workspace.name)
            ])
        ])
    }

    /// Session-addressed control or transcript reads (get_log, stop_session) from a delegated
    /// worker are bounded like reactivation: a depth ≥ 1 caller may only address sessions strictly
    /// deeper than itself. External and depth-0 callers are unchanged.
    private func validateDelegatedControlTarget(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        operation: String
    ) async throws {
        let metadata = await captureRequestMetadata()
        let sourceTabID = await resolveSpawnSourceTabID(metadata)
        try await validateSpawnRouting(metadata, sourceTabID, operation)
        try agentModeVM.mcpValidateDelegationTarget(
            sourceTabID: sourceTabID,
            targetSessionID: sessionID,
            operation: operation
        )
    }

    private func executeGetLog(args: [String: Value]) async throws -> Value {
        let sessionReference = try requireNonEmptyString(args["session_id"], name: "session_id")
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_manage.get_log.")
        }
        let offset = max(0, args["offset"]?.intValue ?? 0)
        let limit = max(1, args["limit"]?.intValue ?? 20)
        let includeRowTimestamps = try parseBool(
            args["include_row_timestamps"],
            name: "include_row_timestamps",
            defaultValue: false
        )
        let includeHostRowIDs = try parseBool(
            args["include_host_row_ids"],
            name: "include_host_row_ids",
            defaultValue: false
        )

        let agentModeVM = targetWindow.agentModeViewModel
        let transcriptInfo = try await resolveTranscript(
            reference: sessionReference,
            workspace: workspace,
            agentModeVM: agentModeVM
        )
        try await validateDelegatedControlTarget(
            sessionID: transcriptInfo.sessionID,
            agentModeVM: agentModeVM,
            operation: "agent_manage.get_log"
        )
        let totalTurns = transcriptInfo.transcript.turns.count
        var completedTurnCount = completedTurnCount(in: transcriptInfo.transcript)
        if transcriptInfo.liveRunState?.isActive == true {
            completedTurnCount = min(completedTurnCount, max(0, totalTurns - 1))
        }
        let slicedTurns = Array(transcriptInfo.transcript.turns.dropFirst(offset).prefix(limit))
        let slicedTranscript = AgentTranscript(
            version: transcriptInfo.transcript.version,
            turns: slicedTurns,
            nextSequenceIndex: transcriptInfo.transcript.nextSequenceIndex,
            compactionFrontier: nil
        )

        var result: [String: Value] = [
            "session_id": .string(transcriptInfo.sessionID.uuidString),
            "turn_offset": .int(offset),
            "turn_limit": .int(limit),
            "returned_turn_count": .int(slicedTurns.count),
            "total_turns": .int(totalTurns),
            "completed_turn_count": .int(completedTurnCount),
            "transcript_xml": .string(
                AgentTranscriptIO.buildSpartanLogXML(
                    from: slicedTranscript,
                    includeRowTimestamps: includeRowTimestamps,
                    includeHostRowIDs: includeHostRowIDs
                )
            )
        ]
        if let name = transcriptInfo.name, !name.isEmpty {
            result["name"] = .string(name)
        }
        return .object(result)
    }

    private func completedTurnCount(in transcript: AgentTranscript) -> Int {
        guard let finalTurn = transcript.turns.last else { return 0 }
        return max(0, transcript.turns.count - 1) + (finalTurn.isCompleted ? 1 : 0)
    }

    private func executeExtractHandoff(args: [String: Value]) async throws -> Value {
        let sessionReference = try requireNonEmptyString(args["session_id"], name: "session_id")
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_manage.extract_handoff.")
        }

        let includeFileContents = try parseBool(
            args["include_file_contents"],
            name: "include_file_contents",
            defaultValue: false
        )
        let outputPath = normalizedString(args["output_path"])
        let inline = try parseBool(
            args["inline"],
            name: "inline",
            defaultValue: outputPath == nil
        )
        let overwrite = try parseBool(
            args["overwrite"],
            name: "overwrite",
            defaultValue: true
        )
        let maxTranscriptItems = try clampedInt(
            args["max_transcript_items"],
            name: "max_transcript_items",
            defaultValue: 200,
            minValue: 1,
            maxValue: 1000
        )
        let maxToolArgsCharacters = try clampedInt(
            args["max_tool_args_characters"],
            name: "max_tool_args_characters",
            defaultValue: 2000,
            minValue: 0,
            maxValue: 20000
        )
        let upToItemID: UUID?
        if let rawCutoff = normalizedString(args["up_to_item_id"]) {
            guard let parsed = UUID(uuidString: rawCutoff) else {
                throw MCPError.invalidParams("up_to_item_id must be a valid UUID.")
            }
            upToItemID = parsed
        } else {
            upToItemID = nil
        }

        let agentModeVM = targetWindow.agentModeViewModel
        let sessionInfo = try await resolveHandoffSession(
            reference: sessionReference,
            workspace: workspace,
            targetWindow: targetWindow,
            agentModeVM: agentModeVM
        )
        if let upToItemID {
            guard AgentTranscriptIO.isValidHandoffExportCutoffRowID(upToItemID, in: sessionInfo.transcript) else {
                throw MCPError.invalidParams("up_to_item_id was not found in the session transcript.")
            }
        }

        var fileContentsBlock: String?
        var includedFileContents = false
        var fileContentsStatus = "not_requested"
        if includeFileContents {
            guard sessionInfo.isLive, let sourceTabID = sessionInfo.sourceTabID else {
                throw MCPError.invalidParams("include_file_contents is only available for a live Agent Mode session; persisted sessions can export transcript-only handoff payloads.")
            }
            guard agentModeVM.currentTabID == sourceTabID else {
                throw MCPError.invalidParams("include_file_contents requires the live source session's tab to be the active tab so the current file selection can be snapshotted reliably.")
            }
            let block = await agentModeVM.buildCurrentTabHandoffFileContentsBlock(tokenCap: 60000)
            if block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fileContentsStatus = "empty_selection"
            } else {
                fileContentsBlock = block
                includedFileContents = true
                fileContentsStatus = "included"
            }
        }

        let transcriptXML = AgentTranscriptIO.buildForkTranscriptXML(
            from: sessionInfo.transcript,
            upToRowID: upToItemID,
            maxTranscriptItems: maxTranscriptItems,
            maxToolArgsCharacters: maxToolArgsCharacters
        )
        let deliveryID = UUID().uuidString
        let handoffXML = AgentModeViewModel.composeSessionHandoffPayload(
            sourceTabName: sessionInfo.sourceTabName,
            sourceAgentName: sessionInfo.sourceAgentName,
            sourceModelName: sessionInfo.sourceModelName,
            fileContentsBlock: fileContentsBlock,
            transcriptXML: transcriptXML,
            deliveryID: deliveryID
        )
        let payloadBytes = Data(handoffXML.utf8).count

        var result: [String: Value] = [
            "session_id": .string(sessionInfo.sessionID.uuidString),
            "name": .string(sessionInfo.name),
            "content_kind": .string("forked_session"),
            "source": .string(sessionInfo.isLive ? "live" : "persisted"),
            "source_tab_name": .string(sessionInfo.sourceTabName),
            "delivery_id": .string(deliveryID),
            "included_file_contents": .bool(includedFileContents),
            "file_contents_status": .string(fileContentsStatus),
            "inline": .bool(inline),
            "bytes": .int(payloadBytes),
            "max_transcript_items": .int(maxTranscriptItems),
            "max_tool_args_characters": .int(maxToolArgsCharacters)
        ]
        if let upToItemID {
            result["up_to_item_id"] = .string(upToItemID.uuidString)
        }
        if inline {
            result["handoff_xml"] = .string(handoffXML)
        }
        if let outputPath {
            let writeResult = try await writeHandoffPayload(handoffXML, to: outputPath, overwrite: overwrite)
            result["output_path"] = .string(writeResult.path)
            result["bytes_written"] = .int(writeResult.bytes)
        }
        return .object(result)
    }

    private func executeForkSession(args: [String: Value]) async throws -> Value {
        let sessionReference = try requireNonEmptyString(args["session_id"], name: "session_id")
        guard UUID(uuidString: sessionReference) != nil else {
            throw MCPError.invalidParams("session_id must be a valid UUID.")
        }

        let metadata = await captureRequestMetadata()
        let requesterTabID = await resolveSpawnSourceTabID(metadata)
        try await validateSpawnRouting(metadata, requesterTabID, "agent_manage.fork_session")
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_manage.fork_session.")
        }
        let destination = try resolveForkDestination(args: args, targetWindow: targetWindow)

        let upToItemID: UUID?
        if let rawCutoff = normalizedString(args["up_to_item_id"]) {
            guard let parsed = UUID(uuidString: rawCutoff) else {
                throw MCPError.invalidParams("up_to_item_id must be a valid UUID.")
            }
            upToItemID = parsed
        } else {
            upToItemID = nil
        }

        let agentModeVM = targetWindow.agentModeViewModel
        let sessionInfo = try await resolveHandoffSession(
            reference: sessionReference,
            workspace: workspace,
            targetWindow: targetWindow,
            agentModeVM: agentModeVM
        )
        guard sessionInfo.isLive, let sourceTabID = sessionInfo.sourceTabID else {
            throw MCPError.invalidParams("Session '\(sessionReference)' is persisted-only; fork_session requires a live source session.")
        }
        if let upToItemID,
           !AgentTranscriptIO.isValidHandoffExportCutoffRowID(upToItemID, in: sessionInfo.transcript)
        {
            throw MCPError.invalidParams("up_to_item_id was not found in the session transcript.")
        }

        // A fork creates a new session: gate the requesting agent like create/start, then place
        // the destination in the delegation tree before it is published.
        let requesterSessionID = try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: requesterTabID)
        let destinationParentSessionID = try agentModeVM.mcpForkDestinationParentSessionID(
            forkSourceSessionID: sessionInfo.sessionID,
            requesterTabID: requesterTabID
        )
        let forkSourceSessionID = sessionInfo.sessionID
        let destinationTabID = try await agentModeVM.prepareHandoffHeadless(
            sourceTabID: sourceTabID,
            upToItemID: upToItemID,
            destinationAgent: destination.agent,
            destinationModelRaw: destination.modelRaw,
            destinationReasoningEffortRaw: destination.reasoningEffortRaw,
            delegationParentSessionID: destinationParentSessionID,
            delegationCommitCheck: {
                try agentModeVM.mcpRevalidateDelegationCommit(
                    sourceTabID: requesterTabID,
                    expectedCallerSessionID: requesterSessionID,
                    operation: "agent_manage.fork_session"
                )
                guard try agentModeVM.mcpForkDestinationParentSessionID(
                    forkSourceSessionID: forkSourceSessionID,
                    requesterTabID: requesterTabID
                ) == destinationParentSessionID else {
                    throw MCPError.invalidParams(
                        "agent_manage.fork_session: the delegation lineage changed while the fork was being prepared. Refusing to publish the fork; retry the call."
                    )
                }
            }
        )
        guard let destinationSession = agentModeVM.session(for: destinationTabID, createIfNeeded: false),
              let destinationSessionID = destinationSession.activeAgentSessionID
        else {
            throw MCPError.internalError("Forked destination session could not be resolved.")
        }
        let destinationName = targetWindow.workspaceManager.composeTab(with: destinationTabID)?.name ?? "Agent Session"
        let descriptor = sessionSummaryObject(
            sessionID: destinationSessionID,
            name: destinationName,
            lastModified: destinationSession.lastActivityAt,
            itemCount: destinationSession.transcriptProjectionCounts.canonicalVisibleRowCount,
            agentRaw: destinationSession.selectedAgent.rawValue,
            modelRaw: destinationSession.selectedModelRaw,
            stateRaw: destinationSession.runState.rawValue,
            isLive: true,
            parentSessionID: destinationSession.parentSessionID,
            isMCPOriginated: destinationSession.isMCPOriginated,
            origin: destinationSession.origin
        )
        // Envelope stability: the remote gateway extracts `session.session_id`
        // from this exact shape to record session→window routing affinity
        // (GatewayRuntime.recordForkSessionAffinityIfNeeded). Keep the
        // `session` key and descriptor `session_id` field stable.
        return .object([
            "status": .string("forked"),
            "session": .object(descriptor)
        ])
    }

    private func resolveForkDestination(
        args: [String: Value],
        targetWindow: WindowState
    ) throws -> (agent: AgentProviderKind, modelRaw: String, reasoningEffortRaw: String?) {
        let rawAgent = try requireNonEmptyString(args["destination_agent"], name: "destination_agent")
        guard let agent = AgentProviderKind(rawValue: rawAgent) else {
            throw MCPError.invalidParams("destination_agent is not a recognized host agent provider.")
        }
        let modelID = try requireNonEmptyString(args["destination_model_id"], name: "destination_model_id")
        let availability = targetWindow.apiSettingsViewModel.agentModeAvailabilityContext
        guard let discoveryAgent = AgentModelCatalog.discoveryAgents(availability: availability).first(where: { $0.agent == agent }),
              discoveryAgent.available
        else {
            throw MCPError.invalidParams("destination_agent '\(rawAgent)' is not available on this host.")
        }
        guard let parsedModelID = AgentModelSelectionID.parse(modelID),
              parsedModelID.agentRaw == agent.rawValue,
              let target = discoveryAgent.models
              .flatMap(\.startTargets)
              .first(where: { $0.selectionID.rawValue == modelID })
        else {
            throw MCPError.invalidParams("destination_model_id is not an available model for destination_agent '\(rawAgent)'.")
        }

        // list_agents emits a distinct compound model_id for each exact model/effort
        // start target. destination_effort is therefore a consistency check for that
        // target, not an independent family-level effort selector.
        let catalogEffort = listAgentsEffortRaw(
            agent: agent,
            modelRaw: target.modelRaw,
            fallback: target.reasoningEffort
        )
        let explicitEffort = normalizedString(args["destination_effort"])
        if let explicitEffort {
            guard let catalogEffort,
                  catalogEffort.caseInsensitiveCompare(explicitEffort) == .orderedSame
            else {
                throw MCPError.invalidParams("destination_effort is not accepted for destination_model_id.")
            }
        }
        let reasoningEffortRaw = agent == .codexExec ? (explicitEffort ?? catalogEffort) : nil
        return (agent, target.modelRaw, reasoningEffortRaw)
    }

    private func executeCreateSession(args: [String: Value]) async throws -> Value {
        let metadata = await captureRequestMetadata()
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sourceTabID = await resolveSpawnSourceTabID(metadata)
        try await validateSpawnRouting(metadata, sourceTabID, "agent_manage.create_session")
        let admittedCallerSessionID = try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: sourceTabID)
        let spawnParentSessionID = await resolveSpawnParentSessionID(metadata, targetWindow)
        // A routed Agent Mode caller must never degrade into an unparented root session.
        if sourceTabID != nil, spawnParentSessionID == nil {
            throw MCPError.invalidParams("agent_manage.create_session was routed from an Agent Mode run, but RepoPrompt could not resolve its parent Agent session. Refusing to create an unparented session; reconnect the agent MCP client or retry after the source session is active.")
        }
        try agentModeVM.mcpRequireAdmittedSpawnParent(
            sourceTabID: sourceTabID,
            admittedCallerSessionID: admittedCallerSessionID,
            resolvedParentSessionID: spawnParentSessionID,
            operation: "agent_manage.create_session"
        )
        // create_session always creates a new session — default to the effective engineer role when model_id is omitted.
        // Validate selection before creating a target to avoid phantom sessions on bad model_id.
        let selection = try AgentMCPSelectionResolver.resolve(
            modelID: normalizedString(args["model_id"]),
            defaultTaskLabel: .engineer,
            availability: targetWindow.apiSettingsViewModel.agentModeAvailabilityContext,
            workspaceID: targetWindow.workspaceManager.activeWorkspace?.id
        )
        let resolved = resolvedModelAndEffort(agentRaw: selection.agentRaw, modelRaw: selection.modelRaw, args: args)
        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: normalizedString(args["session_name"]),
            parentSessionID: spawnParentSessionID,
            inheritWorktreeBindings: false,
            delegationCommitCheck: {
                try agentModeVM.mcpRevalidateDelegationCommit(
                    sourceTabID: sourceTabID,
                    expectedCallerSessionID: admittedCallerSessionID,
                    operation: "agent_manage.create_session"
                )
            }
        )
        do {
            try await agentModeVM.mcpConfigureSession(
                tabID: target.tabID,
                agentRaw: resolved.agent,
                modelRaw: resolved.model,
                reasoningEffortRaw: resolved.effort
            )
            agentModeVM.mcpSeedRoleOhMyPiThinkingSelections(
                tabID: target.tabID,
                targetOrigin: target.origin,
                taskLabelKind: selection.taskLabelKind,
                selections: selection.ohMyPiThinkingSelections
            )
            try await bindCurrentRequestToTab(target.tabID, metadata)
            guard let sessionID = target.sessionID else {
                throw MCPError.internalError("Failed to resolve created agent session ID.")
            }
            try await agentModeVM.mcpActivateControlContext(
                forTabID: target.tabID,
                sessionID: sessionID,
                originatingConnectionID: metadata.connectionID,
                origin: AgentSessionOrigin.fromClientIdentity(metadata.clientName),
                taskLabelKind: selection.taskLabelKind,
                startPending: false
            )
        } catch {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw error
        }
        guard let session = agentModeVM.session(for: target.tabID, createIfNeeded: false) else {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw MCPError.internalError("Failed to create agent session state.")
        }
        let sessionName = targetWindow.workspaceManager.composeTab(with: target.tabID)?.name ?? "Agent Session"
        return .object(sessionSummaryObject(
            sessionID: session.activeAgentSessionID,
            name: sessionName,
            lastModified: session.lastActivityAt,
            itemCount: session.transcriptProjectionCounts.canonicalVisibleRowCount,
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: session.selectedModelRaw,
            stateRaw: session.runState.rawValue,
            isLive: true,
            parentSessionID: session.parentSessionID,
            isMCPOriginated: session.isMCPOriginated,
            origin: session.origin
        ))
    }

    private func executeResumeSession(args: [String: Value]) async throws -> Value {
        let metadata = await captureRequestMetadata()
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_manage.resume_session.")
        }
        let sessionReference = try requireNonEmptyString(args["session_id"], name: "session_id")
        let agentModeVM = targetWindow.agentModeViewModel
        let sourceTabID = await resolveSpawnSourceTabID(metadata)
        try await validateSpawnRouting(metadata, sourceTabID, "agent_manage.resume_session")
        let admittedCallerSessionID = try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: sourceTabID)
        let spawnParentSessionID = await resolveSpawnParentSessionID(metadata, targetWindow)
        try agentModeVM.mcpRequireAdmittedSpawnParent(
            sourceTabID: sourceTabID,
            admittedCallerSessionID: admittedCallerSessionID,
            resolvedParentSessionID: spawnParentSessionID,
            operation: "agent_manage.resume_session"
        )
        guard let sessionID = try await agentModeVM.mcpResolveSessionID(reference: sessionReference, workspace: workspace) else {
            throw MCPError.invalidParams("Session '\(sessionReference)' was not found in the active workspace.")
        }
        try agentModeVM.mcpValidateDelegationTarget(
            sourceTabID: sourceTabID,
            targetSessionID: sessionID,
            operation: "agent_manage.resume_session"
        )
        let selection = try AgentMCPSelectionResolver.resolve(
            modelID: normalizedString(args["model_id"]),
            availability: targetWindow.apiSettingsViewModel.agentModeAvailabilityContext,
            workspaceID: workspace.id
        )
        let resolved = resolvedModelAndEffort(agentRaw: selection.agentRaw, modelRaw: selection.modelRaw, args: args)
        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: true,
            sessionName: nil,
            parentSessionID: spawnParentSessionID,
            inheritWorktreeBindings: false,
            delegationCommitCheck: {
                try agentModeVM.mcpRevalidateDelegationCommit(
                    sourceTabID: sourceTabID,
                    expectedCallerSessionID: admittedCallerSessionID,
                    targetSessionID: sessionID,
                    operation: "agent_manage.resume_session"
                )
            }
        )
        // Revalidate after hydration suspended the request: lineage observed above must still hold.
        do {
            try agentModeVM.mcpValidateDelegationTarget(
                sourceTabID: sourceTabID,
                targetSessionID: sessionID,
                operation: "agent_manage.resume_session"
            )
        } catch {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw error
        }
        let hadMatchingMCPControl = agentModeVM.session(for: target.tabID, createIfNeeded: false)?.mcpControlContext?.sessionID == sessionID
        do {
            // Resume adopts the live session's existing control registration. Re-registering the
            // same persistent session expires in-flight waiters and splits poll state from the UI.
            if !hadMatchingMCPControl {
                try await agentModeVM.mcpActivateControlContext(
                    forTabID: target.tabID,
                    sessionID: sessionID,
                    originatingConnectionID: metadata.connectionID,
                    origin: AgentSessionOrigin.fromClientIdentity(metadata.clientName),
                    taskLabelKind: selection.taskLabelKind,
                    startPending: false
                )
            }
            try await agentModeVM.mcpConfigureSession(
                tabID: target.tabID,
                agentRaw: resolved.agent,
                modelRaw: resolved.model,
                reasoningEffortRaw: resolved.effort
            )
            try await bindCurrentRequestToTab(target.tabID, metadata)
        } catch {
            if !hadMatchingMCPControl {
                await agentModeVM.mcpDeactivateControlContext(
                    sessionID: sessionID,
                    cleanupSessionStore: true
                )
            }
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw error
        }
        guard let session = agentModeVM.session(for: target.tabID, createIfNeeded: false) else {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw MCPError.internalError("Failed to hydrate resumed session.")
        }
        let sessionName = targetWindow.workspaceManager.composeTab(with: target.tabID)?.name ?? "Agent Session"
        return .object(sessionSummaryObject(
            sessionID: sessionID,
            name: sessionName,
            lastModified: session.lastActivityAt,
            itemCount: session.transcriptProjectionCounts.canonicalVisibleRowCount,
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: session.selectedModelRaw,
            stateRaw: session.runState.rawValue,
            isLive: true,
            parentSessionID: session.parentSessionID,
            isMCPOriginated: session.isMCPOriginated,
            origin: session.origin
        ))
    }

    private func executeStopSession(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_manage.stop_session.")
        }
        let sessionReference = try requireNonEmptyString(args["session_id"], name: "session_id")
        let agentModeVM = targetWindow.agentModeViewModel
        guard let sessionID = try await agentModeVM.mcpResolveSessionID(reference: sessionReference, workspace: workspace) else {
            throw MCPError.invalidParams("Session '\(sessionReference)' was not found in the active workspace.")
        }
        try await validateDelegatedControlTarget(
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            operation: "agent_manage.stop_session"
        )

        let target: AgentModeViewModel.MCPSessionTarget
        do {
            target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: sessionID,
                createIfNeeded: false,
                sessionName: nil
            )
        } catch {
            throw MCPError.invalidParams("Session '\(sessionReference)' is not currently live and cannot be stopped.")
        }

        let session = try await agentModeVM.ensureSessionReady(tabID: target.tabID)
        let wasActive = session.runState.isActive
        if wasActive {
            await agentModeVM.cancelAgentRun(tabID: target.tabID, cause: .userCancel, completion: .terminalPublished)
            await Task.yield()
        }

        let tabName = targetWindow.workspaceManager.composeTab(with: target.tabID)?.name ?? "Agent Session"
        var summary = sessionSummaryObject(
            sessionID: sessionID,
            name: tabName,
            lastModified: session.lastActivityAt,
            itemCount: session.transcriptProjectionCounts.canonicalVisibleRowCount,
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: session.selectedModelRaw,
            stateRaw: session.runState.rawValue,
            isLive: true
        )
        summary["stop_requested"] = .bool(wasActive)
        return .object(summary)
    }

    private func executeCleanupSessions(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_manage.cleanup_sessions.")
        }
        let agentModeVM = targetWindow.agentModeViewModel

        // Require explicit session IDs
        guard let sessionIDValues = args["session_ids"]?.arrayValue, !sessionIDValues.isEmpty else {
            throw MCPError.invalidParams("cleanup_sessions requires a non-empty `session_ids` array of session UUIDs to delete.")
        }
        var seenRequestedIDs = Set<UUID>()
        let requestedIDs: [UUID] = sessionIDValues.compactMap { value in
            guard let raw = value.stringValue,
                  let id = UUID(uuidString: raw),
                  seenRequestedIDs.insert(id).inserted else { return nil }
            return id
        }
        guard !requestedIDs.isEmpty else {
            throw MCPError.invalidParams("cleanup_sessions: none of the provided session_ids are valid UUIDs.")
        }
        let cleanupMetadata = await captureRequestMetadata()
        let cleanupSourceTabID = await resolveSpawnSourceTabID(cleanupMetadata)
        try await validateSpawnRouting(cleanupMetadata, cleanupSourceTabID, "agent_manage.cleanup_sessions")

        #if DEBUG
            let cleanupStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            var debugOpenDeletedCount = 0
            var debugPersistedDeletedCount = 0
        #endif
        var persistedMetaByID: [UUID: AgentSessionMeta]?
        var deletedSessions: [[String: Value]] = []
        var skippedSessions: [[String: Value]] = []

        for sessionID in requestedIDs {
            // A delegated worker may only clean up sessions deeper than itself.
            do {
                try agentModeVM.mcpValidateDelegationTarget(
                    sourceTabID: cleanupSourceTabID,
                    targetSessionID: sessionID,
                    operation: "agent_manage.cleanup_sessions"
                )
            } catch {
                skippedSessions.append([
                    "session_id": .string(sessionID.uuidString),
                    "name": .string("Unknown"),
                    "reason": .string("outside_delegation_scope")
                ])
                continue
            }
            let candidate: CleanupSessionCandidate?
            if let liveSession = try agentModeVM.authoritativeLiveSession(for: sessionID) {
                let snapshotStatus = agentModeVM.mcpSnapshot(for: liveSession)?.status
                let isEffectivelyActive = snapshotStatus.map { !$0.isTerminal }
                    ?? (
                        liveSession.runState.isActive
                            || liveSession.mcpFollowUpRunPending
                            || liveSession.pendingSupersedingTurnCompletions > 0
                    )
                candidate = CleanupSessionCandidate(
                    sessionID: sessionID,
                    name: targetWindow.workspaceManager.composeTab(with: liveSession.tabID)?.name ?? "Agent Session",
                    tabID: liveSession.tabID,
                    isLive: true,
                    isMCPOriginated: liveSession.isMCPOriginated,
                    origin: liveSession.origin,
                    runStateRaw: liveSession.runState.rawValue,
                    isEffectivelyActive: isEffectivelyActive
                )
            } else if let indexEntry = agentModeVM.sessionIndex[sessionID] {
                let runState = indexEntry.lastRunStateRaw.flatMap(AgentSessionRunState.init(rawValue:))
                candidate = CleanupSessionCandidate(
                    sessionID: sessionID,
                    name: indexEntry.name,
                    tabID: indexEntry.tabID,
                    isLive: agentModeVM.sessions[indexEntry.tabID] != nil,
                    isMCPOriginated: indexEntry.isMCPOriginated,
                    origin: indexEntry.origin,
                    runStateRaw: indexEntry.lastRunStateRaw,
                    isEffectivelyActive: runState?.isActive == true
                )
            } else {
                if persistedMetaByID == nil {
                    #if DEBUG
                        let persistedLoadStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
                    #endif
                    let persistedMetas = try await AgentSessionDataService.shared.listAgentSessionsMeta(for: workspace, limit: nil)
                    #if DEBUG
                        AgentModePerfDiagnostics.durationEvent(
                            "cleanup.sessions.loadPersistedMeta",
                            startMS: persistedLoadStartMS,
                            fields: [
                                "workspaceID": workspace.id.uuidString,
                                "recordCount": String(persistedMetas.count)
                            ]
                        )
                    #endif
                    persistedMetaByID = Dictionary(
                        persistedMetas.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                }
                if let meta = persistedMetaByID?[sessionID] {
                    let runState = meta.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
                    candidate = CleanupSessionCandidate(
                        sessionID: sessionID,
                        name: meta.name,
                        tabID: meta.composeTabID,
                        isLive: false,
                        isMCPOriginated: meta.isMCPOriginated,
                        origin: meta.origin,
                        runStateRaw: meta.lastRunState,
                        isEffectivelyActive: runState?.isActive == true
                    )
                } else {
                    candidate = nil
                }
            }

            guard let candidate else {
                skippedSessions.append([
                    "session_id": .string(sessionID.uuidString),
                    "name": .string("Unknown"),
                    "reason": .string("not_found")
                ])
                continue
            }

            // Plan §6.4: cleanup eligibility is provenance-scoped — `.mcp` and
            // `.remote` sessions are eligible, `.user` sessions never are.
            let candidateOrigin = candidate.origin ?? AgentSessionOrigin(legacyIsMCPOriginated: candidate.isMCPOriginated)
            guard candidateOrigin.isMCPOriginated else {
                skippedSessions.append([
                    "session_id": .string(sessionID.uuidString),
                    "name": .string(candidate.name),
                    "reason": .string("not_mcp_originated")
                ])
                continue
            }

            if candidate.isEffectivelyActive {
                skippedSessions.append([
                    "session_id": .string(sessionID.uuidString),
                    "name": .string(candidate.name),
                    "reason": .string("skipped_active")
                ])
                continue
            }

            do {
                let openTabID = candidate.tabID.flatMap { tabID -> UUID? in
                    let activeWorkspace = targetWindow.workspaceManager.activeWorkspace ?? workspace
                    guard activeWorkspace.composeTabs.contains(where: { $0.id == tabID }) else { return nil }
                    let liveSessionID = agentModeVM.sessions[tabID]?.activeAgentSessionID
                    let liveBindingMatches = liveSessionID == sessionID
                    let hasDifferentLiveBinding = liveSessionID != nil && liveSessionID != sessionID
                    let workspaceBindingMatches = targetWindow.workspaceManager.activeAgentSessionID(
                        forTabID: tabID,
                        inWorkspaceID: workspace.id
                    ) == sessionID
                    return !hasDifferentLiveBinding && (liveBindingMatches || workspaceBindingMatches) ? tabID : nil
                }
                if let openTabID {
                    #if DEBUG
                        let deleteOpenStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
                    #endif
                    await agentModeVM.deleteSession(tabID: openTabID)
                    #if DEBUG
                        AgentModePerfDiagnostics.durationEvent(
                            "cleanup.sessions.deleteOpen",
                            startMS: deleteOpenStartMS,
                            tabID: openTabID,
                            fields: [
                                "sessionID": sessionID.uuidString,
                                "tabID": openTabID.uuidString
                            ]
                        )
                        let deletePersistedStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
                    #endif
                    try await AgentSessionDataService.shared.deleteAgentSession(id: sessionID, for: workspace)
                    #if DEBUG
                        AgentModePerfDiagnostics.durationEvent(
                            "cleanup.sessions.deletePersisted",
                            startMS: deletePersistedStartMS,
                            fields: ["sessionID": sessionID.uuidString]
                        )
                        debugOpenDeletedCount += 1
                    #endif
                } else {
                    #if DEBUG
                        let deletePersistedStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
                    #endif
                    try await AgentSessionDataService.shared.deleteAgentSession(id: sessionID, for: workspace)
                    #if DEBUG
                        AgentModePerfDiagnostics.durationEvent(
                            "cleanup.sessions.deletePersisted",
                            startMS: deletePersistedStartMS,
                            fields: ["sessionID": sessionID.uuidString]
                        )
                        debugPersistedDeletedCount += 1
                    #endif
                }
                #if DEBUG
                    let finalizeStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
                #endif
                let finalizeResult = await agentModeVM.finalizeDeletedAgentSessionReferences(
                    sessionID: sessionID,
                    workspaceID: workspace.id,
                    knownTabIDs: openTabID.map { [$0] } ?? [],
                    reason: "agent_manage.cleanup_sessions"
                )
                #if DEBUG
                    AgentModePerfDiagnostics.durationEvent(
                        "cleanup.sessions.finalize",
                        startMS: finalizeStartMS,
                        fields: [
                            "sessionID": sessionID.uuidString,
                            "knownTabCount": String(openTabID == nil ? 0 : 1),
                            "affectedTabCount": String(finalizeResult.affectedTabIDs.count)
                        ]
                    )
                #endif
                deletedSessions.append([
                    "session_id": .string(sessionID.uuidString),
                    "name": .string(candidate.name)
                ])
            } catch {
                skippedSessions.append([
                    "session_id": .string(sessionID.uuidString),
                    "name": .string(candidate.name),
                    "reason": .string("delete_failed"),
                    "message": .string(error.localizedDescription)
                ])
            }
        }

        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "cleanup.sessions.execute",
                startMS: cleanupStartMS,
                fields: [
                    "requested": String(sessionIDValues.count),
                    "validRequested": String(requestedIDs.count),
                    "deleted": String(deletedSessions.count),
                    "skipped": String(skippedSessions.count),
                    "openDeleted": String(debugOpenDeletedCount),
                    "persistedDeleted": String(debugPersistedDeletedCount)
                ]
            )
        #endif
        return .object([
            "status": .string(skippedSessions.isEmpty ? "completed" : "partial"),
            "deleted_count": .int(deletedSessions.count),
            "skipped_count": .int(skippedSessions.count),
            "deleted_sessions": .array(deletedSessions.map(Value.object)),
            "skipped_sessions": .array(skippedSessions.map(Value.object))
        ])
    }

    private func executeListWorkflows() async throws -> Value {
        let workflows = AgentWorkflowStore.shared.allWorkflows.map { workflow in
            Value.object([
                "id": .string(workflow.id),
                "name": .string(workflow.displayName),
                "source": .string(workflow.isBuiltIn ? "built_in" : "custom"),
                "icon": .string(workflow.iconName),
                "description": workflow.descriptionText.map(Value.string) ?? .null,
                "tooltip": workflow.tooltipText.map(Value.string) ?? .null
            ])
        }
        return .object([
            "workflows": .array(workflows)
        ])
    }

    private func resolveTranscript(
        reference: String,
        workspace: WorkspaceModel,
        agentModeVM: AgentModeViewModel
    ) async throws -> (sessionID: UUID, name: String?, transcript: AgentTranscript, liveRunState: AgentSessionRunState?) {
        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceUUID = UUID(uuidString: normalizedReference)
        if let referenceUUID,
           let liveSession = try agentModeVM.authoritativeLiveSession(for: referenceUUID),
           let sessionID = liveSession.activeAgentSessionID
        {
            let hydrated = try await agentModeVM.ensureSessionReady(tabID: liveSession.tabID)
            if !hydrated.runState.isActive {
                // Safe on every terminal get_log: canReuseDerivedTranscriptForSave makes this
                // a no-op when already synchronized.
                await agentModeVM.ensureDerivedTranscriptCurrentForExport(tabID: liveSession.tabID)
            } else {
                // Active get_log: settle a background-delayed refresh (no-op otherwise).
                await agentModeVM.flushDeferredDerivedTranscriptRefresh(tabID: liveSession.tabID)
            }
            let liveName = agentModeVM.sessionIndex[sessionID]?.name
            return (sessionID, liveName, hydrated.transcript, hydrated.runState)
        }
        let persistedRunStateRawFromStorage = if let referenceUUID {
            try? await AgentSessionDataService.shared.rawLastRunStateForAgentSession(id: referenceUUID, for: workspace)
        } else {
            String?.none
        }
        guard let persisted = try await AgentSessionDataService.shared.loadAgentSession(reference: reference, for: workspace) else {
            throw MCPError.invalidParams("Session '\(reference)' was not found in the active workspace.")
        }
        let persistedRunStateRaw = persistedRunStateRawFromStorage ?? persisted.lastRunState
        let persistedRunState = persistedRunStateRaw.flatMap(AgentSessionRunState.init(rawValue:))
        return (persisted.id, persisted.name, persisted.transcript ?? .empty, persistedRunState)
    }

    private func resolveHandoffSession(
        reference: String,
        workspace: WorkspaceModel,
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> HandoffSessionInfo {
        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceUUID = UUID(uuidString: normalizedReference)
        if let referenceUUID,
           let liveSession = try agentModeVM.authoritativeLiveSession(for: referenceUUID),
           let sessionID = liveSession.activeAgentSessionID
        {
            let hydrated = try await agentModeVM.ensureSessionReady(tabID: liveSession.tabID)
            // Settle a background-delayed refresh before handing off the derived transcript.
            await agentModeVM.flushDeferredDerivedTranscriptRefresh(tabID: liveSession.tabID)
            let liveName = targetWindow.workspaceManager.composeTab(with: hydrated.tabID)?.name
                ?? agentModeVM.sessionIndex[sessionID]?.name
                ?? "Agent Session"
            return HandoffSessionInfo(
                sessionID: sessionID,
                name: liveName,
                transcript: hydrated.transcript,
                sourceTabID: hydrated.tabID,
                sourceTabName: liveName,
                sourceAgentName: hydrated.selectedAgent.displayName,
                sourceModelName: agentModeVM.modelDisplayName(
                    rawModel: hydrated.selectedModelRaw,
                    agentKind: hydrated.selectedAgent
                ),
                isLive: true
            )
        }

        guard let persisted = try await AgentSessionDataService.shared.loadAgentSession(reference: reference, for: workspace) else {
            throw MCPError.invalidParams("Session '\(reference)' was not found in the active workspace.")
        }
        let agentKind = persisted.agentKind.flatMap { AgentProviderKind(rawValue: $0) }
        let agentName = agentKind?.displayName
            ?? persisted.agentKind?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Agent"
        let modelRaw = persisted.agentModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModelRaw = modelRaw?.isEmpty == false ? modelRaw! : AgentModel.defaultModel.rawValue
        let modelName: String = {
            guard let agentKind else { return modelRaw?.isEmpty == false ? modelRaw! : "unknown model" }
            return agentModeVM.modelDisplayName(
                rawModel: effectiveModelRaw,
                agentKind: agentKind
            )
        }()
        let transcript = persisted.transcript
            ?? AgentTranscriptIO.importLegacyItems(persisted.items.map { $0.toItem() })
        let sourceTabName = persisted.composeTabID.flatMap { targetWindow.workspaceManager.composeTab(with: $0)?.name }
            ?? persisted.name
        return HandoffSessionInfo(
            sessionID: persisted.id,
            name: persisted.name,
            transcript: transcript,
            sourceTabID: nil,
            sourceTabName: sourceTabName,
            sourceAgentName: agentName,
            sourceModelName: modelName,
            isLive: false
        )
    }

    private func sessionSummaryObject(
        sessionID: UUID?,
        name: String,
        lastModified: Date,
        itemCount: Int,
        agentRaw: String?,
        modelRaw: String?,
        stateRaw: String?,
        isLive: Bool,
        parentSessionID: UUID? = nil,
        isMCPOriginated: Bool = false,
        origin: AgentSessionOrigin? = nil
    ) -> [String: Value] {
        let publicState = publicSessionState(raw: stateRaw)
        var obj: [String: Value] = [
            "session_id": sessionID.map { .string($0.uuidString) } ?? .null,
            "name": .string(name),
            "last_modified": .string(timestamp(lastModified)),
            "item_count": .int(itemCount),
            "state": publicState.map(Value.string) ?? .null,
            "is_live": .bool(isLive)
        ]
        if let stateRaw, let publicState,
           normalizedStateToken(stateRaw) != normalizedStateToken(publicState)
        {
            obj["raw_state"] = .string(stateRaw)
        }
        if agentRaw != nil || modelRaw != nil {
            obj["agent"] = .object([
                "id": agentRaw.map(Value.string) ?? .null,
                "model": modelRaw.map(Value.string) ?? .null
            ])
        }
        if let parentSessionID {
            obj["parent_session_id"] = .string(parentSessionID.uuidString)
        }
        if isMCPOriginated {
            obj["is_mcp_originated"] = .bool(true)
        }
        if let origin {
            obj["origin"] = .string(origin.summaryString)
        }
        return obj
    }

    private func sessionStateMatches(object: [String: Value], filter: String) -> Bool {
        let filterAliases = sessionStateAliases(for: filter)
        guard !filterAliases.isEmpty else { return false }
        let stateAliases = sessionStateAliases(for: object["state"]?.stringValue)
        let rawStateAliases = sessionStateAliases(for: object["raw_state"]?.stringValue)
        return !stateAliases.isDisjoint(with: filterAliases)
            || !rawStateAliases.isDisjoint(with: filterAliases)
    }

    private func sessionStateAliases(for raw: String?) -> Set<String> {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let compact = normalizedStateToken(raw)
        var aliases: Set<String> = [compact]
        if let publicState = publicSessionState(raw: raw) {
            aliases.insert(normalizedStateToken(publicState))
        }
        if aliases.contains(where: isWaitingStateToken) {
            aliases.formUnion([
                normalizedStateToken(AgentRunMCPSnapshot.Status.waitingForInput.rawValue),
                normalizedStateToken(AgentSessionRunState.waitingForUser.rawValue),
                normalizedStateToken(AgentSessionRunState.waitingForQuestion.rawValue),
                normalizedStateToken(AgentSessionRunState.waitingForApproval.rawValue)
            ])
        }
        return aliases
    }

    private func publicSessionState(raw stateRaw: String?) -> String? {
        guard let stateRaw = stateRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !stateRaw.isEmpty else { return nil }
        if let runState = AgentSessionRunState(rawValue: stateRaw) {
            switch runState {
            case .waitingForUser, .waitingForQuestion, .waitingForApproval:
                return AgentRunMCPSnapshot.Status.waitingForInput.rawValue
            case .idle, .running, .completed, .cancelled, .failed:
                return runState.rawValue
            }
        }
        let compact = normalizedStateToken(stateRaw)
        if isWaitingStateToken(compact) {
            return AgentRunMCPSnapshot.Status.waitingForInput.rawValue
        }
        return stateRaw
    }

    private func normalizedStateToken(_ state: String) -> String {
        state
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func isWaitingStateToken(_ token: String) -> Bool {
        [
            normalizedStateToken(AgentRunMCPSnapshot.Status.waitingForInput.rawValue),
            normalizedStateToken(AgentSessionRunState.waitingForUser.rawValue),
            normalizedStateToken(AgentSessionRunState.waitingForQuestion.rawValue),
            normalizedStateToken(AgentSessionRunState.waitingForApproval.rawValue)
        ].contains(token)
    }

    private func parseBool(_ value: Value?, name: String, defaultValue: Bool) throws -> Bool {
        guard let value else { return defaultValue }
        guard let parsed = AgentMCPToolHelpers.parseBool(value) else {
            throw MCPError.invalidParams("\(name) must be a boolean value.")
        }
        return parsed
    }

    private func clampedInt(
        _ value: Value?,
        name: String,
        defaultValue: Int,
        minValue: Int,
        maxValue: Int
    ) throws -> Int {
        guard let value else { return defaultValue }
        let parsed: Int?
        switch value {
        case let .int(intValue):
            parsed = intValue
        case let .double(doubleValue):
            guard doubleValue.isFinite else { parsed = nil
                break
            }
            parsed = Int(doubleValue)
        case let .string(stringValue):
            parsed = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }
        guard let parsed else {
            throw MCPError.invalidParams("\(name) must be an integer.")
        }
        return min(max(parsed, minValue), maxValue)
    }

    private func writeHandoffPayload(
        _ payload: String,
        to rawPath: String,
        overwrite: Bool
    ) async throws -> (path: String, bytes: Int) {
        let url = try resolveSafeOutputURL(rawPath, paramName: "output_path")
        let data = Data(payload.utf8)
        let bytes = data.count
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    throw MCPError.invalidParams("output_path points to a directory: \(url.path)")
                }
                if !overwrite {
                    throw MCPError.invalidParams("output_path already exists and overwrite=false: \(url.path)")
                }
            }
            let parent = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let options: Data.WritingOptions = overwrite ? [.atomic] : [.atomic, .withoutOverwriting]
            do {
                try data.write(to: url, options: options)
            } catch {
                if !overwrite, fileManager.fileExists(atPath: url.path) {
                    throw MCPError.invalidParams("output_path already exists and overwrite=false: \(url.path)")
                }
                throw error
            }
        }.value
        return (url.path, bytes)
    }

    private func resolveSafeOutputURL(_ rawPath: String, paramName: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidParams("\(paramName) must not be empty.")
        }
        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "\0\n\r")) == nil else {
            throw MCPError.invalidParams("\(paramName) must be a single filesystem path.")
        }

        let path: String
        if trimmed == "~" {
            path = FileManager.default.homeDirectoryForCurrentUser.path
        } else if trimmed.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .path
        } else if trimmed.hasPrefix("~") {
            throw MCPError.invalidParams("\(paramName) supports '~' or '~/' only; use an absolute path otherwise.")
        } else {
            path = trimmed
        }
        guard path.hasPrefix("/") else {
            throw MCPError.invalidParams("\(paramName) must be absolute. CLI shorthand resolves relative paths before calling MCP.")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Resolves agent, model, and reasoning effort from pre-resolved selection + raw args.
    private func resolvedModelAndEffort(
        agentRaw: String?,
        modelRaw: String?,
        args: [String: Value]
    ) -> (agent: String?, model: String?, effort: String?) {
        let explicitEffort = normalizedString(args["reasoning_effort"])
        if let explicitEffort {
            return (agentRaw, modelRaw, explicitEffort)
        }
        let extracted = AgentExternalMCPRunStarter.extractReasoningEffort(from: modelRaw)
        return (agentRaw, extracted.model, extracted.effort)
    }

    // MARK: - Delegated helpers (via AgentMCPToolHelpers)

    private func requireNonEmptyString(_ value: Value?, name: String) throws -> String {
        try AgentMCPToolHelpers.requireNonEmptyString(value, name: name)
    }

    private func normalizedString(_ value: Value?) -> String? {
        AgentMCPToolHelpers.normalizedString(value)
    }

    private func timestamp(_ date: Date) -> String {
        AgentMCPToolHelpers.timestamp(date)
    }
}
