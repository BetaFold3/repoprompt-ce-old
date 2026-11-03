import Darwin
import Foundation
import RepoPromptMCPCore
import RepoPromptPlatform

/// Update this when releasing new versions
let CLI_VERSION = "1.0.29"

// The private Restart safely relaunch mode is dispatched exclusively, before any MCP code runs.
// Without a reserved argument the ordinary MCP invocation is unchanged; a reserved argument in any
// other form fails without falling back to MCP.
switch ProcessRelaunchInvocation.classify(Array(CommandLine.arguments.dropFirst())) {
case .ordinary:
    await runRepoPromptMCP(version: CLI_VERSION)
case .relaunchV1:
    await exit(ProcessRelaunchHelperMain.run())
case let .invalid(reason):
    FileHandle.standardError.write(Data("repoprompt-mcp: \(reason)\n".utf8))
    exit(64)
}
