import Foundation

/// Stable internal namespace for window-scoped MCP tool names.
package enum MCPWindowToolName {
    package static let manageSelection = "manage_selection"

    package static let fileActions = "file_actions"
    package static let getCodeStructure = "get_code_structure"
    package static let getFileTree = "get_file_tree"
    package static let readFile = "read_file"
    package static let search = "file_search"

    package static let workspaceContext = "workspace_context"
    package static let prompt = "prompt"

    package static let applyEdits = "apply_edits"

    package static let oracleUtils = "oracle_utils"
    package static let askOracle = "ask_oracle"
    package static let oracleSend = "oracle_send"
    package static let oracleChatLog = "oracle_chat_log"

    package static let git = "git"
    /// Fixed `git` diff publication (`op=diff`, `artifacts=true`) for Oracle review. It stays
    /// available in Agent Mode runs that hide `git` because the run has a native shell.
    package static let gitReviewSnapshot = "git_review_snapshot"
    package static let manageWorktree = "manage_worktree"
    package static let contextBuilder = "context_builder"
    package static let askUser = "ask_user"

    package static let remotePairing = "remote_pairing"

    package static let agentExplore = "agent_explore"
    package static let agentRun = "agent_run"
    package static let agentManage = "agent_manage"

    package static let history = "history"

    package static let workspaceSteer = "workspace_steer"

    /// RepoPrompt-owned script executor over the four exploration tools (plan §6 D3). Advertised
    /// and executable only under an installed run policy with `.directTools` eligibility.
    package static let codeMode = "code_mode"

    package static let shareThoughts = "share_thoughts"
    package static let setStatus = "set_status"
    package static let waitForNextInstruction = "wait_for_next_user_instruction"
}
