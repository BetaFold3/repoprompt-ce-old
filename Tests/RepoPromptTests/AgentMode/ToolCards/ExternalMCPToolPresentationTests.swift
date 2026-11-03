@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

final class ExternalMCPToolPresentationTests: XCTestCase {
    private let externalIcon = "puzzlepiece.extension"

    func testArbitraryServersSplitIntoTitleCaseActionAndReadableServer() throws {
        let cases: [(raw: String, action: String, server: String)] = [
            ("mcp__busycal__delete_event", "Delete Event", "BusyCal"),
            ("mcp__github__create_pull_request", "Create Pull Request", "GitHub"),
            ("mcp__linear__get_issue_by_id", "Get Issue By ID", "Linear"),
            ("mcp__google-calendar__list_events", "List Events", "Google Calendar"),
            ("mcp__google_drive__export_pdf", "Export PDF", "Google Drive"),
            ("mcp__context7__resolve_library_id", "Resolve Library ID", "Context7"),
            ("mcp__postgres__run_sql_query", "Run SQL Query", "Postgres"),
            ("mcp__acme_ai__call_api", "Call API", "Acme AI"),
            ("mcp__my-ui-kit__render_html", "Render HTML", "My UI Kit"),
            ("mcp__web__fetch_https_url", "Fetch HTTPS URL", "Web")
        ]
        for entry in cases {
            let presentation = try XCTUnwrap(ExternalMCPToolPresentation(rawToolName: entry.raw), entry.raw)
            XCTAssertEqual(presentation.actionTitle, entry.action, entry.raw)
            XCTAssertEqual(presentation.serverLabel, entry.server, entry.raw)
            XCTAssertEqual(presentation.compactLabel, "\(entry.action) · \(entry.server)", entry.raw)
        }
        let busyCal = try XCTUnwrap(ExternalMCPToolPresentation(rawToolName: "mcp__busycal__delete_event"))
        XCTAssertEqual(busyCal.serverName, "busycal", "Raw segments stay as authored")
        XCTAssertEqual(busyCal.toolName, "delete_event")
    }

    func testKnownAcronymsMatchCaseInsensitivelyAndUnknownMixedCaseIsPreserved() {
        let cases: [(raw: String, action: String)] = [
            ("mcp__srv__list_prs", "List PRs"),
            ("mcp__srv__get_pr", "Get PR"),
            ("mcp__srv__list_apis", "List APIs"),
            ("mcp__srv__get_ids", "Get IDs"),
            ("mcp__srv__fetch_urls", "Fetch URLs"),
            ("mcp__srv__get_uuids_json", "Get UUIDs JSON"),
            ("mcp__srv__sdk_cli_csv", "SDK CLI CSV"),
            ("mcp__srv__mcp_status", "MCP Status"),
            ("mcp__srv__http_ui_ai", "HTTP UI AI"),
            ("mcp__srv__new_uuid", "New UUID"),
            // Known acronyms are corrected regardless of authored case.
            ("mcp__srv__Get_Pr", "Get PR"),
            ("mcp__srv__call_Api", "Call API"),
            ("mcp__srv__Parse_Json", "Parse JSON"),
            ("mcp__srv__list_Ids", "List IDs"),
            ("mcp__srv__get_URL", "Get URL"),
            ("mcp__srv__LIST_PRS", "LIST PRs"),
            ("mcp__srv__sync_Github_repo", "Sync GitHub Repo"),
            // Unknown mixed or upper case is preserved; no camelCase or brand guessing.
            ("mcp__srv__searchPages", "searchPages"),
            ("mcp__srv__open_iCloud_item", "Open iCloud Item"),
            ("mcp__srv__Get_Item", "Get Item")
        ]
        for entry in cases {
            XCTAssertEqual(ExternalMCPToolPresentation(rawToolName: entry.raw)?.actionTitle, entry.action, entry.raw)
        }
    }

    func testBrandAliasesAndAuthoredServerCasing() {
        let cases: [(raw: String, server: String)] = [
            ("mcp__busycal__x", "BusyCal"),
            ("mcp__github__x", "GitHub"),
            ("mcp__BusyCal__x", "BusyCal"),
            ("mcp__GitHub__x", "GitHub"),
            ("mcp__Github__x", "GitHub"),
            ("mcp__GITHUB__x", "GitHub"),
            ("mcp__Busycal__x", "BusyCal"),
            ("mcp__BUSYCAL__x", "BusyCal"),
            ("mcp__Notion__x", "Notion"),
            ("mcp__iCloud__x", "iCloud"),
            ("mcp__SLACK__x", "SLACK"),
            ("mcp__acmecorp__x", "Acmecorp"),
            ("mcp__github_enterprise__x", "GitHub Enterprise")
        ]
        for entry in cases {
            XCTAssertEqual(ExternalMCPToolPresentation(rawToolName: entry.raw)?.serverLabel, entry.server, entry.raw)
        }
    }

