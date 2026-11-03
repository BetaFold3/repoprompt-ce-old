@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class RemoteTranscriptProjectorTests: XCTestCase {
    func testEmptyTranscriptWrapperProducesNoItems() {
        XCTAssertTrue(project(xml: "<transcript></transcript>").isEmpty)
        XCTAssertTrue(project(xml: "<transcript>\n  </transcript>").isEmpty)
        XCTAssertTrue(project(xml: "<transcript/>").isEmpty)
    }

    func testUnparsedTranscriptWrapperPreservesStrippedContentAsSystemItem() throws {
        let items = project(xml: "<transcript>unparsed text</transcript>")

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .system)
        XCTAssertEqual(item.text, "unparsed text")
    }

    func testBareGarbagePreservesContentAsSystemItem() throws {
        let items = project(xml: "hello")

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .system)
        XCTAssertEqual(item.text, "hello")
    }

    func testNormalUserAndAssistantTagsStillParse() {
        let items = project(xml: "<transcript><user>Hello</user><assistant>Hi there</assistant></transcript>")

        XCTAssertEqual(items.map(\.kind), [.user, .assistant])
        XCTAssertEqual(items.map(\.text), ["Hello", "Hi there"])
    }

    func testUpsertingPreservesNewerExistingTimestampForDeterministicID() throws {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-upsert-existing")
        let projected = try XCTUnwrap(projector.projectGetLogResponse(.object([
            "turn_offset": .int(0),
            "returned_turn_count": .int(1),
            "total_turns": .int(1),
            "transcript_xml": .string("<user>Hello remote</user>")
        ])).items.first)
        let existingTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = AgentChatItem(
            id: projected.id,
            timestamp: existingTimestamp,
            kind: .user,
            text: "Optimistic text",
            sequenceIndex: projected.sequenceIndex
        )

        let merged = projector.upserting([projected], into: [existing])
        let item = try XCTUnwrap(merged.first)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(item.id, projected.id)
        XCTAssertEqual(item.timestamp, existingTimestamp)
        XCTAssertEqual(item.text, projected.text)
    }

    func testUpsertingUsesNewerProjectedTimestampForDeterministicID() throws {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-upsert-projected")
        let itemID = UUID()
        let existing = AgentChatItem(
            id: itemID,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .user,
            text: "Old text",
            sequenceIndex: 0
        )
        let projectedTimestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let projected = AgentChatItem(
            id: itemID,
            timestamp: projectedTimestamp,
            kind: .user,
            text: "New wire text",
            sequenceIndex: 0
        )

        let merged = projector.upserting([projected], into: [existing])
        let item = try XCTUnwrap(merged.first)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.timestamp, projectedTimestamp)
        XCTAssertEqual(item.text, projected.text)
    }

    func testToolResultFoldsIntoPrecedingToolCallAndSettlesCard() throws {
        let items = project(xml: """
        <transcript>
        <tool_call name="read_file">{"path":"README.md"}</tool_call>
        <tool_result name="read_file" status="success"/>
        </transcript>
        """)

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .toolCall)
        XCTAssertEqual(item.toolName, "read_file")
        XCTAssertNotNil(item.toolResultJSON)
        XCTAssertEqual(item.toolIsError, false)
        XCTAssertNotEqual(ToolCallCardStateResolver.status(for: item), .running)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .success)
    }

    /// Step 4d6: the method name is ledger-pinned. A result-less call no longer claims
    /// per-call liveness; it renders neutral while staying eligible for run-scoped cancel.
    func testToolCallWithoutToolResultRemainsRunning() throws {
        let item = try XCTUnwrap(project(xml: #"<tool_call name="read_file"/>"#).first)

        XCTAssertNil(item.toolResultJSON)
        XCTAssertNil(item.toolIsError)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .neutral)
        XCTAssertTrue(ToolCallCardStateResolver.allowsRunScopedCancel(for: item))
    }

    func testToolResultDoesNotConsumeSequenceIndex() {
        let withResult = project(xml: """
        <user>Start</user>
        <tool_call name="read_file"/>
        <tool_result status="success" name="read_file" extra="ignored"/>
        <assistant>Done</assistant>
        """)
        let withoutResult = project(xml: """
        <user>Start</user>
        <tool_call name="read_file"/>
        <assistant>Done</assistant>
        """)

        XCTAssertEqual(withResult.map(\.kind), withoutResult.map(\.kind))
        XCTAssertEqual(withResult.map(\.sequenceIndex), withoutResult.map(\.sequenceIndex))
        XCTAssertEqual(withResult.map(\.id), withoutResult.map(\.id))
        XCTAssertNotNil(withResult.first { $0.kind == .toolCall }?.toolResultJSON)
        XCTAssertNil(withoutResult.first { $0.kind == .toolCall }?.toolResultJSON)
    }

    func testUnmatchedToolResultIsIgnored() {
        let items = project(xml: """
        <tool_call name="read_file"/>
        <tool_result name="write_file" status="success"/>
        <assistant>Done</assistant>
        """)

        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items.first { $0.kind == .toolCall }?.toolResultJSON)
    }

    func testUnknownToolResultJSONFallsBackToRunning() {
        let item = AgentChatItem(
            kind: .toolCall,
            text: "Using tool: read_file",
            toolName: "read_file",
            toolResultJSON: #"{"status":"unknown"}"#,
            toolIsError: nil
        )

        // Step 4d6: the method name is ledger-pinned. Unclassifiable evidence now falls back to
        // neutral display, while cancel eligibility keeps the old `.running` fallback.
        XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .neutral)
        XCTAssertTrue(ToolCallCardStateResolver.allowsRunScopedCancel(for: item))
    }

    func testToolCallCardDisplayStatusTruthTable() {
        let cases: [(name: String, raw: String?, isError: Bool?, expected: ToolCardStatus)] = [
            ("missing evidence", nil, nil, .neutral),
            ("unknown status word", #"{"status":"unknown"}"#, nil, .neutral),
            ("unclassifiable non-JSON", "plain text", nil, .neutral),
            ("status word running", #"{"status":"running"}"#, nil, .neutral),
            ("negative command exit without timing", Self.negativeCommandExitJSON, nil, .neutral),
            ("success", #"{"status":"success"}"#, nil, .success),
            ("isError false only", nil, false, .success),
            ("warning", #"{"status":"warning"}"#, nil, .warning),
            ("failure", #"{"status":"failed"}"#, nil, .failure),
            ("isError true only", nil, true, .failure),
            ("explicit running summary", Self.runningRenderSummaryJSON, nil, .running)
        ]
        for testCase in cases {
            let item = Self.toolCallItem(raw: testCase.raw, isError: testCase.isError)
            XCTAssertEqual(ToolCallCardStateResolver.status(for: item), testCase.expected, testCase.name)
        }
    }

    func testToolCallCardRunScopedCancelKeepsPreStep4d6Eligibility() {
        let cases: [(name: String, raw: String?, isError: Bool?, allowed: Bool)] = [
            ("missing evidence", nil, nil, true),
            ("unknown status word", #"{"status":"unknown"}"#, nil, true),
            ("unclassifiable non-JSON", "plain text", nil, true),
            ("status word running", #"{"status":"running"}"#, nil, false),
            ("negative command exit without timing", Self.negativeCommandExitJSON, nil, false),
            ("success", #"{"status":"success"}"#, nil, false),
            ("isError false only", nil, false, false),
            ("warning", #"{"status":"warning"}"#, nil, false),
            ("failure", #"{"status":"failed"}"#, nil, false),
            ("isError true only", nil, true, false),
            ("explicit running summary", Self.runningRenderSummaryJSON, nil, true)
        ]
        for testCase in cases {
            let item = Self.toolCallItem(raw: testCase.raw, isError: testCase.isError)
            // The pre-4d6 formula restated for comparison; it is not an independent oracle.
            // The hardcoded `allowed` column is what pins the behavior.
            let oldEligibility = testCase.raw == nil && testCase.isError == nil
                || ToolResultStatusResolver.resolve(toolIsError: testCase.isError, raw: testCase.raw, fallback: .running) == .running
            XCTAssertEqual(oldEligibility, testCase.allowed, "pre-4d6 formula: \(testCase.name)")
            XCTAssertEqual(ToolCallCardStateResolver.allowsRunScopedCancel(for: item), testCase.allowed, testCase.name)
        }
    }

    func testToolCallCardRunScopedCancelRequiresRunScopeActionAndRepoPromptTool() {
        let unresolved = Self.toolCallItem(raw: nil, isError: nil, toolName: "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__read_file")
        let plainRepoPrompt = Self.toolCallItem(raw: nil, isError: nil, toolName: "read_file")
        let foreign = Self.toolCallItem(raw: nil, isError: nil, toolName: "Bash")
        let settled = Self.toolCallItem(raw: #"{"status":"success"}"#, isError: false, toolName: "read_file")

        XCTAssertTrue(ToolCallCardStateResolver.showsRunScopedCancel(
            for: unresolved, showRunScopedToolCancel: true, hasCancelAction: true
        ))
        XCTAssertTrue(ToolCallCardStateResolver.showsRunScopedCancel(
            for: plainRepoPrompt, showRunScopedToolCancel: true, hasCancelAction: true
        ))
        XCTAssertFalse(ToolCallCardStateResolver.showsRunScopedCancel(
            for: unresolved, showRunScopedToolCancel: false, hasCancelAction: true
        ))
        XCTAssertFalse(ToolCallCardStateResolver.showsRunScopedCancel(
            for: unresolved, showRunScopedToolCancel: true, hasCancelAction: false
        ))
        XCTAssertFalse(ToolCallCardStateResolver.showsRunScopedCancel(
            for: foreign, showRunScopedToolCancel: true, hasCancelAction: true
        ))
        XCTAssertFalse(ToolCallCardStateResolver.showsRunScopedCancel(
            for: settled, showRunScopedToolCancel: true, hasCancelAction: true
        ))
        // Cancel eligibility is decoupled from the neutral display.
        XCTAssertEqual(ToolCallCardStateResolver.status(for: unresolved), .neutral)
    }

    func testRowTimestampAttributesParseAcrossRowKindsWithSyntheticFallback() {
        let items = project(xml: """
        <transcript>
        <user ts="1752717279.250">Hello</user>
        <assistant ts="1752717601.500">Hi there</assistant>
        <system ts="1752717602.750">note</system>
        <error ts="1752717603.125">boom</error>
        <tool_call name="read_file" ts="1752717604.250"/>
        <tool_call name="apply_edits" ts="1752717605.500">{"path":"a.swift"}</tool_call>
        <assistant>legacy row without ts</assistant>
        <assistant ts="nan">non-finite ts row</assistant>
        <assistant ts="inf">infinite ts row</assistant>
        </transcript>
        """)

        XCTAssertEqual(
            items.map(\.kind),
            [.user, .assistant, .system, .error, .toolCall, .toolCall, .assistant, .assistant, .assistant]
        )
        XCTAssertEqual(items[0].timestamp, Date(timeIntervalSince1970: 1_752_717_279.25))
        XCTAssertEqual(items[1].timestamp, Date(timeIntervalSince1970: 1_752_717_601.5))
        XCTAssertEqual(items[2].timestamp, Date(timeIntervalSince1970: 1_752_717_602.75))
        XCTAssertEqual(items[3].timestamp, Date(timeIntervalSince1970: 1_752_717_603.125))
        XCTAssertEqual(items[4].timestamp, Date(timeIntervalSince1970: 1_752_717_604.25))
        XCTAssertEqual(items[4].toolName, "read_file")
        XCTAssertEqual(items[5].timestamp, Date(timeIntervalSince1970: 1_752_717_605.5))
        XCTAssertEqual(items[5].toolArgsJSON, #"{"path":"a.swift"}"#)
        // Rows without a wire ts keep the legacy synthetic sequence-index date.
        XCTAssertEqual(items[6].timestamp, Date(timeIntervalSince1970: TimeInterval(items[6].sequenceIndex)))
        // Non-finite ts values ("nan"/"inf" parse as valid TimeIntervals) must not poison
        // max-merge or persistence; they fall back to the synthetic date.
        XCTAssertEqual(items[7].timestamp, Date(timeIntervalSince1970: TimeInterval(items[7].sequenceIndex)))
        XCTAssertEqual(items[8].timestamp, Date(timeIntervalSince1970: TimeInterval(items[8].sequenceIndex)))
    }

    func testWireTimestampedRowsKeepLegacyDeterministicIDsAndUpsertHealsSyntheticDates() {
        let legacy = project(xml: "<user>Hello</user>\n<assistant>Hi</assistant>")
        let timestamped = project(
            xml: "<user ts=\"1752717279.250\">Hello</user>\n<assistant ts=\"1752717601.500\">Hi</assistant>"
        )

        // The wire ts must not participate in row identity, so legacy and upgraded
        // projections of the same row merge instead of duplicating.
        XCTAssertEqual(legacy.map(\.id), timestamped.map(\.id))

        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-projector-test")
        let healed = projector.upserting(timestamped, into: legacy)

        XCTAssertEqual(healed.map(\.id), legacy.map(\.id))
        XCTAssertEqual(healed.map(\.timestamp), [
            Date(timeIntervalSince1970: 1_752_717_279.25),
            Date(timeIntervalSince1970: 1_752_717_601.5)
        ])
    }

    func testHostRowIDAttributesMapToClientItemsWithoutChangingLegacyProjection() {
        let userHostRowID = UUID()
        let toolHostRowID = UUID()
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-host-row-ids")
        let legacyXML = """
        <user>Hello</user>
        <tool_call name="read_file"/>
        <assistant>Done</assistant>
        <error>Failed</error>
        """
        let upgradedXML = """
        <user id="\(userHostRowID.uuidString)">Hello</user>
        <tool_call name="read_file" id="\(toolHostRowID.uuidString)"/>
        <assistant>Done</assistant>
        <error id="not-a-uuid">Failed</error>
        """
        func payload(xml: String) -> JSONValue {
            .object([
                "turn_offset": .int(0),
                "returned_turn_count": .int(1),
                "total_turns": .int(1),
                "transcript_xml": .string(xml)
            ])
        }

        let legacy = projector.projectGetLogResponse(payload(xml: legacyXML))
        let upgraded = projector.projectGetLogResponse(payload(xml: upgradedXML))

        XCTAssertEqual(upgraded.items, legacy.items)
        XCTAssertTrue(legacy.hostRowIDByClientItemID.isEmpty)
        XCTAssertEqual(upgraded.hostRowIDByClientItemID, [
            upgraded.items[0].id: userHostRowID,
            upgraded.items[1].id: toolHostRowID
        ])
        XCTAssertNil(upgraded.hostRowIDByClientItemID[upgraded.items[2].id])
        XCTAssertNil(upgraded.hostRowIDByClientItemID[upgraded.items[3].id])
    }

    func testProjectSnapshotParsesAgentReasoningEffort() {
        let projector = RemoteTranscriptProjector(remoteSessionID: "remote-session-projector-effort")

        XCTAssertEqual(projector.projectSnapshot(.object([
            "status": .string("running"),
            "agent": .object([
                "id": .string("codexExec"),
                "model": .string("gpt-5.4-mini"),
                "reasoning_effort": .string("  high  ")
            ])
        ])).agentReasoningEffortRaw, "high")
        XCTAssertNil(projector.projectSnapshot(.object([
            "status": .string("running"),
            "agent": .object([
                "id": .string("codexExec"),
                "model": .string("gpt-5.4-mini")
            ])
        ])).agentReasoningEffortRaw)
        XCTAssertNil(projector.projectSnapshot(.object([
            "status": .string("running"),
            "agent": .object([
                "id": .string("codexExec"),
                "model": .string("gpt-5.4-mini"),
                "reasoning_effort": .string("  \n\t ")
            ])
        ])).agentReasoningEffortRaw)
    }

    private func project(xml: String) -> [AgentChatItem] {
        RemoteTranscriptProjector(remoteSessionID: "remote-session-projector-test")
            .projectGetLogResponse(.object([
                "turn_offset": .int(0),
                "returned_turn_count": .int(1),
                "total_turns": .int(1),
                "transcript_xml": .string(xml)
            ]))
            .items
    }

    /// An explicit `.neutral` from the command-exit override (a negative exit code with no timing hint).
    private static let negativeCommandExitJSON = #"{"type":"command_execution","exitCode":-1}"#

    private static let runningRenderSummaryJSON =
        #"{"summary_only":true,"render_summary":{"tool_name":"manage_selection","status":"running"}}"#

    private static func toolCallItem(raw: String?, isError: Bool?, toolName: String = "read_file") -> AgentChatItem {
        AgentChatItem(
            kind: .toolCall,
            text: "Using tool: \(toolName)",
            toolName: toolName,
            toolResultJSON: raw,
            toolIsError: isError
        )
    }
}
