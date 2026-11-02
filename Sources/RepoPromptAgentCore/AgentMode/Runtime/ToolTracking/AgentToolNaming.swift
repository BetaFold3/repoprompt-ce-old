import Foundation

// MARK: - Tool Name Normalization

package func normalizedToolCardName(_ name: String?) -> String? {
    guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    let canonical = MCPIntegrationHelper.canonicalRepoPromptToolName(raw) ?? raw
    // External tools can be namespaced (for example, "functions.bash").
    // Route by suffix so tool cards stay consistent.
    if let webCanonical = AgentWebToolCanonicalNames.canonicalToolCardName(canonical.lowercased()) {
        return webCanonical
    }
    let suffix = canonical.split(separator: ".").last.map(String.init) ?? canonical
    let lowered = suffix.lowercased()
    if lowered == "local_shell" || lowered == "shell" || lowered == "unified_exec" || lowered == "exec_command" || lowered == "run_shell_command" {
        return "bash"
    }
    if let webCanonical = AgentWebToolCanonicalNames.canonicalToolCardName(lowered) {
        return webCanonical
    }
    if lowered == "filechange" || lowered == "file_change" {
        return "apply_patch"
    }
    if lowered == "edit" || lowered == "edit file" {
        return "edit"
    }
    if lowered == "request_user_input" || lowered == "requestuserinput" {
        return "request_user_input"
    }
    return suffix
}

// MARK: - Tool Icon Helpers

/// Get appropriate SF Symbol icon for a tool
package func toolIcon(for toolName: String?) -> String {
    // Presentation-only: recognize external MCP tools from the raw name before lossy normalization.
    if ExternalMCPToolPresentation(rawToolName: toolName) != nil {
        return ExternalMCPToolPresentation.iconName
    }
    let normalized = normalizedToolCardName(toolName) ?? toolName
    switch normalized {
    case "ask_user_question", "ask_user", "AskUserQuestion", "request_user_input", "requestUserInput":
        return "questionmark.circle"
    case "read", "Read", "read_file", "mcp__RepoPrompt__read_file":
        return "doc.text"
    case "bash", "shell", "local_shell", "unified_exec", "exec_command", "run_shell_command":
        return "terminal"
    case "search", "web_read":
        return "globe"
    case "apply_edits", "mcp__RepoPrompt__apply_edits":
        return "pencil"
    case "apply_patch", "edit":
        return "pencil"
    case "file_actions", "mcp__RepoPrompt__file_actions":
        return "doc.badge.plus"
    case "file_search", "mcp__RepoPrompt__file_search":
        return "magnifyingglass.circle"
    case "get_file_tree", "mcp__RepoPrompt__get_file_tree":
        return "folder"
    case "get_code_structure", "mcp__RepoPrompt__get_code_structure":
        return "list.bullet.indent"
    case "manage_selection", "mcp__RepoPrompt__manage_selection":
        return "checkmark.circle"
    case "workspace_context", "mcp__RepoPrompt__workspace_context":
        return "square.stack.3d.up"
    case "ask_oracle", "mcp__RepoPrompt__ask_oracle":
        return "brain"
    case "oracle_send", "mcp__RepoPrompt__oracle_send":
        return "bubble.left.and.bubble.right"
    case "oracle_chat_log", "mcp__RepoPrompt__oracle_chat_log":
        return "clock.arrow.circlepath"
    case "chat_send", "mcp__RepoPrompt__chat_send":
        return "bubble.left.and.bubble.right"
    case "context_builder", "mcp__RepoPrompt__context_builder":
        return "sparkles"
    case "git", "mcp__RepoPrompt__git":
        return "arrow.triangle.branch"
    case "manage_worktree", "mcp__RepoPrompt__manage_worktree":
        return "rectangle.split.3x1"
    case "prompt", "mcp__RepoPrompt__prompt":
        return "text.quote"
    case "chats", "mcp__RepoPrompt__chats":
        return "bubble.left.and.bubble.right"
    case "list_models", "mcp__RepoPrompt__list_models":
        return "cpu"
    case "bind_context", "mcp__RepoPrompt__bind_context":
        return "scope"
    case "manage_workspaces", "mcp__RepoPrompt__manage_workspaces":
        return "rectangle.3.group"
    case "agent_explore", "mcp__RepoPrompt__agent_explore":
        return "magnifyingglass.circle"
    case "agent_run", "mcp__RepoPrompt__agent_run":
        return "play.circle"
    case "agent_manage", "mcp__RepoPrompt__agent_manage":
        return "tray.full"
    case "app_settings", "mcp__RepoPrompt__app_settings":
        return "gearshape.2"
    default:
        return "gearshape.fill"
    }
}

/// Get human-readable display name for a tool.
///
/// External MCP tools return a one-string compact label with the action first and the server
/// retained (for example `Delete Event · BusyCal`), parsed from the raw name.
package func toolDisplayName(for toolName: String?) -> String {
    if let external = ExternalMCPToolPresentation(rawToolName: toolName) {
        return external.compactLabel
    }
    return toolDisplayNameIgnoringExternalMCP(for: toolName)
}

/// Display name without external MCP recognition. Use when the input may already be a lossy
/// normalized name, so an arbitrary dotted name whose suffix looks like `mcp__…` is not
/// presented as an external MCP tool.
func toolDisplayNameIgnoringExternalMCP(for toolName: String?) -> String {
    guard let nameRaw = toolName else { return "Tool" }
    let name = normalizedToolCardName(nameRaw) ?? nameRaw

    // Strip MCP prefix if present
    let stripped = name.replacingOccurrences(of: "mcp__RepoPrompt__", with: "")

    switch stripped {
    case "ask_user_question", "ask_user", "AskUserQuestion", "request_user_input", "requestUserInput":
        return "Question"
    case "bash", "shell", "local_shell", "unified_exec", "exec_command", "run_shell_command":
        return "Bash"
    case "search":
        return "Web Search"
    case "web_read":
        return "Read Web Page"
    case "read", "Read":
        return "Read"
    case "read_file":
        return "Read File"
    case "apply_edits":
        return "Edit"
    case "apply_patch":
        return "Patch"
    case "edit":
        return "Edit File"
    case "file_actions":
        return "File Action"
    case "file_search":
        return "Search"
    case "get_file_tree":
        return "File Tree"
    case "get_code_structure":
        return "Code Structure"
    case "manage_selection":
        return "Selection"
    case "workspace_context":
        return "Context"
    case "ask_oracle":
        return "Oracle"
    case "oracle_send":
        return "Oracle"
    case "oracle_chat_log":
        return "Oracle Log"
    case "chat_send":
        return "Chat"
    case "context_builder":
        return "Context Builder"
    case "git":
        return "Git"
    case "manage_worktree":
        return "Worktrees"
    case "prompt":
        return "Prompt"
    case "chats":
        return "Chats"
    case "list_models":
        return "Models"
    case "bind_context":
        return "Bind Context"
    case "manage_workspaces":
        return "Workspaces"
    case "agent_explore":
        return "Agent Explore"
    case "agent_run":
        return "Agent Run"
    case "agent_manage":
        return "Agent Manage"
    case "app_settings":
        return "App Settings"
    default:
        // Convert snake_case to Title Case
        return stripped
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