    func testDotsWrappingAndSeparatorRunsUseConservativeGrammar() throws {
        // Dots stay inside server words (domains) and split tool words (namespaces).
        let docs = try XCTUnwrap(ExternalMCPToolPresentation(rawToolName: "mcp__docs.rs__search_crates"))
        XCTAssertEqual(docs.serverLabel, "Docs.rs")
        XCTAssertEqual(docs.actionTitle, "Search Crates")
        XCTAssertEqual(ExternalMCPToolPresentation(rawToolName: "mcp__srv__items.get")?.actionTitle, "Items Get")
        // The first `__` after the prefix ends the server; later `__` runs split tool words.
        XCTAssertEqual(ExternalMCPToolPresentation(rawToolName: "mcp__srv__ns__do_thing")?.actionTitle, "Ns Do Thing")
        XCTAssertEqual(ExternalMCPToolPresentation(rawToolName: "mcp__srv__ns__do_thing")?.serverLabel, "Srv")
        // Prefix is case-insensitive; repeated `functions.` wrapping and surrounding whitespace are accepted.
        XCTAssertEqual(ExternalMCPToolPresentation(rawToolName: "MCP__BusyCal__Delete_Event")?.compactLabel, "Delete Event · BusyCal")
        XCTAssertEqual(
            ExternalMCPToolPresentation(rawToolName: "  functions.mcp__busycal__delete_event \n")?.compactLabel,
            "Delete Event · BusyCal"
        )
        XCTAssertEqual(
            ExternalMCPToolPresentation(rawToolName: "functions.functions.mcp__github__get_me")?.compactLabel,
            "Get Me · GitHub"
        )

        let unrecognized: [String?] = [
            nil, "", "   ", "mcp__", "mcp____tool", "mcp__server", "mcp__server__",
            "mcp___server__tool", "mcp__server___tool", "mcp__server__tool_", "mcp__server_____",
            "mcp__-__tool", "mcp__srv__-", "mcp__srv__..",
            "mcp_server__tool", "mcpserver__tool", "mcp__busy cal__delete", "mcp__busycal__delete event",
            "mcp__srv__a/b", "mcp__srv__a:b",
            // Arbitrary dotted wrappers are not MCP.
            "ns.mcp__busycal__delete_event", "tools.mcp__github__search", "functions.ns.mcp__x__y",
            "delete_event", "functions.bash", "bash", "read_file", "Using tool: mcp__busycal__delete_event"
        ]
        for raw in unrecognized {
            XCTAssertNil(ExternalMCPToolPresentation(rawToolName: raw), String(reflecting: raw))
        }
    }

    func testRepoPromptNamesAndLookalikesKeepExistingPresentation() {
        let repoPromptNames = [
            "mcp__RepoPromptCE__read_file", "mcp__RepoPrompt__read_file", "mcp__repoprompt__foo_bar",
            "mcp__RepoPromptCE__unknown_tool", "mcp__OtherRepoPromptCE__agent_run",
            "mcp__RepoPromptCEExtra__agent_run", "functions.mcp__RepoPromptCE__git", "agent_run"
        ]
        for raw in repoPromptNames {
            XCTAssertNil(ExternalMCPToolPresentation(rawToolName: raw), raw)
            XCTAssertEqual(toolDisplayName(for: raw), toolDisplayNameIgnoringExternalMCP(for: raw), raw)
            XCTAssertNotEqual(toolIcon(for: raw), externalIcon, raw)
            XCTAssertNil(ToolCardHeaderPresentation.generic(rawToolName: raw, normalizedToolName: normalizedToolCardName(raw)).sourceLabel, raw)
        }
        XCTAssertEqual(toolDisplayName(for: "mcp__RepoPromptCE__read_file"), "Read File")
        XCTAssertEqual(toolIcon(for: "mcp__RepoPromptCE__read_file"), "doc.text")
        XCTAssertEqual(toolDisplayName(for: "mcp__RepoPrompt__read_file"), "Read File")
        XCTAssertEqual(toolIcon(for: "mcp__RepoPrompt__read_file"), "doc.text")
        XCTAssertEqual(toolDisplayName(for: "functions.mcp__RepoPromptCE__git"), "Git")
        XCTAssertEqual(toolIcon(for: "mcp__RepoPromptCE__git"), "arrow.triangle.branch")
        XCTAssertEqual(toolIcon(for: "mcp__RepoPromptCE__unknown_tool"), "gearshape.fill")
    }

