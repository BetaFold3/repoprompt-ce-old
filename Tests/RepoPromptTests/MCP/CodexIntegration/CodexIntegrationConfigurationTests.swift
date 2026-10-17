import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptShared
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class CodexIntegrationConfigurationTests: XCTestCase {
    private let repoPromptName = RepoPromptMCPServerConfiguration.defaultServerName
    private let repoPromptHeader = "[mcp_servers.RepoPromptCE]"

    private var serverCommand: String {
        RepoPromptMCPServerConfiguration.repoPrompt.command
    }

    private func mutateCodexPersistentConfigForInstall(_ content: String) -> CodexIntegrationConfiguration.PersistentMCPConfigMutationResult {
        CodexIntegrationConfiguration.mutatedPersistentMCPConfigContent(
            from: content,
            defaultEnabledIfMissing: true,
            forceEnabled: true
        )
    }

    private func allToolOutputLimitLines(in content: String) -> [String] {
        content.components(separatedBy: "\n")
            .filter { $0.contains("tool_output_token_limit") }
    }

    private func topLevelToolOutputLimitLines(in content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        let firstHeaderIndex = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("[") && (trimmed.hasSuffix("]") || trimmed.contains("] #"))
        } ?? lines.count
        return lines[..<firstHeaderIndex].filter { $0.contains("tool_output_token_limit") }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    func testDiscoveryEnsureWritesBareRepoPromptCEServerHeader() throws {
        var lines: [String] = []

        let result = CodexIntegrationConfiguration.ensureRepoPromptServer(
            in: &lines,
            defaultEnabledIfMissing: false,
            forceEnabled: nil
        )

        XCTAssertTrue(result.changed)
        XCTAssertFalse(result.wasPresent)

        let content = lines.joined(separator: "\n")
        XCTAssertTrue(content.contains(repoPromptHeader))
        XCTAssertTrue(content.contains("command = \"\(serverCommand)\""))
        XCTAssertTrue(content.contains("args = []"))
        XCTAssertTrue(content.contains("tool_timeout_sec = 10000"))
        XCTAssertTrue(content.contains("supports_parallel_tool_calls = true"))
        XCTAssertTrue(content.contains("enabled = false"))
        XCTAssertTrue(
            content.contains(
                "command = \"\(serverCommand)\"\nargs = []\ntool_timeout_sec = 10000\nsupports_parallel_tool_calls = true\nenabled = false"
            )
        )

        let entry = try XCTUnwrap(CodexIntegrationConfiguration.mcpServerEntries(from: content).first)
        XCTAssertEqual(entry.normalizedName, "RepoPromptCE")
        XCTAssertEqual(entry.cliPathComponent, "RepoPromptCE")
    }

    func testRepoPromptCEServerEntryProducesBareCodexOverrideKeysForExactName() throws {
        let content = """
        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        enabled = false

        [mcp_servers.repopromptce]
        command = "/tmp/lowercase-rp"
        args = []

        [mcp_servers.OtherServer]
        command = "/tmp/other"
        args = []
        """

        let entries = CodexIntegrationConfiguration.mcpServerEntries(from: content)
        XCTAssertEqual(entries.map(\.normalizedName), ["RepoPromptCE", "repopromptce", "OtherServer"])
        let repoPromptEntry = try XCTUnwrap(entries.first { $0.normalizedName == "RepoPromptCE" })
        XCTAssertEqual(repoPromptEntry.cliPathComponent, "RepoPromptCE")

        let policy = CodexOverrides.MCPPolicy.enableOnlyRepoPrompt(
            repoPromptNormalizedName: repoPromptName,
            exceptBroken: Set<String>()
        )
        let cliArgs = CodexOverrides.cliMCPServerArgs(entries: entries, policy: policy)
        XCTAssertTrue(cliArgs.contains("mcp_servers.RepoPromptCE.enabled=true"))
        XCTAssertTrue(cliArgs.contains("mcp_servers.repopromptce.enabled=false"))
        XCTAssertTrue(cliArgs.contains("mcp_servers.OtherServer.enabled=false"))

        let appServerMap = CodexOverrides.appServerMCPServerMap(entries: entries, policy: policy)
        XCTAssertEqual(appServerMap["mcp_servers.RepoPromptCE.enabled"] as? Bool, true)
        XCTAssertEqual(appServerMap["mcp_servers.repopromptce.enabled"] as? Bool, false)
        XCTAssertEqual(appServerMap["mcp_servers.OtherServer.enabled"] as? Bool, false)
    }

    func testMCPServerEntryParserHandlesQuotedBareAndNestedHeaders() {
        let content = """
        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"

        [mcp_servers."server.with.dot"]
        command = "/server"

        [mcp_servers."server.with.dot".env]
        TOKEN = "abc"

        [mcp_servers.'literal server'] # managed
        command = "/literal"

        [mcp_servers.RepoPromptCE.env]
        FOO = "bar"
        """

        let entries = CodexIntegrationConfiguration.mcpServerEntries(from: content)

        XCTAssertEqual(entries.map(\.normalizedName), ["RepoPromptCE", "server.with.dot", "literal server"])
        XCTAssertEqual(entries.map(\.cliPathComponent), ["RepoPromptCE", "\"server.with.dot\"", "\"literal server\""])
    }

    func testRepoPromptNestedSubsectionDoesNotCountAsServerBlock() {
        let content = """
        [mcp_servers.RepoPromptCE.env]
        FOO = "bar"
        """

        let entries = CodexIntegrationConfiguration.mcpServerEntries(from: content)

        XCTAssertFalse(entries.contains { $0.normalizedName == "RepoPromptCE" })
        XCTAssertTrue(entries.isEmpty)
    }

    func testPersistentMutationPreservesUnderscoredGlobalLimitAndStripsServerLevelLimit() {
        let input = """
        tool_output_token_limit = 25_000 # user configured

        [mcp_servers."RepoPromptCE"] # managed
        command = "/old/path"
        args = []
        "tool_output_token_limit"\t=\t25000
        enabled = false
        """

        let result = mutateCodexPersistentConfigForInstall(input)

        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.wasRepoPromptServerPresent)
        XCTAssertTrue(result.content.contains("[mcp_servers.\"RepoPromptCE\"] # managed"))
        XCTAssertTrue(result.content.contains("command = \"\(serverCommand)\""))
        XCTAssertEqual(allToolOutputLimitLines(in: result.content), ["tool_output_token_limit = 25_000 # user configured"])
        XCTAssertFalse(result.content.contains("\"tool_output_token_limit\"\t=\t25000"))
        XCTAssertFalse(result.content.contains("tool_output_token_limit = 25000"))
    }

    func testPersistentMutationRepairsDuplicateValidGlobalsPreservingFirst() {
        let input = """
        "tool_output_token_limit" = 25_000
        tool_output_token_limit = 25000

        [profiles.default]
        model = "gpt-5"
        """

        let result = mutateCodexPersistentConfigForInstall(input)

        XCTAssertEqual(topLevelToolOutputLimitLines(in: result.content), ["\"tool_output_token_limit\" = 25_000"])
        XCTAssertFalse(result.content.contains("\ntool_output_token_limit = 25000"))
    }

    func testPersistentMutationAddsGlobalLimitWhenExistingNumericIsQuoted() {
        let input = """
        tool_output_token_limit = "25000"

        [profiles.default]
        model = "gpt-5"
        """

        let result = mutateCodexPersistentConfigForInstall(input)

        XCTAssertEqual(topLevelToolOutputLimitLines(in: result.content), [
            "tool_output_token_limit = \"25000\"",
            "tool_output_token_limit = 25000"
        ])
    }

    func testPersistentMutationIsIdempotentAfterRepair() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers."RepoPromptCE"]
        command = "/old/path"
        args = []
        tool_output_token_limit = 25000
        enabled = false
        """

        let first = mutateCodexPersistentConfigForInstall(input)
        let second = mutateCodexPersistentConfigForInstall(first.content)

        XCTAssertTrue(first.changed)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.content, first.content)
        XCTAssertEqual(occurrences(of: "[mcp_servers.\"RepoPromptCE\"]", in: second.content), 1)
        XCTAssertEqual(occurrences(of: "tool_timeout_sec = 10000", in: second.content), 1)
        XCTAssertEqual(occurrences(of: "supports_parallel_tool_calls = true", in: second.content), 1)
    }

    func testV5PolicyConstantsPreserveLongActiveTimeoutAndEnableParallelCalls() {
        XCTAssertEqual(CodexIntegrationConfiguration.toolTimeoutDefaultsKey, "CodexToolTimeoutMigratedV5")
        XCTAssertEqual(
            CodexIntegrationConfiguration.desiredToolTimeoutSeconds,
            MCPTimeoutPolicy.codexServerActiveTimeoutSeconds
        )
        XCTAssertTrue(CodexIntegrationConfiguration.desiredSupportsParallelToolCalls)
    }

    func testV5MigrationRestoresLongTimeoutAndParallelPolicyTogether() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        tool_timeout_sec = 600
        supports_parallel_tool_calls = true
        enabled = true
        """

        let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

        XCTAssertTrue(result.foundTarget)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.content.contains("tool_timeout_sec = 10000"))
        XCTAssertTrue(result.content.contains("supports_parallel_tool_calls = true"))
        XCTAssertFalse(result.content.contains("tool_timeout_sec = 600"))
        XCTAssertFalse(result.content.contains("supports_parallel_tool_calls = false"))

        let second = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: result.content)
        XCTAssertTrue(second.foundTarget)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.content, result.content)

        let disabledInput = """
        tool_output_token_limit = 25_000

        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        tool_timeout_sec = 10000
        supports_parallel_tool_calls = false
        enabled = true
        """
        let enabledResult = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: disabledInput)
        XCTAssertTrue(enabledResult.foundTarget)
        XCTAssertTrue(enabledResult.changed)
        XCTAssertEqual(occurrences(of: "supports_parallel_tool_calls", in: enabledResult.content), 1)
        XCTAssertTrue(enabledResult.content.contains("supports_parallel_tool_calls = true"))
        XCTAssertFalse(enabledResult.content.contains("supports_parallel_tool_calls = false"))
    }

    func testV5MigrationCollapsesDuplicatePolicyAssignments() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        tool_timeout_sec = 10000 # keep first equivalent
        tool_timeout_sec = 600
        supports_parallel_tool_calls = true # keep first equivalent
        supports_parallel_tool_calls = false
        """

        let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

        XCTAssertTrue(result.foundTarget)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(occurrences(of: "tool_timeout_sec", in: result.content), 1)
        XCTAssertEqual(occurrences(of: "supports_parallel_tool_calls", in: result.content), 1)
        XCTAssertTrue(result.content.contains("tool_timeout_sec = 10000 # keep first equivalent"))
        XCTAssertTrue(result.content.contains("supports_parallel_tool_calls = true # keep first equivalent"))
    }

    func testV5MigrationPreservesLaterEquivalentDuplicateAssignments() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        tool_timeout_sec = 600
        tool_timeout_sec = 10000 # preserve compliant timeout
        supports_parallel_tool_calls = false
        supports_parallel_tool_calls = true # preserve compliant parallel policy
        """

        let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

        XCTAssertTrue(result.foundTarget)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(occurrences(of: "tool_timeout_sec", in: result.content), 1)
        XCTAssertEqual(occurrences(of: "supports_parallel_tool_calls", in: result.content), 1)
        XCTAssertTrue(result.content.contains("tool_timeout_sec = 10000 # preserve compliant timeout"))
        XCTAssertTrue(result.content.contains("supports_parallel_tool_calls = true # preserve compliant parallel policy"))
    }

    func testV5MigrationLeavesOtherServerPolicyUntouched() {
        let otherServerBlock = """
        [mcp_servers.OtherServer]
        command = "/tmp/other"
        args = []
        tool_timeout_sec = 10000
        supports_parallel_tool_calls = true
        """
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        tool_timeout_sec = 600
        supports_parallel_tool_calls = true

        \(otherServerBlock)
        """

        let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

        XCTAssertTrue(result.foundTarget)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.content.contains(otherServerBlock))
    }

    func testToolTimeoutMutationHandlesCommandCommentsAndUnderscoredTimeout() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers."RepoPromptCE"] # managed
        command = "\(serverCommand)" # stable helper
        args = []
        tool_timeout_sec = 10000 # already equivalent
        supports_parallel_tool_calls = true # serialized by V5
        """

        let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

        XCTAssertTrue(result.foundTarget)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.content.contains("tool_timeout_sec = 10000 # already equivalent"))
        XCTAssertTrue(result.content.contains("supports_parallel_tool_calls = true # serialized by V5"))
    }

    func testToolTimeoutMutationAcceptsIntegerRadixAndSignVariants() {
        let variants = [
            "+10_000",
            "0x2710",
            "0o23420",
            "0b10011100010000"
        ]

        for value in variants {
            let input = """
            tool_output_token_limit = 25_000

            [mcp_servers.RepoPromptCE]
            command = "\(serverCommand)"
            args = []
            tool_timeout_sec = \(value)
            supports_parallel_tool_calls = true
            """

            let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

            XCTAssertTrue(result.foundTarget, value)
            XCTAssertFalse(result.changed, value)
            XCTAssertTrue(result.content.contains("tool_timeout_sec = \(value)"), value)
        }
    }

    func testModelReasoningSummaryOverridesEmitExpectedAppServerValues() {
        var policy = CodexOverrides.ToolPolicy(
            toolOutputTokenLimit: CodexIntegrationConfiguration.desiredToolOutputTokenLimit,
            shellToolEnabled: false,
            webSearchRequestEnabled: false,
            viewImageToolEnabled: false,
            includeApplyPatchTool: false
        )

        policy.modelReasoningSummary = CodexOverrides.ReasoningSummary.none
        XCTAssertEqual(
            CodexOverrides.appServerConfigMap(toolPolicy: policy)["model_reasoning_summary"] as? String,
            "none"
        )

        policy.modelReasoningSummary = .auto
        XCTAssertEqual(
            CodexOverrides.appServerConfigMap(toolPolicy: policy)["model_reasoning_summary"] as? String,
            "auto"
        )

        policy.modelReasoningSummary = nil
        XCTAssertNil(CodexOverrides.appServerConfigMap(toolPolicy: policy)["model_reasoning_summary"])

        let omittedDefault = CodexNativeSessionController.defaultAppServerConfigOverrides(
            forceExperimentalSteering: false
        )
        XCTAssertNil(omittedDefault["model_reasoning_summary"])

        let explicitOff = CodexNativeSessionController.defaultAppServerConfigOverrides(
            forceExperimentalSteering: false,
            reasoningSummariesEnabled: false
        )
        XCTAssertEqual(explicitOff["model_reasoning_summary"] as? String, "none")

        let optIn = CodexNativeSessionController.defaultAppServerConfigOverrides(
            forceExperimentalSteering: false,
            reasoningSummariesEnabled: true
        )
        XCTAssertEqual(optIn["model_reasoning_summary"] as? String, "auto")
    }

    /// Plan §6 D3 `direct + code_mode`: the namespace override is inert unless a direct server
    /// name is supplied, then CLI and app-server builders emit the same one-element list.
    func testDirectOnlyToolNamespaceOverrideIsInertByDefaultAndHasCLIAppServerParity() {
        let policy = CodexNativeSessionController.defaultAppServerToolPolicy(
            shellToolEnabled: true,
            webSearchRequestEnabled: false,
            forceExperimentalSteering: false
        )
        let key = CodexOverrides.directOnlyToolNamespacesKey
        XCTAssertEqual(key, "features.code_mode.direct_only_tool_namespaces")
        for featurePolicy in [CodexOverrides.FeaturePolicy.defaultDisabled, .enabledForComputerUse] {
            let baselineCLI = CodexOverrides.cliConfigArgs(toolPolicy: policy, featurePolicy: featurePolicy)
            let baselineMap = CodexOverrides.appServerConfigMap(toolPolicy: policy, featurePolicy: featurePolicy)
            XCTAssertFalse(baselineCLI.contains { $0.contains("direct_only_tool_namespaces") })
            XCTAssertNil(baselineMap[key])
            // Empty names fail closed and leave output byte-identical.
            XCTAssertEqual(
                CodexOverrides.cliConfigArgs(toolPolicy: policy, featurePolicy: featurePolicy, repoPromptDirectServerName: ""),
                baselineCLI
            )
            XCTAssertNil(
                CodexOverrides.appServerConfigMap(
                    toolPolicy: policy, featurePolicy: featurePolicy, repoPromptDirectServerName: ""
                )[key]
            )

            // Hyphens become underscores; case is preserved, never lowercased.
            let serverName = "RepoPrompt-Direct-Read"
            let cli = CodexOverrides.cliConfigArgs(
                toolPolicy: policy, featurePolicy: featurePolicy, repoPromptDirectServerName: serverName
            )
            XCTAssertEqual(Array(cli.dropLast(2)), baselineCLI, "Only the namespace pair is appended")
            XCTAssertEqual(Array(cli.suffix(2)), ["-c", "\(key)=[\"mcp__RepoPrompt_Direct_Read\"]"])
            var map = CodexOverrides.appServerConfigMap(
                toolPolicy: policy, featurePolicy: featurePolicy, repoPromptDirectServerName: serverName
            )
            XCTAssertEqual(map.removeValue(forKey: key) as? [String], ["mcp__RepoPrompt_Direct_Read"])
            XCTAssertEqual(NSDictionary(dictionary: map), NSDictionary(dictionary: baselineMap))
            // Feature policy (computer use, tool search) is unchanged by the namespace key.
            XCTAssertEqual(map["features.computer_use"] as? Bool, featurePolicy.computerUseEnabled)
        }
        XCTAssertEqual(CodexOverrides.tomlBasicString("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"")
        XCTAssertNil(CodexOverrides.directOnlyToolNamespace(forServerName: nil))

        // The production default path stays inert; an explicit name threads through unchanged.
        XCTAssertNil(CodexNativeSessionController.defaultAppServerConfigOverrides(forceExperimentalSteering: false)[key])
        XCTAssertEqual(
            CodexNativeSessionController.defaultAppServerConfigOverrides(
                forceExperimentalSteering: false,
                repoPromptDirectServerName: "repoprompt-direct"
            )[key] as? [String],
            ["mcp__repoprompt_direct"]
        )
    }

    func testRuntimePoliciesDoNotForceParallelToolCallsOff() {
        let policy = CodexOverrides.ToolPolicy(
            toolOutputTokenLimit: CodexIntegrationConfiguration.desiredToolOutputTokenLimit,
            shellToolEnabled: false,
            webSearchRequestEnabled: false,
            viewImageToolEnabled: false,
            includeApplyPatchTool: false
        )
        let cliOverrides = CodexOverrides.cliConfigArgs(toolPolicy: policy)
        XCTAssertFalse(cliOverrides.contains { $0.contains("features.parallel_tool_calls") })

        let appServerOverrides = CodexOverrides.appServerConfigMap(toolPolicy: policy)
        XCTAssertNil(appServerOverrides["features.parallel_tool_calls"])

        let nativeOverrides = CodexOverrides.appServerConfigMap(
            toolPolicy: CodexNativeSessionController.defaultAppServerToolPolicy(
                shellToolEnabled: false,
                webSearchRequestEnabled: false,
                forceExperimentalSteering: false
            )
        )
        XCTAssertNil(nativeOverrides["features.parallel_tool_calls"])

        let interactiveOverrides = CodexOverrides.appServerConfigMap(
            toolPolicy: CodexCLIProvider.interactiveToolPolicy()
        )
        XCTAssertNil(interactiveOverrides["features.parallel_tool_calls"])

        let headlessOverrides = CodexIntegrationConfiguration.configOverrides(for: .agentRun)
        XCTAssertFalse(headlessOverrides.contains { $0.contains("features.parallel_tool_calls") })

        let execArguments = CodexExecAgentProvider.buildCodexExecArguments(
            selectedModelString: nil,
            serverEntries: [],
            brokenServers: []
        ).args
        XCTAssertFalse(execArguments.contains { $0.contains("features.parallel_tool_calls") })
    }

    func testToolTimeoutMutationRejectsQuotedNumericTimeout() {
        let input = """
        tool_output_token_limit = 25_000

        [mcp_servers.RepoPromptCE]
        command = "\(serverCommand)"
        args = []
        tool_timeout_sec = "10000"
        supports_parallel_tool_calls = "false"
        """

        let result = CodexIntegrationConfiguration.mutatedToolTimeoutConfigContent(from: input)

        XCTAssertTrue(result.foundTarget)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.content.contains("tool_timeout_sec = 10000"))
        XCTAssertTrue(result.content.contains("supports_parallel_tool_calls = true"))
        XCTAssertFalse(result.content.contains("tool_timeout_sec = \"10000\""))
        XCTAssertFalse(result.content.contains("supports_parallel_tool_calls = \"false\""))
    }
}
