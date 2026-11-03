import AppKit
import Foundation
import RepoPromptPlatform

/// Claude-specific integration configuration helpers.
///
/// This namespace owns Claude Desktop/Claude Code MCP installation details,
/// Claude Code MCP environment overrides, and native tool exclusion lists.
package enum ClaudeCodeIntegrationConfiguration {
    static let processEnvironmentOverridePairs: [(String, String)] = [
        ("MCP_TIMEOUT", "30000"),
        ("MCP_TOOL_TIMEOUT", "10800000"),
        ("MAX_MCP_OUTPUT_TOKENS", "25000")
    ]

    static var processEnvironmentOverrides: [String: String] {
        Dictionary(uniqueKeysWithValues: processEnvironmentOverridePairs)
    }

    static var mcpAddEnvironmentFlagArguments: [String] {
        processEnvironmentOverridePairs.flatMap { ["--env", "\($0.0)=\($0.1)"] }
    }

    /// Result of a Claude Code MCP installation attempt.
    package struct InstallResult {
        package let success: Bool
        /// User-facing error message when `success` is false.
        package let errorMessage: String?
        /// Whether the server was already configured (re-installed with updated config).
        let wasAlreadyPresent: Bool
    }

    /// Aggregate result for installing Claude Code in multiple workspaces.
    package struct BatchInstallResult {
        let successCount: Int
        let totalCount: Int
        /// The error message from the last failure, if any.
        package let lastErrorMessage: String?

        package var success: Bool {
            successCount > 0
        }
    }

    /// Claude Code tools to disallow during Agent Mode runs.
    /// Keep native Read, Bash, and Skill enabled in Agent Mode so Claude can
    /// still discover and invoke workspace/user skills from `.claude/skills`.
    private static let agentDisallowedTools: [String] = [
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "Task",
        "Monitor",
        "SlashCommand",
        "NotebookEdit",
        "TodoWrite",
        "EnterPlanMode",
        "ExitPlanMode",
        "EnterWorktree",
        "ExitWorktree",
        "CronCreate",
        "CronDelete",
        "CronList",
        "RemoteTrigger",
        "AskUserQuestion",
        "ScheduleWakeup",
        "PushNotification"
    ]

    /// Claude Code tools to disallow during Knowledge sessions.
    /// Native Read remains available for images and PDFs; RepoPrompt owns text reads.
    /// WebSearch/WebFetch are intentionally absent so provider web preferences remain authoritative.
    /// Native delegation (`Task` and its successor `Agent`) is blocked: Knowledge roots delegate
    /// only through RepoPrompt `agent_run` research workers.
    private static let knowledgeDisallowedTools: [String] = [
        "Bash",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "Task",
        "Agent",
        "SlashCommand",
        "BashOutput",
        "KillShell",
        "Monitor",
        "NotebookEdit",
        "TodoWrite",
        "EnterPlanMode",
        "ExitPlanMode",
        "EnterWorktree",
        "ExitWorktree",
        "CronCreate",
        "CronDelete",
        "CronList",
        "RemoteTrigger",
        "Skill",
        "TaskOutput",
        "TaskStop",
        "AskUserQuestion",
        "ScheduleWakeup",
        "PushNotification"
    ]

    /// Claude Code tools to disallow during discovery runs.
    /// All native file/shell tools blocked — MCP tools drive exploration.
    /// WebSearch + WebFetch are kept enabled so the agent can look up docs/context.
    private static let discoverDisallowedTools: [String] = [
        "Bash",
        "Read",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "Task",
        "SlashCommand",
        "BashOutput",
        "KillShell",
        "Monitor",
        "NotebookEdit",
        "TodoWrite",
        "EnterPlanMode",
        "ExitPlanMode",
        "EnterWorktree",
        "ExitWorktree",
        "CronCreate",
        "CronDelete",
        "CronList",
        "RemoteTrigger",
        "Skill",
        "TaskOutput",
        "TaskStop",
        "AskUserQuestion",
        "ScheduleWakeup",
        "PushNotification"
    ]

    /// Claude Code tools to disallow during interactive terminal sessions.
    /// More permissive, but still blocks file/discovery/edit tools plus Monitor
    /// because Monitor can outlive the turn and send wake-ups later.
    private static let terminalDisallowedTools: [String] = [
        "Read",
        "Write",
        "Edit",
        "Glob",
        "Grep",
        "Monitor",
        "EnterWorktree",
        "ScheduleWakeup",
        "PushNotification"
    ]

    /// Returns disallowed tools for Claude Code in the given context.
    /// Pass `allowNativeBashTool: true` to keep Bash/BashOutput/KillShell enabled.
    static func disallowedTools(
        for context: AgentCLIToolContext,
        allowNativeBashTool: Bool = false,
        sessionProfile: AgentSessionProfile = .standard
    ) -> [String] {
        let base: [String] = if sessionProfile == .knowledge, context == .agentRun || context == .promptOnly {
            knowledgeDisallowedTools
        } else {
            switch context {
            case .agentRun:
                agentDisallowedTools
            case .discoverRun:
                discoverDisallowedTools
            case .promptOnly:
                agentDisallowedTools
            case .terminal:
                terminalDisallowedTools
            }
        }
        guard allowNativeBashTool, sessionProfile == .standard else { return base }
        let bashToolNames: Set = ["Bash", "BashOutput", "KillShell"]
        return base.filter { !bashToolNames.contains($0) }
    }

    /// Attempts to merge RepoPrompt MCP entry into Claude Desktop.
    /// Returns `true` on success. Never creates the "Claude" directory.
    static func installInClaudeDesktop(
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folderURL = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
        let fileURL = folderURL.appendingPathComponent("claude_desktop_config.json")

        // Abort if Claude folder does not exist
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return false }

        do {
            // Load existing JSON (if any)
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: fileURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                root = existing
            }

            var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
            if mcpServers[configuration.name] != nil {
                return true
            }

            mcpServers[configuration.name] = configuration.settingsJSONObject
            root["mcpServers"] = mcpServers

            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            print("ClaudeCodeIntegrationConfiguration – Claude Desktop install failed: \(error)")
            return false
        }
    }

    /// Installs the RepoPrompt MCP server in Claude Code (the CLI tool) for a single workspace.
    ///
    /// Uses `CLIProcessRunner` so we get proper PATH resolution and can set
    /// a working directory for project-scoped installs.
    ///
    /// Command executed:
    ///   `claude mcp add --env KEY=value ... RepoPrompt -- <serverCommand>`
    ///
    /// The installed RepoPrompt MCP entry receives RepoPrompt's preferred Claude/MCP env values via
    /// `--env` flags during `claude mcp add`.
    ///
    /// - Parameter workspacePath: Optional path to the workspace/project folder.
    ///   When provided, installs as a project-scoped MCP server (runs in that directory).
    ///   When nil, installs globally.
    /// - Returns: `true` when the CLI exits with code 0, `false` otherwise.
    @discardableResult
    static func installInClaudeCode(
        workspacePath: String? = nil,
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt,
        defaults: UserDefaults = .standard
    ) async -> InstallResult {
        let commandSelection: CLICommandSelection
        do {
            commandSelection = try CLIExecutableOverrideStore.effectiveCommand(
                for: CLILaunchProfiles.claudeCode,
                defaults: defaults
            )
        } catch {
            return InstallResult(
                success: false,
                errorMessage: error.localizedDescription,
                wasAlreadyPresent: false
            )
        }

        let config = CLIProcessConfiguration(
            command: commandSelection.command,
            validationCommandName: CLILaunchProfiles.claudeCode.commandName,
            commandSelection: commandSelection,
            workingDirectory: workspacePath,
            enableDebugLogging: false
        )
        let runner = CLIProcessRunner(config: config)

        // Arguments: mcp add RepoPrompt --env KEY=value ... -- <serverCommand>
        // Note: name must come before --env flags for claude CLI argument parsing.
        let addArgs = ["mcp", "add", configuration.name] + mcpAddEnvironmentFlagArguments + ["--", configuration.command]
        // R6: these short administrative config commands are not managed runtimes (no registration),
        // but their copied environment never carries an inherited runtime marker.
        let removedKeys: Set<String> = [ProcessLauncher.runtimeMarkerEnvironmentKey]

        do {
            let result = try await runner.run(
                args: addArgs,
                stdin: nil,
                outputMode: .none,
                timeout: 30,
                additionalRemovedKeys: removedKeys
            )

            if result.status == 0 {
                return InstallResult(success: true, errorMessage: nil, wasAlreadyPresent: false)
            }

            let stderr = (String(data: result.stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // If the server already exists, remove and re-add to update config
            if stderr.localizedCaseInsensitiveContains("already exists") {
                print("ClaudeCodeIntegrationConfiguration – RepoPrompt already exists in Claude Code, updating config...")
                let removeResult = try await runner.run(
                    args: ["mcp", "remove", configuration.name],
                    stdin: nil,
                    outputMode: .none,
                    timeout: 15,
                    additionalRemovedKeys: removedKeys
                )
                if removeResult.status == 0 {
                    let readdResult = try await runner.run(
                        args: addArgs,
                        stdin: nil,
                        outputMode: .none,
                        timeout: 30,
                        additionalRemovedKeys: removedKeys
                    )
                    if readdResult.status == 0 {
                        return InstallResult(success: true, errorMessage: nil, wasAlreadyPresent: true)
                    }
                    let readdStderr = (String(data: readdResult.stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    print("ClaudeCodeIntegrationConfiguration – Claude Code re-add failed (code \(readdResult.status)):\n\(readdStderr)")
                    return InstallResult(success: false, errorMessage: friendlyClaudeCodeError(readdStderr), wasAlreadyPresent: true)
                }
            }

            print(
                "ClaudeCodeIntegrationConfiguration – Claude Code install failed " +
                    "(code \(result.status)):\n\(stderr)"
            )
            return InstallResult(success: false, errorMessage: friendlyClaudeCodeError(stderr), wasAlreadyPresent: false)
        } catch {
            print("ClaudeCodeIntegrationConfiguration – Claude Code install error: \(error)")
            let message = if let runnerError = error as? CLIProcessRunnerError {
                switch runnerError {
                case .explicitCommandNotLaunchable:
                    runnerError.localizedDescription
                case .commandNotFound:
                    "Claude Code CLI not found. Install it from claude.ai/download"
                default:
                    "Install error: \(runnerError.localizedDescription)"
                }
            } else if let overrideError = error as? CLIExecutableOverrideError {
                overrideError.localizedDescription
            } else {
                "Install error: \(error.localizedDescription)"
            }
            return InstallResult(success: false, errorMessage: message, wasAlreadyPresent: false)
        }
    }

    /// Installs the RepoPrompt MCP server in Claude Code for multiple workspaces.
    ///
    /// Runs `claude mcp add` in each workspace directory sequentially.
    ///
    /// - Parameter workspacePaths: Array of workspace folder paths. If empty, installs globally.
    /// - Returns: Aggregate result with success count and last error message (if any).
    @discardableResult
    static func installInClaudeCode(
        workspacePaths: [String],
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) async -> BatchInstallResult {
        if workspacePaths.isEmpty {
            // No workspaces open - install globally
            let result = await installInClaudeCode(workspacePath: nil, configuration: configuration)
            return BatchInstallResult(
                successCount: result.success ? 1 : 0,
                totalCount: 1,
                lastErrorMessage: result.errorMessage
            )
        }

        var successCount = 0
        var lastError: String?
        for path in workspacePaths {
            let result = await installInClaudeCode(workspacePath: path, configuration: configuration)
            if result.success {
                successCount += 1
            } else {
                lastError = result.errorMessage
            }
        }
        return BatchInstallResult(
            successCount: successCount,
            totalCount: workspacePaths.count,
            lastErrorMessage: lastError
        )
    }

    /// Maps raw stderr from `claude mcp add` to a user-friendly message.
    private static func friendlyClaudeCodeError(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("not found") || lower.contains("not installed") {
            return "Claude Code CLI not found. Install it from claude.ai/download"
        }
        if lower.contains("permission denied") {
            return "Permission denied. Check Claude Code CLI permissions."
        }
        if !stderr.isEmpty {
            // Return the first line of stderr as a concise message
            return stderr.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? stderr
        }
        return "Claude Code install failed"
    }
}
