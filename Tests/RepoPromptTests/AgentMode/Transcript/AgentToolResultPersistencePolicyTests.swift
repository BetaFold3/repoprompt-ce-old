import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AgentToolResultPersistencePolicyTests: XCTestCase {
    func testDelegatedQuestionNoticesSurviveSanitizationAndPersistenceSummary() throws {
        let notices: [[String: String]] = [[
            "kind": "delegated_question",
            "child_session_id": UUID().uuidString,
            "interaction_id": UUID().uuidString,
            "text": String(repeating: "Question content the model saw. ", count: 100)
        ]]
        for toolName in ["read_file", "agent_run", "ask_oracle", "prompt"] {
            let raw = jsonString([
                "status": "running",
                "session_id": UUID().uuidString,
                "contents": String(repeating: "unrelated file body ", count: 500),
                AgentDelegatedQuestionNoticeWire.resultKey: notices
            ])
            let item = AgentChatItem.toolResult(name: toolName, resultJSON: raw, isError: false)
            let sanitized = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: item))
            let sanitizedObject = try decodedObject(XCTUnwrap(sanitized.resultJSON))
            XCTAssertEqual(
                sanitizedObject[AgentDelegatedQuestionNoticeWire.resultKey] as? [[String: String]],
                notices, toolName
            )
            let persisted = try XCTUnwrap(persistedSummary(toolName: toolName, rawResultJSON: raw))
            let object = try decodedObject(persisted.resultJSON)
            XCTAssertEqual(
                object[AgentDelegatedQuestionNoticeWire.resultKey] as? [[String: String]],
                notices, toolName
            )
            XCTAssertNil(object["contents"], "Only the delivered notice bypasses ordinary summary truncation")
            let again = try XCTUnwrap(persistedSummary(toolName: toolName, rawResultJSON: persisted.resultJSON))
            XCTAssertEqual(
                try decodedObject(again.resultJSON)[AgentDelegatedQuestionNoticeWire.resultKey] as? [[String: String]],
                notices, toolName
            )
        }
    }

    func testDelegatedQuestionNoticesSurviveNonObjectSummaries() throws {
        let notices: [[String: String]] = [[
            "kind": "delegated_question",
            "child_session_id": UUID().uuidString,
            "interaction_id": UUID().uuidString,
            "text": "Which branch should I use?"
        ]]
        let cases: [(summary: String, matches: (Any?) -> Bool)] = [
            ("[\"a\",\"b\"]", { ($0 as? [String]) == ["a", "b"] }),
            ("\"done\"", { ($0 as? String) == "done" }),
            ("42", { ($0 as? Int) == 42 }),
            ("plain text summary", { ($0 as? String) == "plain text summary" })
        ]
        for row in cases {
            let wrapped = AgentToolResultPersistencePolicy.preservingDelegatedQuestionNotices(notices, in: row.summary)
            let object = try decodedObject(wrapped)
            XCTAssertEqual(
                object[AgentDelegatedQuestionNoticeWire.resultKey] as? [[String: String]],
                notices, row.summary
            )
            XCTAssertTrue(row.matches(object["summary"]), "Non-object summary is kept under `summary`: \(row.summary)")
        }
        let objectSummary = AgentToolResultPersistencePolicy.preservingDelegatedQuestionNotices(
            notices,
            in: jsonString(["status": "success"])
        )
        let object = try decodedObject(objectSummary)
        XCTAssertEqual(object["status"] as? String, "success")
        XCTAssertNil(object["summary"], "Object summaries keep their shape and gain only the notice sibling")
    }

    func testDelegatedQuestionNoticeStrippingKeepsDistinctRenderedText() throws {
        let notices: [[String: String]] = [[
            "kind": "delegated_question",
            "child_session_id": UUID().uuidString,
            "interaction_id": UUID().uuidString,
            "text": "Which branch should I use?"
        ]]
        for toolName in ["read_file", "ask_user", "bash"] {
            let base: [String: Any] = ["status": "success", "contents": "file body"]
            var withNotices = base
            withNotices[AgentDelegatedQuestionNoticeWire.resultKey] = notices
            let renderedText = "Rendered presentation distinct from the raw JSON"

            var plain = AgentChatItem.toolResult(name: toolName, resultJSON: jsonString(base), isError: false)
            plain.text = renderedText
            var delivered = AgentChatItem.toolResult(name: toolName, resultJSON: jsonString(withNotices), isError: false)
            delivered.text = renderedText

            let plainResult = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: plain))
            let deliveredResult = try XCTUnwrap(AgentToolResultPersistencePolicy.sanitizedToolResult(for: delivered))
            var deliveredObject = try decodedObject(XCTUnwrap(deliveredResult.resultJSON))
            XCTAssertEqual(
                deliveredObject.removeValue(forKey: AgentDelegatedQuestionNoticeWire.resultKey) as? [[String: String]],
                notices, toolName
            )
            XCTAssertEqual(
                jsonString(deliveredObject),
                try jsonString(decodedObject(XCTUnwrap(plainResult.resultJSON))),
                "Notice stripping must summarize exactly what the same item without notices would, \(toolName)"
            )
            XCTAssertEqual(deliveredResult.transcriptStatus, plainResult.transcriptStatus, toolName)
            XCTAssertEqual(deliveredResult.summaryOnly, plainResult.summaryOnly, toolName)
        }
    }

    func testConfirmedOracleSendToolNamesPersistBoundedStructuredSummaries() throws {
        let rows: [(toolName: String, receivesOracleMetadata: Bool)] = [
            ("ask_oracle", true),
            ("oracle_send", true),
            ("chat_send", false)
        ]

        for row in rows {
            let rawResponse = String(repeating: "oracle raw response ", count: 40)
            let rawError = String(repeating: "raw oracle error ", count: 20)
            let rawDiff = "diff --git a/File.swift b/File.swift\n@@ -1 +1 @@\n-old\n+new"
            let raw = jsonString([
                "status": "success",
                "chat_id": "chat-123",
                "mode": "review",
                "ui_model_id": "provider-model-id",
                "ui_model_name": "Resolved Provider Model",
                "model_selection": "explicit",
                "model_source": "preset",
                "model_preset_id": "11111111-2222-3333-4444-555555555555",
                "model_preset_name": "Claude_Fable_xhigh",
                "response": rawResponse,
                "diffs": [["path": "File.swift", "diff": rawDiff]],
                "errors": [rawError]
            ])

            let summary = try XCTUnwrap(persistedSummary(toolName: row.toolName, rawResultJSON: raw))
            let object = try decodedObject(summary.resultJSON)

            XCTAssertEqual(object["status"] as? String, "success", row.toolName)
            XCTAssertTrue(summary.summaryOnly, row.toolName)
            XCTAssertEqual(object["summary_only"] as? Bool, true, row.toolName)
            if row.receivesOracleMetadata {
                XCTAssertEqual(object["chat_id"] as? String, "chat-123", row.toolName)
                XCTAssertEqual(object["mode"] as? String, "review", row.toolName)
                XCTAssertNil(object["model_id"], row.toolName)
                XCTAssertNil(object["model_name"], row.toolName)
                XCTAssertEqual(object["model_selection"] as? String, "explicit", row.toolName)
                XCTAssertEqual(object["model_source"] as? String, "preset", row.toolName)
                XCTAssertEqual(
                    object["model_preset_id"] as? String,
                    "11111111-2222-3333-4444-555555555555",
                    row.toolName
                )
                XCTAssertEqual(object["model_preset_name"] as? String, "Claude_Fable_xhigh", row.toolName)
                XCTAssertEqual(object["has_response"] as? Bool, true, row.toolName)
                XCTAssertEqual(object["diff_count"] as? Int, 1, row.toolName)
                XCTAssertEqual(object["error_count"] as? Int, 1, row.toolName)
                // A result carrying `errors[]` is failed under the Oracle card's trusted resolution
                // (`OracleToolCardPresentation.state`), so the summary keeps the redacted, bounded
                // primary diagnostic and a `Failed:` headline (failure-inspection plan B3).
                let retainedError = rawError.trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertEqual(
                    object["errors"] as? [[String: String]],
                    [["message": retainedError]],
                    row.toolName
                )
                XCTAssertNil(object["error_truncated"], row.toolName)
                XCTAssertEqual(
                    object["summary_text"] as? String,
                    OracleToolResultInspection.truncatedUTF8(
                        "Failed: " + retainedError,
                        maxBytes: OracleToolResultInspection.summaryTextMaxBytes
                    ).text,
                    row.toolName
                )

                var successObject = try decodedObject(raw)
                successObject.removeValue(forKey: "errors")
                let successSummary = try XCTUnwrap(
                    persistedSummary(toolName: row.toolName, rawResultJSON: jsonString(successObject))
                )
                let successSummaryObject = try decodedObject(successSummary.resultJSON)
                XCTAssertEqual(
                    successSummaryObject["summary_text"] as? String,
                    "review • Claude_Fable_xhigh • 1 diff",
                    row.toolName
                )
                XCTAssertNil(successSummaryObject["errors"], row.toolName)
                XCTAssertNil(successSummaryObject["error_count"], row.toolName)
                XCTAssertNil(successSummaryObject["error_truncated"], row.toolName)

                let uiIdentityJSON = try XCTUnwrap(
                    AgentToolResultPersistencePolicy.uiFacingOracleIdentityJSON(
                        toolName: row.toolName,
                        rawResultJSON: raw
                    )
                )
                let uiIdentity = try decodedObject(uiIdentityJSON)
                XCTAssertEqual(uiIdentity["ui_model_id"] as? String, "provider-model-id", row.toolName)
                XCTAssertEqual(uiIdentity["ui_model_name"] as? String, "Resolved Provider Model", row.toolName)
                XCTAssertNil(uiIdentity["model_id"], row.toolName)
                XCTAssertNil(uiIdentity["model_name"], row.toolName)

                if row.toolName == "ask_oracle" {
                    let item = AgentChatItem.toolResult(
                        name: row.toolName,
                        resultJSON: raw,
                        isError: false
                    )
                    let transcript = AgentTranscriptIO.buildTranscript(
                        from: [item],
                        nextSequenceIndex: 1,
                        policy: .canonical
                    )
                    let compactTranscript = AgentToolResultPersistencePolicy
                        .sanitizeTranscriptForPersistence(transcript)
                    let compactData = try JSONEncoder().encode(compactTranscript)
                    let compactJSON = String(decoding: compactData, as: UTF8.self)
                    XCTAssertFalse(compactJSON.contains("provider-model-id"), compactJSON)
                    XCTAssertFalse(compactJSON.contains("Resolved Provider Model"), compactJSON)

                    let handoff = AgentTranscriptIO.buildForkTranscriptXML(from: compactTranscript)
                    XCTAssertFalse(handoff.contains("provider-model-id"), handoff)
                    XCTAssertFalse(handoff.contains("Resolved Provider Model"), handoff)

                    let persistedSession = AgentSession(
                        items: [],
                        uiToolResultPayloadsByItemID: [item.id.uuidString: uiIdentityJSON],
                        transcript: compactTranscript
                    )
                    let persistedData = try JSONEncoder().encode(persistedSession)
                    let restoredSession = try JSONDecoder().decode(AgentSession.self, from: persistedData)
                    XCTAssertEqual(
                        restoredSession.uiToolResultPayloadsByItemID[item.id.uuidString],
                        uiIdentityJSON
                    )
                }
            } else {
                XCTAssertNil(object["chat_id"], row.toolName)
                XCTAssertNil(object["mode"], row.toolName)
                XCTAssertNil(object["model_id"], row.toolName)
                XCTAssertNil(object["model_name"], row.toolName)
                XCTAssertNil(object["model_selection"], row.toolName)
                XCTAssertNil(object["model_source"], row.toolName)
                XCTAssertNil(object["model_preset_id"], row.toolName)
                XCTAssertNil(object["model_preset_name"], row.toolName)
                XCTAssertNil(object["has_response"], row.toolName)
                XCTAssertNil(object["diff_count"], row.toolName)
                XCTAssertNil(object["error_count"], row.toolName)
                XCTAssertEqual(object["summary_text"] as? String, "chat_send • success", row.toolName)
                XCTAssertNil(object["errors"], row.toolName)
                XCTAssertFalse(summary.resultJSON.contains(rawError), row.toolName)
            }
            XCTAssertNil(object["response"], row.toolName)
            XCTAssertNil(object["diffs"], row.toolName)
            XCTAssertFalse(summary.resultJSON.contains(rawResponse), row.toolName)
            XCTAssertFalse(summary.resultJSON.contains(rawDiff), row.toolName)
            XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes, row.toolName)
        }

        let nonPresetRaw = jsonString([
            "status": "success",
            "chat_id": "planning-chat",
            "mode": "plan",
            "model_id": "planning-model-id",
            "model_name": "Planning Model",
            "model_selection": "explicit",
            "model_source": "planning_model",
            "response": "done"
        ])
        let nonPresetSummary = try XCTUnwrap(
            persistedSummary(toolName: "ask_oracle", rawResultJSON: nonPresetRaw)
        )
        let nonPresetObject = try decodedObject(nonPresetSummary.resultJSON)
        XCTAssertEqual(nonPresetObject["model_id"] as? String, "planning-model-id")
        XCTAssertEqual(nonPresetObject["model_name"] as? String, "Planning Model")
        XCTAssertNil(
            AgentToolResultPersistencePolicy.uiFacingOracleIdentityJSON(
                toolName: "ask_oracle",
                rawResultJSON: nonPresetRaw
            )
        )
    }

    func testContextBuilderPersistsOnlySelectedBoundedFollowUpRoutingMetadata() throws {
        let rows: [(responseType: String, persistedResponseType: String, selectedKey: String, chatID: String, mode: String)] = [
            ("plan", "plan", "plan", "plan-chat", "plan"),
            ("question", "question", "plan", "plan-chat", "plan"),
            ("review", "review", "review", "review-chat", "review"),
            ("  PlAn\n", "PlAn", "plan", "plan-chat", "plan"),
            ("\tReViEw ", "ReViEw", "review", "review-chat", "review")
        ]

        for row in rows {
            let bulkyResponse = String(repeating: "generated response ", count: 200)
            let bulkyDiff = String(repeating: "diff --git a/File.swift b/File.swift\n", count: 100)
            let raw = jsonString([
                "status": "success",
                "context_id": "11111111-2222-3333-4444-555555555555",
                "response_type": row.responseType,
                "plan": [
                    "chat_id": "plan-chat",
                    "mode": "plan",
                    "response": bulkyResponse,
                    "diffs": [["path": "File.swift", "patch": bulkyDiff]],
                    "errors": ["plan error"]
                ],
                "review": [
                    "chat_id": "review-chat",
                    "mode": "review",
                    "response": bulkyResponse,
                    "diffs": [["path": "File.swift", "patch": bulkyDiff]],
                    "errors": ["review error"]
                ]
            ])

            let summary = try XCTUnwrap(persistedSummary(toolName: "context_builder", rawResultJSON: raw))
            let object = try decodedObject(summary.resultJSON)
            let selectedReply = try XCTUnwrap(object[row.selectedKey] as? [String: Any])
            let unselectedKey = row.selectedKey == "plan" ? "review" : "plan"
            let dto = try XCTUnwrap(ToolJSON.decode(
                ToolResultDTOs.ContextBuilderDTO.self,
                from: summary.resultJSON
            ))
            let selectedDTO = row.selectedKey == "plan" ? dto.plan : dto.review

            XCTAssertTrue(summary.summaryOnly, row.responseType)
            XCTAssertEqual(object["status"] as? String, "success", row.responseType)
            XCTAssertEqual(object["summary_only"] as? Bool, true, row.responseType)
            XCTAssertEqual(object["context_id"] as? String, "11111111-2222-3333-4444-555555555555", row.responseType)
            XCTAssertEqual(object["response_type"] as? String, row.persistedResponseType, row.responseType)
            XCTAssertEqual(selectedReply["chat_id"] as? String, row.chatID, row.responseType)
            XCTAssertEqual(selectedReply["mode"] as? String, row.mode, row.responseType)
            XCTAssertNil(selectedReply["response"], row.responseType)
            XCTAssertNil(selectedReply["diffs"], row.responseType)
            XCTAssertNil(selectedReply["errors"], row.responseType)
            XCTAssertNil(object[unselectedKey], row.responseType)
            XCTAssertEqual(dto.tabID, "11111111-2222-3333-4444-555555555555", row.responseType)
            XCTAssertEqual(dto.responseType, row.persistedResponseType, row.responseType)
            XCTAssertEqual(selectedDTO?.chatID, row.chatID, row.responseType)
            XCTAssertEqual(selectedDTO?.mode, row.mode, row.responseType)
            XCTAssertFalse(summary.resultJSON.contains(bulkyResponse), row.responseType)
            XCTAssertFalse(summary.resultJSON.contains(bulkyDiff), row.responseType)
            XCTAssertLessThanOrEqual(
                summary.resultJSON.utf8.count,
                AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
                row.responseType
            )
        }
    }

    func testCursorContextBuilderPersistenceReloadPreservesSelectedOracleIdentity() throws {
        let rows: [(responseType: String, selectedKey: String, chatID: String, mode: String)] = [
            ("plan", "plan", "cursor-plan-chat", "plan"),
            ("question", "plan", "cursor-plan-chat", "plan"),
            ("review", "review", "cursor-review-chat", "review")
        ]

        for row in rows {
            let bulkyResponse = String(repeating: "cursor generated response ", count: 200)
            let events = CursorACPEventNormalizer.normalize([
                "sessionUpdate": "tool_call_update",
                "status": "completed",
                "toolCallId": "cursor-context-builder-\(row.responseType)",
                "toolName": "context_builder",
                "kind": "message",
                "title": "Context builder result",
                "rawOutput": [
                    "status": "success",
                    "context_id": "11111111-2222-3333-4444-555555555555",
                    "response_type": row.responseType,
                    "plan": [
                        "chat_id": "cursor-plan-chat",
                        "mode": "plan",
                        "response": bulkyResponse
                    ],
                    "review": [
                        "chat_id": "cursor-review-chat",
                        "mode": "review",
                        "response": bulkyResponse
                    ]
                ],
                "content": [[
                    "type": "text",
                    "text": "cursor acp context builder payload"
                ]]
            ])
            guard case let .stream(result) = try XCTUnwrap(events.first) else {
                return XCTFail("Expected normalized Cursor ACP stream event for \(row.responseType)")
            }
            let raw = try XCTUnwrap(result.toolResultJSON)
            let item = AgentChatItem.toolResult(
                name: "context_builder",
                resultJSON: raw,
                isError: false
            )
            let persistedData = try JSONEncoder().encode(AgentChatItemPersist(from: item))
            let restored = try JSONDecoder().decode(AgentChatItemPersist.self, from: persistedData).toItem()
            let restoredJSON = try XCTUnwrap(restored.toolResultJSON)
            let object = try decodedObject(restoredJSON)
            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: restoredJSON))
            let selectedDTO = row.selectedKey == "plan" ? dto.plan : dto.review

            XCTAssertEqual(dto.tabID, "11111111-2222-3333-4444-555555555555", row.responseType)
            XCTAssertEqual(dto.responseType, row.responseType, row.responseType)
            XCTAssertEqual(selectedDTO?.chatID, row.chatID, row.responseType)
            XCTAssertEqual(selectedDTO?.mode, row.mode, row.responseType)
            XCTAssertNil(object[row.selectedKey == "plan" ? "review" : "plan"], row.responseType)
            XCTAssertFalse(restoredJSON.contains(bulkyResponse), row.responseType)
            XCTAssertLessThanOrEqual(
                restoredJSON.utf8.count,
                AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
                row.responseType
            )
        }
    }

    func testContextBuilderPersistenceRejectsUnknownMissingAndMismatchedResponseBranch() throws {
        let rows: [(payload: [String: Any], expectedResponseType: String?)] = [
            ([
                "status": "success",
                "response_type": "review",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ], "review"),
            ([
                "status": "success",
                "response_type": "plan",
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ], "plan"),
            ([
                "status": "success",
                "response_type": "clarify",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"],
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ], "clarify"),
            ([
                "status": "success",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"],
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ], nil)
        ]

        for row in rows {
            let raw = jsonString(row.payload)
            let summary = try XCTUnwrap(persistedSummary(toolName: "context_builder", rawResultJSON: raw))
            let dto = try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: summary.resultJSON))

            XCTAssertEqual(dto.responseType, row.expectedResponseType)
            XCTAssertNil(dto.plan)
            XCTAssertNil(dto.review)
        }
    }

    func testOversizedStructuredSummaryFallsBackToMinimalResultJSON() throws {
        let oversizedReviewStatus = String(repeating: "approved-with-a-very-long-note-", count: 120)
        let raw = jsonString([
            "status": "success",
            "edits_requested": 1,
            "edits_applied": 1,
            "review_status": oversizedReviewStatus
        ])

        let summary = try XCTUnwrap(persistedSummary(toolName: "apply_edits", rawResultJSON: raw))
        let object = try decodedObject(summary.resultJSON)

        XCTAssertEqual(object["status"] as? String, "success")
        XCTAssertEqual(object["summary_only"] as? Bool, true)
        XCTAssertNil(object["review_status"])
        XCTAssertFalse(summary.resultJSON.contains(oversizedReviewStatus))
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
    }

    func testAgentManagePersistsSmallDeleteAndSkipCounts() throws {
        let raw = jsonString([
            "status": "success",
            "deleted_sessions": ["a", "b", "c"],
            "skipped_sessions": ["d", "e"],
            "agent": ["id": "agent-1", "name": "Pair Programmer"],
            "sessions": [["name": "raw-session", "state": "closed"]]
        ])

        let summary = try XCTUnwrap(persistedSummary(toolName: "agent_manage", rawResultJSON: raw))
        let object = try decodedObject(summary.resultJSON)

        XCTAssertEqual(object["status"] as? String, "success")
        XCTAssertEqual(object["summary_only"] as? Bool, true)
        XCTAssertEqual(object["deleted_count"] as? Int, 3)
        XCTAssertEqual(object["skipped_count"] as? Int, 2)
        XCTAssertEqual(object["summary_text"] as? String, "3 deleted, 2 skipped")
        XCTAssertNil(object["deleted_sessions"])
        XCTAssertNil(object["skipped_sessions"])
        XCTAssertNil(object["agent"])
        XCTAssertNil(object["sessions"])
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
    }

    func testAgentLifecycleWaitPolicyPersistsCanonicalMetadataOnly() throws {
        let lifecycleRows: [(toolName: String, policy: [String: Any], expected: [String: Any])] = [
            (
                "agent_run",
                [
                    "mode": "automatic",
                    "timeout_seconds": 420,
                    "parent_family": "codex",
                    "arbitrary": ["secret": "drop-me"]
                ],
                ["mode": "automatic", "timeout_seconds": 420, "parent_family": "codex"]
            ),
            (
                "agent_explore",
                ["mode": "explicit", "timeout_seconds": 90, "arbitrary": true],
                ["mode": "explicit", "timeout_seconds": 90]
            ),
            (
                "agent_run",
                ["mode": "poll", "timeout_seconds": 0, "arbitrary": ["drop": true]],
                ["mode": "poll", "timeout_seconds": 0]
            )
        ]
        for row in lifecycleRows {
            let lifecycleRaw = jsonString([
                "status": "completed",
                "wait_policy": row.policy
            ])
            try XCTAssertNotNil(
                AgentMCPWaitPolicy.canonicalMetadata(from: decodedObject(lifecycleRaw)),
                row.toolName
            )
            let lifecycleSummary = try XCTUnwrap(
                persistedSummary(toolName: row.toolName, rawResultJSON: lifecycleRaw)
            )
            let lifecycleObject = try decodedObject(lifecycleSummary.resultJSON)
            let persistedPolicy = try XCTUnwrap(
                lifecycleObject["wait_policy"] as? [String: Any],
                "\(row.toolName): \(lifecycleSummary.resultJSON)"
            )
            XCTAssertEqual(persistedPolicy as NSDictionary, row.expected as NSDictionary, row.toolName)
            XCTAssertNil(persistedPolicy["arbitrary"], row.toolName)
        }

        let malformedPolicies: [[String: Any]] = [
            [
                "mode": "automatic",
                "timeout_seconds": 180,
                "parent_family": "legacy-unknown"
            ],
            [
                "mode": "automatic",
                "timeout_seconds": true,
                "parent_family": "codex"
            ],
            [
                "mode": "automatic",
                "timeout_seconds": -1,
                "parent_family": "codex"
            ],
            [
                "mode": "automatic",
                "timeout_seconds": 14401,
                "parent_family": "codex"
            ]
        ]
        for policy in malformedPolicies {
            let malformedLifecycleRaw = jsonString([
                "status": "completed",
                "wait_policy": policy
            ])
            let malformedObject = try decodedObject(malformedLifecycleRaw)
            XCTAssertNil(AgentMCPWaitPolicy.canonicalMetadata(from: malformedObject))
            let malformedLifecycleSummary = try XCTUnwrap(
                persistedSummary(toolName: "agent_run", rawResultJSON: malformedLifecycleRaw)
            )
            XCTAssertNil(try decodedObject(malformedLifecycleSummary.resultJSON)["wait_policy"])
        }

        XCTAssertNil(AgentMCPWaitPolicy.canonicalMetadata(from: [
            "wait_policy": [
                "mode": "automatic",
                "timeout_seconds": Double.infinity,
                "parent_family": "codex"
            ]
        ]))

        let bulkyText = String(repeating: "bulky lifecycle field ", count: 400)
        let oversizedLifecycleRaw = jsonString([
            "status": "completed",
            "wait_policy": [
                "mode": "automatic",
                "timeout_seconds": 420,
                "parent_family": "codex"
            ],
            "assistant_text": bulkyText,
            "note": bulkyText,
            "reason": bulkyText,
            "status_text": bulkyText,
            "workflow_name": bulkyText,
            "session": ["id": "session-1", "name": bulkyText],
            "agent": ["id": "codex", "name": bulkyText, "model": bulkyText],
            "interaction": ["id": "interaction-1", "kind": "question", "prompt": bulkyText],
            "_meta": ["delivery": bulkyText]
        ])
        XCTAssertGreaterThan(
            oversizedLifecycleRaw.utf8.count,
            AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes
        )

        let oversizedLifecycleSummary = try XCTUnwrap(
            persistedSummary(toolName: "agent_run", rawResultJSON: oversizedLifecycleRaw)
        )
        let oversizedLifecycleObject = try decodedObject(oversizedLifecycleSummary.resultJSON)
        XCTAssertEqual(oversizedLifecycleObject["status"] as? String, "completed")
        XCTAssertEqual(oversizedLifecycleObject["summary_only"] as? Bool, true)
        XCTAssertEqual(
            oversizedLifecycleObject["wait_policy"] as? NSDictionary,
            [
                "mode": "automatic",
                "timeout_seconds": 420,
                "parent_family": "codex"
            ] as NSDictionary
        )
        for omittedKey in [
            "assistant_text",
            "note",
            "reason",
            "status_text",
            "workflow_name",
            "session",
            "agent",
            "interaction",
            "_meta"
        ] {
            XCTAssertNil(oversizedLifecycleObject[omittedKey], omittedKey)
        }
        XCTAssertLessThanOrEqual(
            oversizedLifecycleSummary.resultJSON.utf8.count,
            AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes
        )
    }

    func testCursorACPStructuredSummaryKeepsChatIDForAllowedOracleTools() throws {
        for toolName in ["ask_oracle", "oracle_send"] {
            let events = CursorACPEventNormalizer.normalize([
                "sessionUpdate": "tool_call_update",
                "status": "completed",
                "toolCallId": "oracle-routing-\(toolName)",
                "toolName": toolName,
                "kind": "message",
                "title": "Tool result",
                "rawOutput": [
                    "chat_id": "  chat-789  ",
                    "mode": "review",
                    "response": "raw oracle response",
                    "diffs": [["path": 42]]
                ],
                "content": [[
                    "type": "text",
                    "text": "cursor acp text payload"
                ]]
            ])
            guard case let .stream(result) = try XCTUnwrap(events.first) else {
                return XCTFail("Expected normalized Cursor ACP stream event for \(toolName)")
            }
            let raw = try XCTUnwrap(result.toolResultJSON)
            let summary = try XCTUnwrap(persistedSummary(toolName: toolName, rawResultJSON: raw))
            let object = try decodedObject(summary.resultJSON)
            let content = try XCTUnwrap(object["content"] as? [[String: Any]])
            let firstContent = try XCTUnwrap(content.first)

            XCTAssertEqual(object["acp_status"] as? String, "completed", toolName)
            XCTAssertEqual(object["kind"] as? String, "message", toolName)
            XCTAssertEqual(object["chat_id"] as? String, "chat-789", toolName)
            XCTAssertEqual(firstContent["text_bytes"] as? Int, "cursor acp text payload".utf8.count, toolName)
            XCTAssertNil(object["mode"], toolName)
            XCTAssertNil(object["has_response"], toolName)
            XCTAssertNil(object["response"], toolName)
            XCTAssertFalse(summary.resultJSON.contains("raw oracle response"), toolName)
            XCTAssertLessThanOrEqual(
                summary.resultJSON.utf8.count,
                AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes,
                toolName
            )
        }

        let invalidRawOutputs: [[String: Any]] = [
            ["result": ["chat_id": "nested-only"]],
            ["chatID": "camel-only"],
            ["chat_id": 42],
            ["chat_id": "  \n"],
            ["chat_id": "authoritative", "result": ["chat_id": "conflict"]],
            ["chat_id": "authoritative", "items": [["chatID": "conflict"]]]
        ]
        for rawOutput in invalidRawOutputs {
            let events = CursorACPEventNormalizer.normalize([
                "sessionUpdate": "tool_call_update",
                "status": "completed",
                "toolCallId": "oracle-routing-invalid",
                "toolName": "ask_oracle",
                "kind": "message",
                "rawOutput": rawOutput
            ])
            guard case let .stream(result) = try XCTUnwrap(events.first) else {
                return XCTFail("Expected normalized Cursor ACP stream event")
            }
            let raw = try XCTUnwrap(result.toolResultJSON)
            let item = AgentChatItem.toolResult(name: "ask_oracle", resultJSON: raw, isError: false)
            let restored = AgentChatItemPersist(from: item).toItem()
            let restoredObject = try decodedObject(XCTUnwrap(restored.toolResultJSON))

            XCTAssertNil(restoredObject["chat_id"])
            XCTAssertNil(oracleToolResultPopoverUserInfo(
                item: restored,
                openContext: AgentOracleOpenContext(
                    windowID: 1,
                    workspaceID: UUID(),
                    tabID: UUID()
                )
            ))
        }
    }

    func testCompletionOnlyToolResultFactoryPreservesArgsForPersistenceClassification() throws {
        let args = jsonString([
            "action": "find_in_page",
            "url": "https://example.com/docs",
            "pattern": "install"
        ])
        let invocationID = UUID()
        let raw = jsonString(["status": "completed", "match_count": 2])
        let item = AgentChatItem.toolResult(
            name: "search",
            invocationID: invocationID,
            argsJSON: args,
            resultJSON: raw,
            isError: false,
            sequenceIndex: 42
        )

        XCTAssertEqual(item.toolInvocationID, invocationID)
        XCTAssertEqual(item.toolArgsJSON, args)
        XCTAssertEqual(item.toolResultJSON, raw)
        XCTAssertEqual(item.toolIsError, false)
        XCTAssertEqual(item.sequenceIndex, 42)
        let persisted = AgentChatItemPersist(from: item)
        let object = try decodedObject(XCTUnwrap(persisted.toolResultJSON))
        let renderSummary = try XCTUnwrap(object["render_summary"] as? [String: Any])
        XCTAssertEqual(renderSummary["title"] as? String, "Find In Page")
        XCTAssertEqual(renderSummary["op"] as? String, "find_in_page")
    }

    func testWebSearchPersistsBoundedSummaryOnlySuccessPresentation() throws {
        let bulkySnippet = String(repeating: "full page body ", count: 80)
        let raw = jsonString([
            "status": "completed",
            "query": "native web search cards",
            "results": [[
                "title": "Native Web Search Cards",
                "url": "https://example.com/search-cards",
                "snippet": bulkySnippet
            ]],
            "sources": [["title": "Plan", "url": "https://example.com/plan"]]
        ])
        let args = jsonString(["query": "native web search cards"])

        let summary = try XCTUnwrap(persistedSummary(toolName: "search", rawResultJSON: raw, argsJSON: args))
        let object = try decodedObject(summary.resultJSON)
        let renderSummary = try XCTUnwrap(object["render_summary"] as? [String: Any])
        let restored = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: summary.resultJSON))

        XCTAssertTrue(summary.summaryOnly)
        XCTAssertEqual(object["summary_only"] as? Bool, true)
        XCTAssertEqual(renderSummary["tool_name"] as? String, "search")
        XCTAssertEqual(renderSummary["title"] as? String, "Web Search")
        XCTAssertEqual(renderSummary["status"] as? String, "success")
        XCTAssertTrue((renderSummary["subtitle"] as? String)?.contains("native web search cards") == true)
        XCTAssertTrue((renderSummary["subtitle"] as? String)?.contains("1 result") == true)
        XCTAssertTrue((renderSummary["subtitle"] as? String)?.contains("1 source") == true)
        XCTAssertEqual(restored.title, "Web Search")
        XCTAssertEqual(restored.status, .success)
        XCTAssertFalse(summary.resultJSON.contains(bulkySnippet))
        XCTAssertNil(object["results"])
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
    }

    func testWebReadAndFindPersistActionAwareSummaryOnlyPresentations() throws {
        let readRaw = jsonString([
            "status": "completed",
            "title": "RepoPrompt docs",
            "content": String(repeating: "full page body ", count: 80)
        ])
        let readArgs = jsonString(["url": "https://docs.example.com/a/b/c"])
        let readSummary = try XCTUnwrap(persistedSummary(toolName: "webfetch", rawResultJSON: readRaw, argsJSON: readArgs))
        let readObject = try decodedObject(readSummary.resultJSON)
        let readRenderSummary = try XCTUnwrap(readObject["render_summary"] as? [String: Any])
        XCTAssertEqual(readRenderSummary["tool_name"] as? String, "web_read")
        XCTAssertEqual(readRenderSummary["title"] as? String, "Read Web Page")
        XCTAssertEqual(readRenderSummary["subtitle"] as? String, "docs.example.com/…/c")
        XCTAssertEqual(readRenderSummary["detail_text"] as? String, "RepoPrompt docs")
        XCTAssertFalse(readSummary.resultJSON.contains("full page body"))

        let bodySummaryRaw = jsonString([
            "status": "completed",
            "summary": String(repeating: "page body ", count: 80)
        ])
        let bodySummary = try XCTUnwrap(persistedSummary(toolName: "webfetch", rawResultJSON: bodySummaryRaw, argsJSON: readArgs))
        XCTAssertFalse(bodySummary.resultJSON.contains("page body"))

        let findRaw = jsonString(["status": "completed", "match_count": 3])
        let findArgs = jsonString(["url": "https://example.com/docs", "pattern": "needle"])
        let findSummary = try XCTUnwrap(persistedSummary(toolName: "search", rawResultJSON: findRaw, argsJSON: findArgs))
        let findObject = try decodedObject(findSummary.resultJSON)
        let findRenderSummary = try XCTUnwrap(findObject["render_summary"] as? [String: Any])
        XCTAssertEqual(findRenderSummary["tool_name"] as? String, "search")
        XCTAssertEqual(findRenderSummary["title"] as? String, "Find In Page")
        XCTAssertEqual(findRenderSummary["op"] as? String, "find_in_page")
        XCTAssertEqual(findRenderSummary["detail_text"] as? String, "3 matches")
        let restored = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: findSummary.resultJSON))
        XCTAssertEqual(restored.title, "Find In Page")
    }

    func testWebSearchPersistsBoundedSummaryOnlyErrorPresentation() throws {
        let raw = jsonString([
            "status": "failed",
            "query": "native web search cards",
            "error": ["message": "web search unavailable"]
        ])
        let args = jsonString(["query": "native web search cards"])

        let summary = try XCTUnwrap(persistedSummary(toolName: "web_search", rawResultJSON: raw, argsJSON: args))
        let object = try decodedObject(summary.resultJSON)
        let renderSummary = try XCTUnwrap(object["render_summary"] as? [String: Any])
        let restored = try XCTUnwrap(StoredToolCardPresentation.fromSummaryOnly(raw: summary.resultJSON))

        XCTAssertTrue(summary.summaryOnly)
        XCTAssertEqual(renderSummary["tool_name"] as? String, "search")
        XCTAssertEqual(renderSummary["title"] as? String, "Web Search")
        XCTAssertEqual(renderSummary["status"] as? String, "failure")
        XCTAssertTrue((renderSummary["detail_text"] as? String)?.contains("web search unavailable") == true)
        XCTAssertEqual(restored.title, "Web Search")
        XCTAssertEqual(restored.status, .failure)
        XCTAssertLessThanOrEqual(summary.resultJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
    }

    func testSummaryOnlyFalseOnlyForPromptExportStructuredMetadata() throws {
        let promptRaw = jsonString([
            "op": "export",
            "export": [
                "path": "/tmp/context.txt",
                "tokens": 42,
                "bytes": 2048
            ]
        ])
        let promptSummary = try XCTUnwrap(persistedSummary(toolName: "prompt", rawResultJSON: promptRaw))
        let promptObject = try decodedObject(promptSummary.resultJSON)
        let export = try XCTUnwrap(promptObject["export"] as? [String: Any])

        XCTAssertFalse(promptSummary.summaryOnly)
        XCTAssertEqual(promptObject["op"] as? String, "export")
        XCTAssertEqual(export["path"] as? String, "/tmp/context.txt")
        XCTAssertEqual(export["tokens"] as? Int, 42)
        XCTAssertEqual(export["bytes"] as? Int, 2048)
        XCTAssertNil(promptObject["summary_only"])
    }

    func testTrustedIncrementalFinalTurnSanitizationMatchesFullSanitization() {
        let turnID = UUID()
        let spanID = UUID()
        let startedAt = Date()
        let activities = (0 ..< 100).map { sequenceIndex in
            makeReadFileActivity(
                id: UUID(),
                sequenceIndex: sequenceIndex,
                marker: "before-\(sequenceIndex)"
            )
        }
        let previousRaw = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: turnID,
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            id: spanID,
                            lifecycle: .open,
                            startedAt: startedAt,
                            activities: activities
                        )
                    ],
                    startedAt: startedAt
                )
            ],
            nextSequenceIndex: 100
        )
        let previousSanitized = AgentToolResultPersistencePolicy
            .sanitizeTranscriptWithMetrics(previousRaw)
            .transcript

        var updatedActivities = activities
        updatedActivities[99] = makeReadFileActivity(
            id: activities[99].id,
            sequenceIndex: 99,
            marker: "after"
        )
        let updatedRaw = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: turnID,
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            id: spanID,
                            lifecycle: .open,
                            startedAt: startedAt,
                            activities: updatedActivities
                        )
                    ],
                    startedAt: startedAt
                )
            ],
            nextSequenceIndex: 100
        )

        let incremental = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            updatedRaw,
            previousSanitizedTranscript: previousSanitized,
            trustedReusablePrefixTurnCount: 0,
            trustedIncrementalFinalTurnStartSequenceIndex: 99
        )
        let fullySanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(updatedRaw)

        XCTAssertEqual(incremental.transcript, fullySanitized.transcript)
        XCTAssertLessThanOrEqual(incremental.sanitizedActivityCount, 1)
        XCTAssertGreaterThan(fullySanitized.sanitizedActivityCount, incremental.sanitizedActivityCount)
    }

    func testIncrementalSanitizerFallbackDoesNotReuseChangedCompactionPrefix() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1)
        let prefixActivity = makeReadFileActivity(
            id: UUID(),
            sequenceIndex: 0,
            marker: "prefix"
        )
        let previousFinalActivity = makeReadFileActivity(
            id: UUID(),
            sequenceIndex: 100,
            marker: "previous-final"
        )
        let previousRaw = AgentTranscript(
            turns: [
                AgentTranscriptTurn(
                    id: UUID(),
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .completed,
                            startedAt: startedAt,
                            activities: [prefixActivity]
                        )
                    ],
                    retentionTier: .archived,
                    startedAt: startedAt,
                    completedAt: startedAt
                ),
                AgentTranscriptTurn(
                    id: UUID(),
                    responseSpans: [
                        AgentTranscriptProviderResponseSpan(
                            lifecycle: .open,
                            startedAt: startedAt,
                            activities: [previousFinalActivity]
                        )
                    ],
                    startedAt: startedAt
                )
            ],
            nextSequenceIndex: 101
        )
        let previousSanitized = AgentToolResultPersistencePolicy
            .sanitizeTranscriptWithMetrics(previousRaw)
            .transcript

        var changedPrefix = previousSanitized.turns[0]
        changedPrefix.retentionTier = .summary
        let changedFinalActivity = makeReadFileActivity(
            id: previousFinalActivity.id,
            sequenceIndex: 100,
            marker: "changed-final"
        )
        let appendedFinalActivity = makeReadFileActivity(
            id: UUID(),
            sequenceIndex: 101,
            marker: "appended-final"
        )
        var updatedRaw = previousRaw
        updatedRaw.turns[0] = changedPrefix
        updatedRaw.turns[1].responseSpans = [
            AgentTranscriptProviderResponseSpan(
                lifecycle: .completed,
                startedAt: startedAt,
                activities: [changedFinalActivity]
            ),
            AgentTranscriptProviderResponseSpan(
                lifecycle: .open,
                startedAt: startedAt,
                activities: [appendedFinalActivity]
            )
        ]
        updatedRaw.nextSequenceIndex = 102

        let incrementalFallback = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            updatedRaw,
            previousSanitizedTranscript: previousSanitized,
            trustedReusablePrefixTurnCount: 1,
            trustedIncrementalFinalTurnStartSequenceIndex: 100
        )
        let fullySanitized = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(updatedRaw)

        XCTAssertEqual(incrementalFallback.transcript, fullySanitized.transcript)
        XCTAssertEqual(incrementalFallback.transcript.turns[0].retentionTier, .summary)
        XCTAssertEqual(incrementalFallback.reusedTurnCount, 0)
    }

    /// Canonical save (`AgentSessionDataService` → persisted transcript) and a cold reload by a fresh
    /// service keep a completed `ask_user` exchange intact: the questions (args) and the submitted
    /// answers (result) reach the card unchanged, so the reloaded card renders every question,
    /// context, option, and answer and keeps its "Show full exchange" affordance.
    func testCompletedAskUserExchangeSurvivesCanonicalSaveAndColdReload() async throws {
        let contextToken = "CONTEXT_TOKEN_5e1d"
        let answerToken = "ANSWER_TOKEN_3c9b"
        let longContext = "CONTEXT_START " + String(repeating: "Context sentence with selectable detail. ", count: 200) + contextToken
        let questionContext = "Question context " + String(repeating: "with rollout constraints. ", count: 40) + "QCTX_TOKEN_77a2"
        let argsJSON = jsonString([
            "title": "Covered persistence",
            "context": longContext,
            "timeout_seconds": 60,
            "questions": [
                [
                    "id": "decision",
                    "header": "Decision",
                    "question": "Approve the rollout?",
                    "context": questionContext,
                    "options": [
                        ["label": "APPROVE_6D2F", "description": "Ship it now."],
                        ["label": "REJECT_6D2F", "description": "Hold the release."]
                    ],
                    "allows_multiple": false,
                    "allows_custom": false
                ],
                [
                    "id": "checks",
                    "question": "Which checks must pass first?",
                    "options": ["unit", "integration"],
                    "allows_multiple": true,
                    "allows_custom": true
                ]
            ]
        ])
        let resultJSON = jsonString([
            "answers": [
                "decision": [
                    "answers": ["APPROVE_6D2F"],
                    "selected_options": ["APPROVE_6D2F"],
                    "custom_response": NSNull(),
                    "skipped": false
                ],
                "checks": [
                    "answers": ["unit", "integration", "Smoke the canary \(answerToken)"],
                    "selected_options": ["unit", "integration"],
                    "custom_response": "Smoke the canary \(answerToken)",
                    "skipped": false
                ]
            ],
            "timed_out": false,
            "skipped": false,
            "elapsed_seconds": 4
        ])
        XCTAssertGreaterThan(argsJSON.utf8.count, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentToolResultPersistencePolicyTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(name: "Ask User Persistence", repoPaths: ["/tmp/repo"], customStoragePath: directory)
        let session = AgentSession(id: UUID(), workspaceID: workspace.id, composeTabID: UUID(), name: "Ask user child")
            .withItems([
                AgentChatItem(kind: .user, text: "Ask the question.", sequenceIndex: 0),
                .toolResult(name: "ask_user", invocationID: UUID(), argsJSON: argsJSON, resultJSON: resultJSON, isError: false, sequenceIndex: 1),
                AgentChatItem(kind: .assistant, text: "Approved.", sequenceIndex: 2)
            ])
        let fileURL = try await AgentSessionDataService().saveAgentSession(session, for: workspace)
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains(contextToken), "The canonical file keeps the question content")
        XCTAssertTrue(onDisk.contains(answerToken), "The canonical file keeps the submitted answer")

        // Cold reload, then re-save and reload again: restored sessions are saved again in normal use.
        let reloaded = try await AgentSessionDataService().loadAgentSession(from: fileURL)
        _ = try await AgentSessionDataService().saveAgentSession(reloaded, for: workspace)
        let resaved = try await AgentSessionDataService().loadAgentSession(from: fileURL)
        for (label, restored) in [("reload", reloaded), ("re-save", resaved)] {
            let item = try XCTUnwrap(
                restored.toLiveItems().first { $0.kind == .toolResult && $0.toolName == "ask_user" },
                label
            )
            XCTAssertEqual(item.toolArgsJSON, argsJSON, label)
            XCTAssertEqual(item.toolResultJSON, resultJSON, "Only the submitted answers persist, unchanged (\(label))")

            let summary = parseAskUserQuestionSummaryRobust(args: item.toolArgsJSON, result: item.toolResultJSON)
            XCTAssertFalse(summary.isHistoricalScalar, "The reloaded card offers Show full exchange (\(label))")
            XCTAssertEqual(summary.displayTitle, "Covered persistence (2 questions)", label)
            XCTAssertEqual(summary.contextLine, longContext, label)
            XCTAssertEqual(summary.questions.map(\.id), ["decision", "checks"], label)
            let decision = try XCTUnwrap(summary.questions.first, label)
            XCTAssertEqual(decision.header, "Decision", label)
            XCTAssertEqual(decision.question, "Approve the rollout?", label)
            XCTAssertEqual(decision.context, questionContext, label)
            XCTAssertEqual(decision.options.map(\.label), ["APPROVE_6D2F", "REJECT_6D2F"], label)
            XCTAssertEqual(decision.options.map(\.description), ["Ship it now.", "Hold the release."], label)
            XCTAssertEqual(decision.options.map(\.isSelected), [true, false], label)
            XCTAssertEqual(decision.answer, "APPROVE_6D2F", label)
            let checks = try XCTUnwrap(summary.questions.last, label)
            XCTAssertEqual(checks.options.map(\.isSelected), [true, true], label)
            XCTAssertEqual(checks.answer, "unit, integration, Smoke the canary \(answerToken)", label)
            XCTAssertEqual(checks.customResponse, "Smoke the canary \(answerToken)", label)
        }

        // Stored metadata pairs with the stored transcript, which is the persisted-pipeline output of
        // the saved transcript; a cold load leaves the canonical file unchanged; a trusted canonical
        // item count overrides only the item count, never the stored projection counts.
        let storedData = try Data(contentsOf: fileURL)
        let stored = try JSONDecoder().decode(AgentSession.self, from: storedData)
        let storedTranscript = try XCTUnwrap(stored.transcript)
        let storedCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: storedTranscript)
        XCTAssertEqual(stored.transcriptProjectionCounts, storedCounts)
        XCTAssertEqual(stored.itemCount, storedCounts.canonicalVisibleRowCount)
        XCTAssertEqual(stored.lastUserMessageAt, AgentTranscriptIO.lastUserInteractionDate(in: storedTranscript))
        _ = try await AgentSessionDataService().loadAgentSession(from: fileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), storedData, "A cold load does not rewrite a canonical file")
        let firstSaved = try JSONDecoder().decode(AgentSession.self, from: XCTUnwrap(onDisk.data(using: .utf8)))
        XCTAssertEqual(firstSaved.transcript, session.transcript.map { AgentTranscriptIO.persistedTranscript($0) })

        let trustedItemCount = storedCounts.canonicalVisibleRowCount + 7
        _ = try await AgentSessionDataService().saveAgentSession(
            resaved,
            for: workspace,
            trustedCanonicalItemCount: trustedItemCount
        )
        let overridden = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
        let overriddenTranscript = try XCTUnwrap(overridden.transcript)
        XCTAssertEqual(overridden.itemCount, trustedItemCount)
        XCTAssertEqual(overridden.transcriptProjectionCounts, AgentTranscriptProjectionBuilder.projectionCounts(for: overriddenTranscript))
        XCTAssertNotEqual(overridden.transcriptProjectionCounts?.canonicalVisibleRowCount, trustedItemCount)

        // An already summarized legacy payload stays a summary; it is never re-labeled as complete.
        let legacyStub = #"{"status":"success","summary_only":true,"summary_text":"ask_user • success"}"#
        let legacy = try XCTUnwrap(persistedSummary(toolName: "ask_user", rawResultJSON: legacyStub, argsJSON: argsJSON))
        XCTAssertTrue(legacy.summaryOnly)
        XCTAssertEqual(try decodedObject(legacy.resultJSON)["summary_only"] as? Bool, true)
    }

    /// Exchanges produced by the Claude tool-tracking handler (completion-only with arguments, completion-only
    /// without arguments in a content envelope, and a normal provider-first exchange) survive canonical save,
    /// cold reload, and re-save byte-for-byte, and the reloaded cards keep their honest presentation.
    @MainActor
    func testHandlerProducedAskUserExchangesSurviveCanonicalSaveAndColdReload() async throws {
        let handler = ClaudeAgentToolTrackingHandler(mcpHost: ServerNetworkManager.shared)
        let tab = AgentTabSession(tabID: UUID())
        tab.selectedAgent = .claudeCode
        tab.setItemsSilently([AgentChatItem(kind: .user, text: "Interview me.", sequenceIndex: 0)], reason: .testOverride)
        tab.runState = .running
        handler.resetTurnState(for: tab)

        let argsJSON = #"{"title":"Rollout","questions":[{"id":"decision","question":"Approve DECISION_TOKEN_41aa?","options":["Yes","No"]}]}"#
        let args = try JSONDecoder().decode([String: Value].self, from: Data(argsJSON.utf8))
        handler.handleTrackerToolResult(
            invocationID: UUID(),
            toolName: "ask_user",
            args: args,
            resultJSON: #"{"answers":{"decision":{"answers":["Yes"]}}}"#,
            isError: false,
            session: tab
        )
        handler.handleTrackerToolResult(
            invocationID: UUID(),
            toolName: "ask_user",
            args: nil,
            resultJSON: #"{"content":[{"type":"text","text":"{\"answers\":{\"actions\":{\"answers\":[\"ORPHAN_TOKEN_9d1e\"]}}}"}]}"#,
            isError: false,
            session: tab
        )
        let followUpArgsJSON = #"{"title":"Follow-up","questions":[{"id":"decision","question":"Approve FOLLOWUP_TOKEN_2b7c?"}]}"#
        let followUpArgs = try JSONDecoder().decode([String: Value].self, from: Data(followUpArgsJSON.utf8))
        let providerID = UUID()
        let trackerID = UUID()
        handler.handleClaudeProviderRepoPromptToolCall(
            invocationID: providerID,
            toolName: "mcp__RepoPromptCE__ask_user",
            argsJSON: followUpArgsJSON,
            session: tab
        )
        handler.handleTrackerToolCall(invocationID: trackerID, toolName: "ask_user", args: followUpArgs, session: tab)
        handler.handleTrackerToolResult(
            invocationID: trackerID,
            toolName: "ask_user",
            args: followUpArgs,
            resultJSON: #"{"answers":{"decision":{"answers":["No"]}}}"#,
            isError: false,
            session: tab
        )
        tab.appendItem(AgentChatItem(kind: .assistant, text: "Done.", sequenceIndex: tab.nextSequenceIndex))

        let produced = tab.items.filter { $0.kind == .toolResult && $0.toolName == "ask_user" }
        XCTAssertEqual(produced.count, 3)
        XCTAssertEqual(produced.last?.toolInvocationID, providerID)
        XCTAssertNotNil(produced.first?.toolArgsJSON, "Unmatched completion keeps its arguments")
        XCTAssertNil(produced.dropFirst().first?.toolArgsJSON, "Missing arguments stay missing")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentToolResultPersistencePolicyTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(name: "Ask User Handler Persistence", repoPaths: ["/tmp/repo"], customStoragePath: directory)
        let session = AgentSession(id: UUID(), workspaceID: workspace.id, composeTabID: UUID(), name: "Interview")
            .withItems(tab.items)
        let fileURL = try await AgentSessionDataService().saveAgentSession(session, for: workspace)
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("DECISION_TOKEN_41aa"))
        XCTAssertTrue(onDisk.contains("ORPHAN_TOKEN_9d1e"))
        XCTAssertTrue(onDisk.contains("FOLLOWUP_TOKEN_2b7c"))

        let reloaded = try await AgentSessionDataService().loadAgentSession(from: fileURL)
        _ = try await AgentSessionDataService().saveAgentSession(reloaded, for: workspace)
        let resaved = try await AgentSessionDataService().loadAgentSession(from: fileURL)
        for (label, restored) in [("reload", reloaded), ("re-save", resaved)] {
            let items = restored.toLiveItems().filter { $0.kind == .toolResult && $0.toolName == "ask_user" }
            XCTAssertEqual(items.map(\.toolArgsJSON), produced.map(\.toolArgsJSON), label)
            XCTAssertEqual(items.map(\.toolResultJSON), produced.map(\.toolResultJSON), label)

            let summaries = items.map { parseAskUserQuestionSummaryRobust(args: $0.toolArgsJSON, result: $0.toolResultJSON) }
            XCTAssertEqual(summaries.map { $0.questions.map(\.answer) }, [["Yes"], [], ["No"]], label)
            XCTAssertEqual(summaries.map(\.isQuestionTextUnavailable), [false, true, false], label)
            XCTAssertEqual(summaries.map { $0.unmatchedAnswers.map(\.answer) }, [[], ["ORPHAN_TOKEN_9d1e"], []], label)
            XCTAssertEqual(summaries.map(\.isHistoricalScalar), [false, false, false], label)
        }
    }

    /// Cold hydration preparation over a real store: a stored pending `ask_user` call is accepted
    /// as-is without pending-question UI, takes the excluded-policy rebuild (hiding the call) with
    /// it, and an empty session with no transcript takes the missing-transcript build.
    func testColdHydrationPreparationAcceptedRebuildAndMissingTranscriptBranches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentToolResultPersistencePolicyTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(name: "Cold Preparation", repoPaths: ["/tmp/repo"], customStoragePath: directory)
        let service = AgentSessionDataService()
        func prepare(_ session: AgentSession, pendingQuestionUI: Bool) async throws -> AgentSessionHydrationPayload {
            let prepared = try await service.preparePersistedHydration(AgentSessionHydrationRequest(
                workspace: workspace,
                tabID: session.composeTabID ?? UUID(),
                sessionID: session.id,
                resolvedDisplayName: session.name,
                hasPendingQuestionUI: pendingQuestionUI,
                transcriptViewportState: .liveBottom,
                isCompressedHistoryRevealed: false,
                initialPerformanceSnapshot: .empty
            ))
            return try XCTUnwrap(prepared)
        }

        let invocationID = UUID()
        var pending = AgentSession(id: UUID(), workspaceID: workspace.id, composeTabID: UUID(), name: "Pending question")
            .withItems([
                AgentChatItem(kind: .user, text: "Ask me.", sequenceIndex: 0),
                .toolCall(name: "ask_user", invocationID: invocationID, argsJSON: #"{"questions":[{"id":"q","question":"Proceed?"}]}"#, sequenceIndex: 1)
            ])
        pending.lastRunState = AgentSessionRunState.waitingForQuestion.rawValue
        let pendingFileURL = try await service.saveAgentSession(pending, for: workspace)
        // The saved file of an open pending question pairs its metadata with the stored transcript.
        let pendingStored = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: pendingFileURL))
        let pendingTranscript = try XCTUnwrap(pendingStored.transcript)
        XCTAssertTrue(AgentTranscriptIO.workingSourceItems(from: pendingTranscript).contains {
            $0.kind == .toolCall && $0.toolInvocationID == invocationID
        }, "The open ask_user call is stored")
        let pendingCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: pendingTranscript)
        XCTAssertGreaterThan(pendingCounts.canonicalVisibleRowCount, 0)
        XCTAssertEqual(pendingStored.transcriptProjectionCounts, pendingCounts)
        XCTAssertEqual(pendingStored.itemCount, pendingCounts.canonicalVisibleRowCount)

        let accepted = try await prepare(pending, pendingQuestionUI: false)
        XCTAssertTrue(accepted.canonicalLiveItems.contains { $0.kind == .toolCall && $0.toolInvocationID == invocationID })
        XCTAssertEqual(accepted.canonicalLiveItems, AgentTranscriptIO.workingSourceItems(from: accepted.transcript))

        let rebuilt = try await prepare(pending, pendingQuestionUI: true)
        XCTAssertFalse(rebuilt.canonicalLiveItems.contains { $0.kind == .toolCall }, "The pending question call is hidden")
        XCTAssertEqual(rebuilt.canonicalLiveItems.map(\.text), ["Ask me."])
        XCTAssertEqual(rebuilt.canonicalLiveItems, AgentTranscriptIO.workingSourceItems(from: rebuilt.transcript))
        XCTAssertTrue(rebuilt.needsReloadMigrationSave)

        let empty = AgentSession(id: UUID(), workspaceID: workspace.id, composeTabID: UUID(), name: "Empty")
        _ = try await service.saveAgentSession(empty, for: workspace)
        let emptyPrepared = try await prepare(empty, pendingQuestionUI: false)
        XCTAssertNil(emptyPrepared.persistedSession.transcript, "The stored session has no transcript")
        XCTAssertTrue(emptyPrepared.transcript.turns.isEmpty)
        XCTAssertTrue(emptyPrepared.canonicalLiveItems.isEmpty)
    }

    /// Same saved bytes, copied into a fresh store with a fresh service for every run: cold load and
    /// hydration preparation give identical outputs whether runtime normalization derives its
    /// initial and post-refresh visible tool results from projection builds (reference), its
    /// initial IDs structurally (structural initial), or both structurally (candidate). Each step
    /// skips exactly one projection build per runtime normalization: the initial build, then the
    /// final build `runtimeTranscriptOnly` never makes.
    func testColdLoadStructuralInitialVisibilityMatchesProjectionReferenceForSameSavedBytes() async throws {
        let buildCounter = ColdLoadProjectionBuildCounter()
        AgentTranscriptDebugInstrumentation.reset()
        AgentTranscriptDebugInstrumentation.isEnabled = true
        AgentTranscriptDebugInstrumentation.projectionBuildHandler = { _ in buildCounter.increment() }
        defer { AgentTranscriptDebugInstrumentation.reset() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentToolResultPersistencePolicyTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = UUID()
        func workspace(_ directory: URL) -> WorkspaceModel {
            WorkspaceModel(id: workspaceID, name: "Structural Visibility", repoPaths: ["/tmp/repo"], customStoragePath: directory)
        }
        let seedDirectory = root.appendingPathComponent("seed", isDirectory: true)
        let seedService = AgentSessionDataService()

        var fixtures: [(label: String, session: AgentSession, relativePath: String, pendingQuestionUI: [Bool])] = []
        func addFixture(_ label: String, items: [AgentChatItem], runState: AgentSessionRunState? = nil, pendingQuestionUI: [Bool] = [false]) async throws {
            var session = AgentSession(id: UUID(), workspaceID: workspaceID, composeTabID: UUID(), name: label).withItems(items)
            session.lastRunState = runState?.rawValue
            let fileURL = try await seedService.saveAgentSession(session, for: workspace(seedDirectory))
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(seedDirectory.standardizedFileURL.path.count))
            fixtures.append((label, session, relativePath, pendingQuestionUI))
        }
        try await addFixture("single large turn", items: Self.largeSingleTurnItems())
        let multiTurnItems = Self.multiTurnItems(turnCount: 40, toolsPerTurn: 10)
        try await addFixture("multi-turn", items: multiTurnItems)
        try await addFixture(
            "pending ask_user",
            items: multiTurnItems + [
                .user("Ask me.", sequenceIndex: multiTurnItems.count),
                .toolCall(name: "ask_user", invocationID: UUID(), argsJSON: #"{"questions":[{"id":"q","question":"Proceed?"}]}"#, sequenceIndex: multiTurnItems.count + 1)
            ],
            runState: .waitingForQuestion,
            pendingQuestionUI: [false, true]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func encoded(_ session: AgentSession) throws -> Data {
            var session = session
            session.fileURL = nil
            return try encoder.encode(session)
        }
        struct ColdLoadOutputs: Equatable {
            let runtimeSession: Data
            /// The file after load, decoded and re-encoded with sorted keys: raw rewrite bytes are
            /// not byte-stable across identical runs (dictionary key order), independent of mode.
            let canonicalFileAfterLoad: Data
            /// Whether the file's bytes differ from the saved bytes after load. A rewrite of
            /// identical bytes is indistinguishable, so this is content-change evidence only, not
            /// proof of the rewrite decision or of a write occurring.
            let persistedBytesChanged: Bool
        }
        struct HydrationOutputs: Equatable {
            let persistedSession: Data
            let canonicalLiveItems: [AgentChatItem]
            let transcript: AgentTranscript
            let presentationTranscript: AgentTranscript
            let fullProjection: AgentTranscriptProjection
            let projection: AgentTranscriptProjection
            let projectionCounts: AgentTranscriptProjectionCounts
            let sanitizedActivityCount: Int
            let payloadRevisions: [UUID: Int]
            /// The retained raw tool-result payloads the owner installs, rebuilt from the canonical
            /// live items by the existing view-model authority.
            let rawPayloadByItemID: [UUID: String]
            let rawInputSanitizeEvidence: AgentSanitizeRawInputEvidence?
            let normalizedRunState: AgentSessionRunState
            let lastUserMessageAt: Date?
            let needsReloadMigrationSave: Bool
            /// Persistence-state components that are comparable across fresh services; the stamp's
            /// service ID and file URL are per-run by construction.
            let persistenceSessionID: UUID
            let persistenceWorkspaceID: UUID
            let deletionGeneration: UInt64
            let transcriptResetGeneration: UInt64
        }
        var runIndex = 0
        func freshStore() throws -> URL {
            runIndex += 1
            let directory = root.appendingPathComponent("run-\(runIndex)", isDirectory: true)
            try FileManager.default.copyItem(at: seedDirectory, to: directory)
            return directory
        }
        enum Mode: Int, CaseIterable {
            case reference
            case structuralInitial
            case candidate
        }
        func withMode<T>(_ mode: Mode, _ body: () async throws -> T) async rethrows -> (T, builds: Int) {
            let before = buildCounter.value
            let value = try await AgentTranscriptPolicyPipeline.$derivesInitialVisibilityFromProjection.withValue(mode == .reference) {
                try await AgentTranscriptPolicyPipeline.$derivesPostRefreshVisibilityFromProjection.withValue(mode != .candidate) {
                    try await body()
                }
            }
            return (value, buildCounter.value - before)
        }
        func assertBuilds(_ builds: Int, mode: Mode, key: String, _ message: String) throws {
            guard mode != .reference else {
                buildCounter.recordReference(builds, key: "\(mode) \(key)")
                return
            }
            let previousMode = try XCTUnwrap(Mode(rawValue: mode.rawValue - 1))
            let previousBuilds = try XCTUnwrap(buildCounter.reference(key: "\(previousMode) \(key)"))
            XCTAssertEqual(builds, previousBuilds - 1, "\(key) \(mode): \(message)")
            buildCounter.recordReference(builds, key: "\(mode) \(key)")
        }

        for fixture in fixtures {
            var loads: [Mode: [ColdLoadOutputs]] = [:]
            var hydrations: [String: [HydrationOutputs]] = [:]
            // Interleaved reference/structural-initial/candidate runs, each on a fresh copy of the same saved bytes.
            for mode in Mode.allCases + Mode.allCases {
                let store = try freshStore()
                let fileURL = URL(fileURLWithPath: store.standardizedFileURL.path + fixture.relativePath)
                let savedBytes = try Data(contentsOf: fileURL)
                let (loaded, loadBuilds) = try await withMode(mode) {
                    try await AgentSessionDataService().loadAgentSession(from: fileURL)
                }
                let bytesAfterLoad = try Data(contentsOf: fileURL)
                let runtimeSessionData = try encoded(loaded)
                let canonicalFileAfterLoad = try encoded(JSONDecoder().decode(AgentSession.self, from: bytesAfterLoad))
                loads[mode, default: []].append(.init(
                    runtimeSession: runtimeSessionData,
                    canonicalFileAfterLoad: canonicalFileAfterLoad,
                    persistedBytesChanged: bytesAfterLoad != savedBytes
                ))
                XCTAssertNotNil(loaded.transcript, fixture.label)

                for pendingQuestionUI in fixture.pendingQuestionUI {
                    let hydrationStore = try freshStore()
                    let (prepared, prepareBuilds) = try await withMode(mode) {
                        try await AgentSessionDataService().preparePersistedHydration(AgentSessionHydrationRequest(
                            workspace: workspace(hydrationStore),
                            tabID: fixture.session.composeTabID ?? UUID(),
                            sessionID: fixture.session.id,
                            resolvedDisplayName: fixture.session.name,
                            hasPendingQuestionUI: pendingQuestionUI,
                            transcriptViewportState: .liveBottom,
                            isCompressedHistoryRevealed: false,
                            initialPerformanceSnapshot: .empty
                        ))
                    }
                    let payload = try XCTUnwrap(prepared, fixture.label)
                    let presentation = payload.builtPresentation
                    let persistedSessionData = try encoded(payload.persistedSession)
                    hydrations["\(mode) pending=\(pendingQuestionUI)", default: []].append(.init(
                        persistedSession: persistedSessionData,
                        canonicalLiveItems: payload.canonicalLiveItems,
                        transcript: payload.transcript,
                        presentationTranscript: presentation.transcript,
                        fullProjection: presentation.fullProjection,
                        projection: presentation.projection,
                        projectionCounts: presentation.projectionCounts,
                        sanitizedActivityCount: presentation.sanitizedActivityCount,
                        payloadRevisions: presentation.rawToolResultPayloadRenderRevisionByItemID,
                        rawPayloadByItemID: AgentModeViewModel.rebuildEphemeralToolResultPayloadMap(from: payload.canonicalLiveItems),
                        rawInputSanitizeEvidence: presentation.rawInputSanitizeEvidence,
                        normalizedRunState: payload.normalizedRunState,
                        lastUserMessageAt: payload.lastUserMessageAt,
                        needsReloadMigrationSave: payload.needsReloadMigrationSave,
                        persistenceSessionID: payload.persistenceState.stamp.sessionID,
                        persistenceWorkspaceID: payload.persistenceState.stamp.workspaceID,
                        deletionGeneration: payload.persistenceState.stamp.deletionGeneration,
                        transcriptResetGeneration: payload.persistenceState.transcriptResetGeneration
                    ))
                    try assertBuilds(
                        prepareBuilds,
                        mode: mode,
                        key: "\(fixture.label) prepare pending=\(pendingQuestionUI)",
                        "preparation skips one more projection build"
                    )
                }
                try assertBuilds(loadBuilds, mode: mode, key: "\(fixture.label) load", "cold load skips one more projection build")
            }
            let referenceLoads = try XCTUnwrap(loads[.reference])
            XCTAssertEqual(Set(referenceLoads.map(\.runtimeSession)).count, 1, "\(fixture.label): reference loads are deterministic")
            XCTAssertEqual(Set(referenceLoads.map(\.canonicalFileAfterLoad)).count, 1, "\(fixture.label): reference files are deterministic")
            for mode in [Mode.structuralInitial, .candidate] {
                XCTAssertEqual(
                    try XCTUnwrap(loads[mode]),
                    referenceLoads,
                    "\(fixture.label) \(mode): runtime session, persisted file content, and whether persisted bytes changed match"
                )
            }
            for pendingQuestionUI in fixture.pendingQuestionUI {
                let referenceHydrations = try XCTUnwrap(hydrations["\(Mode.reference) pending=\(pendingQuestionUI)"])
                XCTAssertEqual(referenceHydrations.count, 2)
                XCTAssertFalse(
                    referenceHydrations[0].rawPayloadByItemID.isEmpty,
                    "\(fixture.label) pending=\(pendingQuestionUI): the fixture retains raw payloads"
                )
                for mode in [Mode.structuralInitial, .candidate] {
                    XCTAssertEqual(
                        try XCTUnwrap(hydrations["\(mode) pending=\(pendingQuestionUI)"]),
                        referenceHydrations,
                        "\(fixture.label) pending=\(pendingQuestionUI) \(mode): hydration outputs match"
                    )
                }
            }
        }
    }

    // MARK: - Overlapped cold hydration

    private enum ColdHydrationPreparationMode: String, CaseIterable {
        case sequential
        case overlapped

        func run<T>(_ body: () async throws -> T) async rethrows -> T {
            try await AgentSessionDataService.$forcesSequentialHydrationPreparation.withValue(self == .sequential) {
                try await body()
            }
        }
    }

    private struct ColdHydrationFixture {
        let label: String
        let session: AgentSession
        /// The session file's path relative to the seed store directory.
        let relativePath: String
        let pendingQuestionUI: [Bool]
    }

    /// Saved sessions in one seed store (with its metadata index). Every run copies the seed into a
    /// fresh store and uses a fresh service.
    private final class ColdHydrationStore {
        let root: URL
        let seedDirectory: URL
        let workspaceID = UUID()
        private(set) var fixtures: [ColdHydrationFixture] = []
        private var runIndex = 0

        init(label: String) {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentToolResultPersistencePolicyTests", isDirectory: true)
                .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
            seedDirectory = root.appendingPathComponent("seed", isDirectory: true)
        }

        func workspace(_ directory: URL) -> WorkspaceModel {
            WorkspaceModel(id: workspaceID, name: "Cold Hydration Overlap", repoPaths: ["/tmp/repo"], customStoragePath: directory)
        }

        func addFixture(
            _ label: String,
            items: [AgentChatItem],
            runState: AgentSessionRunState? = nil,
            mergeOperations: [AgentSessionWorktreeMergeOperation] = [],
            pendingQuestionUI: [Bool] = [false],
            loadedOnce: Bool = false
        ) async throws {
            var session = AgentSession(id: UUID(), workspaceID: workspaceID, composeTabID: UUID(), name: label).withItems(items)
            session.lastRunState = runState?.rawValue
            session.worktreeMergeOperations = mergeOperations
            let fileURL = try await AgentSessionDataService().saveAgentSession(session, for: workspace(seedDirectory))
            if loadedOnce {
                // One cold load leaves the file in its steady-state canonical form.
                _ = try await AgentSessionDataService().loadAgentSession(from: fileURL)
            }
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(seedDirectory.standardizedFileURL.path.count))
            fixtures.append(.init(label: label, session: session, relativePath: relativePath, pendingQuestionUI: pendingQuestionUI))
        }

        func freshStore() throws -> URL {
            runIndex += 1
            let directory = root.appendingPathComponent("run-\(runIndex)", isDirectory: true)
            try FileManager.default.copyItem(at: seedDirectory, to: directory)
            return directory
        }

        func fileURL(of fixture: ColdHydrationFixture, in store: URL) -> URL {
            URL(fileURLWithPath: store.standardizedFileURL.path + fixture.relativePath)
        }

        func request(_ fixture: ColdHydrationFixture, store: URL, pendingQuestionUI: Bool) -> AgentSessionHydrationRequest {
            AgentSessionHydrationRequest(
                workspace: workspace(store),
                tabID: fixture.session.composeTabID ?? UUID(),
                sessionID: fixture.session.id,
                resolvedDisplayName: fixture.session.name,
                hasPendingQuestionUI: pendingQuestionUI,
                transcriptViewportState: .liveBottom,
                isCompressedHistoryRevealed: false,
                initialPerformanceSnapshot: .empty
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Everything a cold hydration produces that is comparable across fresh stores and services.
    private struct ColdHydrationRunOutputs: Equatable {
        let runtimeSession: Data
        let canonicalLiveItems: [AgentChatItem]
        let transcript: AgentTranscript
        let presentationTranscript: AgentTranscript
        let fullProjection: AgentTranscriptProjection
        let projection: AgentTranscriptProjection
        let projectionCounts: AgentTranscriptProjectionCounts
        let sanitizedActivityCount: Int
        let payloadRevisions: [UUID: Int]
        let rawInputSanitizeEvidence: AgentSanitizeRawInputEvidence?
        let normalizedRunState: AgentSessionRunState
        let normalizedSelection: AgentModelCatalog.NormalizedAgentSelection
        let lastUserMessageAt: Date?
        let restoredIndexEntry: AgentSessionIndexEntry
        let needsReloadMigrationSave: Bool
        /// Persistence-state components comparable across fresh services; the stamp's service ID
        /// and file URL are per-run by construction, so `persistenceStateAuthorizesSave` covers them.
        let persistenceSessionID: UUID
        let persistenceWorkspaceID: UUID
        let deletionGeneration: UInt64
        let transcriptResetGeneration: UInt64
        let persistenceStateAuthorizesSave: Bool
        /// The file after hydration, decoded and re-encoded with sorted keys (raw rewrite bytes are
        /// not byte-stable across identical runs because of dictionary key order).
        let canonicalFileAfterHydration: Data
        let fileBytesChanged: Bool
        /// The session's metadata-index record after hydration, without per-run file observations.
        let metadataRecord: Data?
    }

    /// Sorted-key encoding without per-run values: the store-specific file URL and the merge
    /// reconciliation timestamps, which use the reconciliation's wall-clock `now`.
    private static func comparableEncoding(_ session: AgentSession) throws -> Data {
        var session = session
        session.fileURL = nil
        session.worktreeMergeOperations = session.worktreeMergeOperations.map { operation in
            var operation = operation
            operation.updatedAt = .distantPast
            operation.completedAt = operation.completedAt.map { _ in .distantPast }
            return operation
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(session)
    }

    private static func comparableMetadataRecord(sessionID: UUID, folder: URL) throws -> Data? {
        let indexURL = folder.appendingPathComponent("AgentSessionIndex.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let index = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(contentsOf: indexURL))
        guard var record = index.entries.first(where: { $0.id == sessionID }) else { return nil }
        // The observed size must describe the current file; its value varies across runs when a
        // reconciled merge operation encodes the reconciliation's wall-clock timestamp.
        let sessionFileURL = folder.appendingPathComponent(record.filename)
        let fileSize = try FileManager.default.attributesOfItem(atPath: sessionFileURL.path)[.size] as? NSNumber
        XCTAssertEqual(record.observedFileSize, fileSize?.int64Value, "The index record observes the current file")
        record.observedFileSize = nil
        record.observedFileModificationDate = nil
        record.lastIndexedAt = .distantPast
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private static func coldHydrationRun(
        _ fixture: ColdHydrationFixture,
        in store: ColdHydrationStore,
        mode: ColdHydrationPreparationMode,
        pendingQuestionUI: Bool
    ) async throws -> ColdHydrationRunOutputs {
        let directory = try store.freshStore()
        let fileURL = store.fileURL(of: fixture, in: directory)
        let savedBytes = try Data(contentsOf: fileURL)
        let service = AgentSessionDataService()
        let prepared = try await mode.run {
            try await service.preparePersistedHydration(store.request(fixture, store: directory, pendingQuestionUI: pendingQuestionUI))
        }
        let payload = try XCTUnwrap(prepared, "\(fixture.label) \(mode)")
        let bytesAfterHydration = try Data(contentsOf: fileURL)
        let canonicalFile = try comparableEncoding(JSONDecoder().decode(AgentSession.self, from: bytesAfterHydration))
        let metadataRecord = try comparableMetadataRecord(sessionID: fixture.session.id, folder: fileURL.deletingLastPathComponent())
        // The paired state must authorize an owner save of the hydrated session on this service.
        let authorizesSave: Bool
        do {
            _ = try await service.saveAgentSession(
                payload.persistedSession,
                for: store.workspace(directory),
                fileCreationPolicy: .requireExisting,
                persistenceState: payload.persistenceState
            )
            authorizesSave = true
        } catch {
            authorizesSave = false
        }
        let presentation = payload.builtPresentation
        return try ColdHydrationRunOutputs(
            runtimeSession: comparableEncoding(payload.persistedSession),
            canonicalLiveItems: payload.canonicalLiveItems,
            transcript: payload.transcript,
            presentationTranscript: presentation.transcript,
            fullProjection: presentation.fullProjection,
            projection: presentation.projection,
            projectionCounts: presentation.projectionCounts,
            sanitizedActivityCount: presentation.sanitizedActivityCount,
            payloadRevisions: presentation.rawToolResultPayloadRenderRevisionByItemID,
            rawInputSanitizeEvidence: presentation.rawInputSanitizeEvidence,
            normalizedRunState: payload.normalizedRunState,
            normalizedSelection: payload.normalizedSelection,
            lastUserMessageAt: payload.lastUserMessageAt,
            restoredIndexEntry: payload.restoredIndexEntry,
            needsReloadMigrationSave: payload.needsReloadMigrationSave,
            persistenceSessionID: payload.persistenceState.stamp.sessionID,
            persistenceWorkspaceID: payload.persistenceState.stamp.workspaceID,
            deletionGeneration: payload.persistenceState.stamp.deletionGeneration,
            transcriptResetGeneration: payload.persistenceState.transcriptResetGeneration,
            persistenceStateAuthorizesSave: authorizesSave,
            canonicalFileAfterHydration: canonicalFile,
            fileBytesChanged: bytesAfterHydration != savedBytes,
            metadataRecord: metadataRecord
        )
    }

    private static func differingFields(_ lhs: ColdHydrationRunOutputs, _ rhs: ColdHydrationRunOutputs) -> [String] {
        var fields: [String] = []
        func check(_ name: String, _ isEqual: Bool) {
            if !isEqual { fields.append(name) }
        }
        check("runtimeSession", lhs.runtimeSession == rhs.runtimeSession)
        check("canonicalLiveItems", lhs.canonicalLiveItems == rhs.canonicalLiveItems)
        check("transcript", lhs.transcript == rhs.transcript)
        check("presentationTranscript", lhs.presentationTranscript == rhs.presentationTranscript)
        check("fullProjection", lhs.fullProjection == rhs.fullProjection)
        check("projection", lhs.projection == rhs.projection)
        check("projectionCounts", lhs.projectionCounts == rhs.projectionCounts)
        check("sanitizedActivityCount", lhs.sanitizedActivityCount == rhs.sanitizedActivityCount)
        check("payloadRevisions", lhs.payloadRevisions == rhs.payloadRevisions)
        check("rawInputSanitizeEvidence", lhs.rawInputSanitizeEvidence == rhs.rawInputSanitizeEvidence)
        check("normalizedRunState", lhs.normalizedRunState == rhs.normalizedRunState)
        check("normalizedSelection", lhs.normalizedSelection == rhs.normalizedSelection)
        check("lastUserMessageAt", lhs.lastUserMessageAt == rhs.lastUserMessageAt)
        check("restoredIndexEntry", lhs.restoredIndexEntry == rhs.restoredIndexEntry)
        check("needsReloadMigrationSave", lhs.needsReloadMigrationSave == rhs.needsReloadMigrationSave)
        check("persistenceSessionID", lhs.persistenceSessionID == rhs.persistenceSessionID)
        check("persistenceWorkspaceID", lhs.persistenceWorkspaceID == rhs.persistenceWorkspaceID)
        check("deletionGeneration", lhs.deletionGeneration == rhs.deletionGeneration)
        check("transcriptResetGeneration", lhs.transcriptResetGeneration == rhs.transcriptResetGeneration)
        check("persistenceStateAuthorizesSave", lhs.persistenceStateAuthorizesSave == rhs.persistenceStateAuthorizesSave)
        check("canonicalFileAfterHydration", lhs.canonicalFileAfterHydration == rhs.canonicalFileAfterHydration)
        check("fileBytesChanged", lhs.fileBytesChanged == rhs.fileBytesChanged)
        if lhs.metadataRecord != rhs.metadataRecord {
            func object(_ data: Data?) -> [String: Any] {
                data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            }
            let lhsObject = object(lhs.metadataRecord)
            let rhsObject = object(rhs.metadataRecord)
            let keys = Set(lhsObject.keys).union(rhsObject.keys).filter { key in
                !NSDictionary(dictionary: [key: lhsObject[key] ?? NSNull()]).isEqual(to: [key: rhsObject[key] ?? NSNull()])
            }
            fields.append("metadataRecord\(keys.sorted())")
        }
        return fields
    }

    private static func awaitingApprovalMergeOperation() -> AgentSessionWorktreeMergeOperation {
        let source = GitWorktreeMergeEndpoint(
            worktreeID: "wt_source",
            repositoryID: "gitrepo_overlap",
            repoKey: "repo",
            path: "/tmp/repo-source",
            name: "feature-worktree",
            branch: "feature/merge",
            head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            isMain: false
        )
        let target = GitWorktreeMergeEndpoint(
            worktreeID: "wt_target",
            repositoryID: "gitrepo_overlap",
            repoKey: "repo",
            path: "/tmp/repo-target",
            name: "main",
            branch: "main",
            head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            isMain: true
        )
        return AgentSessionWorktreeMergeOperation(
            id: "merge_overlap",
            source: source,
            target: target,
            mergeBase: "cccccccccccccccccccccccccccccccccccccccc",
            sourceHead: source.head,
            targetHeadBefore: target.head,
            status: .awaitingApproval,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
    }

    /// Overlapped cold hydration (storage canonicalization and rewrite in parallel with the
    /// hydration branch, inside one gate-held operation) and the sequential reference (editable
    /// load, then the hydration branch on the actor) give equal payloads, persisted file content,
    /// rewrite outcome, metadata-index record, and runtime session, and both issue a persistence
    /// state that authorizes the owner's next save. Fixtures cover a steady-state canonical file (no
    /// rewrite), a freshly saved file, an active run state (rewrite), a merge operation
    /// reconciliation changes (forced rewrite preserving `savedAt`), pending-question UI on and
    /// off, and a missing session.
    func testColdHydrationOverlappedPreparationMatchesSequentialReference() async throws {
        let store = ColdHydrationStore(label: "overlap-differential")
        defer { store.remove() }
        let multiTurnItems = Self.multiTurnItems(turnCount: 12, toolsPerTurn: 6)
        try await store.addFixture("canonical", items: multiTurnItems, loadedOnce: true)
        try await store.addFixture("freshly saved", items: multiTurnItems)
        try await store.addFixture("active run state", items: multiTurnItems, runState: .running)
        try await store.addFixture("merge awaiting approval", items: multiTurnItems, mergeOperations: [Self.awaitingApprovalMergeOperation()])
        try await store.addFixture(
            "pending ask_user",
            items: multiTurnItems + [
                .user("Ask me.", sequenceIndex: multiTurnItems.count),
                .toolCall(name: "ask_user", invocationID: UUID(), argsJSON: #"{"questions":[{"id":"q","question":"Proceed?"}]}"#, sequenceIndex: multiTurnItems.count + 1)
            ],
            runState: .waitingForQuestion,
            pendingQuestionUI: [false, true]
        )

        var outputsByKey: [String: [ColdHydrationRunOutputs]] = [:]
        for fixture in store.fixtures {
            for pendingQuestionUI in fixture.pendingQuestionUI {
                // Interleaved sequential/overlapped runs, each on a fresh copy of the same saved bytes.
                for mode in ColdHydrationPreparationMode.allCases + ColdHydrationPreparationMode.allCases {
                    let outputs = try await Self.coldHydrationRun(fixture, in: store, mode: mode, pendingQuestionUI: pendingQuestionUI)
                    outputsByKey["\(fixture.label) pending=\(pendingQuestionUI) \(mode)", default: []].append(outputs)
                }
                let label = "\(fixture.label) pending=\(pendingQuestionUI)"
                let sequential = try XCTUnwrap(outputsByKey["\(label) sequential"])
                let overlapped = try XCTUnwrap(outputsByKey["\(label) overlapped"])
                XCTAssertEqual(sequential.count, 2)
                XCTAssertEqual(Set(sequential.map(\.canonicalFileAfterHydration)).count, 1, "\(label): sequential runs are deterministic")
                XCTAssertTrue(sequential.allSatisfy(\.persistenceStateAuthorizesSave), label)
                XCTAssertNotNil(sequential[0].metadataRecord, "\(label): the store has an index record")
                for (overlappedRun, sequentialRun) in zip(overlapped, sequential) {
                    XCTAssertEqual(
                        Self.differingFields(overlappedRun, sequentialRun),
                        [],
                        "\(label): overlapped preparation matches the sequential reference"
                    )
                }
                XCTAssertEqual(overlapped, sequential, "\(label): overlapped preparation matches the sequential reference")
            }
        }

        /// The fixtures exercise both rewrite outcomes and the merge-forced rewrite.
        func outputs(_ label: String) throws -> ColdHydrationRunOutputs {
            try XCTUnwrap(outputsByKey["\(label) pending=false overlapped"]?.first, label)
        }
        XCTAssertFalse(try outputs("canonical").fileBytesChanged, "A canonical file is not rewritten")
        XCTAssertTrue(try outputs("active run state").fileBytesChanged, "A restored active run state is rewritten")
        let mergeFixture = try XCTUnwrap(store.fixtures.first { $0.label == "merge awaiting approval" })
        let merged = try JSONDecoder().decode(AgentSession.self, from: outputs("merge awaiting approval").canonicalFileAfterHydration)
        XCTAssertEqual(merged.worktreeMergeOperations.map(\.status), [.cancelled], "Reconciliation forces the rewrite")
        let seedSavedAt = try JSONDecoder().decode(
            AgentSession.self,
            from: Data(contentsOf: store.fileURL(of: mergeFixture, in: store.seedDirectory))
        ).savedAt
        XCTAssertEqual(merged.savedAt, seedSavedAt, "The forced rewrite keeps the decoded savedAt")

        // A missing session yields no payload and creates no file in either mode.
        let missingID = UUID()
        for mode in ColdHydrationPreparationMode.allCases {
            let directory = try store.freshStore()
            let prepared = try await mode.run {
                try await AgentSessionDataService().preparePersistedHydration(AgentSessionHydrationRequest(
                    workspace: store.workspace(directory),
                    tabID: UUID(),
                    sessionID: missingID,
                    resolvedDisplayName: "Missing",
                    hasPendingQuestionUI: false,
                    transcriptViewportState: .liveBottom,
                    isCompressedHistoryRevealed: false,
                    initialPerformanceSnapshot: .empty
                ))
            }
            XCTAssertNil(prepared, "\(mode): a missing session has no payload")
            let missingFile = directory
                .appendingPathComponent("AgentSessions", isDirectory: true)
                .appendingPathComponent("AgentSession-\(missingID.uuidString).json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingFile.path), "\(mode)")
        }
    }

    /// The overlapped operation's storage and hydration branches both start before either finishes
    /// (each branch waits at its start until the other has started, bounded by a timeout), and the
    /// sequential reference never consults the probe.
    func testColdHydrationOverlapRunsStorageAndHydrationBranchesConcurrently() async throws {
        let store = ColdHydrationStore(label: "overlap-probe")
        defer { store.remove() }
        try await store.addFixture("active run state", items: Self.multiTurnItems(turnCount: 6, toolsPerTurn: 4), runState: .running)
        let fixture = try XCTUnwrap(store.fixtures.first)

        let probe = AgentSessionHydrationOverlapProbe()
        let directory = try store.freshStore()
        let prepared = try await AgentSessionDataService.$hydrationOverlapProbe.withValue(probe) {
            try await AgentSessionDataService().preparePersistedHydration(store.request(fixture, store: directory, pendingQuestionUI: false))
        }
        XCTAssertNotNil(prepared)
        XCTAssertTrue(probe.overlapObserved, "Both branches ran at once: \(probe.events)")
        XCTAssertEqual(Set(probe.events.suffix(2)), [.finished(.storage), .finished(.hydration)])

        let sequentialProbe = AgentSessionHydrationOverlapProbe()
        let sequentialDirectory = try store.freshStore()
        _ = try await AgentSessionDataService.$hydrationOverlapProbe.withValue(sequentialProbe) {
            try await ColdHydrationPreparationMode.sequential.run {
                try await AgentSessionDataService().preparePersistedHydration(
                    store.request(fixture, store: sequentialDirectory, pendingQuestionUI: false)
                )
            }
        }
        XCTAssertEqual(sequentialProbe.events, [], "The sequential reference has no overlapped branches")
    }

    /// A failed rewrite surfaces as `loadFailed` in both modes and leaves the file untouched, and a
    /// hydration cancelled while queued on the session gate completes its load (the file is fully
    /// rewritten and indexed, exactly as an uncancelled run leaves it) and then throws
    /// `CancellationError` in both modes, matching the sequential (pre-overlap) behavior.
    func testColdHydrationRewriteFailureAndCancellationMatchSequentialReference() async throws {
        let store = ColdHydrationStore(label: "overlap-failure")
        defer { store.remove() }
        try await store.addFixture("active run state", items: Self.multiTurnItems(turnCount: 6, toolsPerTurn: 4), runState: .running)
        let fixture = try XCTUnwrap(store.fixtures.first)

        for mode in ColdHydrationPreparationMode.allCases {
            // Rewrite failure: the session folder refuses the atomic replacement.
            let directory = try store.freshStore()
            let fileURL = store.fileURL(of: fixture, in: directory)
            let folder = fileURL.deletingLastPathComponent()
            let savedBytes = try Data(contentsOf: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            let service = AgentSessionDataService()
            let request = store.request(fixture, store: directory, pendingQuestionUI: false)
            let probe = AgentSessionHydrationOverlapProbe()
            let failure: Error?
            do {
                _ = try await mode.run {
                    try await AgentSessionDataService.$hydrationOverlapProbe.withValue(probe) {
                        try await service.preparePersistedHydration(request)
                    }
                }
                failure = nil
            } catch {
                failure = error
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            var surfacedAsLoadFailed = false
            if let dataError = failure as? AgentSessionDataError, case .loadFailed = dataError {
                surfacedAsLoadFailed = true
            }
            XCTAssertTrue(surfacedAsLoadFailed, "\(mode): the rewrite failure surfaces as loadFailed, got \(String(describing: failure))")
            XCTAssertEqual(try Data(contentsOf: fileURL), savedBytes, "\(mode): a failed rewrite leaves the file untouched")
            if mode == .overlapped {
                // The hydration child was joined (cancelled and implicitly awaited) before the throw.
                XCTAssertTrue(probe.events.contains(.finished(.hydration)), "\(mode): \(probe.events)")
                XCTAssertFalse(probe.events.contains(.finished(.storage)), "\(mode): \(probe.events)")
            }
            // The gate is free after the storage failure: nothing waits, and the next load succeeds.
            let waiters = await service.test_sessionPersistenceWaiterCount(for: fixture.session.id)
            XCTAssertEqual(waiters, 0, "\(mode)")
            let next = try await service.preparePersistedHydration(request)
            XCTAssertNotNil(next, "\(mode): a later load succeeds after a storage failure")
        }

        let reference = try await Self.coldHydrationRun(fixture, in: store, mode: .sequential, pendingQuestionUI: false)
        XCTAssertTrue(reference.fileBytesChanged)
        for mode in ColdHydrationPreparationMode.allCases {
            let directory = try store.freshStore()
            let fileURL = store.fileURL(of: fixture, in: directory)
            let workspace = store.workspace(directory)
            let service = AgentSessionDataService()
            // Hold the session gate with a conditional deletion that aborts once released.
            let holder = ColdHydrationGateHolder()
            await service.test_setConditionalDeletionHook { _ in
                await holder.holdUntilReleased()
                throw CancellationError()
            }
            let composeTabID = try XCTUnwrap(fixture.session.composeTabID)
            let candidates = try await service.deletionCandidates(forComposeTabID: composeTabID, for: workspace)
            let candidate = try XCTUnwrap(candidates.first { $0.sessionID == fixture.session.id })
            let deletion = Task { try await service.deleteAgentSession(ifCurrent: candidate, for: workspace) }
            try await Self.waitUntilColdHydration { holder.isHolding }
            let request = store.request(fixture, store: directory, pendingQuestionUI: false)
            let hydration = Task {
                try await mode.run { try await service.preparePersistedHydration(request) }
            }
            var queued = 0
            for _ in 0 ..< 500 {
                queued = await service.test_sessionPersistenceWaiterCount(for: fixture.session.id)
                if queued > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(queued, 1, "\(mode): the hydration waits on the session gate")
            hydration.cancel()
            holder.release()
            _ = await deletion.result
            await service.test_setConditionalDeletionHook(nil)

            let result = await hydration.result
            switch result {
            case .success:
                XCTFail("\(mode): a cancelled hydration throws")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError, "\(mode): \(error)")
            }
            let bytesAfter = try Data(contentsOf: fileURL)
            XCTAssertEqual(
                try Self.comparableEncoding(JSONDecoder().decode(AgentSession.self, from: bytesAfter)),
                reference.canonicalFileAfterHydration,
                "\(mode): the cancelled hydration's load still completed the full rewrite"
            )
            XCTAssertEqual(
                try Self.comparableMetadataRecord(sessionID: fixture.session.id, folder: fileURL.deletingLastPathComponent()),
                reference.metadataRecord,
                "\(mode): the index matches the rewritten file"
            )
        }
    }

    /// A cancellation that arrives while the storage branch is still committing, after the hydration
    /// child has already finished, is not lost: the commit completes (the file is fully rewritten and
    /// indexed, exactly as an uncancelled run leaves it), the operation throws `CancellationError`,
    /// and the session gate is free for the next load.
    func testColdHydrationCancelledWhileStorageCommitsAfterHydrationFinishedThrows() async throws {
        let store = ColdHydrationStore(label: "overlap-late-cancel")
        defer { store.remove() }
        try await store.addFixture("active run state", items: Self.multiTurnItems(turnCount: 6, toolsPerTurn: 4), runState: .running)
        let fixture = try XCTUnwrap(store.fixtures.first)
        let reference = try await Self.coldHydrationRun(fixture, in: store, mode: .sequential, pendingQuestionUI: false)
        XCTAssertTrue(reference.fileBytesChanged)

        let directory = try store.freshStore()
        let fileURL = store.fileURL(of: fixture, in: directory)
        let savedBytes = try Data(contentsOf: fileURL)
        let service = AgentSessionDataService()
        let request = store.request(fixture, store: directory, pendingQuestionUI: false)
        let probe = AgentSessionHydrationOverlapProbe(holdsStorageCommit: true)
        let hydration = Task {
            try await AgentSessionDataService.$hydrationOverlapProbe.withValue(probe) {
                try await service.preparePersistedHydration(request)
            }
        }
        // Failure-path cleanup: never leave the operation suspended at the cancellation-insensitive
        // commit hold (and its session gate held). Cancelling and releasing again are no-ops.
        defer {
            hydration.cancel()
            probe.releaseStorageCommit()
        }
        try await Self.waitUntilColdHydration { probe.isHoldingStorageCommit && probe.events.contains(.finished(.hydration)) }
        XCTAssertFalse(probe.events.contains(.finished(.storage)), "Storage is held before its commit")
        XCTAssertEqual(try Data(contentsOf: fileURL), savedBytes, "Nothing is written before the commit")
        hydration.cancel()
        probe.releaseStorageCommit()

        switch await hydration.result {
        case .success:
            XCTFail("A hydration cancelled during the storage commit throws")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(probe.events.contains(.finished(.storage)), "The storage commit completed")
        XCTAssertEqual(
            try Self.comparableEncoding(JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))),
            reference.canonicalFileAfterHydration,
            "The cancelled hydration's load still completed the full rewrite"
        )
        XCTAssertEqual(
            try Self.comparableMetadataRecord(sessionID: fixture.session.id, folder: fileURL.deletingLastPathComponent()),
            reference.metadataRecord,
            "The index matches the rewritten file"
        )
        let waiters = await service.test_sessionPersistenceWaiterCount(for: fixture.session.id)
        XCTAssertEqual(waiters, 0)
        let next = try await service.preparePersistedHydration(request)
        XCTAssertNotNil(next, "The session gate is free: a subsequent load succeeds")
    }

    private final class ColdHydrationGateHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var holding = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        var isHolding: Bool {
            lock.withLock { holding }
        }

        func holdUntilReleased() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    holding = true
                    if released { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func release() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                released = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }

    private static func waitUntilColdHydration(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the condition")
    }

    private final class ColdLoadProjectionBuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var references: [String: Int] = [:]
        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }

        func recordReference(_ builds: Int, key: String) {
            lock.withLock { references[key] = builds }
        }

        func reference(key: String) -> Int? {
            lock.withLock { references[key] }
        }
    }

    /// One request, 300 bash calls, 900 bash results, and 299 assistant rows in one turn.
    private static func largeSingleTurnItems() -> [AgentChatItem] {
        var items: [AgentChatItem] = [.user("Run the large workload", sequenceIndex: 0)]
        var assistantCount = 0
        for index in 0 ..< 900 {
            let invocationID = UUID()
            let argsJSON = #"{"command":"run \#(index)"}"#
            if index < 300 {
                items.append(.toolCall(name: "bash", invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: items.count))
            }
            items.append(.toolResult(
                name: "bash",
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: bashResultJSON(index: index),
                isError: false,
                sequenceIndex: items.count
            ))
            if index % 3 == 2, assistantCount < 299 {
                items.append(.assistant("Step \(index)", sequenceIndex: items.count))
                assistantCount += 1
            }
        }
        return items
    }

    private static func multiTurnItems(turnCount: Int, toolsPerTurn: Int) -> [AgentChatItem] {
        var items: [AgentChatItem] = []
        for turn in 0 ..< turnCount {
            items.append(.user("Turn \(turn)", sequenceIndex: items.count))
            for tool in 0 ..< toolsPerTurn {
                let invocationID = UUID()
                let argsJSON = #"{"command":"turn \#(turn) tool \#(tool)"}"#
                items.append(.toolCall(name: "bash", invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: items.count))
                items.append(.toolResult(
                    name: "bash",
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: bashResultJSON(index: turn * toolsPerTurn + tool),
                    isError: false,
                    sequenceIndex: items.count
                ))
                if tool % 4 == 3 {
                    items.append(.assistant("Turn \(turn) progress \(tool)", sequenceIndex: items.count))
                }
            }
            items.append(.assistant("Turn \(turn) done", sequenceIndex: items.count))
        }
        return items
    }

    private static func bashResultJSON(index: Int) -> String {
        let object: [String: Any] = [
            "type": "commandExecution",
            "status": "completed",
            "processId": "process-\(index)",
            "exitCode": 0,
            "aggregatedOutput": String(repeating: "output \(index)\n", count: 20)
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func persistedSummary(toolName: String, rawResultJSON: String, argsJSON: String? = nil) -> AgentPersistedToolResultSummary? {
        let invocationID = UUID()
        let item = AgentChatItem(
            kind: .toolResult,
            text: rawResultJSON,
            toolName: toolName,
            toolInvocationID: invocationID,
            toolArgsJSON: argsJSON,
            toolResultJSON: rawResultJSON
        )
        let execution = AgentTranscriptToolExecution(
            stableExecutionID: invocationID.uuidString,
            toolName: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            resultJSON: rawResultJSON,
            toolIsError: nil,
            status: .unknown
        )
        return AgentToolResultPersistencePolicy.persistedToolResultSummary(
            for: item,
            toolExecution: execution,
            rawResultTextFallback: rawResultJSON
        )
    }

    private func makeReadFileActivity(
        id: UUID,
        sequenceIndex: Int,
        marker: String
    ) -> AgentTranscriptActivity {
        let invocationID = UUID()
        let argsJSON = jsonString(["path": "/tmp/\(marker).txt"])
        let resultJSON = jsonString([
            "path": "/tmp/\(marker).txt",
            "content": String(repeating: "\(marker) payload ", count: 80)
        ])
        let execution = AgentTranscriptToolExecution(
            stableExecutionID: invocationID.uuidString,
            toolName: "read_file",
            invocationID: invocationID,
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            toolIsError: false,
            status: .success
        )
        return AgentTranscriptActivity(
            id: id,
            timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(sequenceIndex)),
            sequenceIndex: sequenceIndex,
            role: .toolExecution,
            itemKind: .toolResult,
            text: resultJSON,
            toolExecution: execution
        )
    }

    private func jsonString(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func decodedObject(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }
}
