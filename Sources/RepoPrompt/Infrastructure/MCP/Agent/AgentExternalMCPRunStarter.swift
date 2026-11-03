import Foundation
import MCP
import RepoPromptAgentCore

@MainActor
enum AgentExternalMCPRunStarter {
    #if DEBUG
        enum OMPQualificationInvocationError: LocalizedError {
            case contextReplaced

            var errorDescription: String? {
                "The OMP qualification transaction context was replaced before instruction dispatch."
            }
        }
    #endif
    struct StartOutcome: Equatable {
        let snapshot: AgentRunMCPSnapshot
        let delivery: AgentModeViewModel.MCPInstructionDispatch
    }

    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias BindCurrentRequestToTab = (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void
    typealias DispatchInstruction = @MainActor (
        _ sessionID: UUID,
        _ tabID: UUID,
        _ message: String,
        _ workflow: AgentWorkflowDefinition?,
        _ agentModeVM: AgentModeViewModel
    ) async throws -> AgentModeViewModel.MCPInstructionDispatch

    /// Extracts a reasoning effort suffix from a model string if present.
    /// Supports formats like "gpt-5.4-high", "o3_low", "gpt-5.4-fast-high".
    /// The model string is passed through unchanged (preserving service tier and other modifiers);
    /// only the effort is extracted separately.
    static func extractReasoningEffort(from modelRaw: String?) -> (model: String?, effort: String?) {
        guard let modelRaw, !modelRaw.isEmpty else { return (modelRaw, nil) }
        let specifier = CodexModelSpecifier(raw: modelRaw)
        if let effort = specifier.reasoningEffort {
            return (modelRaw, effort.rawValue)
        }
        return (modelRaw, nil)
    }

    static func resolvedModelAndEffort(
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        cursorParameterizedModelsEnabled: Bool = CursorParameterizedModels.isEnabled
    ) throws -> (model: String?, effort: String?) {
        if let reasoningEffortRaw {
            if agentRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(AgentProviderKind.cursor.rawValue) == .orderedSame
            {
                guard cursorParameterizedModelsEnabled else {
                    return (modelRaw, nil)
                }
                return try (
                    cursorModelByOverlayingReasoningEffort(
                        modelRaw: modelRaw,
                        reasoningEffortRaw: reasoningEffortRaw
                    ),
                    nil
                )
            }
            return (modelRaw, reasoningEffortRaw)
        }
        if agentRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(AgentProviderKind.cursor.rawValue) == .orderedSame
        {
            return (modelRaw, nil)
        }
        return extractReasoningEffort(from: modelRaw)
    }

    private static func cursorModelByOverlayingReasoningEffort(
        modelRaw: String?,
        reasoningEffortRaw: String
    ) throws -> String {
        guard let modelRaw,
              !modelRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MCPError.invalidParams(
                "reasoning_effort for Cursor requires a model_id. Use the bracket grammar cursor:<base>[k=v,…]."
            )
        }
        guard let parameterSpec = CursorModelParameterCatalog.shared
            .uniqueThoughtLevelParameterSpec(forModel: modelRaw)
        else {
            throw MCPError.invalidParams(
                "Cursor parameter metadata is unavailable for model_id '\(modelRaw)'. Use the bracket grammar cursor:<base>[k=v,…]."
            )
        }
        let suppliedEffort = reasoningEffortRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonicalEffort = parameterSpec.options.first(where: {
            $0.value.caseInsensitiveCompare(suppliedEffort) == .orderedSame
        })?.value
        else {
            throw MCPError.invalidParams(
                "Unsupported reasoning_effort '\(reasoningEffortRaw)' for Cursor model_id '\(modelRaw)'. Valid values: \(parameterSpec.options.map(\.value).joined(separator: ", "))."
            )
        }
        let parameterID = parameterSpec.id

        let trimmed = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCursorPrefix = trimmed.lowercased().hasPrefix("cursor:")
        let stripped = CursorBracketModelID.strippingCursorPrefix(trimmed)
        guard let parsed = CursorBracketModelID.parse(stripped) else {
            throw MCPError.invalidParams(
                "Invalid Cursor model_id '\(modelRaw)'. Use the bracket grammar cursor:<base>[k=v,…]."
            )
        }

        var parameters = parsed.params
        if let existingIndex = parameters.firstIndex(where: {
            $0.key.caseInsensitiveCompare(parameterID) == .orderedSame
        }) {
            let existing = parameters[existingIndex]
            guard existing.value.caseInsensitiveCompare(canonicalEffort) == .orderedSame else {
                throw MCPError.invalidParams(
                    "reasoning_effort '\(reasoningEffortRaw)' conflicts with the explicit Cursor parameter '\(parameterID)=\(existing.value)'."
                )
            }
            parameters[existingIndex] = .init(key: existing.key, value: canonicalEffort)
        } else {
            parameters.append(.init(key: parameterID, value: canonicalEffort))
        }

        guard let composed = CursorBracketModelID.compose(base: parsed.base, params: parameters) else {
            throw MCPError.invalidParams(
                "Invalid Cursor model parameters. Use the bracket grammar cursor:<base>[k=v,…]."
            )
        }
        return hasCursorPrefix ? "cursor:\(composed)" : composed
    }

