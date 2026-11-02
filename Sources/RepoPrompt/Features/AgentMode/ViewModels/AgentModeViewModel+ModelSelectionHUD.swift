import Foundation
import RepoPromptAgentCore

private struct AgentModelSelectionHUDCommitError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

extension AgentModeViewModel {
    @MainActor
    func makeModelSelectionHUDPresentation(
        mode: AgentModelSelectionHUDMode,
        sourceTabID: UUID,
        windowID: Int
    ) -> AgentModelSelectionHUDPresentation {
        switch mode {
        case .switchModel:
            makeCurrentModelSelectionHUDPresentation(
                sourceTabID: sourceTabID
            )
        case .handoffLastReply:
            makeHandoffModelSelectionHUDPresentation(
                sourceTabID: sourceTabID,
                windowID: windowID
            )
        }
    }

    @MainActor
    private func makeCurrentModelSelectionHUDPresentation(
        sourceTabID: UUID
    ) -> AgentModelSelectionHUDPresentation {
        guard currentTabID == sourceTabID,
              let sourceSession = sessions[sourceTabID]
        else {
            return .unavailable(
                title: AgentModelSelectionHUDMode.switchModel.title,
                message: AgentModelSelectionCommitError.sourceUnavailable.localizedDescription
            )
        }

        switch modelSelectionInteractivity(tabID: sourceTabID) {
        case .interactive:
            break
        case let .disabled(reason):
            return .unavailable(
                title: AgentModelSelectionHUDMode.switchModel.title,
                message: reason
            )
        }

        let sourceIdentity = ObjectIdentifier(sourceSession)
        if let remoteHost = sourceSession.remoteHost {
            let catalog = cachedRemoteHostCatalog(sourceTabID: sourceTabID)
            let index = AgentModelSelectionIndex.remote(
                hostID: remoteHost.hostID,
                hostDisplayName: remoteHost.hostDisplayName,
                catalog: catalog,
                includeHostDefault: true,
                selectedModelID: sourceSession.selectedModelRaw
            )
            return AgentModelSelectionHUDPresentation(
                title: AgentModelSelectionHUDMode.switchModel.title,
                subtitle: "Models on \(remoteHost.hostDisplayName)",
                index: index,
                noticeText: catalog == nil
                    ? "Using the host default until a cached model catalog is available."
                    : nil,
                unavailableMessage: index.leaves.isEmpty
                    ? "No cached remote models are available for this session."
                    : nil,
                onSuccessfulModelSelection: { [weak self] in
                    self?.requestComposerFocusAfterModelSelection(
                        sourceTabID: sourceTabID,
                        sourceIdentity: sourceIdentity
                    )
                },
                commit: { [weak self] leaf in
                    guard let self else {
                        throw AgentModelSelectionCommitError.sourceUnavailable
                    }
                    try commitCurrentRemoteModelSelection(
                        leaf: leaf,
                        sourceTabID: sourceTabID,
                        sourceIdentity: sourceIdentity,
                        expectedHostID: remoteHost.hostID
                    )
                }
            )
        }

        let agents = selectableAgents(forTabID: sourceTabID).filter {
            canSelectAgentInCurrentChat($0, tabID: sourceTabID)
        }
        var optionsByAgent: [AgentProviderKind: [AgentModelOption]] = [:]
        for agent in agents {
            optionsByAgent[agent] = modelOptions(
                for: agent,
                includeClaudeEffortVariants: !agent.usesClaudeTooling
            )
        }
        let index = AgentModelSelectionIndex.local(
            agents: agents,
            optionsByAgent: optionsByAgent,
            selected: AgentModelSelectionLocalSelection(
                agent: sourceSession.selectedAgent,
                modelRaw: sourceSession.selectedModelRaw,
                reasoningEffortRaw: sourceSession.selectedReasoningEffortRaw
            ),
            selectionDefaults: .standard
        )
        return AgentModelSelectionHUDPresentation(
            title: AgentModelSelectionHUDMode.switchModel.title,
            subtitle: "Current Agent session",
            index: index,
            noticeText: lockedAgentSelectionMessage(tabID: sourceTabID),
            unavailableMessage: index.leaves.isEmpty
                ? "No selectable models are available for this session."
                : nil,
            onSuccessfulModelSelection: { [weak self] in
                self?.requestComposerFocusAfterModelSelection(
                    sourceTabID: sourceTabID,
                    sourceIdentity: sourceIdentity
                )
            },
            commit: { [weak self] leaf in
                guard let self,
                      let liveSession = sessions[sourceTabID],
                      ObjectIdentifier(liveSession) == sourceIdentity
                else {
                    throw AgentModelSelectionCommitError.sourceUnavailable
                }
                guard case let .local(agent, modelRaw, effortRaw) = leaf.commitPayload else {
                    throw AgentModelSelectionCommitError.modelUnavailable
                }
                try commitCurrentSessionModelSelection(
                    agent: agent,
                    rawModel: modelRaw,
                    explicitCodexEffort: CodexReasoningEffort.parse(effortRaw),
                    sourceTabID: sourceTabID
                )
            }
        )
    }

