@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AgentRunningStatusPresentationTests: XCTestCase {
    func testCanonicalRawToolsUseExistingDisplayNames() {
        let cases = [
            ("mcp__RepoPromptCE__agent_run", "Agent Run"),
            ("agent_run", "Agent Run"),
            ("mcp__RepoPromptCE__read_file", "Read File"),
            ("mcp__RepoPromptCE__ask_user", "Question")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(AgentRunningStatusPresentation.displayText(for: raw), expected, raw)
        }
    }

    func testOrdinaryStatusProseAndNilFallbackRemainUnchanged() {
        let cases: [(String?, String)] = [
            (nil, "Thinking…"),
            ("Thinking…", "Thinking…"),
            ("Reviewing the implementation", "Reviewing the implementation"),
            ("Running mcp__RepoPromptCE__agent_run", "Running mcp__RepoPromptCE__agent_run"),
            ("  Thinking deeply… \n", "  Thinking deeply… \n"),
            ("", "")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(AgentRunningStatusPresentation.displayText(for: raw), expected)
        }
    }

    func testUnsupportedPrefixesUnknownSuffixesAndLookalikesStayUnrecognized() {
        let names = [
            "mcp_RepoPromptCE_agent_run",
            "mcp__RepoPromptCE__unknown_tool",
            "mcp__RepoPromptCEExtra__agent_run",
            "mcp__OtherRepoPromptCE__agent_run",
            "mcp_RepoPromptCEExtra_agent_run",
            "mcp__RepoPromptCE__agent_runner"
        ]
        for raw in names {
            XCTAssertNil(MCPIntegrationHelper.canonicalRepoPromptToolName(raw), raw)
            XCTAssertFalse(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(raw), raw)
            XCTAssertEqual(AgentRunningStatusPresentation.displayText(for: raw), raw, raw)
        }
    }

    func testRecognizedExternalMCPToolsUseCompactActionAndServerLabel() {
        let cases = [
            ("mcp__busycal__delete_event", "Delete Event · BusyCal"),
            ("functions.mcp__github__list_prs", "List PRs · GitHub"),
            ("mcp__docs.rs__search_crates", "Search Crates · Docs.rs")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(AgentRunningStatusPresentation.displayText(for: raw), expected, raw)
        }
        for raw in ["Running mcp__busycal__delete_event", "ns.mcp__busycal__delete_event", "mcp__busycal__", "mcp__RepoPromptCE__unknown_tool"] {
            XCTAssertEqual(AgentRunningStatusPresentation.displayText(for: raw), raw, raw)
        }
    }

    func testExplicitServerPrefixesStripInFirstMatchOrderAndMatchLegacyResolution() {
        let pinned: [(raw: String, normalized: String, canonical: String?, explicit: Bool)] = [
            ("mcp__RepoPromptCE__read_file", "read_file", "read_file", true),
            ("MCP_REPOPROMPTCE__Read_File", "read_file", "read_file", true),
            ("repopromptce__agent_run", "agent_run", "agent_run", true),
            ("RepoPromptCE_git", "git", "git", true),
            // `<server>__` precedes `<server>_`: one underscore of three is consumed by the first match.
            ("repopromptce___git", "_git", nil, false),
            ("  functions.functions.mcp__RepoPromptCE__ask_user_question \n", "ask_user_question", "ask_user", true),
            ("mcp__RepoPromptCE__unknown_tool", "unknown_tool", nil, false),
            ("read_file", "read_file", "read_file", false),
            ("   ", "", nil, false)
        ]
        for entry in pinned {
            XCTAssertEqual(MCPIntegrationHelper.normalizedRepoPromptToolName(entry.raw), entry.normalized, entry.raw)
            XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptToolName(entry.raw), entry.canonical, entry.raw)
            XCTAssertEqual(MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(entry.raw), entry.explicit, entry.raw)
        }
        XCTAssertNil(MCPIntegrationHelper.canonicalRepoPromptToolName(nil))

        let corpus = pinned.map(\.raw) + [
            "mcp__repopromptce___read_file", "mcp_repopromptce_git", "RepoPromptCE__", "RepoPromptCE_",
            "mcp__RepoPromptCE__", "functions.", "mcp__RepoPromptCE__READ_F\u{0130}LE", "\u{0130}repopromptce_git",
            "mcp__RepoPrompt__read_file", "mcp__RepoPromptCE__mcp__RepoPromptCE__git", "\tRepoPromptCE__Ask_User\n"
        ]
        for raw in corpus {
            let legacy = legacyResolution(raw)
            XCTAssertEqual(
                MCPIntegrationHelper.normalizedRepoPromptToolName(raw),
                legacy?.normalized ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                String(reflecting: raw)
            )
            XCTAssertEqual(MCPIntegrationHelper.canonicalRepoPromptToolName(raw), legacy?.canonical, String(reflecting: raw))
            XCTAssertEqual(
                MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(raw),
                legacy?.explicit ?? false,
                String(reflecting: raw)
            )
        }
    }

    /// Verbatim copy of the pre-change resolution, including per-call prefix construction.
    private func legacyResolution(_ raw: String) -> (normalized: String, canonical: String?, explicit: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var name = trimmed.lowercased()
        while name.hasPrefix("functions.") {
            name = String(name.dropFirst("functions.".count))
        }
        let server = MCPIntegrationHelper.repoPromptMCPServerName.lowercased()
        var explicit = false
        for prefix in ["mcp__\(server)__", "mcp_\(server)__", "\(server)__", "\(server)_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            explicit = true
            break
        }
        let canonical: String? = if MCPIntegrationHelper.repoPromptToolNames.contains(name) {
            name == "ask_user_question" ? "ask_user" : name
        } else {
            nil
        }
        return (name, canonical, explicit && canonical != nil)
    }
}
