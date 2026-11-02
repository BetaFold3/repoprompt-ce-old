import Foundation
import RepoPromptAgentCore
import RepoPromptShared
import RepoPromptUI
import SwiftUI

func isAutoExpandableEditToolResult(_ item: AgentChatItem) -> Bool {
    guard item.kind == .toolResult,
          let toolName = normalizedToolCardName(item.toolName)?.lowercased()
    else { return false }
    return toolName == "apply_edits" || toolName == "apply_patch" || toolName == "edit"
}

enum AgentOracleToolRouting {
    static func operationPopoverUserInfo(
        openContext: AgentOracleOpenContext?,
        chatID: String?,
        tabID: UUID? = nil
    ) -> [AnyHashable: Any]? {
        AgentOraclePopoverRoute(
            openContext: openContext,
            chatID: chatID,
            tabID: tabID
        )?.notificationUserInfo
    }

    static func latestPopoverUserInfo(
        openContext: AgentOracleOpenContext?,
        tabID: UUID? = nil
    ) -> [AnyHashable: Any]? {
        AgentOracleLatestPopoverRoute(
            openContext: openContext,
            tabID: tabID
        )?.notificationUserInfo
    }
}

struct ContextBuilderCardContext {
    let tabID: UUID?
    let contextBuilderAgentVM: ContextBuilderAgentViewModel
    let activeContextBuilderCallItemID: UUID?
    let activeContextBuilderResultItemID: UUID?
    let oracleOpenContext: AgentOracleOpenContext?
    let showRunScopedToolCancel: Bool
    let cancelActiveToolsAction: (() -> Void)?
    var isRemoteSession: Bool = false

    init(
        tabID: UUID?,
        contextBuilderAgentVM: ContextBuilderAgentViewModel,
        activeContextBuilderCallItemID: UUID?,
        activeContextBuilderResultItemID: UUID?,
        oracleOpenContext: AgentOracleOpenContext?,
        showRunScopedToolCancel: Bool = false,
        cancelActiveToolsAction: (() -> Void)? = nil,
        isRemoteSession: Bool = false
    ) {
        self.tabID = tabID
        self.contextBuilderAgentVM = contextBuilderAgentVM
        self.activeContextBuilderCallItemID = activeContextBuilderCallItemID
        self.activeContextBuilderResultItemID = activeContextBuilderResultItemID
        self.oracleOpenContext = oracleOpenContext
        self.showRunScopedToolCancel = showRunScopedToolCancel
        self.cancelActiveToolsAction = cancelActiveToolsAction
        self.isRemoteSession = isRemoteSession
    }
}

struct AgentControlToolCardContext {
    let authoritativeLocalParentFamily: AgentMCPWaitPolicy.ParentFamily?
    let authoritativeLocalParentPromptCacheRetention: AgentMCPWaitPolicy.ParentPromptCacheRetention

    init(
        authoritativeLocalParentFamily: AgentMCPWaitPolicy.ParentFamily?,
        authoritativeLocalParentPromptCacheRetention: AgentMCPWaitPolicy.ParentPromptCacheRetention = .standard
    ) {
        self.authoritativeLocalParentFamily = authoritativeLocalParentFamily
        self.authoritativeLocalParentPromptCacheRetention = authoritativeLocalParentPromptCacheRetention
    }
}

struct AgentOracleToolCardContext {
    let operationStore: OracleMCPOperationStore
}

enum ToolCardRouter {
    static let knownResultTools: Set<String> = [
        "bash",
        "read",
        "read_file",
        "apply_edits",
        "apply_patch",
        "edit",
        "file_search",
        "search",
        "web_read",
        "get_file_tree",
        "get_code_structure",
        "file_actions",
        "manage_selection",
        "workspace_context",
        "prompt",
        "ask_oracle",
        "oracle_utils",
        "oracle_chat_log",
        "bind_context",
        "manage_workspaces",
        "git",
        "manage_worktree",
        "context_builder",
        "request_user_input",
        "agent_explore",
        "agent_run",
        "agent_manage",
        "app_settings"
    ]