    @MainActor
    private func requestComposerFocusAfterModelSelection(
        sourceTabID: UUID,
        sourceIdentity: ObjectIdentifier
    ) {
        guard !isShutdownFrozen,
              currentTabID == sourceTabID,
              let session = sessions[sourceTabID],
              ObjectIdentifier(session) == sourceIdentity
        else { return }
        ui.composer.requestFocus(AgentComposerFocusRequest(
            id: UUID(),
            tabID: sourceTabID,
            reason: .modelSelectionCommitted
        ))
    }

    @MainActor
    private func makeHandoffModelSelectionHUDPresentation(
        sourceTabID: UUID,
        windowID: Int
    ) -> AgentModelSelectionHUDPresentation {
        let mode = AgentModelSelectionHUDMode.handoffLastReply
        let target: AgentLastCompletedAssistantReplyHandoffTarget
        switch resolveLastReplyHandoffTarget(sourceTabID: sourceTabID) {
        case let .target(resolved):
            target = resolved
        case let .unavailable(message):
            return .unavailable(
                title: mode.title,
                message: message
            )
        }

        guard let config = makeHandoffConfig(
            for: target.clientRowID,
            sourceTabID: sourceTabID,
            windowID: windowID,
            remoteCatalogAccess: .cacheOnly
        ) else {
            return .unavailable(
                title: mode.title,
                message: "The source reply is no longer available for handoff."
            )
        }

        let index: AgentModelSelectionIndex
        let unavailableMessage: String?
        switch config.destinationSource {
        case .localProviders:
            let agents = config.availableAgentsProvider()
            var optionsByAgent: [AgentProviderKind: [AgentModelOption]] = [:]
            for agent in agents {
                optionsByAgent[agent] = config.modelOptionsProvider(agent)
            }
            index = AgentModelSelectionIndex.local(
                agents: agents,
                optionsByAgent: optionsByAgent,
                selected: AgentModelSelectionLocalSelection(
                    agent: config.defaultDestinationAgent,
                    modelRaw: config.defaultModelRaw,
                    reasoningEffortRaw: config.defaultReasoningEffortRaw
                ),
                selectionDefaults: .standard
            )
            unavailableMessage = index.leaves.isEmpty
                ? "No handoff destination models are available."
                : nil

        case let .remoteCatalog(hostID):
            index = AgentModelSelectionIndex.remote(
                hostID: hostID,
                hostDisplayName: sessions[sourceTabID]?.remoteHost?.hostDisplayName,
                catalog: config.remoteCatalogSnapshot,
                includeHostDefault: false,
                selectedModelID: config.defaultModelRaw
            )
            if config.remoteCatalogSnapshot == nil {
                unavailableMessage = "The remote model catalog is not cached yet."
            } else if config.remoteCatalogSnapshot?.isDegraded == true {
                unavailableMessage = "This host did not expose handoff destination models."
            } else {
                unavailableMessage = index.leaves.isEmpty
                    ? "No remote handoff destination models are available."
                    : nil
            }
        }

        let notice = target.previewText.isEmpty
            ? "Handing off the last completed assistant reply."
            : "Target reply: “\(target.previewText)”"
        return AgentModelSelectionHUDPresentation(
            title: mode.title,
            subtitle: "Start a new session from the last completed reply",
            index: index,
            noticeText: notice,
            unavailableMessage: unavailableMessage,
            commit: { [weak self] leaf in
                guard let self else {
                    throw AgentHandoffConfigurationError.sourceUnavailable
                }
                do {
                    let destination = try validatedHandoffDestination(
                        leaf: leaf,
                        sourceTabID: sourceTabID,
                        expectedTarget: target,
                        windowID: windowID
                    )
                    try await AgentHandoffActionSupport.performCommittedHandoff(
                        destination,
                        perform: config.performHandoff
                    )
                } catch {
                    throw AgentModelSelectionHUDCommitError(
                        message: AgentHandoffActionSupport.errorMessage(
                            for: .handoff,
                            error: error
                        )
                    )
                }
            }
        )
    }

