import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// D1 structured results: today's text is unchanged, `structuredContent` carries the existing DTO
/// payload when a connection has structured results on, and errors stay text-only. Committed
/// delegated-question notices appear in both the unchanged text and the reserved structured
/// field (owner decision 2026-10-17).
final class MCPStructuredOutputTests: XCTestCase {
    private typealias DTO = ToolResultDTOs
    private typealias GitDTO = ToolResultDTOs.GitToolReplyDTO

    /// Tools whose DTO carries an optional `worktree_scope`.
    private static let worktreeScopedTools: Set<String> = [
        MCPWindowToolName.readFile, MCPWindowToolName.search,
        MCPWindowToolName.getFileTree, MCPWindowToolName.getCodeStructure
    ]

    // MARK: - Result projection

    func testStructuredOffEncodesExactlyTheLegacyContentOnlyResult() throws {
        // makeToolResult reads this default; pin it to match the legacy comparison below.
        let emitResourceContentKey = "mcp.emitResourceContent"
        let previousEmitResourceContent = UserDefaults.standard.object(forKey: emitResourceContentKey)
        UserDefaults.standard.set(false, forKey: emitResourceContentKey)
        defer {
            if let previousEmitResourceContent {
                UserDefaults.standard.set(previousEmitResourceContent, forKey: emitResourceContentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: emitResourceContentKey)
            }
        }
        let gitFixture = Fixture(toolName: MCPWindowToolName.git, value: .object(["status": .string("clean")]))
        for fixture in try Self.fullFixtures() + Self.noticeFixtures() + [gitFixture] {
            for args in Self.argumentVariants {
                let off = ServerNetworkManager.makeToolResult(
                    toolName: fixture.toolName, args: args, value: fixture.value, structured: false
                )
                let legacy = CallTool.Result(
                    content: ToolOutputFormatter.buildContentBlocks(
                        toolName: fixture.toolName, args: args, result: fixture.value, emitResources: false
                    ),
                    isError: false
                )
                XCTAssertNil(off.structuredContent, fixture.toolName)
                XCTAssertEqual(try Self.encoded(off), try Self.encoded(legacy), fixture.toolName)
                let keys = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.encoded(off)) as? [String: Any]
                ).keys
                XCTAssertEqual(Set(keys), ["content", "isError"], fixture.toolName)
            }
        }
    }

    func testStructuredOnKeepsTextIdenticalAndCarriesTheDTOPayload() throws {
        for fixture in try Self.fullFixtures() + Self.minimalFixtures() {
            for args in Self.argumentVariants {
                let off = ServerNetworkManager.makeToolResult(
                    toolName: fixture.toolName, args: args, value: fixture.value, structured: false
                )
                let on = ServerNetworkManager.makeToolResult(
                    toolName: fixture.toolName, args: args, value: fixture.value, structured: true
                )
                XCTAssertEqual(try Self.encoded(on.content), try Self.encoded(off.content), fixture.toolName)
                XCTAssertEqual(on.isError, false)
                XCTAssertEqual(on.structuredContent, fixture.value, fixture.toolName)
            }
        }
    }

    func testRawJSONKeepsItsExactTextAndStructuredContentEqualsThatPayload() throws {
        let truthyFlags: [Value] = [.bool(true), .int(1), .string("yes"), .string(" ON ")]
        for fixture in try Self.fullFixtures() {
            for flag in truthyFlags {
                let args: [String: Value] = ["_rawJSON": flag]
                let off = ServerNetworkManager.makeToolResult(
                    toolName: fixture.toolName, args: args, value: fixture.value, structured: false
                )
                let on = ServerNetworkManager.makeToolResult(
                    toolName: fixture.toolName, args: args, value: fixture.value, structured: true
                )
                let expectedText = ToolOutputFormatter.rawJSONString(fixture.value)
                XCTAssertEqual(Self.texts(off), [expectedText], fixture.toolName)
                XCTAssertEqual(Self.texts(on), [expectedText], fixture.toolName)
                XCTAssertEqual(
                    try JSONDecoder().decode(Value.self, from: Data(expectedText.utf8)),
                    on.structuredContent,
                    fixture.toolName
                )
            }
        }
        // A falsy flag keeps formatted text; structuredContent is unaffected by `_rawJSON`.
        let fixture = try XCTUnwrap(Self.fullFixtures().first)
        let formatted = ServerNetworkManager.makeToolResult(
            toolName: fixture.toolName, args: ["_rawJSON": .string("no")], value: fixture.value, structured: true
        )
        XCTAssertNotEqual(Self.texts(formatted), [ToolOutputFormatter.rawJSONString(fixture.value)])
        XCTAssertEqual(formatted.structuredContent, fixture.value)
    }

    func testDelegatedQuestionNoticesAppearInUnchangedTextAndReservedStructuredField() throws {
        let notices = [Self.noticePayload(populated: true), Self.noticePayload(populated: false)]
        for fixture in try Self.fullFixtures() + Self.minimalFixtures() {
            let attached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching(notices, to: fixture.value))
            for args in Self.argumentVariants {
                let plain = ServerNetworkManager.makeToolResult(
                    toolName: fixture.toolName, args: args, value: fixture.value, structured: true
                )
                for structured in [false, true] {
                    let result = ServerNetworkManager.makeToolResult(
                        toolName: fixture.toolName, args: args, value: attached, structured: structured
                    )
                    // Text: the notice-free blocks plus one appended notice block, regardless of mode.
                    XCTAssertEqual(result.content.count, plain.content.count + 1, fixture.toolName)
                    XCTAssertEqual(
                        try Self.encoded(Array(result.content.dropLast())),
                        try Self.encoded(plain.content),
                        fixture.toolName
                    )
                    let noticeText = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.renderedText(for: notices))
                    XCTAssertEqual(Self.texts(result).last, noticeText)
                    guard structured else {
                        XCTAssertNil(result.structuredContent)
                        continue
                    }
                    // Structured: every DTO field unchanged, plus the committed entries under the reserved key.
                    var object = try XCTUnwrap(result.structuredContent?.objectValue, fixture.toolName)
                    let entries = try XCTUnwrap(
                        object.removeValue(forKey: AgentDelegatedQuestionNoticeWire.resultKey)?.arrayValue
                    )
                    XCTAssertEqual(Value.object(object), fixture.value, fixture.toolName)
                    XCTAssertEqual(entries, notices.map { $0.wireValue() }, fixture.toolName)
                    XCTAssertEqual(
                        entries.compactMap { $0.objectValue?["text"]?.stringValue },
                        notices.map(\.renderedText)
                    )
                }
            }
        }
    }

    func testRawJSONTextStaysNoticeFreeWhileStructuredContentAlsoCarriesTheNotice() throws {
        let notice = Self.noticePayload(populated: true)
        for fixture in try Self.fullFixtures() {
            let attached = try XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching([notice], to: fixture.value))
            let args: [String: Value] = ["_rawJSON": .bool(true)]
            let off = ServerNetworkManager.makeToolResult(
                toolName: fixture.toolName, args: args, value: attached, structured: false
            )
            let on = ServerNetworkManager.makeToolResult(
                toolName: fixture.toolName, args: args, value: attached, structured: true
            )
            // `_rawJSON` text is unchanged by the mode: notice-free JSON, then the notice block.
            let expectedTexts = [ToolOutputFormatter.rawJSONString(fixture.value), notice.renderedText]
            XCTAssertEqual(Self.texts(off), expectedTexts, fixture.toolName)
            XCTAssertEqual(Self.texts(on), expectedTexts, fixture.toolName)
            // structuredContent differs from the raw JSON text by exactly the reserved notice key.
            let rawPayload = try JSONDecoder().decode(Value.self, from: Data(expectedTexts[0].utf8))
            XCTAssertNil(rawPayload.objectValue?[AgentDelegatedQuestionNoticeWire.resultKey])
            XCTAssertEqual(on.structuredContent, attached, fixture.toolName)
            XCTAssertNotEqual(on.structuredContent, rawPayload, fixture.toolName)
            XCTAssertEqual(AgentDelegatedQuestionNoticeWire.splitting(attached).original, rawPayload, fixture.toolName)
        }
    }

    func testTruncatedResultsKeepTheirFlagsAndFullDataInStructuredContent() throws {
        let longLine = String(repeating: "x", count: 600)
        let search = DTO.SearchResultDTO(
            totalMatches: 900, totalFiles: 40, contentMatches: 900, pathMatches: 0, limitHit: true,
            perFileCounts: [.init(path: "Sources/A.swift", count: 900)],
            pathMatchLines: [],
            contentMatchGroups: [.init(path: "Sources/A.swift", lines: [
                .init(lineNumber: 3, lineText: longLine, contextBefore: nil, contextAfter: nil)
            ])],
            sizeLimitHit: true, omittedTotal: 899, omittedContentMatches: 899, omittedPathMatches: 0
        )
        let tree = DTO.FileTreeDTO(
            rootsCount: 1, usesLegend: true, tree: "root\n└── a", note: "Depth trimmed", wasTruncated: true
        )
        for (toolName, value) in try [
            (MCPWindowToolName.search, Value(search)),
            (MCPWindowToolName.getFileTree, Value(tree))
        ] {
            let off = ServerNetworkManager.makeToolResult(toolName: toolName, args: [:], value: value, structured: false)
            let on = ServerNetworkManager.makeToolResult(toolName: toolName, args: [:], value: value, structured: true)
            XCTAssertEqual(try Self.encoded(on.content), try Self.encoded(off.content), toolName)
            XCTAssertEqual(on.structuredContent, value, toolName)
        }
        let searchStructured = try XCTUnwrap(
            ServerNetworkManager.makeToolResult(
                toolName: MCPWindowToolName.search, args: [:], value: Value(search), structured: true
            ).structuredContent?.objectValue
        )
        XCTAssertEqual(searchStructured["size_limit_hit"], .bool(true))
        XCTAssertEqual(searchStructured["omitted_total"], .int(899))
        XCTAssertEqual(searchStructured["limit_hit"], .bool(true))
        let line = searchStructured["content_match_groups"]?.arrayValue?.first?.objectValue?["lines"]?.arrayValue?.first
        XCTAssertEqual(line?.objectValue?["line_text"], .string(longLine))
        let treeStructured = try XCTUnwrap(
            ServerNetworkManager.makeToolResult(
                toolName: MCPWindowToolName.getFileTree, args: [:], value: Value(tree), structured: true
            ).structuredContent?.objectValue
        )
        XCTAssertEqual(treeStructured["was_truncated"], .bool(true))
    }

    func testNonObjectPayloadNeverBecomesStructuredContent() {
        for value: Value in [.string("text"), .array([.int(1)]), .null, .bool(true)] {
            let result = ServerNetworkManager.makeToolResult(
                toolName: MCPWindowToolName.readFile, args: [:], value: value, structured: true
            )
            XCTAssertNil(result.structuredContent)
            XCTAssertEqual(result.isError, false)
        }
    }

    func testErrorResultsKeepIsErrorAndTextWithoutStructuredContent() throws {
        let plain = ServerNetworkManager.toolErrorResult(rawJSON: false, message: "boom")
        XCTAssertEqual(plain.isError, true)
        XCTAssertNil(plain.structuredContent)
        XCTAssertEqual(Self.texts(plain), ["boom"])

        let raw = ServerNetworkManager.toolErrorResult(rawJSON: true, message: "boom")
        XCTAssertEqual(raw.isError, true)
        XCTAssertNil(raw.structuredContent)
        XCTAssertEqual(
            Self.texts(raw),
            [ToolOutputFormatter.rawJSONString(.object(["is_error": .bool(true), "error": .string("boom")]))]
        )

        for rawJSON in [false, true] {
            let contract = ServerNetworkManager.executionContractToolErrorResult(
                rawJSON: rawJSON, code: "tool_execution_window_terminal", message: "closing"
            )
            XCTAssertEqual(contract.isError, true)
            XCTAssertNil(contract.structuredContent)
            let thrown = ServerNetworkManager.toolErrorResult(rawJSON: rawJSON, error: MCPError.invalidParams("bad"))
            XCTAssertEqual(thrown.isError, true)
            XCTAssertNil(thrown.structuredContent)
            let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.encoded(thrown)) as? [String: Any]).keys
            XCTAssertEqual(Set(keys), ["content", "isError"])
        }
    }

    // MARK: - Schemas

    func testSchemasDeclareExactlyTheFullyPopulatedDTOKeys() throws {
        // Full fixtures plus a fully populated notice under the reserved key.
        for fixture in try Self.noticeFixtures() {
            let schema = try XCTUnwrap(MCPToolOutputSchemas.schemasByToolName[fixture.toolName])
            XCTAssertEqual(schema.objectValue?["type"], .string("object"))
            Self.assertConforms(fixture.value, to: schema, keys: .allProperties, path: fixture.toolName)
        }
    }

    func testSchemasRequireExactlyTheNonOptionalDTOKeys() throws {
        for fixture in try Self.minimalFixtures() {
            let schema = try XCTUnwrap(MCPToolOutputSchemas.schemasByToolName[fixture.toolName])
            Self.assertConforms(fixture.value, to: schema, keys: .requiredOnly, path: fixture.toolName)
        }
        // Optional nested objects are absent from the minimal DTOs; check their own minimal shapes.
        let worktreeScope = try Value(Self.worktreeScope(minimalMapping: true))
        XCTAssertEqual(
            Set(MCPToolOutputSchemas.schemasByToolName.keys.filter { Self.property("worktree_scope", of: $0) != nil }),
            Self.worktreeScopedTools
        )
        for toolName in Self.worktreeScopedTools {
            let fragment = try XCTUnwrap(Self.property("worktree_scope", of: toolName))
            Self.assertConforms(worktreeScope, to: fragment, keys: .requiredOnly, path: "\(toolName).worktree_scope")
        }
        let snapshotSchema = try XCTUnwrap(MCPToolOutputSchemas.schemasByToolName[MCPWindowToolName.gitReviewSnapshot])
        for (propertyPath, minimal) in try Self.minimalGitSnapshotFragments() {
            let label = "git_review_snapshot." + propertyPath.joined(separator: ".")
            let fragment = try XCTUnwrap(Self.schema(at: propertyPath, in: snapshotSchema), label)
            Self.assertConforms(minimal, to: fragment, keys: .requiredOnly, path: label)
        }
        let retry = try Value(DTO.CodeStructureReplyDTO.RetryDTO(retryable: false, retryAfterMilliseconds: nil))
        let retryFragment = try XCTUnwrap(Self.property("retry", of: MCPWindowToolName.getCodeStructure))
        Self.assertConforms(retry, to: retryFragment, keys: .requiredOnly, path: "get_code_structure.retry")
        // The reserved notice field is optional on every schema; a minimal entry has only its required keys.
        let minimalNotices = Value.array([Self.noticePayload(populated: false).wireValue()])
        for toolName in MCPToolOutputSchemas.schemasByToolName.keys {
            let schema = try XCTUnwrap(MCPToolOutputSchemas.schemasByToolName[toolName])
            let required = (schema.objectValue?["required"]?.arrayValue ?? []).compactMap(\.stringValue)
            XCTAssertFalse(required.contains(AgentDelegatedQuestionNoticeWire.resultKey), toolName)
            let fragment = try XCTUnwrap(Self.property(AgentDelegatedQuestionNoticeWire.resultKey, of: toolName))
            XCTAssertEqual(fragment, MCPToolOutputSchemas.delegatedQuestionNotices, toolName)
            Self.assertConforms(minimalNotices, to: fragment, keys: .requiredOnly, path: "\(toolName).notices")
        }
    }

    func testOnlyTheExplorationToolsTheReviewSnapshotAndCodeModeAdvertiseAnOutputSchema() {
        // `code_mode` (plan §6 D3) advertises its result shape like the other schema-bearing tools.
        XCTAssertEqual(
            Set(MCPToolOutputSchemas.schemasByToolName.keys),
            Self.worktreeScopedTools.union([MCPWindowToolName.gitReviewSnapshot, MCPWindowToolName.codeMode])
        )
        // The legacy `git` tool returns the same DTO for every op but declares no schema.
        XCTAssertNil(MCPToolOutputSchemas.schemasByToolName[MCPWindowToolName.git])
    }

    @MainActor
    func testWindowCatalogAttachesExactlyTheDeclaredSchemas() async {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let tools = await window.mcpServer.windowMCPTools
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            XCTAssertEqual(tool.outputSchema, MCPToolOutputSchemas.schemasByToolName[tool.name], tool.name)
        }
        XCTAssertEqual(
            Set(tools.filter { $0.outputSchema != nil }.map(\.name)),
            Set(MCPToolOutputSchemas.schemasByToolName.keys)
        )
    }

    // MARK: - Setting

    @MainActor
    func testStructuredResultsSettingDefaultsOffAndPersistsOnAndOff() async throws {
        #if DEBUG
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPStructuredOutputTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suiteName = "MCPStructuredOutputTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let fileURL = root.appendingPathComponent("globalSettings.json")
            func makeStore() -> GlobalSettingsStore {
                GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
            }
            let store = makeStore()
            XCTAssertEqual(store.mcpStructuredResultsMode(), .off)
            let service = AppSettingsMCPService(store: store, scheduleRemoteGatewayReconciliation: {})
            let key = "mcp.structured_results"

            let listed = try await service.handleForTesting([
                "op": .string("list"), "group": .string("mcp"), "detailed": .bool(true)
            ])
            let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
            let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
            XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "string")
            XCTAssertEqual(catalog.objectValue?["value"]?.stringValue, "off")
            XCTAssertEqual(catalog.objectValue?["writable"]?.boolValue, true)

            let setOn = try await service.handleForTesting([
                "op": .string("set"), "key": .string(key), "value": .string("on")
            ])
            XCTAssertEqual(setOn.objectValue?["status"]?.stringValue, "ok")
            XCTAssertEqual(store.mcpStructuredResultsMode(), .on)
            XCTAssertEqual(makeStore().mcpStructuredResultsMode(), .on)

            do {
                _ = try await service.handleForTesting([
                    "op": .string("set"), "key": .string(key), "value": .string("auto")
                ])
                XCTFail("Expected an invalid value to be rejected")
            } catch {}
            XCTAssertEqual(store.mcpStructuredResultsMode(), .on)

            _ = try await service.handleForTesting([
                "op": .string("set"), "key": .string(key), "value": .string("off")
            ])
            let get = try await service.handleForTesting(["op": .string("get"), "key": .string(key)])
            XCTAssertEqual(get.objectValue?["values"]?.objectValue?[key]?.stringValue, "off")
            XCTAssertEqual(makeStore().mcpStructuredResultsMode(), .off)
        #else
            throw XCTSkip("AppSettingsMCPService.handleForTesting requires DEBUG.")
        #endif
    }

    // MARK: - Fixtures

    private struct Fixture {
        let toolName: String
        let value: Value
    }

    private static let argumentVariants: [[String: Value]] = [
        [:],
        ["path": .string("Sources/A.swift"), "_windowID": .int(1)],
        ["scope": .string("paths"), "mode": .string("auto")]
    ]

    private static func worktreeScope(minimalMapping: Bool) -> DTO.WorktreeScopeDTO {
        DTO.WorktreeScopeDTO(
            kind: "session_bound_worktree",
            displayIdentity: "logical_canonical_root",
            effectiveIdentity: "bound_worktree_root",
            rootMappings: [
                DTO.WorktreeScopeDTO.RootMappingDTO(
                    logicalRootName: "repo",
                    logicalRootPath: "repo",
                    effectiveRootName: "wt",
                    effectiveRootPath: "session-bound",
                    worktreeID: "wt_1",
                    worktreeName: minimalMapping ? nil : "wt",
                    branch: minimalMapping ? nil : "feature",
                    label: minimalMapping ? nil : "T1"
                )
            ]
        )
    }

    /// Every optional field set, including nested optional DTOs.
    private static func fullFixtures() throws -> [Fixture] {
        let scope = worktreeScope(minimalMapping: false)
        let read = DTO.ReadFileReply(
            content: "let a = 1\n", totalLines: 10, firstLine: 1, lastLine: 1, message: "Partial read",
            displayPath: "Sources/A.swift", worktreeScope: scope, errorMessage: "warn", errorCode: "code",
            retryable: true, retryAfterMilliseconds: 250
        )
        let contextLine = DTO.SearchResultDTO.ContentMatchGroup.ContextLine(lineNumber: 1, lineText: "before")
        let search = DTO.SearchResultDTO(
            totalMatches: 2, totalFiles: 1, matchedFiles: 1, searchedFiles: 5, contentMatches: 1,
            pathMatches: 1, limitHit: false, perFileCounts: [.init(path: "Sources/A.swift", count: 1)],
            pathMatchLines: ["Sources/A.swift"],
            contentMatchGroups: [.init(path: "Sources/A.swift", lines: [
                .init(lineNumber: 2, lineText: "let a = 1", contextBefore: [contextLine], contextAfter: [contextLine])
            ])],
            sizeLimitHit: true, omittedTotal: 1, omittedContentMatches: 1, omittedPathMatches: 0,
            errorMessage: "partial", errorCode: "search_partial", retryable: true, retryAfterMilliseconds: 100,
            suggestion: "narrow", warning: "slow", perFileTotals: [.init(path: "Sources/A.swift", count: 2)],
            worktreeScope: scope
        )
        let tree = DTO.FileTreeDTO(
            rootsCount: 1, usesLegend: true, tree: "repo\n└── A.swift", note: "note", wasTruncated: true,
            worktreeScope: scope
        )
        let structure = DTO.CodeStructureReplyDTO(
            status: "budget",
            files: [.init(path: "Sources/A.swift", role: "seed", depth: 0, reachedBy: ["seed"], content: "func a()", tokens: 3)],
            summary: .init(
                requestedSeeds: 1, resolvedSeeds: 1, returnedSeeds: 1, returnedRelated: 0, returnedFiles: 1,
                codemapContentTokens: 3, examinedEdges: 0
            ),
            issues: [.init(
                code: "budget", phase: "render", path: "Sources/B.swift", retryable: true,
                retryAfterMilliseconds: 500, attempted: 2, limit: 1, message: "over budget", detail: "detail"
            )],
            retry: .init(retryable: true, retryAfterMilliseconds: 500),
            worktreeScope: scope
        )
        return try [
            Fixture(toolName: MCPWindowToolName.readFile, value: Value(read)),
            Fixture(toolName: MCPWindowToolName.search, value: Value(search)),
            Fixture(toolName: MCPWindowToolName.getFileTree, value: Value(tree)),
            Fixture(toolName: MCPWindowToolName.getCodeStructure, value: Value(structure)),
            Fixture(toolName: MCPWindowToolName.gitReviewSnapshot, value: Value(fullGitSnapshot()))
        ]
    }

    /// A `git_review_snapshot` reply with every diff-relevant field set, flat and per repo. The
    /// status, log, show, and blame payloads stay nil: the snapshot always runs `op = diff`.
    private static func fullGitSnapshot() -> GitDTO {
        let byStatus = ["M": 1, "A": 1]
        let totals = GitDTO.TotalsDTO(files: 2, insertions: 3, deletions: 1)
        let diff = GitDTO.DiffDTO(
            compare: "uncommitted", detail: "summary",
            files: [.init(
                path: "Sources/A.swift", status: "M", insertions: 3, deletions: 1,
                hunks: [.init(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, patch: "-a\n+b")]
            )],
            totals: totals, byStatus: byStatus, oneliner: "2 files (+3 -1)", truncated: true,
            truncationNote: "trimmed"
        )
        let worktree = GitDTO.WorktreeDTO(
            isWorktree: true, worktreeName: "wt", worktreeRoot: "/wt", commonGitDir: "/repo/.git",
            mainWorktreeRoot: "/repo", worktreeBranch: "feature", mainBranch: "main", worktreeHead: "abc",
            mainHead: "def"
        )
        let artifacts = GitDTO.ArtifactsDTO(
            manifest: "manifest.json", map: "MAP.txt", filesTsv: "files.tsv", changedLines: "changed.tsv",
            tree: "tree.txt", selectionPaths: "selection.txt", allPatch: "diff/all.patch", deepHunks: "hunks.txt",
            deepChangedLines: "deep.tsv"
        )
        let primary = GitDTO.PrimaryArtifactsDTO(
            map: "MAP.txt", allPatch: "diff/all.patch", autoSelected: ["MAP.txt"],
            perFilePatches: [.init(
                jumpIndex: 1, gitPath: "Sources/A.swift", selectionPath: "diff/A.patch", status: "M",
                additions: 3, deletions: 1
            )]
        )
        let summary = GitDTO.SummaryDTO(files: 2, insertions: 3, deletions: 1, byStatus: byStatus)
        let inputs = GitDTO.DiffInputsDTO(
            compare: "uncommitted", compareInput: "uncommitted", scope: "selected", requestedPathsCount: 1,
            contextLines: 3, detectRenames: false
        )
        let inline = GitDTO.InlineDTO(mapExcerpt: "MAP", truncated: false, totalLines: 1, returnedLines: 1)
        let repo = GitDTO.RepoResultDTO(
            repoRoot: "/repo", repoKey: "repo-key", repoName: "repo", diff: diff, worktree: worktree,
            snapshotId: "snap-1", snapshotDir: "/snap", artifacts: artifacts, primaryArtifacts: primary,
            summary: summary, oneliner: "2 files (+3 -1)", inputs: inputs, modeDetails: "standard", inline: inline,
            warning: "warn", emptyReason: "none", error: "partial"
        )
        return GitDTO(
            op: "diff", repos: [repo],
            aggregate: .init(totals: totals, byStatus: byStatus, oneliner: "1 repo", repoCount: 1),
            diff: diff, worktree: worktree, snapshotId: "snap-1", snapshotDir: "/snap", artifacts: artifacts,
            primaryArtifacts: primary, summary: summary, oneliner: "2 files (+3 -1)", inputs: inputs,
            modeDetails: "standard", inline: inline, warning: "warn", emptyReason: "none", error: "partial"
        )
    }

    /// Minimal shapes of the snapshot's optional nested values, keyed by property path (array
    /// properties are checked through their item schema).
    private static func minimalGitSnapshotFragments() throws -> [([String], Value)] {
        let totals = GitDTO.TotalsDTO(files: 0, insertions: 0, deletions: 0)
        let diff = GitDTO.DiffDTO(
            compare: "uncommitted", detail: nil, files: nil, totals: totals, byStatus: nil, oneliner: "",
            truncated: nil, truncationNote: nil
        )
        let diffFile = GitDTO.DiffFileDTO(
            path: "Sources/A.swift", status: "M", insertions: nil, deletions: nil, hunks: nil
        )
        let hunk = GitDTO.DiffHunkDTO(header: "@@", oldStart: 0, newStart: 0, patch: "")
        let worktree = GitDTO.WorktreeDTO(
            isWorktree: false, worktreeName: nil, worktreeRoot: "/repo", commonGitDir: nil,
            mainWorktreeRoot: nil, worktreeBranch: nil, mainBranch: nil, worktreeHead: nil, mainHead: nil
        )
        let artifacts = GitDTO.ArtifactsDTO(
            manifest: "m", map: "MAP.txt", filesTsv: "f", changedLines: nil, tree: "t", selectionPaths: nil,
            allPatch: nil, deepHunks: nil, deepChangedLines: nil
        )
        let primary = GitDTO.PrimaryArtifactsDTO(map: "MAP.txt", allPatch: nil, autoSelected: nil, perFilePatches: nil)
        let perFilePatch = GitDTO.PrimaryArtifactsDTO.PerFilePatchDTO(
            jumpIndex: 0, gitPath: "a", selectionPath: "b", status: nil, additions: nil, deletions: nil
        )
        return try [
            (["diff"], Value(diff)),
            (["diff", "files"], Value([diffFile])),
            (["diff", "files", "hunks"], Value([hunk])),
            (["worktree"], Value(worktree)),
            (["artifacts"], Value(artifacts)),
            (["primary_artifacts"], Value(primary)),
            (["primary_artifacts", "per_file_patches"], Value([perFilePatch])),
            (["summary"], Value(GitDTO.SummaryDTO(files: 0, insertions: 0, deletions: 0, byStatus: nil))),
            (["inputs"], Value(GitDTO.DiffInputsDTO(
                compare: "uncommitted", compareInput: nil, scope: "all", requestedPathsCount: nil,
                contextLines: 3, detectRenames: false
            ))),
            (["inline"], Value(GitDTO.InlineDTO(mapExcerpt: "", truncated: false, totalLines: 0, returnedLines: 0))),
            (["repos"], Value([GitDTO.RepoResultDTO(repoRoot: "/repo", repoKey: "repo-key")])),
            (["aggregate"], Value(GitDTO.AggregateDTO()))
        ]
    }

    /// Every optional field nil; arrays non-empty so nested required keys are checked too.
    private static func minimalFixtures() throws -> [Fixture] {
        let read = DTO.ReadFileReply(content: "", totalLines: 0, firstLine: 0, lastLine: 0)
        let search = DTO.SearchResultDTO(
            totalMatches: 1, totalFiles: 1, contentMatches: 1, pathMatches: 0, limitHit: false,
            perFileCounts: [.init(path: "Sources/A.swift", count: 1)],
            pathMatchLines: ["Sources/A.swift"],
            contentMatchGroups: [.init(path: "Sources/A.swift", lines: [
                .init(lineNumber: 2, lineText: "let a = 1", contextBefore: nil, contextAfter: nil)
            ])]
        )
        let tree = DTO.FileTreeDTO(rootsCount: 0, usesLegend: false, tree: "")
        let structure = DTO.CodeStructureReplyDTO(
            status: "ready",
            files: [.init(path: "Sources/A.swift", role: "seed", depth: 0, reachedBy: [], content: "", tokens: 0)],
            summary: .init(
                requestedSeeds: 0, resolvedSeeds: 0, returnedSeeds: 0, returnedRelated: 0, returnedFiles: 0,
                codemapContentTokens: 0, examinedEdges: 0
            ),
            issues: [.init(
                code: "c", phase: "p", path: nil, retryable: false, retryAfterMilliseconds: nil,
                attempted: nil, limit: nil, message: "m"
            )],
            retry: nil,
            worktreeScope: nil
        )
        let snapshot = GitDTO(op: "diff")
        return try [
            Fixture(toolName: MCPWindowToolName.readFile, value: Value(read)),
            Fixture(toolName: MCPWindowToolName.search, value: Value(search)),
            Fixture(toolName: MCPWindowToolName.getFileTree, value: Value(tree)),
            Fixture(toolName: MCPWindowToolName.getCodeStructure, value: Value(structure)),
            Fixture(toolName: MCPWindowToolName.gitReviewSnapshot, value: Value(snapshot))
        ]
    }

    /// Full fixtures, each carrying one fully populated notice under the reserved key.
    private static func noticeFixtures() throws -> [Fixture] {
        let notice = noticePayload(populated: true)
        return try fullFixtures().map { fixture in
            try Fixture(
                toolName: fixture.toolName,
                value: XCTUnwrap(AgentDelegatedQuestionNoticeWire.attaching([notice], to: fixture.value))
            )
        }
    }

    /// `populated` sets every optional notice, question, and option field; otherwise all are nil.
    private static func noticePayload(populated: Bool) -> AgentDelegatedQuestionNoticePayload {
        AgentDelegatedQuestionNoticePayload(
            key: .init(childSessionID: UUID(), interactionID: UUID()),
            childSessionName: "Child",
            title: populated ? "Choose" : nil,
            context: populated ? "Need a decision" : nil,
            questions: [.init(
                id: "path",
                header: populated ? "Path" : nil,
                question: "Which?",
                context: populated ? "Pick one" : nil,
                options: [.init(label: "A", description: populated ? "First" : nil)],
                allowsMultiple: false, allowsCustom: true
            )]
        )
    }

    // MARK: - Schema checking (test-only; the server does not validate)

    private enum KeyExpectation {
        /// Every object's keys equal its schema's declared properties.
        case allProperties
        /// Every object's keys equal its schema's required list.
        case requiredOnly
    }

    private static func property(_ name: String, of toolName: String) -> Value? {
        MCPToolOutputSchemas.schemasByToolName[toolName]?.objectValue?["properties"]?.objectValue?[name]
    }

    /// Walks object `properties`, stepping through array `items`, so `["diff", "files", "hunks"]`
    /// resolves the hunks array schema.
    private static func schema(at propertyPath: [String], in root: Value) -> Value? {
        var current = root
        for name in propertyPath {
            if current.objectValue?["type"] == .string("array"), let items = current.objectValue?["items"] {
                current = items
            }
            guard let next = current.objectValue?["properties"]?.objectValue?[name] else { return nil }
            current = next
        }
        return current
    }

    private static func assertConforms(
        _ value: Value,
        to schema: Value,
        keys expectation: KeyExpectation,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let schemaObject = schema.objectValue, let type = schemaObject["type"]?.stringValue else {
            XCTFail("\(path): schema has no type", file: file, line: line)
            return
        }
        switch (type, value) {
        case ("string", .string), ("integer", .int), ("boolean", .bool):
            return
        case let ("array", .array(items)):
            guard let itemSchema = schemaObject["items"] else {
                XCTFail("\(path): array schema has no items", file: file, line: line)
                return
            }
            for (index, item) in items.enumerated() {
                assertConforms(item, to: itemSchema, keys: expectation, path: "\(path)[\(index)]", file: file, line: line)
            }
        case let ("object", .object(object)) where schemaObject["additionalProperties"]?.objectValue != nil:
            // A map such as `by_status`: no declared keys, every value matches one schema.
            let valueSchema = schemaObject["additionalProperties"] ?? .null
            XCTAssertNil(schemaObject["properties"], path, file: file, line: line)
            XCTAssertFalse(object.isEmpty, "\(path): map fixture needs entries", file: file, line: line)
            for (key, child) in object {
                assertConforms(child, to: valueSchema, keys: expectation, path: "\(path).\(key)", file: file, line: line)
            }
        case let ("object", .object(object)):
            XCTAssertEqual(schemaObject["additionalProperties"], .bool(true), path, file: file, line: line)
            let properties = schemaObject["properties"]?.objectValue ?? [:]
            let required = Set((schemaObject["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            XCTAssertTrue(required.isSubset(of: Set(properties.keys)), "\(path): required key without property", file: file, line: line)
            let expectedKeys = switch expectation {
            case .allProperties: Set(properties.keys)
            case .requiredOnly: required
            }
            XCTAssertEqual(Set(object.keys), expectedKeys, path, file: file, line: line)
            for (key, child) in object {
                guard let childSchema = properties[key] else { continue }
                assertConforms(child, to: childSchema, keys: expectation, path: "\(path).\(key)", file: file, line: line)
            }
        default:
            XCTFail("\(path): value \(value) does not match schema type \(type)", file: file, line: line)
        }
    }

    // MARK: - Encoding helpers

    private static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { block in
            if case let .text(text, _, _) = block { return text }
            return nil
        }
    }
}