    static func callView(
        for item: AgentChatItem,
        oracleOpenContext: AgentOracleOpenContext? = nil,
        contextBuilder: ContextBuilderCardContext? = nil,
        agentControlContext: AgentControlToolCardContext? = nil,
        showRunScopedToolCancel: Bool = false,
        cancelActiveToolsAction: (() -> Void)? = nil
    ) -> AnyView {
        let normalized = normalizedToolCardName(item.toolName)
        let key = normalized?.lowercased()
        let presentation = callPresentation(for: item)
        let subtitle = presentation?.subtitle ?? callSubtitle(
            for: key,
            argsJSON: item.toolArgsJSON,
            resultJSON: item.toolResultJSON,
            toolIsError: item.toolIsError,
            agentControlContext: agentControlContext
        )
        let header = genericHeader(for: item, normalizedToolName: normalized, explicitTitle: presentation?.title)
        return AnyView(
            ToolCallCard(
                item: item,
                title: header.title,
                sourceLabel: header.sourceLabel,
                subtitle: subtitle,
                oracleOpenContext: oracleOpenContext,
                showRunScopedToolCancel: showRunScopedToolCancel,
                cancelActiveToolsAction: cancelActiveToolsAction
            )
        )
    }

    static func resultView(
        for item: AgentChatItem,
        isMostRecentEditBubble: Bool = true,
        oracleOpenContext: AgentOracleOpenContext? = nil,
        oracleToolCardContext: AgentOracleToolCardContext? = nil,
        contextBuilder: ContextBuilderCardContext? = nil,
        promptManager: PromptViewModel? = nil
    ) -> AnyView {
        let normalized = normalizedToolCardName(item.toolName)
        let key = normalized?.lowercased()
        switch key {
        case "bash":
            return AnyView(BashResultCard(item: item))
        case "read":
            return AnyView(NativeReadResultCard(item: item))
        case "read_file":
            return AnyView(ReadFileResultCard(item: item))
        case "apply_edits":
            return AnyView(ApplyEditsResultCard(item: item, isMostRecentEdit: isMostRecentEditBubble))
        case "apply_patch":
            return AnyView(ApplyPatchResultCard(item: item, isMostRecentEdit: isMostRecentEditBubble))
        case "edit":
            return AnyView(CursorNativeEditResultCard(item: item, isMostRecentEdit: isMostRecentEditBubble))
        case "file_search":
            return AnyView(FileSearchResultCard(item: item))
        case "search":
            return AnyView(WebSearchResultCard(item: item, normalizedToolName: "search"))
        case "web_read":
            return AnyView(WebSearchResultCard(item: item, normalizedToolName: "web_read"))
        case "get_file_tree":
            return AnyView(FileTreeResultCard(item: item))
        case "get_code_structure":
            return AnyView(CodeStructureResultCard(item: item))
        case "file_actions":
            return AnyView(FileActionResultCard(item: item))
        case "manage_selection":
            return AnyView(ManageSelectionResultCard(item: item))
        case "workspace_context":
            return AnyView(WorkspaceContextResultCard(item: item))
        case "prompt":
            return AnyView(PromptResultCard(item: item, promptManager: promptManager))
        case "ask_oracle", "oracle_send":
            return AnyView(ChatSendResultCard(
                item: item,
                oracleOpenContext: oracleOpenContext,
                oracleToolCardContext: oracleToolCardContext
            ))
        case "oracle_chat_log":
            return AnyView(ChatsResultCard(item: item))
        case "chat_send":
            return AnyView(ChatSendResultCard(
                item: item,
                oracleOpenContext: oracleOpenContext,
                oracleToolCardContext: nil
            ))
        case "chats":
            return AnyView(ChatsResultCard(item: item))
        case "list_models":
            return AnyView(ListModelsResultCard(item: item))
        case "bind_context":
            return AnyView(UnknownToolResultCard(item: item, title: toolDisplayName(for: normalized ?? item.toolName)))
        case "manage_workspaces":
            return AnyView(ManageWorkspacesResultCard(item: item))
        case "git":
            return AnyView(GitResultCard(item: item))
        case "manage_worktree":
            if isWorktreeMergeOp(item.toolArgsJSON) || isWorktreeMergeResult(item.toolResultJSON) {
                return AnyView(ToolResultWorktreeMergeCard(item: item))
            }
            return AnyView(UnknownToolResultCard(item: item, title: toolDisplayName(for: normalized ?? item.toolName)))
        case "context_builder":
            return AnyView(UnknownToolResultCard(item: item, title: toolDisplayName(for: normalized ?? item.toolName)))
        case "agent_explore":
            return AnyView(AgentExploreResultCard(item: item))
        case "agent_run":
            return AnyView(AgentRunResultCard(item: item))
        case "agent_manage":
            return AnyView(AgentManageResultCard(item: item))
        case "app_settings":
            return AnyView(AppSettingsResultCard(item: item))
        default:
            if NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: key) != nil {
                return AnyView(NativeToolResultCard(item: item, normalizedToolName: key))
            }
            let header = genericHeader(for: item, normalizedToolName: normalized, explicitTitle: nil)
            return AnyView(UnknownToolResultCard(item: item, title: header.title, sourceLabel: header.sourceLabel))
        }
    }

    /// Generic call/result header. An explicit specialized title (for example a web action) wins and
    /// carries no source label; otherwise external MCP tools split into action title + server label,
    /// parsed from the raw tool name before lossy dotted-suffix normalization.
    static func genericHeader(
        for item: AgentChatItem,
        normalizedToolName: String?,
        explicitTitle: String?
    ) -> ToolCardHeaderPresentation {
        if let explicitTitle {
            return ToolCardHeaderPresentation(title: explicitTitle, sourceLabel: nil)
        }
        return ToolCardHeaderPresentation.generic(
            rawToolName: item.toolName,
            normalizedToolName: normalizedToolName
        )
    }

    struct ToolCallPresentation: Equatable {
        let title: String
        let subtitle: String?
    }

    static func callPresentation(for item: AgentChatItem) -> ToolCallPresentation? {
        let normalized = normalizedToolCardName(item.toolName)?.lowercased()
        guard let webPresentation = AgentWebToolActionPresentation.classify(
            rawToolName: item.toolName,
            normalizedToolName: normalized,
            argsJSON: item.toolArgsJSON,
            resultJSON: nil
        ) else { return nil }
        return ToolCallPresentation(title: webPresentation.title, subtitle: webPresentation.subtitle)
    }

    static func callSubtitle(
        for toolName: String?,
        argsJSON: String?,
        resultJSON: String? = nil,
        toolIsError: Bool? = nil,
        agentControlContext: AgentControlToolCardContext? = nil
    ) -> String? {
        let normalized = normalizedToolCardName(toolName)?.lowercased() ?? toolName?.lowercased()
        // Some provider paths complete a call with only toolIsError populated. Represent that
        // status-only completion as an empty structured result so lifecycle labels cannot fall
        // back to live parent context after the call has settled.
        let presentationResultJSON = resultJSON ?? (toolIsError != nil ? "{}" : nil)
        return ToolCardSubtitleBuilder.subtitle(
            for: normalized,
            argsJSON: argsJSON,
            resultJSON: presentationResultJSON,
            agentControlContext: agentControlContext
        )
    }

    static func isWorktreeMergeOp(_ argsJSON: String?) -> Bool {
        guard let argsJSON,
              let data = argsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String
        else { return false }
        return isWorktreeMergeOpName(op)
    }

    static func isWorktreeMergeResult(_ resultJSON: String?) -> Bool {
        guard let reply = ToolJSON.decode(ToolResultDTOs.ManageWorktreeReplyDTO.self, from: resultJSON) else {
            return false
        }
        return reply.merge != nil || isWorktreeMergeOpName(reply.op)
    }

    private static func isWorktreeMergeOpName(_ op: String) -> Bool {
        ["preview", "apply", "status", "continue", "abort"].contains(op.lowercased())
    }
}