    func testNonMCPNamesKeepExistingDisplayNamesAndIcons() {
        let cases: [(raw: String?, name: String, icon: String)] = [
            (nil, "Tool", "gearshape.fill"),
            ("delete_event", "Delete Event", "gearshape.fill"),
            ("bash", "Bash", "terminal"),
            ("functions.bash", "Bash", "terminal"),
            ("exec_command", "Bash", "terminal"),
            ("read_file", "Read File", "doc.text"),
            ("file_search", "Search", "magnifyingglass.circle"),
            ("web_search", "Web Search", "globe"),
            ("edit", "Edit File", "pencil"),
            ("ns.mcp__busycal__delete_event", toolDisplayNameIgnoringExternalMCP(for: "ns.mcp__busycal__delete_event"), "gearshape.fill")
        ]
        for entry in cases {
            let label = String(reflecting: entry.raw)
            XCTAssertEqual(toolDisplayName(for: entry.raw), entry.name, label)
            XCTAssertEqual(toolIcon(for: entry.raw), entry.icon, label)
            XCTAssertFalse(toolDisplayName(for: entry.raw).contains("·"), label)
        }
    }

    func testExternalNamesCollidingWithBuiltInsKeepRoutingKeysAndShowServer() {
        let cases: [(raw: String, label: String)] = [
            ("mcp__github__search", "Search · GitHub"),
            ("mcp__fs__read", "Read · Fs"),
            ("mcp__fs__read_file", "Read File · Fs"),
            ("mcp__shell__bash", "Bash · Shell"),
            ("mcp__x__exec_command", "Exec Command · X"),
            ("mcp__editor__edit", "Edit · Editor"),
            ("mcp__fs__apply_patch", "Apply Patch · Fs"),
            ("mcp__web__web_search", "Web Search · Web"),
            ("mcp__fetch__web_fetch", "Web Fetch · Fetch")
        ]
        for entry in cases {
            let normalized = normalizedToolCardName(entry.raw)
            XCTAssertEqual(normalized, entry.raw, "Routing key is unchanged: \(entry.raw)")
            let key = normalized?.lowercased() ?? ""
            XCTAssertFalse(ToolCardRouter.knownResultTools.contains(key), entry.raw)
            XCTAssertEqual(ClusterToolCategory.classification(forNormalizedToolName: key).family, .other, entry.raw)
            XCTAssertEqual(ToolCardAccentResolver.family(for: entry.raw), .other, entry.raw)
            XCTAssertEqual(toolIcon(for: entry.raw), externalIcon, entry.raw)
            XCTAssertEqual(toolDisplayName(for: entry.raw), entry.label, entry.raw)

            let call = AgentChatItem.toolCall(name: entry.raw, argsJSON: #"{"query":"q","path":"a.swift","command":"ls"}"#)
            XCTAssertNil(ToolCardRouter.callPresentation(for: call), "No native web presentation: \(entry.raw)")
            XCTAssertFalse(
                ToolCallCardStateResolver.showsRunScopedCancel(for: call, showRunScopedToolCancel: true, hasCancelAction: true),
                "Run-scoped cancel stays RepoPrompt-only: \(entry.raw)"
            )
            let header = ToolCardRouter.genericHeader(for: call, normalizedToolName: normalized, explicitTitle: nil)
            XCTAssertEqual("\(header.title) · \(header.sourceLabel ?? "")", entry.label, entry.raw)
        }
        let repoPromptCall = AgentChatItem.toolCall(name: "mcp__RepoPromptCE__read_file", argsJSON: "{}")
        XCTAssertTrue(
            ToolCallCardStateResolver.showsRunScopedCancel(for: repoPromptCall, showRunScopedToolCancel: true, hasCancelAction: true)
        )
    }

    func testGenericHeaderSplitsExternalTitleAndSourceUsingRawName() {
        let busyCal = ToolCardHeaderPresentation.generic(
            rawToolName: "mcp__busycal__delete_event",
            normalizedToolName: normalizedToolCardName("mcp__busycal__delete_event")
        )
        XCTAssertEqual(busyCal, ToolCardHeaderPresentation(title: "Delete Event", sourceLabel: "BusyCal"))

        // Dotted servers are parsed from the raw name; the routing key keeps its existing lossy suffix.
        let dottedRaw = "mcp__docs.rs__search_crates"
        XCTAssertEqual(normalizedToolCardName(dottedRaw), "rs__search_crates")
        XCTAssertEqual(
            ToolCardHeaderPresentation.generic(rawToolName: dottedRaw, normalizedToolName: normalizedToolCardName(dottedRaw)),
            ToolCardHeaderPresentation(title: "Search Crates", sourceLabel: "Docs.rs")
        )

        // A wrapper whose normalized suffix looks like MCP is not presented as MCP.
        let wrappedRaw = "ns.mcp__busycal__delete_event"
        let wrapped = ToolCardHeaderPresentation.generic(rawToolName: wrappedRaw, normalizedToolName: normalizedToolCardName(wrappedRaw))
        XCTAssertNil(wrapped.sourceLabel)
        XCTAssertEqual(wrapped.title, toolDisplayNameIgnoringExternalMCP(for: normalizedToolCardName(wrappedRaw)))
        XCTAssertFalse(wrapped.title.contains("·"))

        XCTAssertEqual(
            ToolCardHeaderPresentation.generic(rawToolName: "read_file", normalizedToolName: "read_file"),
            ToolCardHeaderPresentation(title: "Read File", sourceLabel: nil)
        )
        XCTAssertEqual(
            ToolCardHeaderPresentation.generic(rawToolName: nil, normalizedToolName: nil),
            ToolCardHeaderPresentation(title: "Tool", sourceLabel: nil)
        )

        // An explicit specialized title wins without a source label.
        let call = AgentChatItem.toolCall(name: "mcp__busycal__delete_event", argsJSON: nil)
        XCTAssertEqual(
            ToolCardRouter.genericHeader(for: call, normalizedToolName: normalizedToolCardName(call.toolName), explicitTitle: "Web Search"),
            ToolCardHeaderPresentation(title: "Web Search", sourceLabel: nil)
        )
        let result = AgentChatItem.toolResult(name: "mcp__github__list_prs", resultJSON: #"{"ok":true}"#)
        XCTAssertEqual(
            ToolCardRouter.genericHeader(for: result, normalizedToolName: normalizedToolCardName(result.toolName), explicitTitle: nil),
            ToolCardHeaderPresentation(title: "List PRs", sourceLabel: "GitHub")
        )
    }

    func testSourceLabelPresentationRules() {
        XCTAssertNil(ToolCardSourceLabel.displayText(nil))
        XCTAssertNil(ToolCardSourceLabel.displayText(""))
        XCTAssertNil(ToolCardSourceLabel.displayText(" \n\t"))
        XCTAssertEqual(ToolCardSourceLabel.displayText(" BusyCal \n"), "BusyCal")
    }

    func testClusterLabelsUseOneStringCompactLabelAndOtherFamily() {
        XCTAssertEqual(
            ClusterToolCategory.buildGroups(toolNames: ["mcp__busycal__delete_event"], counts: [:]),
            [ClusterToolGroup(icon: externalIcon, label: "Delete Event · BusyCal")]
        )
        XCTAssertEqual(
            ClusterToolCategory.buildGroups(toolNames: ["mcp__busycal__delete_event"], counts: ["mcp__busycal__delete_event": 3]),
            [ClusterToolGroup(icon: externalIcon, label: "Delete Event · BusyCal ×3")]
        )
        XCTAssertEqual(
            ClusterToolCategory.buildGroups(toolNames: ["mcp__busycal__delete_event", "mcp__github__search"], counts: [:]),
            [ClusterToolGroup(icon: "ellipsis.circle", label: "Other ×2")]
        )
        XCTAssertEqual(
            ClusterToolCategory.buildGroups(toolNames: ["read_file", "mcp__github__search"], counts: [:]),
            [
                ClusterToolGroup(icon: "magnifyingglass", label: "Read File"),
                ClusterToolGroup(icon: externalIcon, label: "Search · GitHub")
            ]
        )
        XCTAssertEqual(
            ClusterToolCategory.summaryTitleSemantic(
                toolNames: ["mcp__github__search", "mcp__fs__read_file"],
                toolNameCounts: [:],
                containsRunningWork: false
            ),
            .toolActivity,
            "External look-alikes do not count as codebase navigation"
        )
    }
}
