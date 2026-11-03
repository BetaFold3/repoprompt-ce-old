import Foundation
import MCP
@testable import RepoPromptGateway
import RepoPromptRemoteWire
import RepoPromptShared
import XCTest

final class RemoteCommandTranslatorTests: XCTestCase {
    func testTableDrivenMappings() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let cases: [(RemoteClientFrame, String, String, [String: Value])] = [
            (
                RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go"), "model_id": .string("pair")])),
                "agent_run",
                "start",
                ["message": .string("go"), "model_id": .string("pair")]
            ),
            (
                RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sid, payload: .object(["message": .string("next"), "wait": .bool(true)])),
                "agent_run",
                "steer",
                ["session_id": .string(sid), "message": .string("next"), "wait": .bool(true)]
            ),
            (
                RemoteClientFrame(type: "respond", requestID: "r3", sessionID: sid, payload: .object(["interaction_id": .string("22222222-2222-2222-2222-222222222222"), "response": .string("yes")])),
                "agent_run",
                "respond",
                ["session_id": .string(sid), "interaction_id": .string("22222222-2222-2222-2222-222222222222"), "response": .string("yes")]
            ),
            (
                RemoteClientFrame(type: "cancel", requestID: "r4", sessionID: sid, payload: .object([:])),
                "agent_run",
                "cancel",
                ["session_id": .string(sid)]
            ),
            (
                RemoteClientFrame(type: "poll", sessionID: sid, payload: .object([:])),
                "agent_run",
                "poll",
                ["session_id": .string(sid)]
            ),
            (
                RemoteClientFrame(type: "list_agents", requestID: "req-list-agents", payload: .object([:])),
                "agent_manage",
                "list_agents",
                [:]
            ),
            (
                RemoteClientFrame(
                    type: "list_sessions",
                    payload: .object([
                        "limit": .int(5),
                        "parent_session_id": .string("22222222-2222-2222-2222-222222222222")
                    ])
                ),
                "agent_manage",
                "list_sessions",
                [
                    "limit": .int(5),
                    "parent_session_id": .string("22222222-2222-2222-2222-222222222222")
                ]
            ),
            (
                RemoteClientFrame(type: "get_log", sessionID: sid, payload: .object(["offset": .int(2), "limit": .int(3)])),
                "agent_manage",
                "get_log",
                ["session_id": .string(sid), "offset": .int(2), "limit": .int(3)]
            )
        ]

        let translator = RemoteCommandTranslator()
        for (frame, expectedTool, expectedOp, expectedArgs) in cases {
            let call = try translator.translate(frame)
            XCTAssertEqual(call.toolName, expectedTool)
            XCTAssertEqual(call.arguments["op"], .string(expectedOp))
            XCTAssertEqual(call.arguments["_rawJSON"], .bool(true))
            for (key, value) in expectedArgs {
                XCTAssertEqual(call.arguments[key], value, "\(frame.type).\(key)")
            }
        }
    }

    func testListAgentsForwardsCursorParameterOptInAndRejectsUnknownKeys() throws {
        let call = try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "list_agents",
            payload: .object(["include_model_parameters": .bool(true)])
        ))
        XCTAssertEqual(call.toolName, "agent_manage")
        XCTAssertEqual(call.arguments["op"], .string("list_agents"))
        XCTAssertEqual(call.arguments["include_model_parameters"], .bool(true))

        XCTAssertThrowsError(try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "list_agents",
            payload: .object(["verbose": .bool(true)])
        ))) { error in
            XCTAssertEqual(
                error as? RemoteCommandTranslatorError,
                .unsupportedPayloadKey(operation: "list_agents", key: "verbose")
            )
        }
    }

    func testGetLogForwardsOptionalRowMetadataAndStillRejectsUnknownKeys() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let call = try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "get_log",
            sessionID: sid,
            payload: .object([
                "offset": .int(0),
                "limit": .int(20),
                "include_row_timestamps": .bool(true),
                "include_host_row_ids": .bool(true)
            ])
        ))
        XCTAssertEqual(call.toolName, "agent_manage")
        XCTAssertEqual(call.arguments["op"], .string("get_log"))
        XCTAssertEqual(call.arguments["include_row_timestamps"], .bool(true))
        XCTAssertEqual(call.arguments["include_host_row_ids"], .bool(true))

        // The whitelist still rejects any other unknown key.
        XCTAssertThrowsError(try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "get_log",
            sessionID: sid,
            payload: .object(["offset": .int(0), "verbose": .bool(true)])
        ))) { error in
            XCTAssertEqual(
                error as? RemoteCommandTranslatorError,
                .unsupportedPayloadKey(operation: "get_log", key: "verbose")
            )
        }
    }

    func testHandoffFramesMapAllowedPayloadsWithoutForwardingRequestID() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let cases: [(frame: RemoteClientFrame, op: String, expected: [String: Value])] = [
            (
                RemoteClientFrame(
                    type: "fork_session",
                    requestID: "fork-request-1",
                    sessionID: sid,
                    payload: .object([
                        "up_to_item_id": .string("22222222-2222-2222-2222-222222222222"),
                        "destination_agent": .string("pair"),
                        "destination_model_id": .string("gpt-5.4"),
                        "destination_effort": .string("high")
                    ])
                ),
                "fork_session",
                [
                    "up_to_item_id": .string("22222222-2222-2222-2222-222222222222"),
                    "destination_agent": .string("pair"),
                    "destination_model_id": .string("gpt-5.4"),
                    "destination_effort": .string("high")
                ]
            ),
            (
                RemoteClientFrame(
                    type: "extract_handoff",
                    sessionID: sid,
                    payload: .object([
                        "up_to_item_id": .string("22222222-2222-2222-2222-222222222222"),
                        "max_transcript_items": .int(40),
                        "max_tool_args_characters": .int(2000)
                    ])
                ),
                "extract_handoff",
                [
                    "up_to_item_id": .string("22222222-2222-2222-2222-222222222222"),
                    "max_transcript_items": .int(40),
                    "max_tool_args_characters": .int(2000)
                ]
            )
        ]

        for (frame, op, expected) in cases {
            let call = try RemoteCommandTranslator().translate(frame)
            XCTAssertEqual(call.toolName, "agent_manage", frame.type)
            XCTAssertEqual(call.arguments["op"], .string(op), frame.type)
            XCTAssertEqual(call.arguments["session_id"], .string(sid), frame.type)
            XCTAssertEqual(call.arguments["_rawJSON"], .bool(true), frame.type)
            XCTAssertNil(call.arguments["request_id"], frame.type)
            XCTAssertEqual(call.timeout, 60, frame.type)
            for (key, value) in expected {
                XCTAssertEqual(call.arguments[key], value, "\(frame.type).\(key)")
            }
        }
    }

    func testCancelForwardsObservedRunIDAndStillRejectsOtherKeys() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let runID = "33333333-3333-3333-3333-333333333333"
        let call = try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "cancel",
            requestID: "req-stop",
            sessionID: sid,
            payload: .object(["run_id": .string(runID)])
        ))
        XCTAssertEqual(call.toolName, "agent_run")
        XCTAssertEqual(call.arguments["op"], .string("cancel"))
        XCTAssertEqual(call.arguments["session_id"], .string(sid))
        XCTAssertEqual(call.arguments["run_id"], .string(runID))

        XCTAssertThrowsError(try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "cancel",
            requestID: "req-stop-2",
            sessionID: sid,
            payload: .object(["message": .string("stop")])
        ))) { error in
            XCTAssertEqual(
                error as? RemoteCommandTranslatorError,
                .unsupportedPayloadKey(operation: "cancel", key: "message")
            )
        }
    }

    func testHandoffFramesRejectUnknownKeysAndMissingSessionID() throws {
        for type in ["fork_session", "extract_handoff"] {
            XCTAssertThrowsError(try RemoteCommandTranslator().translate(RemoteClientFrame(
                type: type,
                requestID: type == "fork_session" ? "fork-request-1" : nil,
                sessionID: "11111111-1111-1111-1111-111111111111",
                payload: .object(["unsupported": .bool(true)])
            )), type) { error in
                XCTAssertEqual(
                    error as? RemoteCommandTranslatorError,
                    .unsupportedPayloadKey(operation: type, key: "unsupported")
                )
            }

            XCTAssertThrowsError(try RemoteCommandTranslator().translate(RemoteClientFrame(
                type: type,
                requestID: type == "fork_session" ? "fork-request-2" : nil,
                payload: .object([:])
            )), type) { error in
                XCTAssertEqual(error as? RemoteCommandTranslatorError, .missingSessionID(type))
            }
        }
    }

    func testHandoffFramesUseResolvedWindowToBypassBinding() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let frames = [
            RemoteClientFrame(type: "fork_session", requestID: "fork-request-1", sessionID: sid),
            RemoteClientFrame(type: "extract_handoff", sessionID: sid)
        ]

        for bindingState in [
            RemoteGatewayBindingState.bindingRequired("bind first"),
            .ambiguousStartTarget("multiple windows")
        ] {
            let translator = RemoteCommandTranslator(bindingState: bindingState)
            for frame in frames {
                let call = try translator.translate(frame, resolvedWindowID: 9)
                XCTAssertEqual(call.toolName, "agent_manage", frame.type)
                XCTAssertEqual(call.arguments["op"], .string(frame.type), frame.type)
                XCTAssertEqual(call.arguments["session_id"], .string(sid), frame.type)
                XCTAssertEqual(call.arguments["_windowID"], .int(9), frame.type)
            }
        }
    }

    func testRejectsArbitraryToolPassthrough() throws {
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "r1",
            payload: .object(["tool_name": .string("read_file"), "message": .string("go")])
        )
        XCTAssertThrowsError(try RemoteCommandTranslator().translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .arbitraryToolPassthroughRejected)
        }
    }

    func testListAgentsRejectsRemotePayloadKeys() throws {
        let frame = RemoteClientFrame(
            type: "list_agents",
            requestID: "req-list-agents",
            payload: .object(["roles_only": .bool(true)])
        )
        XCTAssertThrowsError(try RemoteCommandTranslator().translate(frame)) { error in
            XCTAssertEqual(
                error as? RemoteCommandTranslatorError,
                .unsupportedPayloadKey(operation: "list_agents", key: "roles_only")
            )
        }
    }

    func testListSessionsAllowsParentFilterAndRejectsUnknownKeys() throws {
        let parentID = "22222222-2222-2222-2222-222222222222"
        let allowed = try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "list_sessions",
            payload: .object([
                "parent_session_id": .string(parentID),
                "limit": .int(10)
            ])
        ))
        XCTAssertEqual(allowed.toolName, "agent_manage")
        XCTAssertEqual(allowed.arguments["op"], .string("list_sessions"))
        XCTAssertEqual(allowed.arguments["parent_session_id"], .string(parentID))
        XCTAssertEqual(allowed.arguments["limit"], .int(10))

        XCTAssertThrowsError(try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "list_sessions",
            payload: .object([
                "parent_session_id": .string(parentID),
                "include_hidden": .bool(true)
            ])
        ))) { error in
            XCTAssertEqual(
                error as? RemoteCommandTranslatorError,
                .unsupportedPayloadKey(operation: "list_sessions", key: "include_hidden")
            )
        }
    }

    func testListSessionsWorkspaceSelectorsRouteWithResolvedWindowAndStripName() throws {
        let workspaceID = "33333333-3333-3333-3333-333333333333"
        let frame = RemoteClientFrame(
            type: "list_sessions",
            payload: .object([
                "workspace_id": .string(workspaceID),
                "workspace_name": .string("Workspace A")
            ])
        )

        for bindingState in [
            RemoteGatewayBindingState.bound,
            RemoteGatewayBindingState.bindingRequired("bind first")
        ] {
            let call = try RemoteCommandTranslator(bindingState: bindingState).translate(
                frame,
                resolvedWindowID: 7
            )

            XCTAssertEqual(call.toolName, "agent_manage")
            XCTAssertEqual(call.arguments["op"], .string("list_sessions"))
            XCTAssertEqual(call.arguments["workspace_id"], .string(workspaceID))
            XCTAssertNil(call.arguments["workspace_name"])
            XCTAssertEqual(call.arguments["_windowID"], .int(7))
        }
    }

    func testParentSessionIDIsRejectedOutsideListSessions() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let parentID = "22222222-2222-2222-2222-222222222222"
        let frames = [
            RemoteClientFrame(
                type: "start",
                payload: .object(["message": .string("go"), "parent_session_id": .string(parentID)])
            ),
            RemoteClientFrame(
                type: "steer",
                sessionID: sid,
                payload: .object(["message": .string("next"), "parent_session_id": .string(parentID)])
            ),
            RemoteClientFrame(
                type: "get_log",
                sessionID: sid,
                payload: .object(["parent_session_id": .string(parentID)])
            )
        ]

        for frame in frames {
            XCTAssertThrowsError(try RemoteCommandTranslator().translate(frame), frame.type) { error in
                XCTAssertEqual(
                    error as? RemoteCommandTranslatorError,
                    .unsupportedPayloadKey(operation: frame.type, key: "parent_session_id"),
                    frame.type
                )
            }
        }
    }

    func testAmbiguousStartTargetReturnsStructuredError() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let frame = RemoteClientFrame(type: "start", requestID: "r1", payload: .object(["message": .string("go")]))
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .ambiguousStartTarget)
        }
    }

    func testBindingRequiredAppliesToAllOps() throws {
        let translator = RemoteCommandTranslator(bindingState: .bindingRequired("bind first"))
        let frame = RemoteClientFrame(type: "list_sessions")
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"))
        }
    }

    func testOpenWorkspaceTranslatesClosedPayloadAndUsesFastTimeout() throws {
        let call = try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "open_workspace",
            requestID: "open-1",
            payload: .object(["workspace_name": .string("Project Alpha")])
        ))

        XCTAssertEqual(call.toolName, "manage_workspaces")
        XCTAssertEqual(call.arguments["action"], .string("open"))
        XCTAssertEqual(call.arguments["workspace_name"], .string("Project Alpha"))
        XCTAssertEqual(call.arguments["_rawJSON"], .bool(true))
        XCTAssertNil(call.arguments["op"])
        XCTAssertEqual(call.timeout, 60)
    }

    func testOpenWorkspaceIsBindingExemptAndIDTakesPrecedence() throws {
        let workspaceID = "33333333-3333-3333-3333-333333333333"
        let frame = RemoteClientFrame(
            type: "open_workspace",
            requestID: "open-2",
            payload: .object([
                "workspace_id": .string(workspaceID),
                "workspace_name": .string("Stale Name")
            ])
        )

        for bindingState in [
            RemoteGatewayBindingState.bindingRequired("bind first"),
            .ambiguousStartTarget("multiple windows")
        ] {
            let call = try RemoteCommandTranslator(bindingState: bindingState).translate(frame)
            XCTAssertEqual(call.arguments["workspace_id"], .string(workspaceID))
            XCTAssertNil(call.arguments["workspace_name"], "ID precedence must be encoded before the host call")
        }
    }

    func testOpenWorkspaceRejectsMissingBlankUnknownAndPassthroughPayloads() {
        let invalidPayloads: [JSONValue] = [
            .object([:]),
            .object(["workspace_id": .string("  "), "workspace_name": .string("\n")]),
            .object(["workspace_name": .string("Project"), "extra": .bool(true)]),
            .object(["workspace_name": .string("Project"), "tool": .string("manage_workspaces")]),
            .object(["workspace_name": .string("Project"), "arguments": .object([:])]),
            .object(["workspace_name": .string("Project"), "op": .string("open")])
        ]

        for (index, payload) in invalidPayloads.enumerated() {
            XCTAssertThrowsError(
                try RemoteCommandTranslator().translate(RemoteClientFrame(
                    type: "open_workspace",
                    requestID: "invalid-\(index)",
                    payload: payload
                )),
                "case \(index)"
            )
        }
    }

    // MARK: - Plan §6.1: request_id forwarding to the app idempotency registry

    func testForwardsRequestIDForMutatingOpsOnly() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let translator = RemoteCommandTranslator()

        let start = try translator.translate(
            RemoteClientFrame(type: "start", requestID: "req-start", payload: .object(["message": .string("go")]))
        )
        XCTAssertEqual(start.arguments["request_id"], .string("req-start"))

        let steer = try translator.translate(
            RemoteClientFrame(type: "steer", requestID: "req-steer", sessionID: sid, payload: .object(["message": .string("next")]))
        )
        XCTAssertEqual(steer.arguments["request_id"], .string("req-steer"))

        let respond = try translator.translate(
            RemoteClientFrame(
                type: "respond",
                requestID: "req-respond",
                sessionID: sid,
                payload: .object(["interaction_id": .string(sid), "response": .string("yes")])
            )
        )
        XCTAssertEqual(respond.arguments["request_id"], .string("req-respond"))

        let cancel = try translator.translate(
            RemoteClientFrame(type: "cancel", requestID: "req-cancel", sessionID: sid, payload: .object([:]))
        )
        XCTAssertNil(cancel.arguments["request_id"], "Non-idempotent-registry ops must not forward request_id")

        let poll = try translator.translate(
            RemoteClientFrame(type: "poll", requestID: "req-poll", sessionID: sid, payload: .object([:]))
        )
        XCTAssertNil(poll.arguments["request_id"])
    }

    // MARK: - Plan §6.6: explicit multi-window start selector

    func testStartWindowSelectorMapsToHiddenWindowIDOverride() throws {
        let translator = RemoteCommandTranslator()

        let intSelector = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "window_id": .int(3)])
            )
        )
        XCTAssertEqual(intSelector.arguments["_windowID"], .int(3))
        XCTAssertNil(intSelector.arguments["window_id"], "window_id is consumed into the routing override")

        let stringSelector = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r2",
                payload: .object(["message": .string("go"), "window_id": .string("7")])
            )
        )
        XCTAssertEqual(stringSelector.arguments["_windowID"], .int(7))
    }

    func testStartWindowSelectorRejectsNonIntegerValues() throws {
        let translator = RemoteCommandTranslator()
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "r1",
            payload: .object(["message": .string("go"), "window_id": .string("main")])
        )
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            guard case .invalidPayload = error as? RemoteCommandTranslatorError else {
                return XCTFail("Expected invalidPayload, got \(error)")
            }
        }
    }

    func testStartWorkspaceSelectorPassesThroughForAppSideValidation() throws {
        let translator = RemoteCommandTranslator()
        let call = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object([
                    "message": .string("go"),
                    "workspace_id": .string("33333333-3333-3333-3333-333333333333")
                ])
            )
        )
        XCTAssertEqual(call.arguments["workspace_id"], .string("33333333-3333-3333-3333-333333333333"))
    }

    func testStartWorkspaceNameIsAcceptedButConsumedByGateway() throws {
        let translator = RemoteCommandTranslator()
        let call = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object([
                    "message": .string("go"),
                    "workspace_name": .string("Workspace A")
                ])
            )
        )
        XCTAssertNil(call.arguments["workspace_name"])
        XCTAssertNil(call.arguments["_windowID"])

        let ambiguousTranslator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        XCTAssertThrowsError(try ambiguousTranslator.translate(RemoteClientFrame(
            type: "start",
            requestID: "r2",
            payload: .object([
                "message": .string("go"),
                "workspace_name": .string("Workspace A")
            ])
        ))) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .ambiguousStartTarget)
        }
    }

    func testWorkspaceSelectorAloneDoesNotBypassAmbiguousStartTarget() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "r1",
            payload: .object([
                "message": .string("go"),
                "workspace_id": .string("33333333-3333-3333-3333-333333333333")
            ])
        )
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .ambiguousStartTarget)
        }
    }

    func testWorkspaceSelectorAloneDoesNotBypassBindingRequired() throws {
        let translator = RemoteCommandTranslator(bindingState: .bindingRequired("bind first"))
        let frame = RemoteClientFrame(
            type: "start",
            requestID: "r1",
            payload: .object([
                "message": .string("go"),
                "workspace_id": .string("33333333-3333-3333-3333-333333333333")
            ])
        )
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"))
        }
    }

    func testWindowAndWorkspaceSelectorsBypassAmbiguousStartTarget() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let call = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object([
                    "message": .string("go"),
                    "window_id": .int(2),
                    "workspace_id": .string("33333333-3333-3333-3333-333333333333")
                ])
            )
        )
        XCTAssertEqual(call.arguments["_windowID"], .int(2))
        XCTAssertEqual(call.arguments["workspace_id"], .string("33333333-3333-3333-3333-333333333333"))
    }

    func testExplicitSelectorBypassesAmbiguousStartTargetForStart() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let call = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "window_id": .int(2)])
            )
        )
        XCTAssertEqual(call.arguments["_windowID"], .int(2))
        XCTAssertEqual(call.arguments["op"], .string("start"))
    }

    func testExplicitSelectorBypassesBindingRequiredForStartOnly() throws {
        let translator = RemoteCommandTranslator(bindingState: .bindingRequired("bind first"))

        let start = try translator.translate(
            RemoteClientFrame(
                type: "start",
                requestID: "r1",
                payload: .object(["message": .string("go"), "window_id": .int(2)])
            )
        )
        XCTAssertEqual(start.arguments["_windowID"], .int(2))

        let sid = "11111111-1111-1111-1111-111111111111"
        let observationOps: [RemoteClientFrame] = [
            RemoteClientFrame(type: "poll", sessionID: sid, payload: .object([:])),
            RemoteClientFrame(
                type: "respond",
                requestID: "r2",
                sessionID: sid,
                payload: .object(["interaction_id": .string(sid), "response": .string("yes")])
            ),
            RemoteClientFrame(type: "list_sessions")
        ]
        for frame in observationOps {
            XCTAssertThrowsError(try translator.translate(frame), frame.type) { error in
                XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"), frame.type)
            }
        }
    }

    func testResolvedWindowBypassesBindingRequiredForSessionAddressedOps() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let translator = RemoteCommandTranslator(bindingState: .bindingRequired("bind first"))

        let steer = try translator.translate(
            RemoteClientFrame(type: "steer", requestID: "r1", sessionID: sid, payload: .object(["message": .string("next")])),
            resolvedWindowID: 9
        )
        XCTAssertEqual(steer.arguments["_windowID"], .int(9))
        XCTAssertEqual(steer.arguments["session_id"], .string(sid))

        let getLog = try translator.translate(
            RemoteClientFrame(type: "get_log", sessionID: sid, payload: .object([:])),
            resolvedWindowID: 9
        )
        XCTAssertEqual(getLog.toolName, "agent_manage")
        XCTAssertEqual(getLog.arguments["_windowID"], .int(9))

        let listSessions = try translator.translate(
            RemoteClientFrame(type: "list_sessions", payload: .object(["parent_session_id": .string(sid)])),
            resolvedWindowID: 9
        )
        XCTAssertEqual(listSessions.toolName, "agent_manage")
        XCTAssertEqual(listSessions.arguments["op"], .string("list_sessions"))
        XCTAssertEqual(listSessions.arguments["parent_session_id"], .string(sid))
        XCTAssertEqual(listSessions.arguments["_windowID"], .int(9))

        XCTAssertThrowsError(try translator.translate(
            RemoteClientFrame(type: "steer", requestID: "r2", sessionID: sid, payload: .object(["message": .string("next")]))
        )) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"))
        }
    }

    func testAmbiguousStartTargetRefusesNonStartOpsWithBindingRequired() throws {
        let translator = RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows"))
        let frame = RemoteClientFrame(type: "list_sessions")
        XCTAssertThrowsError(try translator.translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("multiple windows"))
        }
    }

    func testListAgentsWithResolvedWindowBypassesBindingGateAndInjectsWindowID() throws {
        let frame = RemoteClientFrame(type: "list_agents", requestID: "req-list-agents")

        for bindingState in [
            RemoteGatewayBindingState.bindingRequired("bind first"),
            RemoteGatewayBindingState.ambiguousStartTarget("multiple windows")
        ] {
            let translator = RemoteCommandTranslator(bindingState: bindingState)
            let call = try translator.translate(frame, resolvedWindowID: 7)

            XCTAssertEqual(call.toolName, "agent_manage")
            XCTAssertEqual(call.arguments["op"], .string("list_agents"))
            XCTAssertEqual(call.arguments["_windowID"], .int(7))
        }
    }

    func testListAgentsWithoutResolvedWindowStillRequiresBinding() throws {
        let frame = RemoteClientFrame(type: "list_agents", requestID: "req-list-agents")

        XCTAssertThrowsError(try RemoteCommandTranslator(bindingState: .bindingRequired("bind first")).translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("bind first"))
        }
        XCTAssertThrowsError(try RemoteCommandTranslator(bindingState: .ambiguousStartTarget("multiple windows")).translate(frame)) { error in
            XCTAssertEqual(error as? RemoteCommandTranslatorError, .bindingRequired("multiple windows"))
        }
    }

    func testFastAndPollToolCallsRetainAppLinkTimeoutPolicy() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let translator = RemoteCommandTranslator()

        let fastFrames = [
            RemoteClientFrame(type: "cancel", sessionID: sid, payload: .object([:])),
            RemoteClientFrame(type: "get_log", sessionID: sid, payload: .object([:])),
            RemoteClientFrame(type: "list_agents", payload: .object([:])),
            RemoteClientFrame(type: "list_sessions", payload: .object([:]))
        ]
        for frame in fastFrames {
            XCTAssertEqual(try translator.translate(frame).timeout, 60, frame.type)
        }

        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(type: "poll", sessionID: sid, payload: .object(["timeout": .int(120)]))
            ).timeout,
            150
        )
        XCTAssertEqual(
            try translator.translate(RemoteClientFrame(type: "poll", sessionID: sid, payload: .object([:]))).timeout,
            60
        )
    }

    func testOmittedStartAndWaitingSteerUseOwnedResponseEnvelope() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let translator = RemoteCommandTranslator()
        // The shared owned-host envelope may exceed the gateway's independent app-link cap.
        let expected = min(
            MCPTimeoutPolicy.agentLifecycleAutomaticWaitResponseEnvelopeSeconds,
            AppLinkCallTimeoutPolicy.cap
        )
        XCTAssertEqual(expected, 900)
        let frames = [
            RemoteClientFrame(type: "start", payload: .object(["message": .string("go")])),
            RemoteClientFrame(
                type: "start",
                payload: .object(["message": .string("go"), "detach": .bool(true)])
            ),
            RemoteClientFrame(
                type: "steer",
                sessionID: sid,
                payload: .object(["message": .string("next"), "wait": .bool(true)])
            )
        ]

        for frame in frames {
            XCTAssertEqual(try translator.translate(frame).timeout, expected, frame.type)
        }
    }

    func testSteerTimeoutPresenceInfersWaitUnlessWaitIsFalse() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        let translator = RemoteCommandTranslator()

        let inferredWait = try translator.translate(RemoteClientFrame(
            type: "steer",
            sessionID: sid,
            payload: .object(["message": .string("next"), "timeout_seconds": .int(300)])
        ))
        XCTAssertEqual(inferredWait.timeout, 330)
        XCTAssertNil(inferredWait.arguments["wait"])
        XCTAssertEqual(inferredWait.arguments["timeout_seconds"], .int(300))

        let explicitNonWait = try translator.translate(RemoteClientFrame(
            type: "steer",
            sessionID: sid,
            payload: .object([
                "message": .string("next"),
                "wait": .bool(false),
                "timeout_seconds": .int(300)
            ])
        ))
        XCTAssertEqual(explicitNonWait.timeout, 60)
        XCTAssertEqual(explicitNonWait.arguments["wait"], .bool(false))
        XCTAssertEqual(explicitNonWait.arguments["timeout_seconds"], .int(300))

        let falseWaitValues: [JSONValue] = [
            .string(" FALSE "),
            .string("0"),
            .string("no"),
            .int(0),
            .double(0)
        ]
        for wait in falseWaitValues {
            let call = try translator.translate(RemoteClientFrame(
                type: "steer",
                sessionID: sid,
                payload: .object([
                    "message": .string("next"),
                    "wait": wait,
                    "timeout_seconds": .int(300)
                ])
            ))
            XCTAssertEqual(call.timeout, 60, "\(wait)")
        }

        let trueWaitValues: [JSONValue] = [
            .string(" TRUE "),
            .string("1"),
            .string("yes"),
            .int(2),
            .double(-1)
        ]
        for wait in trueWaitValues {
            let call = try translator.translate(RemoteClientFrame(
                type: "steer",
                sessionID: sid,
                payload: .object(["message": .string("next"), "wait": wait])
            ))
            XCTAssertEqual(
                call.timeout,
                min(
                    MCPTimeoutPolicy.agentLifecycleAutomaticWaitResponseEnvelopeSeconds,
                    AppLinkCallTimeoutPolicy.cap
                ),
                "\(wait)"
            )
        }

        let omittedWait = try translator.translate(RemoteClientFrame(
            type: "steer",
            sessionID: sid,
            payload: .object(["message": .string("next")])
        ))
        XCTAssertEqual(omittedWait.timeout, 60)
    }

    func testExplicitAppLinkTimeoutsRetainFloorGraceAndCap() throws {
        let translator = RemoteCommandTranslator()

        XCTAssertEqual(AppLinkCallTimeoutPolicy.fast, 60)
        XCTAssertEqual(AppLinkCallTimeoutPolicy.grace, 30)
        XCTAssertEqual(AppLinkCallTimeoutPolicy.cap, 900)
        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(type: "start", payload: .object(["message": .string("go"), "timeout": .int(0)]))
            ).timeout,
            60
        )
        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(type: "start", payload: .object(["message": .string("go"), "timeout": .int(60)]))
            ).timeout,
            90
        )
        XCTAssertEqual(
            try translator.translate(
                RemoteClientFrame(type: "start", payload: .object(["message": .string("go"), "timeout": .int(870)]))
            ).timeout,
            900
        )
        XCTAssertEqual(
            try translator.translate(RemoteClientFrame(
                type: "start",
                payload: .object([
                    "message": .string("go"),
                    "timeout": .double(MCPTimeoutPolicy.agentLifecycleMaximumExplicitTimeoutSeconds)
                ])
            )).timeout,
            900
        )
    }

    func testTimeoutAbove870CapsTransportWithoutTranslatingWorkerCancellation() throws {
        let requestedTimeout: TimeInterval = 871
        let call = try RemoteCommandTranslator().translate(RemoteClientFrame(
            type: "start",
            payload: .object(["message": .string("go"), "timeout": .double(requestedTimeout)])
        ))

        XCTAssertEqual(call.timeout, 900)
        XCTAssertEqual(
            call.timeout,
            AppLinkCallTimeoutPolicy.cap,
            "The gateway transport cap remains independent of the accepted worker wait."
        )
        XCTAssertLessThan(
            try XCTUnwrap(call.timeout),
            requestedTimeout + AppLinkCallTimeoutPolicy.grace,
            "Above 870 seconds the gateway can expire before the semantic wait plus response grace."
        )
        XCTAssertEqual(call.toolName, "agent_run")
        XCTAssertEqual(call.arguments["op"], .string("start"))
        XCTAssertEqual(call.arguments["timeout"], .double(requestedTimeout))
        XCTAssertNotEqual(call.arguments["op"], .string("cancel"), "Transport expiry does not cancel the worker.")
    }
}