enum AgentControlWaitLabelBuilder {
    static func callLabel(
        detach: Bool?,
        timeout: Double?,
        context: AgentControlToolCardContext?
    ) -> String {
        if detach == true {
            return "detach"
        }
        if let timeout {
            return timeout <= 0 ? "poll" : "wait ≤\(formatSeconds(timeout))"
        }
        if let context, let family = context.authoritativeLocalParentFamily {
            let seconds = MCPTimeoutPolicy.agentLifecycleAutomaticWaitSeconds(
                for: family,
                promptCacheRetention: context.authoritativeLocalParentPromptCacheRetention
            )
            return "wait ≤\(formatSeconds(seconds))"
        }
        return "wait auto"
    }

    static func lifecycleLabel(
        resultJSON: String?,
        showBeforeCompletion: Bool,
        detach: Bool?,
        timeout: Double?,
        context: AgentControlToolCardContext?
    ) -> String? {
        if detach == true {
            return "detach"
        }
        if let resultJSON {
            guard let resultObject = ToolJSON.structuredResultObject(from: resultJSON) else { return nil }
            return resultLabel(from: resultObject)
        }
        guard showBeforeCompletion else { return nil }
        return callLabel(detach: detach, timeout: timeout, context: context)
    }

    static func resultLabel(from resultObject: [String: Any]) -> String? {
        guard let metadata = AgentMCPWaitPolicy.canonicalMetadata(from: resultObject) else { return nil }
        switch metadata.mode {
        case .automatic, .explicit:
            return "wait ≤\(formatSeconds(metadata.timeoutSeconds))"
        case .poll:
            return "poll"
        }
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded % 60 == 0, rounded >= 60 {
            let minutes = rounded / 60
            return minutes == 1 ? "1m" : "\(minutes)m"
        }
        return "\(rounded)s"
    }
}