    static func start(
        target: AgentModeViewModel.MCPSessionTarget,
        message: String,
        metadata: RequestMetadata,
        bindCurrentRequestToTab: BindCurrentRequestToTab,
        agentModeVM: AgentModeViewModel,
        agentRaw: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        roleOhMyPiThinkingSelections: OhMyPiThinkingSelections = .empty,
        workflow: AgentWorkflowDefinition? = nil,
        expectedParentSessionID: UUID? = nil,
        oracleReviewSource: AgentRunOracleReviewSource? = nil,
        dispatchInstruction: DispatchInstruction? = nil
    ) async throws -> StartOutcome {
        #if DEBUG
            let ompQualificationInvocationContext = OhMyPiAgentModeSmokeGate.invocationStartContext
            if let ompQualificationInvocationContext {
                guard let liveSession = agentModeVM.session(for: target.tabID, createIfNeeded: false),
                      liveSession.mcpStartInvocationGenerationID == ompQualificationInvocationContext.generationID,
                      liveSession.ompQualificationStartContext === ompQualificationInvocationContext
                else {
                    ompQualificationInvocationContext.authorizationReceipt.resolve(.denied)
                    throw OMPQualificationInvocationError.contextReplaced
                }
            }
        #endif
        let resolved = try resolvedModelAndEffort(
            agentRaw: agentRaw,
            modelRaw: modelRaw,
            reasoningEffortRaw: reasoningEffortRaw
        )
        let resolvedModel = resolved.model
        let resolvedEffort = resolved.effort
        guard let sessionID = target.sessionID else {
            throw MCPError.internalError("Failed to resolve target agent session ID.")
        }
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.externalRunStarterActivate", tabID: target.tabID, fields: [
                "sessionID": sessionID.uuidString,
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "clientName": metadata.clientName ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "taskLabel": taskLabelKind?.rawValue ?? "nil",
                "agent": agentRaw ?? "nil",
                "model": resolvedModel ?? "nil",
                "workflowID": workflow?.id ?? "nil",
                "workflowName": workflow?.displayName ?? "nil"
            ])
        #endif
        let activatedControlContext = try await agentModeVM.mcpActivateControlContext(
            forTabID: target.tabID,
            sessionID: sessionID,
            originatingConnectionID: metadata.connectionID,
            origin: AgentSessionOrigin.fromClientIdentity(metadata.clientName),
            taskLabelKind: taskLabelKind,
            startPending: true,
            // A Knowledge research worker's target carries its adopted profile from creation.
            expectedSessionProfile: target.adoptedSessionProfile ?? .standard
        )

        // All failures after activation must clean up only this invocation's control context.
        do {
            if let oracleReviewSource {
                try agentModeVM.mcpStageAgentRunOracleReviewSource(
                    oracleReviewSource,
                    targetTabID: target.tabID,
                    targetSessionID: sessionID,
                    expectedParentSessionID: expectedParentSessionID
                )
            }
            try await agentModeVM.mcpConfigureSession(
                tabID: target.tabID,
                agentRaw: agentRaw,
                modelRaw: resolvedModel,
                reasoningEffortRaw: resolvedEffort
            )
            agentModeVM.mcpSeedRoleOhMyPiThinkingSelections(
                tabID: target.tabID,
                targetOrigin: target.origin,
                taskLabelKind: taskLabelKind,
                selections: roleOhMyPiThinkingSelections
            )
            try await bindCurrentRequestToTab(target.tabID, metadata)
            #if DEBUG
                AgentModePerfDiagnostics.event("mcp.routing.externalRunStarterBoundRequest", tabID: target.tabID, fields: [
                    "sessionID": sessionID.uuidString,
                    "connectionID": metadata.connectionID?.uuidString ?? "nil",
                    "windowID": metadata.windowID.map(String.init) ?? "nil"
                ])
            #endif

            guard let liveSession = agentModeVM.session(for: target.tabID, createIfNeeded: false) else {
                throw MCPError.internalError("Failed to resolve target agent session.")
            }
            #if DEBUG
                if let ompQualificationInvocationContext,
                   liveSession.mcpStartInvocationGenerationID != ompQualificationInvocationContext.generationID
                   || liveSession.ompQualificationStartContext !== ompQualificationInvocationContext
                {
                    ompQualificationInvocationContext.authorizationReceipt.resolve(.denied)
                    throw OMPQualificationInvocationError.contextReplaced
                }
            #endif
            // Step 5b: a linked delegated child dispatches only while its parent admission holds.
            try agentModeVM.mcpRequireDelegatedChildDispatchFence(
                agentModeVM.mcpDelegatedChildDispatchFence(for: sessionID)
            )

            let delivery: AgentModeViewModel.MCPInstructionDispatch = if let dispatchInstruction {
                try await dispatchInstruction(sessionID, target.tabID, message, workflow, agentModeVM)
            } else {
                try await agentModeVM.mcpDispatchInstruction(
                    sessionID: sessionID,
                    text: message,
                    allowStartingRun: true,
                    workflow: workflow
                )
            }

            let snapshot = await resolveInitialSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
            #if DEBUG
                AgentModePerfDiagnostics.event("mcp.routing.externalRunStarterDispatched", tabID: target.tabID, fields: [
                    "sessionID": sessionID.uuidString,
                    "connectionID": metadata.connectionID?.uuidString ?? "nil",
                    "snapshotStatus": snapshot.status.rawValue
                ])
            #endif
            return StartOutcome(snapshot: snapshot, delivery: delivery)
        } catch {
            await agentModeVM.mcpDeactivateControlContext(
                sessionID: sessionID,
                ifOwnedBy: activatedControlContext,
                cleanupSessionStore: true
            )
            throw error
        }
    }

    private static func resolveInitialSnapshot(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> AgentRunMCPSnapshot {
        guard let registration = agentModeVM.mcpRegistration(sessionID: sessionID) else {
            return .expired(sessionID: sessionID)
        }
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration) {
            return storedSnapshot
        }
        await Task.yield()
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration) {
            return storedSnapshot
        }
        return .expired(sessionID: sessionID)
    }
}
