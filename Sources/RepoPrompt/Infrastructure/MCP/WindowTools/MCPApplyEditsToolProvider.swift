import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptAgentCore
import RepoPromptShared
import RepoPromptWorkspace

@MainActor
final class MCPApplyEditsToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .applyEdits

    private typealias EditSummary = ToolResultDTOs.EditSummary

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [applyEditsTool()]
    }

    private func applyEditsTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.applyEdits,
            freshnessPolicy: .providerManaged,
            description: """
            Apply direct file edits. Provide exactly ONE of these three modes:

            **Mode 1: Rewrite** - Replace entire file content
            `{"path": "file.swift", "rewrite": "new content...", "on_missing": "create"}`

            **Mode 2: Single replacement** - Find and replace text
            `{"path": "file.swift", "search": "oldCode", "replace": "newCode", "all": true}`

            **Mode 3: Multiple edits** - Apply several replacements
            `{"path": "file.swift", "edits": [{"search": "old1", "replace": "new1"}, {"search": "old2", "replace": "new2"}]}`

            Note: Modes are mutually exclusive. Providing more than one will result in an error.

            Options: `verbose` (show diff), `on_missing` (for rewrite only: "error" | "create", default: "error")
            Edits are literal. Use real JSON newlines for multi-line search/replace (not `\\n`). If a match fails, the tool may retry internally with escape decoding.
            """,
            annotations: .repoPromptLocalDestructive,
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File path"),
                    "operation_id": .string(description: "Optional caller-stable correlation ID echoed in applied mutation replies; this does not provide deduplication or replay safety"),
                    "rewrite": .string(description: "Replace the entire file content with this string"),
                    "search": .string(description: "Text to find"),
                    "replace": .string(description: "Replacement text"),
                    "all": .boolean(description: "Replace all occurrences (default: false)"),
                    "edits": .array(
                        description: "Multiple edits",
                        items: .object(
                            properties: [
                                "search": .string(description: "Text to find"),
                                "replace": .string(description: "Replacement text"),
                                "all": .boolean(description: "Replace all occurrences (default: false)")
                            ],
                            required: ["search", "replace"]
                        )
                    ),
                    "verbose": .boolean(description: "Include diff preview"),
                    "on_missing": .string(
                        description: "Behavior when the file is missing (only for `rewrite`)",
                        enum: ["error", "create"]
                    )
                ],
                required: ["path"]
            )
        ) { [self] _, args in
            try await Value(executeApplyEdits(args: args))
        }
    }

    private func executeApplyEdits(args: [String: Value]) async throws -> EditSummary {
        var requestPath: String? = nil
        do {
            let request = try EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.requestBuild) {
                try ApplyEditsRequestBuilder().buildFromNormalizedPayload(args)
            }
            requestPath = request.path
            let suppliedOperationID = args["operation_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let operationID = suppliedOperationID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let metadata = await dependencies.captureRequestMetadata()
            let (resolvedContext, lookupContext) = try await dependencies.resolveMutationFileToolContext(
                metadata,
                MCPWindowToolName.applyEdits
            )
            if !resolvedContext.usesActiveTabCompatibility,
               let failure = MCPMutationRetryableFailure.unresolvedRouteFailure(
                   for: resolvedContext.snapshot
               )
            {
                return Self.retryableFailureSummary(request: request, failure: failure)
            }
            if let failure = await MCPMutationRetryableFailure.mutationScopeFailure(
                for: lookupContext,
                store: dependencies.promptVM.workspaceFileContextStore
            ) {
                return Self.retryableFailureSummary(request: request, failure: failure)
            }
            let effectivePath = lookupContext.translateInputPath(request.path)
            let displayPath = lookupContext.bindingProjection?.projectedLogicalDisplayPath(forPhysicalPath: effectivePath, display: .relative) ?? request.path
            do {
                _ = try await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                    userPath: effectivePath,
                    fallbackScope: lookupContext.rootScope,
                    timeout: .seconds(MCPTimeoutPolicy.workspaceFreshnessWaitTimeoutSeconds)
                )
            } catch is WorkspaceAppliedIngressWaitError {
                return Self.retryableFailureSummary(
                    request: request,
                    failure: .workspaceFreshnessUnavailable()
                )
            }
            if let issue = await dependencies.promptVM.workspaceFileContextStore.exactPathResolutionIssue(for: effectivePath, kind: .file, rootScope: lookupContext.rootScope) {
                throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
            }
            let store = await MainActor.run { dependencies.promptVM.workspaceFileContextStore }
            let host = WorkspaceFileEditHost(
                store: store,
                selectionCoordinator: dependencies.selectionCoordinator,
                lookupRootScope: lookupContext.rootScope,
                createPathResolutionPolicy: .canonicalAliasFirst,
                selectCreatedFiles: true
            )
            let service = ApplyEditsService(engine: .default, host: host)

            let runPurpose: MCPRunPurpose? = if let connectionID = metadata.connectionID {
                await ServerNetworkManager.shared.runPurpose(for: connectionID)
            } else {
                nil
            }
            let virtualTabID: UUID? = resolvedContext.usesActiveTabCompatibility ? nil : resolvedContext.snapshot.tabID
            let availableTabIDs = await MainActor.run {
                Set(dependencies.workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
            }
            let tabID = try Self.resolveApplyEditsAgentModeTabID(
                runPurpose: runPurpose,
                virtualTabID: virtualTabID,
                rawTabID: args["_tabID"]?.stringValue,
                availableTabIDs: availableTabIDs
            )

            #if DEBUG
                let probeRequestIdentity = MCPRequestTimelineContext.current
                    ?? MCPApplyEditsRebaseProbeRecorder.latestApplyEditsRequestIdentity(
                        connectionID: metadata.connectionID
                    )
                MCPApplyEditsRebaseProbeRecorder.recordApplyEditsInvocation(
                    connectionID: metadata.connectionID,
                    workspaceID: resolvedContext.snapshot.workspaceID,
                    tabID: resolvedContext.snapshot.tabID,
                    physicalPath: effectivePath,
                    requestIdentity: probeRequestIdentity
                )
            #endif

            let approvalScope: ApplyEditsApprovalScope? = if runPurpose == .agentModeRun, let tabID {
                ApplyEditsApprovalScope(windowID: dependencies.windowID, tabID: tabID)
            } else {
                nil
            }

            var shouldRequireApproval = false
            if let approvalScope {
                let autoEditEnabled = await dependencies.applyEditsApprovalStore.autoEditEnabled(for: approvalScope)
                shouldRequireApproval = !autoEditEnabled
            }

            if shouldRequireApproval, let approvalScope {
                // Step 5a: the review's recovery owner (or its established untracked status) is
                // frozen before any new await; nothing later adopts a replacement owner.
                let agentModeViewModel = try dependencies.requireTargetWindow().agentModeViewModel
                let recoveryOwner = try agentModeViewModel.mcpCaptureApplyEditsReviewOwner(tabID: approvalScope.tabID)
                // A recovery-tracked review is bound to one canonical absolute file: the preview reads
                // it, the proposal stores it, and the reviewed write targets it (untracked unchanged).
                let existingTarget: String? = if recoveryOwner != nil {
                    await host.canonicalExistingFilePath(path: effectivePath)
                } else {
                    nil
                }
                let previewRequest = ApplyEditsRequest(
                    path: existingTarget ?? effectivePath,
                    mode: request.mode,
                    verbose: true
                )
                let preview = try await service.preview(previewRequest)
                let previewResult = preview.result
                if previewResult.editsApplied == 0 {
                    return editSummary(from: previewResult, path: displayPath)
                }
                let reviewUnifiedDiff = previewResult.unifiedDiffForToolCard(filePath: displayPath)
                    ?? "No textual diff available for this apply_edits request."
                let reviewTargetPath: String = if recoveryOwner == nil {
                    effectivePath
                } else {
                    try await Self.canonicalReviewTarget(
                        existingTarget: existingTarget,
                        previewExists: preview.exists,
                        effectivePath: effectivePath,
                        host: host
                    )
                }

                // Then the review's identity, then its proposal saved for crash recovery under the
                // frozen owner before the review is shown.
                let ticket = await dependencies.applyEditsApprovalStore.beginReview(scope: approvalScope)
                let recovery = try await agentModeViewModel.mcpAdmitApplyEditsReviewProposal(
                    owner: recoveryOwner,
                    reviewID: ticket.reviewID,
                    input: ApplyEditsReviewProposalInput(
                        physicalPath: reviewTargetPath,
                        displayPath: displayPath,
                        unifiedDiff: reviewUnifiedDiff,
                        proposedText: previewResult.updatedText,
                        baseText: preview.exists ? preview.originalText : nil
                    )
                )
                let decision = await dependencies.applyEditsApprovalStore.awaitReview(
                    ticket,
                    path: displayPath,
                    unifiedDiff: reviewUnifiedDiff,
                    timeoutSeconds: MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds
                )
                let recoveryViewModel = recovery == nil ? nil : agentModeViewModel
                let approvalStore = dependencies.applyEditsApprovalStore

                switch decision {
                case .accept:
                    // `applicationStarted` acknowledged, then the exact ticket and owner re-checked,
                    // before the existing host write (recovery-tracked sessions only).
                    let recorded = try await agentModeViewModel.mcpPerformAcceptedApplyEditsReview(
                        recovery,
                        ticketIsCurrent: { await approvalStore.isReviewTicketCurrent(ticket) },
                        write: {
                            try await EditFlowPerf.measure(
                                EditFlowPerf.Stage.ApplyEdits.hostWrite,
                                EditFlowPerf.Dimensions(fileBytes: previewResult.updatedText.utf8.count, appliedCount: previewResult.editsApplied)
                            ) {
                                try await host.writeText(
                                    path: reviewTargetPath,
                                    content: previewResult.updatedText,
                                    overwrite: preview.exists
                                )
                            }
                        }
                    )
                    let freshness = await postMutationFreshness(
                        userPath: effectivePath,
                        rootScope: lookupContext.rootScope
                    )
                    let persistedResult = previewResult.withFileMetadata(created: !preview.exists, overwritten: false)
                    #if DEBUG
                        MCPApplyEditsRebaseProbeRecorder.recordApplyEditsOutcome(
                            connectionID: metadata.connectionID,
                            workspaceID: resolvedContext.snapshot.workspaceID,
                            tabID: resolvedContext.snapshot.tabID,
                            physicalPath: effectivePath,
                            requestIdentity: probeRequestIdentity,
                            editsApplied: persistedResult.editsApplied,
                            outcome: "success"
                        )
                    #endif
                    guard recorded else {
                        // Truthful partial success: the file was written; only the recovery
                        // record of that is missing. Never "nothing changed", never retry.
                        return editSummary(
                            from: persistedResult,
                            path: displayPath,
                            statusOverride: "partial",
                            noteOverride: Self.recoveryRecordFailedNote,
                            reviewStatus: "accepted",
                            requiresUserApproval: true,
                            operationID: operationID,
                            freshness: freshness,
                            errorMessage: Self.recoveryRecordFailedNote,
                            errorCode: "recovery_record_failed",
                            retryable: false
                        )
                    }
                    return editSummary(
                        from: persistedResult,
                        path: displayPath,
                        reviewStatus: "accepted",
                        requiresUserApproval: true,
                        operationID: operationID,
                        freshness: freshness
                    )
                case let .reject(reason):
                    let withdrawn = await recoveryViewModel?.mcpFinishApplyEditsReview(recovery, .withdrawn) ?? true
                    guard withdrawn else {
                        // Truthful: nothing was written, but the rejection was not saved, so the
                        // proposal stays historical in Needs Attention.
                        let note = Self.rejectionNotRecordedNote(reason: reason)
                        return editSummary(
                            from: previewResult,
                            path: displayPath,
                            statusOverride: "failed",
                            noteOverride: note,
                            reviewStatus: "rejected",
                            rejectionReason: reason,
                            requiresUserApproval: true,
                            errorMessage: note,
                            errorCode: "recovery_record_failed",
                            retryable: false
                        )
                    }
                    return editSummary(
                        from: previewResult,
                        path: displayPath,
                        statusOverride: "failed",
                        noteOverride: "Rejected by user: \(reason)",
                        reviewStatus: "rejected",
                        rejectionReason: reason,
                        requiresUserApproval: true
                    )
                case .timeout:
                    await recoveryViewModel?.mcpFinishApplyEditsReview(recovery, .preserved)
                    return editSummary(
                        from: previewResult,
                        path: displayPath,
                        statusOverride: "failed",
                        noteOverride: "Timed out waiting for apply_edits review approval",
                        reviewStatus: "timeout",
                        requiresUserApproval: true
                    )
                case let .cancelled(reason):
                    await recoveryViewModel?.mcpFinishApplyEditsReview(recovery, .preserved)
                    return editSummary(
                        from: previewResult,
                        path: displayPath,
                        statusOverride: "failed",
                        noteOverride: "Apply edits review was cancelled: \(reason)",
                        reviewStatus: "cancelled",
                        rejectionReason: reason,
                        requiresUserApproval: true
                    )
                }
            }

            let effectiveRequest = ApplyEditsRequest(path: effectivePath, mode: request.mode, verbose: request.verbose)
            let result = try await service.run(effectiveRequest)
            let freshness: String?
            if result.editsApplied > 0 {
                freshness = await postMutationFreshness(
                    userPath: effectivePath,
                    rootScope: lookupContext.rootScope
                )
            } else {
                freshness = nil
                EditFlowPerf.event(
                    EditFlowPerf.Stage.ApplyEdits.flushDeltas,
                    EditFlowPerf.Dimensions(outcome: "skipped", appliedCount: result.editsApplied)
                )
            }
            #if DEBUG
                MCPApplyEditsRebaseProbeRecorder.recordApplyEditsOutcome(
                    connectionID: metadata.connectionID,
                    workspaceID: resolvedContext.snapshot.workspaceID,
                    tabID: resolvedContext.snapshot.tabID,
                    physicalPath: effectivePath,
                    requestIdentity: probeRequestIdentity,
                    editsApplied: result.editsApplied,
                    outcome: "success"
                )
            #endif
            return editSummary(
                from: result,
                path: displayPath,
                operationID: result.editsApplied > 0 ? operationID : nil,
                freshness: freshness
            )
        } catch let error as FileManagerError {
            throw await dependencies.mapFileManagerErrorToMCP(error, MCPWindowToolName.applyEdits, requestPath)
        } catch let error as ApplyEditsError {
            throw Self.mapApplyEditsError(error)
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.internalError(error.localizedDescription)
        }
    }

    private func postMutationFreshness(
        userPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> String {
        await EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.flushDeltas) {
            do {
                _ = try await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                    userPath: userPath,
                    fallbackScope: rootScope,
                    timeout: .seconds(2)
                )
                return "fresh"
            } catch {
                return "pending"
            }
        }
    }

    private static func retryableFailureSummary(
        request: ApplyEditsRequest,
        failure: MCPMutationRetryableFailure
    ) -> EditSummary {
        EditSummary(
            status: "failed",
            editsRequested: request.editCount,
            editsApplied: 0,
            addedLines: nil,
            deletedLines: nil,
            totalLinesChanged: nil,
            totalChunks: nil,
            results: nil,
            unifiedDiff: nil,
            cardUnifiedDiff: nil,
            note: nil,
            fileCreated: nil,
            fileOverwritten: nil,
            reviewStatus: nil,
            rejectionReason: nil,
            requiresUserApproval: nil,
            errorMessage: failure.errorMessage,
            errorCode: failure.errorCode,
            retryable: failure.retryable,
            retryAfterMilliseconds: failure.retryAfterMilliseconds,
            suggestion: failure.suggestion
        )
    }

    private static func resolveApplyEditsAgentModeTabID(
        runPurpose: MCPRunPurpose?,
        virtualTabID: UUID?,
        rawTabID: String?,
        availableTabIDs: Set<UUID>
    ) throws -> UUID? {
        guard runPurpose == .agentModeRun else { return virtualTabID }

        let normalizedRawTabID = normalizedTabIDArgument(rawTabID)
        if let normalizedRawTabID, UUID(uuidString: normalizedRawTabID) == nil {
            throw MCPError.invalidParams("Invalid _tabID '\(normalizedRawTabID)'. Expected a UUID.")
        }
        let explicitTabID = normalizedRawTabID.flatMap(UUID.init(uuidString:))

        let resolvedTabID = virtualTabID ?? explicitTabID
        guard let resolvedTabID else {
            throw MCPError.invalidParams(
                "RepoPrompt could not route this Agent Mode MCP call to the active run. Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
            )
        }
        let sourceDescription = (virtualTabID != nil && resolvedTabID == virtualTabID)
            ? "bound tab"
            : "_tabID '\(resolvedTabID.uuidString)'"
        guard availableTabIDs.contains(resolvedTabID) else {
            throw MCPError.invalidParams("Tab not found for \(sourceDescription).")
        }
        return resolvedTabID
    }

    private static func normalizedTabIDArgument(_ rawTabID: String?) -> String? {
        let trimmed = rawTabID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func editSummary(
        from result: ApplyEditsResult,
        path: String,
        statusOverride: String? = nil,
        noteOverride: String? = nil,
        reviewStatus: String? = nil,
        rejectionReason: String? = nil,
        requiresUserApproval: Bool? = nil,
        operationID: String? = nil,
        freshness: String? = nil,
        errorMessage: String? = nil,
        errorCode: String? = nil,
        retryable: Bool? = nil
    ) -> EditSummary {
        let lineStats = result.toolCardLineStats()
        return EditSummary(
            status: statusOverride ?? result.status.rawValue,
            editsRequested: result.editsRequested,
            editsApplied: result.editsApplied,
            addedLines: lineStats?.addedLines,
            deletedLines: lineStats?.deletedLines,
            totalLinesChanged: result.stats?.linesChanged,
            totalChunks: result.stats?.chunks,
            results: result.outcomes,
            unifiedDiff: result.unifiedDiff,
            cardUnifiedDiff: result.unifiedDiffForToolCard(filePath: path),
            note: noteOverride ?? result.note,
            fileCreated: result.fileCreated ? true : nil,
            fileOverwritten: result.fileOverwritten ? true : nil,
            reviewStatus: reviewStatus,
            rejectionReason: rejectionReason,
            requiresUserApproval: requiresUserApproval,
            errorMessage: errorMessage,
            errorCode: errorCode,
            retryable: retryable,
            operationID: operationID,
            mutationState: operationID == nil ? nil : "applied",
            freshness: freshness
        )
    }

    /// Step 5a: the canonical absolute file a recovery-tracked review previewed and will write: the
    /// existing file resolved before the preview, or for a new file the create destination resolved
    /// now (current selection and policy). Fails closed rather than inventing a target when the
    /// preview disagrees with the resolution or no destination can be established.
    static func canonicalReviewTarget(
        existingTarget: String?,
        previewExists: Bool,
        effectivePath: String,
        host: WorkspaceFileEditHost
    ) async throws -> String {
        let unestablished = "apply_edits: the file this edit targets couldn't be established for review (it appeared, disappeared, or moved while the edit was being prepared). Nothing was changed. Retry the edit."
        if previewExists {
            guard let existingTarget else { throw MCPError.invalidParams(unestablished) }
            return existingTarget
        }
        guard existingTarget == nil else { throw MCPError.invalidParams(unestablished) }
        return try await host.canonicalCreateDestinationPath(path: effectivePath)
    }

    static func rejectionNotRecordedNote(reason: String) -> String {
        "Rejected by user: \(reason). The file was not changed, but RepoPrompt could not save the rejection in its crash-recovery state, so the proposal remains listed in Needs Attention. It is never applied automatically."
    }

    static let recoveryRecordFailedNote = "The edit was written to the file, but RepoPrompt could not record that in its crash-recovery state. Do not retry this edit; it is already applied. After a restart this edit may be listed as possibly applied."

    private static func mapApplyEditsError(_ error: ApplyEditsError) -> MCPError {
        switch error {
        case let .invalidParams(message):
            MCPError.invalidParams(message)
        case let .internalError(message):
            MCPError.internalError(message)
        }
    }
}