private enum ToolCardSubtitleBuilder {
    static func subtitle(
        for toolName: String?,
        argsJSON: String?,
        resultJSON: String?,
        agentControlContext: AgentControlToolCardContext?
    ) -> String? {
        switch toolName {
        case "read":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.NativeReadArgs.self, from: argsJSON),
               let path = args.filePath ?? args.path,
               !path.isEmpty
            {
                return shortenPath(path)
            }
        case "read_file":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.ReadFileArgs.self, from: argsJSON),
               let path = args.path
            {
                return shortenPath(path)
            }
        case "apply_edits":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.ApplyEditsArgs.self, from: argsJSON),
               let path = args.path
            {
                return shortenPath(path)
            }
        case "apply_patch":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.ApplyPatchArgs.self, from: argsJSON) {
                if let path = args.path, !path.isEmpty {
                    return shortenPath(path)
                }
                if let paths = args.paths, !paths.isEmpty {
                    let first = shortenPath(paths[0])
                    if paths.count == 1 {
                        return first
                    }
                    return "\(first) (+\(paths.count - 1) more)"
                }
                if let changeCount = args.changeCount, changeCount > 0 {
                    return "\(changeCount) file\(changeCount == 1 ? "" : "s")"
                }
            }
        case "file_search":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.FileSearchArgs.self, from: argsJSON) {
                let patternPart = args.pattern.map { "\"\($0)\"" }
                let scopePart: String? = {
                    let scopePaths = args.scopePaths
                    guard !scopePaths.isEmpty else { return nil }
                    let first = shortenPath(scopePaths[0])
                    if scopePaths.count == 1 {
                        return "scope: \(first)"
                    }
                    return "scope: \(first) (+\(scopePaths.count - 1) more)"
                }()
                let parts = [patternPart, scopePart].compactMap(\.self)
                return parts.isEmpty ? nil : parts.joined(separator: " • ")
            }
        case "get_file_tree":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.FileTreeArgs.self, from: argsJSON) {
                return fileTreeSubtitle(args: args)
            }
        case "get_code_structure":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.CodeStructureArgs.self, from: argsJSON) {
                if args.scope == "selected" {
                    return "selected"
                }
                if let count = args.paths?.count, count > 0 {
                    return "\(count) path\(count == 1 ? "" : "s")"
                }
            }
        case "file_actions":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.FileActionsArgs.self, from: argsJSON),
               let path = args.path
            {
                if let newPath = args.newPath, !newPath.isEmpty {
                    return "\(shortenPath(path)) → \(shortenPath(newPath))"
                }
                return shortenPath(path)
            }
        case "manage_selection":
            if let op = ToolJSON.decodeArgs(ToolArgsDTOs.ManageSelectionArgs.self, from: argsJSON)?.op,
               !op.isEmpty
            {
                return op
            }
        case "workspace_context":
            if let include = ToolJSON.decodeArgs(ToolArgsDTOs.WorkspaceContextArgs.self, from: argsJSON)?.include,
               !include.isEmpty
            {
                return include.joined(separator: ", ")
            }
        case "prompt":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.PromptArgs.self, from: argsJSON) {
                if let opRaw = args.op?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !opRaw.isEmpty
                {
                    let op = opRaw.lowercased()
                    switch op {
                    case "export":
                        var parts = ["export"]
                        if let path = args.path, !path.isEmpty {
                            parts.append(shortenPath(path))
                        }
                        if let preset = args.copyPreset, !preset.isEmpty {
                            parts.append("preset: \(preset)")
                        }
                        return parts.joined(separator: " • ")
                    case "set", "append":
                        if let text = args.text, !text.isEmpty {
                            return "\(op) • \(text.count) chars"
                        }
                    case "select_preset":
                        if let preset = args.preset, !preset.isEmpty {
                            return "\(op) • \(preset)"
                        }
                    default:
                        break
                    }
                    return op
                }
                if let path = args.path, !path.isEmpty { return shortenPath(path) }
            }
        case "ask_oracle":
            return oracleCallSubtitle(
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                agentControlContext: agentControlContext
            )
        case "oracle_chat_log":
            if let chatID = stringArgument(from: argsJSON, keys: ["chat_id"]), !chatID.isEmpty {
                return chatID
            }
            if let limit = stringArgument(from: argsJSON, keys: ["limit"]), !limit.isEmpty {
                return "limit=\(limit)"
            }
        case "chats":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.ChatsArgs.self, from: argsJSON) {
                if let action = args.action, !action.isEmpty { return action }
                if let chatID = args.chatID, !chatID.isEmpty { return chatID }
            }
        case "bind_context":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.BindContextArgs.self, from: argsJSON) {
                let op = args.op?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let contextID = args.contextID, !contextID.isEmpty {
                    return op.isEmpty ? contextID : "\(op) • \(contextID)"
                }
                if let windowID = args.windowID {
                    return op.isEmpty ? "window \(windowID)" : "\(op) • window \(windowID)"
                }
                if !op.isEmpty { return op }
            }
        case "manage_workspaces":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.ManageWorkspacesArgs.self, from: argsJSON) {
                if let action = args.action, !action.isEmpty { return action }
                if let workspace = args.workspace, !workspace.isEmpty { return workspace }
            }
        case "git":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.GitArgs.self, from: argsJSON),
               let op = args.op,
               !op.isEmpty
            {
                return op
            }
        case "manage_worktree":
            if let op = stringArgument(from: argsJSON, keys: ["op"]), !op.isEmpty {
                var parts = [op.lowercased()]
                if ToolCardRouter.isWorktreeMergeOp(argsJSON) {
                    if let operationID = stringArgument(from: argsJSON, keys: ["operation_id"]),
                       !operationID.isEmpty
                    {
                        parts.append(operationID)
                    } else if let target = stringArgument(from: argsJSON, keys: ["target"]),
                              !target.isEmpty
                    {
                        parts.append(target)
                    }
                }
                return parts.joined(separator: " • ")
            }
        case "bash", "shell", "local_shell", "unified_exec", "exec_command", "run_shell_command":
            if let command = stringArgument(from: argsJSON, keys: ["command", "cmd", "input", "text", "value", "argv", "args"]),
               !command.isEmpty
            {
                return command
            }
        case "search":
            if let query = stringArgument(from: argsJSON, keys: AgentWebToolPayloadKeys.legacySearchQueryKeys),
               !query.isEmpty
            {
                return "\"\(query)\""
            }
        case "agent_explore":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.AgentExploreArgs.self, from: argsJSON) {
                let op = args.op?.lowercased() ?? "start"
                switch op {
                case "start":
                    var parts = [op]
                    if let count = args.messages?.count, count > 1 {
                        parts.append("\(count) probes")
                    }
                    if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                        resultJSON: resultJSON,
                        showBeforeCompletion: true,
                        detach: args.detach,
                        timeout: args.timeout,
                        context: agentControlContext
                    ) {
                        parts.append(waitLabel)
                    }
                    return parts.joined(separator: " • ")
                case "cancel":
                    var parts = [op]
                    if let sessionID = args.sessionID, !sessionID.isEmpty {
                        parts.append(sessionID)
                    }
                    if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                        resultJSON: resultJSON,
                        showBeforeCompletion: false,
                        detach: false,
                        timeout: nil,
                        context: agentControlContext
                    ) {
                        parts.append(waitLabel)
                    }
                    return parts.joined(separator: " • ")
                case "poll", "wait":
                    var parts = [op]
                    if let sessionID = args.sessionID, !sessionID.isEmpty {
                        parts.append(sessionID)
                    } else if let sessionIDs = args.sessionIDs, !sessionIDs.isEmpty {
                        parts.append("\(sessionIDs.count) sessions")
                    }
                    if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                        resultJSON: resultJSON,
                        showBeforeCompletion: op == "wait",
                        detach: false,
                        timeout: args.timeout,
                        context: agentControlContext
                    ) {
                        parts.append(waitLabel)
                    }
                    return parts.joined(separator: " • ")
                default:
                    return op
                }
            }
        case "agent_run":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.AgentRunArgs.self, from: argsJSON) {
                let op = args.op?.lowercased() ?? "start"
                let workflowLabel: String? = {
                    let name = args.workflowName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !name.isEmpty { return name }
                    let id = args.workflowID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return id.isEmpty ? nil : id
                }()
                switch op {
                case "start":
                    var parts: [String] = [op]
                    if let workflowLabel {
                        parts.append(workflowLabel)
                    }
                    if let agent = args.agent, !agent.isEmpty {
                        parts.append(agent)
                    }
                    if let model = args.model, !model.isEmpty {
                        parts.append(model)
                    }
                    if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                        resultJSON: resultJSON,
                        showBeforeCompletion: true,
                        detach: args.detach,
                        timeout: args.timeout,
                        context: agentControlContext
                    ) {
                        parts.append(waitLabel)
                    }
                    return parts.joined(separator: " • ")
                case "poll", "wait", "cancel":
                    var parts = [op]
                    if let sessionID = args.sessionID, !sessionID.isEmpty {
                        parts.append(sessionID)
                    }
                    if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                        resultJSON: resultJSON,
                        showBeforeCompletion: op == "wait",
                        detach: false,
                        timeout: args.timeout,
                        context: agentControlContext
                    ) {
                        parts.append(waitLabel)
                    }
                    return parts.joined(separator: " • ")
                case "steer":
                    var parts = [op]
                    if let sessionID = args.sessionID, !sessionID.isEmpty {
                        parts.append(sessionID)
                    }
                    if let workflowLabel {
                        parts.append(workflowLabel)
                    }
                    if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                        resultJSON: resultJSON,
                        showBeforeCompletion: args.wait == true || args.timeoutSeconds != nil,
                        detach: false,
                        timeout: args.timeoutSeconds ?? args.timeout,
                        context: agentControlContext
                    ) {
                        parts.append(waitLabel)
                    }
                    return parts.joined(separator: " • ")
                case "respond":
                    var parts = [op]
                    if let sessionID = args.sessionID, !sessionID.isEmpty {
                        parts.append(sessionID)
                    }
                    if let workflowLabel {
                        parts.append(workflowLabel)
                    }
                    if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                        resultJSON: resultJSON,
                        showBeforeCompletion: false,
                        detach: false,
                        timeout: nil,
                        context: agentControlContext
                    ) {
                        parts.append(waitLabel)
                    }
                    return parts.joined(separator: " • ")
                default:
                    return op
                }
            }
        case "app_settings":
            return AppSettingsCardPresentationBuilder.callSubtitle(argsJSON: argsJSON)
        case "agent_manage":
            if let args = ToolJSON.decodeArgs(ToolArgsDTOs.AgentManageArgs.self, from: argsJSON) {
                let op = args.op?.lowercased() ?? "list_sessions"
                switch op {
                case "list_agents", "list_workflows":
                    return op.replacingOccurrences(of: "_", with: " ")
                case "list_sessions":
                    var filters: [String] = []
                    if let name = args.name, !name.isEmpty { filters.append(name) }
                    if let state = args.state, !state.isEmpty { filters.append(state) }
                    let suffix = filters.isEmpty ? nil : filters.joined(separator: " • ")
                    return (["list sessions"] + [suffix].compactMap(\.self)).joined(separator: " • ")
                case "get_log":
                    var parts = ["get log"]
                    if let sessionID = args.sessionID, !sessionID.isEmpty {
                        parts.append(sessionID)
                    }
                    if let offset = args.offset {
                        parts.append("offset \(offset)")
                    }
                    return parts.joined(separator: " • ")
                case "create_session":
                    if let name = args.sessionName, !name.isEmpty { return "create • \(name)" }
                    if let agent = args.agent, !agent.isEmpty { return "create • \(agent)" }
                    return "create session"
                case "resume_session":
                    if let sessionID = args.sessionID, !sessionID.isEmpty {
                        return "resume • \(sessionID)"
                    }
                    return "resume session"
                case "stop_session":
                    if let sessionID = args.sessionID, !sessionID.isEmpty {
                        return "stop • \(sessionID)"
                    }
                    return "stop session"
                case "cleanup_sessions":
                    return "cleanup sessions"
                default:
                    return op
                }
            }
        default:
            break
        }
        return nil
    }

    private static func fileTreeSubtitle(args: ToolArgsDTOs.FileTreeArgs) -> String? {
        let treeType = args.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "files"
        if treeType == "roots" {
            return "roots"
        }
        var parts: [String] = [fileTreeModeLabel(args.mode)]
        if let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            parts.append(shortenPath(path))
        }
        if let maxDepth = args.maxDepth {
            parts.append("depth \(maxDepth)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func fileTreeModeLabel(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "full":
            "full tree"
        case "folders":
            "folders only"
        case "selected":
            "selected files"
        case "auto", nil, "":
            "auto tree"
        default:
            raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "auto tree"
        }
    }

    private static func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 2 {
            return path
        }
        return "..." + components.suffix(2).joined(separator: "/")
    }

    private static func stringArgument(from argsJSON: String?, keys: [String]) -> String? {
        guard let argsJSON else { return nil }
        let trimmed = argsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") {
            return unquotedString(trimmed) ?? trimmed
        }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return nil
        }
        if let extracted = extractStringValue(from: json, keys: keys) {
            return unquotedString(extracted) ?? extracted
        }
        return nil
    }

    private static func extractStringValue(from value: Any, keys: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let string = dictionary[key] as? String, !string.isEmpty {
                    return string
                }
                if let number = dictionary[key] as? NSNumber {
                    let text = number.stringValue
                    if !text.isEmpty { return text }
                }
                if let nested = dictionary[key],
                   let joined = joinedStringArrayValue(from: nested)
                {
                    return joined
                }
                if let nested = dictionary[key],
                   let nestedString = extractStringValue(from: nested, keys: keys)
                {
                    return nestedString
                }
            }
            for nested in dictionary.values {
                if let nestedString = extractStringValue(from: nested, keys: keys) {
                    return nestedString
                }
            }
        }
        if let array = value as? [Any] {
            if let joined = joinedStringArrayValue(from: array) {
                return joined
            }
            for element in array {
                if let nestedString = extractStringValue(from: element, keys: keys) {
                    return nestedString
                }
            }
        }
        if let number = value as? NSNumber {
            let text = number.stringValue
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func joinedStringArrayValue(from value: Any) -> String? {
        guard let array = value as? [Any] else { return nil }
        let parts = array.compactMap { element -> String? in
            if let string = element as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let number = element as? NSNumber {
                let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func oracleCallSubtitle(
        argsJSON: String?,
        resultJSON: String?,
        agentControlContext: AgentControlToolCardContext?
    ) -> String? {
        guard let args = ToolRawJSON.object(from: argsJSON) else { return nil }
        let op = ToolRawJSON.string(args, key: "op")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "send"
        let operationIDs = (args["operation_ids"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let timeout = oracleTimeoutSeconds(from: args)

        switch op {
        case "wait":
            var parts = ["wait"]
            if !operationIDs.isEmpty {
                parts.append(operationIDs.count == 1 ? operationIDs[0] : "\(operationIDs.count) operations")
            }
            if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                resultJSON: resultJSON,
                showBeforeCompletion: true,
                detach: false,
                timeout: timeout,
                context: agentControlContext
            ) {
                parts.append(waitLabel)
            }
            return parts.joined(separator: " • ")
        case "cancel":
            var parts = ["cancel"]
            if !operationIDs.isEmpty {
                parts.append(operationIDs.count == 1 ? operationIDs[0] : "\(operationIDs.count) operations")
            }
            return parts.joined(separator: " • ")
        default:
            var parts: [String] = []
            if let mode = nonEmptyOracleArgument(ToolRawJSON.string(args, key: "mode")) {
                parts.append(mode)
            }
            if let model = nonEmptyOracleArgument(ToolRawJSON.string(args, key: "model")) {
                parts.append(model)
            }
            if parts.isEmpty,
               let message = nonEmptyOracleArgument(ToolRawJSON.string(args, key: "message"))
            {
                parts.append("\"\(message)\"")
            }
            if let waitLabel = AgentControlWaitLabelBuilder.lifecycleLabel(
                resultJSON: resultJSON,
                showBeforeCompletion: true,
                detach: false,
                timeout: timeout,
                context: agentControlContext
            ) {
                parts.append(waitLabel)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        }
    }

    private static func oracleTimeoutSeconds(from args: [String: Any]) -> Double? {
        if let number = args["timeout_seconds"] as? NSNumber {
            return number.doubleValue
        }
        if let string = args["timeout_seconds"] as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func nonEmptyOracleArgument(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func unquotedString(_ raw: String) -> String? {
        guard raw.count >= 2 else { return nil }
        guard let first = raw.first, let last = raw.last, first == last, first == "\"" || first == "'" else {
            return nil
        }
        let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }
}

func oracleToolCallPopoverUserInfo(
    item: AgentChatItem,
    openContext: AgentOracleOpenContext?
) -> [AnyHashable: Any]? {
    guard let toolName = normalizedToolCardName(item.toolName)?.lowercased(),
          toolName == "chat_send" || toolName == "ask_oracle" || toolName == "oracle_send"
    else { return nil }

    if let exact = AgentOracleToolRouting.operationPopoverUserInfo(
        openContext: openContext,
        chatID: AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: item.toolResultJSON)
    ) {
        return exact
    }
    guard item.toolResultJSON == nil, item.toolIsError == nil else { return nil }

    if let exact = AgentOracleToolRouting.operationPopoverUserInfo(
        openContext: openContext,
        chatID: AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: item.toolArgsJSON)
    ) {
        return exact
    }
    guard AgentOracleAuthoritativeChatIDPolicy.allowsLatestFallback(fromSerializedJSON: item.toolArgsJSON) else {
        return nil
    }
    return AgentOracleToolRouting.latestPopoverUserInfo(openContext: openContext)
}

enum ToolCallCardStateResolver {
    /// Display status for a generic tool-call card.
    ///
    /// A call with no attached result evidence, or with evidence that does not classify, is
    /// `.neutral`: render blocks carry no per-call liveness, so the card must not claim the call
    /// is executing. The session-level run indicator shows run activity, and separate result cards
    /// own their outcomes. Explicitly classified success, warning, failure, or running is kept.
    static func status(for item: AgentChatItem) -> ToolCardStatus {
        guard hasAttachedResultEvidence(item) else { return .neutral }
        return ToolResultStatusResolver.resolve(
            toolIsError: item.toolIsError,
            raw: item.toolResultJSON,
            fallback: .neutral
        )
    }

    /// Run-scoped cancel eligibility, intentionally identical to the pre-Step-4d6 set (the old
    /// `.running` fallback). This is not a claim that this call is executing; the cancel action
    /// targets the run's active tools.
    static func allowsRunScopedCancel(for item: AgentChatItem) -> Bool {
        guard hasAttachedResultEvidence(item) else { return true }
        return ToolResultStatusResolver.resolve(
            toolIsError: item.toolIsError,
            raw: item.toolResultJSON,
            fallback: .running
        ) == .running
    }

    static func showsRunScopedCancel(
        for item: AgentChatItem,
        showRunScopedToolCancel: Bool,
        hasCancelAction: Bool
    ) -> Bool {
        showRunScopedToolCancel
            && hasCancelAction
            && allowsRunScopedCancel(for: item)
            && MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization(item.toolName)
    }

    private static func hasAttachedResultEvidence(_ item: AgentChatItem) -> Bool {
        item.toolResultJSON != nil || item.toolIsError != nil
    }
}

struct ToolCallCard: View {
    let item: AgentChatItem
    let title: String
    let sourceLabel: String?
    let subtitle: String?
    let oracleOpenContext: AgentOracleOpenContext?
    let showRunScopedToolCancel: Bool
    let cancelActiveToolsAction: (() -> Void)?

    init(
        item: AgentChatItem,
        title: String,
        sourceLabel: String? = nil,
        subtitle: String?,
        oracleOpenContext: AgentOracleOpenContext?,
        showRunScopedToolCancel: Bool = false,
        cancelActiveToolsAction: (() -> Void)? = nil
    ) {
        self.item = item
        self.title = title
        self.sourceLabel = sourceLabel
        self.subtitle = subtitle
        self.oracleOpenContext = oracleOpenContext
        self.showRunScopedToolCancel = showRunScopedToolCancel
        self.cancelActiveToolsAction = cancelActiveToolsAction
    }

    private var status: ToolCardStatus {
        ToolCallCardStateResolver.status(for: item)
    }

    /// Whether this card should show the run-scoped cancel button in the header.
    /// Eligibility is decoupled from the display status (see `ToolCallCardStateResolver`).
    private var showsCancelButton: Bool {
        ToolCallCardStateResolver.showsRunScopedCancel(
            for: item,
            showRunScopedToolCancel: showRunScopedToolCancel,
            hasCancelAction: cancelActiveToolsAction != nil
        )
    }

    private static let cancelActiveToolsLabel = "Cancel active tools for this run"

    private var onTap: (() -> Void)? {
        guard let userInfo = oracleToolCallPopoverUserInfo(
            item: item,
            openContext: oracleOpenContext
        ) else { return nil }
        return {
            NotificationCenter.default.post(name: .showAgentOraclePopover, object: nil, userInfo: userInfo)
        }
    }

    var body: some View {
        StaticToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: title,
            sourceLabel: sourceLabel,
            subtitle: subtitle,
            status: status,
            timestamp: item.timestamp,
            showsTimestamp: !showsCancelButton,
            headerTrailingView: showsCancelButton
                ? AnyView(
                    ToolCardCancelButton(action: cancelActiveToolsAction!)
                        .hoverTooltip(Self.cancelActiveToolsLabel)
                        .accessibilityLabel(Self.cancelActiveToolsLabel)
                )
                : nil,
            onTap: onTap
        ) {
            // Tool call cards don't show args by default
            EmptyView()
        }
    }
}
