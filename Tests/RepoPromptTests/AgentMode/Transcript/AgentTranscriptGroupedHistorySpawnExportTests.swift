import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AgentTranscriptGroupedHistorySpawnExportTests: XCTestCase {
    func testSpartanLogXMLIncludesAgentRunPreviewAndStatusForCollapsedGroupedHistory() throws {
        let transcript = try makeCollapsedSpawnTranscript(resultObject: [
            "session_id": "child-success-1",
            "session_name": "Worker Alpha",
            "status": "completed"
        ])

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        let summaryRange = try XCTUnwrap(xml.range(of: "<system>"))
        let toolCallRange = try XCTUnwrap(xml.range(of: "<tool_call name=\"agent_run\""))
        let toolResultRange = try XCTUnwrap(xml.range(of: "<tool_result name=\"agent_run\" status=\"success\"/>"))
        let statusRange = try XCTUnwrap(xml.range(of: "<system>Sub-agent Worker Alpha: completed</system>"))
        XCTAssertLessThan(summaryRange.lowerBound, toolCallRange.lowerBound)
        XCTAssertLessThan(toolCallRange.upperBound, toolResultRange.lowerBound)
        XCTAssertLessThan(toolResultRange.upperBound, statusRange.lowerBound)
    }

    func testSpartanLogXMLKeepsFailedAgentRunPreviewAndStatusForCollapsedGroupedHistory() throws {
        let transcript = try makeCollapsedSpawnTranscript(
            resultObject: [
                "session_id": "child-failed-1",
                "status": "failed"
            ],
            toolIsError: true,
            spawnSessionName: nil
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<tool_call name=\"agent_run\""))
        XCTAssertTrue(xml.contains("<tool_result name=\"agent_run\" status=\"failed\"/>"))
        XCTAssertTrue(xml.contains("<system>Sub-agent child-failed-1: failed</system>"))
    }

    func testSpartanLogXMLEmitsFailedToolResultForFreshFinalTurnRun() throws {
        let transcript = try makeFreshToolTranscript(
            toolName: "agent_run",
            resultObject: [
                "session_id": "child-failed-fresh-1",
                "status": "failed",
                "is_error": true
            ],
            toolIsError: true
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        let toolCallRange = try XCTUnwrap(xml.range(of: "<tool_call name=\"agent_run\""))
        let toolResultRange = try XCTUnwrap(xml.range(of: "<tool_result name=\"agent_run\" status=\"failed\"/>"))
        XCTAssertLessThan(toolCallRange.upperBound, toolResultRange.lowerBound)
    }

    func testSpartanLogXMLDropsToolCallAndToolResultAsPairWhenBudgetedOut() throws {
        let transcript = try makeFreshToolTranscript(
            toolName: "read_file",
            resultObject: ["status": "completed"],
            toolIsError: false
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 2,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<user>Run a tool</user>"))
        XCTAssertTrue(xml.contains("<assistant>Done.</assistant>"))
        XCTAssertFalse(xml.contains("<tool_call name=\"read_file\""))
        XCTAssertFalse(xml.contains("<tool_result name=\"read_file\""))
    }

    func testSpartanLogXMLDoesNotEmitToolResultForRunningToolResult() throws {
        let transcript = try makeFreshToolTranscript(
            toolName: "read_file",
            resultObject: ["status": "running"],
            toolIsError: false
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<tool_call name=\"read_file\""))
        XCTAssertFalse(xml.contains("<tool_result name=\"read_file\""))

        let item = try XCTUnwrap(
            RemoteTranscriptProjector(remoteSessionID: "remote-running-result")
                .projectGetLogResponse(.object([
                    "session_id": .string("remote-running-result"),
                    "turn_offset": .int(0),
                    "turn_limit": .int(20),
                    "returned_turn_count": .int(1),
                    "total_turns": .int(1),
                    "transcript_xml": .string(xml)
                ]))
                .items
                .first { $0.kind == .toolCall }
        )
        // Step 4d6: a result-less remote call renders neutral; run-scoped cancel eligibility is unchanged.
        XCTAssertNil(item.toolResultJSON)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .neutral)
        XCTAssertTrue(ToolCallCardStateResolver.allowsRunScopedCancel(for: item))
    }

    func testSpartanLogXMLEscapesHostileToolNameAttributesConsistently() throws {
        let hostileToolName = "hostile\" > & < tool"
        let sanitizedToolName = "hostile\"_>_&_<_tool"
        let escapedToolName = "hostile&quot;_&gt;_&amp;_&lt;_tool"
        let transcript = try makeFreshToolTranscript(
            toolName: hostileToolName,
            resultObject: ["status": "completed"],
            toolIsError: false
        )

        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertTrue(xml.contains("<tool_call name=\"\(escapedToolName)\">"))
        XCTAssertTrue(xml.contains("<tool_result name=\"\(escapedToolName)\" status=\"success\"/>"))
        XCTAssertFalse(xml.contains("<tool_call name=\"\(hostileToolName)"))
        XCTAssertFalse(xml.contains("<tool_result name=\"\(hostileToolName)"))

        let item = try XCTUnwrap(
            RemoteTranscriptProjector(remoteSessionID: "remote-hostile-tool-name")
                .projectGetLogResponse(.object([
                    "session_id": .string("remote-hostile-tool-name"),
                    "turn_offset": .int(0),
                    "turn_limit": .int(20),
                    "returned_turn_count": .int(1),
                    "total_turns": .int(1),
                    "transcript_xml": .string(xml)
                ]))
                .items
                .first { $0.kind == .toolCall }
        )
        XCTAssertEqual(item.toolName, sanitizedToolName)
        XCTAssertNotNil(item.toolResultJSON)
        XCTAssertNotEqual(ToolCallCardStateResolver.status(for: item), .running)
        XCTAssertEqual(ToolCallCardStateResolver.status(for: item), .success)
    }

    func testSpartanLogXMLAgentRunPreviewRoundTripsThroughRemoteTranscriptProjector() throws {
        let transcript = try makeCollapsedSpawnTranscript(resultObject: [
            "session_id": "child-roundtrip-1",
            "session_name": "Round Trip Worker",
            "status": "completed"
        ])
        let xml = AgentTranscriptIO.buildSpartanLogXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        let page = RemoteTranscriptProjector(remoteSessionID: "remote-spawn-roundtrip")
            .projectGetLogResponse(.object([
                "session_id": .string("remote-spawn-roundtrip"),
                "turn_offset": .int(0),
                "turn_limit": .int(20),
                "returned_turn_count": .int(1),
                "total_turns": .int(1),
                "transcript_xml": .string(xml)
            ]))

        XCTAssertTrue(page.items.contains { item in
            item.kind == .toolCall && item.toolName == "agent_run"
        })
    }

    func testDefaultHandoffExportDoesNotEmitGroupedHistorySpawnPreviewOrStatus() throws {
        let transcript = try makeCollapsedSpawnTranscript(resultObject: [
            "session_id": "child-handoff-1",
            "session_name": "Handoff Worker",
            "status": "completed"
        ])

        let xml = AgentTranscriptIO.buildForkTranscriptXML(
            from: transcript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )

        XCTAssertFalse(xml.contains("<tool_call name=\"agent_run\""))
        XCTAssertFalse(xml.contains("Sub-agent Handoff Worker: completed"))

        let failedTranscript = try makeCollapsedSpawnTranscript(
            resultObject: [
                "session_id": "child-handoff-failed-1",
                "status": "failed"
            ],
            toolIsError: true,
            spawnSessionName: nil
        )
        let failedXML = AgentTranscriptIO.buildForkTranscriptXML(
            from: failedTranscript,
            maxTranscriptItems: 100,
            maxToolArgsCharacters: 2000
        )
        XCTAssertFalse(failedXML.contains("<tool_call name=\"agent_run\""))
        XCTAssertFalse(failedXML.contains("Sub-agent child-handoff-failed-1: failed"))
    }

    #if DEBUG
        func testGroupedHistorySpawnPreviewUsesSpawnSourceRowInsideMixedChildBlock() throws {
            let readInvocationID = UUID()
            let spawnInvocationID = UUID()
            let spawnArgs = try jsonString([
                "message": "Investigate mixed child block",
                "session_name": "Mixed Worker"
            ])
            let rows: [AgentChatItem] = try [
                .toolCall(
                    name: "read_file",
                    invocationID: readInvocationID,
                    argsJSON: jsonString(["path": "/tmp/not-the-spawn.swift"]),
                    sequenceIndex: 0
                ),
                .toolCall(
                    name: "agent_run",
                    invocationID: spawnInvocationID,
                    argsJSON: spawnArgs,
                    sequenceIndex: 1
                ),
                .toolResult(
                    name: "agent_run",
                    invocationID: spawnInvocationID,
                    argsJSON: spawnArgs,
                    resultJSON: jsonString([
                        "session_id": "child-mixed-1",
                        "status": "completed"
                    ]),
                    sequenceIndex: 2
                )
            ]
            let childBlock = AgentTranscriptRenderBlock(
                id: "mixed-spawn-child",
                kind: .activityCluster,
                turnID: UUID(),
                retentionTier: .full,
                rows: rows,
                isArchived: false,
                activityIDs: rows.map(\.id)
            )

            let items = AgentTranscriptIO.debugGroupedHistorySpawnXMLItemsForTesting(from: childBlock)

            let toolCallItems = items.filter { $0.kind == .toolCall }
            XCTAssertEqual(toolCallItems.count, 1)
            let preview = try XCTUnwrap(toolCallItems.first)
            XCTAssertEqual(preview.toolName, "agent_run")
            XCTAssertTrue(preview.toolArgsJSON?.contains("\"session_name\":\"Mixed Worker\"") == true)
            XCTAssertFalse(items.contains { $0.kind == .toolCall && $0.toolName == "read_file" })
            XCTAssertTrue(items.contains { item in
                item.kind == .system && item.text == "Sub-agent Mixed Worker: completed"
            })
        }
    #endif

    private func makeFreshToolTranscript(
        toolName: String,
        resultObject: [String: Any],
        toolIsError: Bool
    ) throws -> AgentTranscript {
        let invocationID = UUID()
        let argsJSON = try jsonString(["path": "README.md"])
        let items: [AgentChatItem] = try [
            .user("Run a tool", sequenceIndex: 0),
            .toolCall(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                sequenceIndex: 1
            ),
            .toolResult(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: jsonString(resultObject),
                isError: toolIsError,
                sequenceIndex: 2
            ),
            .assistant("Done.", sequenceIndex: 3)
        ]
        return AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: 4,
            compact: false
        )
    }

    private func makeCollapsedSpawnTranscript(
        resultObject: [String: Any],
        toolIsError: Bool = false,
        spawnSessionName: String? = "Worker Alpha"
    ) throws -> AgentTranscript {
        var sequenceIndex = 0
        var items: [AgentChatItem] = []
        items.append(.user("Launch a sub-agent and continue", sequenceIndex: sequenceIndex))
        sequenceIndex += 1

        let spawnInvocationID = UUID()
        var spawnArgsObject = ["message": "Investigate S2"]
        if let spawnSessionName {
            spawnArgsObject["session_name"] = spawnSessionName
        }
        let spawnArgs = try jsonString(spawnArgsObject)
        items.append(.toolCall(
            name: "agent_run",
            invocationID: spawnInvocationID,
            argsJSON: spawnArgs,
            sequenceIndex: sequenceIndex
        ))
        sequenceIndex += 1
        try items.append(.toolResult(
            name: "agent_run",
            invocationID: spawnInvocationID,
            argsJSON: spawnArgs,
            resultJSON: jsonString(resultObject),
            isError: toolIsError,
            sequenceIndex: sequenceIndex
        ))
        sequenceIndex += 1

        for fillerIndex in 0 ..< 9 {
            let invocationID = UUID()
            try items.append(.toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: jsonString(["path": "/tmp/filler-\(fillerIndex).swift"]),
                sequenceIndex: sequenceIndex
            ))
            sequenceIndex += 1
            try items.append(.toolResult(
                name: "read_file",
                invocationID: invocationID,
                resultJSON: jsonString([
                    "content": "ok \(fillerIndex)",
                    "status": "completed"
                ]),
                sequenceIndex: sequenceIndex
            ))
            sequenceIndex += 1
        }

        items.append(.assistant("Completed the parent turn.", sequenceIndex: sequenceIndex))
        sequenceIndex += 1

        return AgentTranscriptIO.buildTranscript(
            from: items,
            terminalState: .completed,
            nextSequenceIndex: sequenceIndex,
            compact: false
        )
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