    @MainActor
    private func commitCurrentRemoteModelSelection(
        leaf: AgentModelSelectionLeaf,
        sourceTabID: UUID,
        sourceIdentity: ObjectIdentifier,
        expectedHostID: String
    ) throws {
        guard currentTabID == sourceTabID,
              let session = sessions[sourceTabID],
              ObjectIdentifier(session) == sourceIdentity
        else {
            throw AgentModelSelectionCommitError.sourceUnavailable
        }
        switch modelSelectionInteractivity(tabID: sourceTabID) {
        case .interactive:
            break
        case let .disabled(reason):
            throw AgentModelSelectionCommitError.controlsDisabled(reason: reason)
        }
        guard session.remoteHost?.hostID == expectedHostID else {
            throw AgentModelSelectionCommitError.sourceUnavailable
        }

        let catalog = cachedRemoteHostCatalog(sourceTabID: sourceTabID)
        let liveIndex = AgentModelSelectionIndex.remote(
            hostID: expectedHostID,
            hostDisplayName: session.remoteHost?.hostDisplayName,
            catalog: catalog,
            includeHostDefault: true,
            selectedModelID: session.selectedModelRaw
        )
        guard liveIndex.leaves.contains(where: { $0.commitPayload == leaf.commitPayload }) else {
            throw AgentModelSelectionCommitError.modelUnavailable
        }
        switch leaf.commitPayload {
        case let .remote(_, modelID, _):
            selectRemoteAgentModel(rawModel: modelID)
        case .hostDefault:
            selectRemoteAgentModel(rawModel: RemoteHostAgentCatalog.hostDefaultModelID)
        case .local:
            throw AgentModelSelectionCommitError.modelUnavailable
        }
    }

    @MainActor
    private func validatedHandoffDestination(
        leaf: AgentModelSelectionLeaf,
        sourceTabID: UUID,
        expectedTarget: AgentLastCompletedAssistantReplyHandoffTarget,
        windowID: Int
    ) throws -> AgentHandoffDestination {
        guard case let .target(liveTarget) = resolveLastReplyHandoffTarget(
            sourceTabID: sourceTabID
        ),
            liveTarget.clientRowID == expectedTarget.clientRowID,
            liveTarget.hostRowID == expectedTarget.hostRowID,
            let config = makeHandoffConfig(
                for: liveTarget.clientRowID,
                sourceTabID: sourceTabID,
                windowID: windowID,
                remoteCatalogAccess: .cacheOnly
            )
        else {
            throw AgentHandoffConfigurationError.sourceUnavailable
        }

        switch leaf.commitPayload {
        case let .local(agent, modelRaw, reasoningEffortRaw):
            guard config.destinationSource == .localProviders else {
                throw AgentHandoffConfigurationError.invalidDestination
            }
            let agents = config.availableAgentsProvider()
            guard agents.contains(agent) else {
                throw AgentHandoffConfigurationError.invalidDestination
            }
            let options = config.modelOptionsProvider(agent)
            let liveIndex = AgentModelSelectionIndex.local(
                agents: [agent],
                optionsByAgent: [agent: options],
                selected: AgentModelSelectionLocalSelection(
                    agent: config.defaultDestinationAgent,
                    modelRaw: config.defaultModelRaw,
                    reasoningEffortRaw: config.defaultReasoningEffortRaw
                ),
                selectionDefaults: .standard
            )
            guard liveIndex.leaves.contains(where: { $0.commitPayload == leaf.commitPayload }) else {
                throw AgentHandoffConfigurationError.invalidDestination
            }
            return .local(AgentHandoffSelection(
                agent: agent,
                modelRaw: modelRaw,
                reasoningEffortRaw: reasoningEffortRaw
            ))

        case let .remote(agentID, modelID, effort):
            guard case let .remoteCatalog(hostID) = config.destinationSource else {
                throw AgentHandoffConfigurationError.invalidDestination
            }
            let liveIndex = AgentModelSelectionIndex.remote(
                hostID: hostID,
                hostDisplayName: sessions[sourceTabID]?.remoteHost?.hostDisplayName,
                catalog: config.remoteCatalogSnapshot,
                includeHostDefault: false,
                selectedModelID: config.defaultModelRaw
            )
            guard liveIndex.leaves.contains(where: { $0.commitPayload == leaf.commitPayload }) else {
                throw AgentHandoffConfigurationError.invalidDestination
            }
            return .remote(agentID: agentID, modelID: modelID, effort: effort)

        case .hostDefault:
            throw AgentHandoffConfigurationError.invalidDestination
        }
    }
}
