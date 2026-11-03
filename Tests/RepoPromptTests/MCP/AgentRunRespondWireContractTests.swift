import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptGateway
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AgentRunRespondWireContractTests: XCTestCase {
    @MainActor
    func testSkipAllRoundTripPassesHostValidation() throws {
        let interactionID = "22222222-2222-2222-2222-222222222222"
        let response = makeTwoQuestionInteraction().buildSkippedResponse(elapsedSeconds: 3)
        let args = try translatedRespondArgs(
            interactionID: interactionID,
            payload: RemoteInteractionResponsePayload.askUser(response).wirePayload(interactionID: interactionID)
        )

        let payload = try makeService().parseResponsePayload(args: args)

        XCTAssertTrue(payload.skip)
        XCTAssertTrue(payload.explicitSkip)
        XCTAssertNil(payload.decisionRaw)
        XCTAssertTrue(payload.answersByQuestionID.isEmpty)
        XCTAssertTrue(payload.askUserAnswersByQuestionID.isEmpty)
    }

    @MainActor
    func testPartialSkipRoundTripPassesHostValidation() throws {
        let interactionID = "22222222-2222-2222-2222-222222222222"
        let interaction = makeTwoQuestionInteraction()
        var drafts = interaction.emptyDrafts()
        drafts["first"] = AgentAskUserDraft(skipped: true)
        drafts["second"] = AgentAskUserDraft(customResponse: "answer")
        let response = try interaction.buildSubmittedResponse(drafts: drafts, elapsedSeconds: 4)
        let args = try translatedRespondArgs(
            interactionID: interactionID,
            payload: RemoteInteractionResponsePayload.askUser(response).wirePayload(interactionID: interactionID)
        )

        let payload = try makeService().parseResponsePayload(args: args)

        XCTAssertFalse(payload.skip)
        XCTAssertFalse(payload.explicitSkip)
        XCTAssertEqual(payload.answersByQuestionID["first"], [])
        XCTAssertEqual(payload.answersByQuestionID["second"], ["answer"])
        XCTAssertEqual(payload.askUserAnswersByQuestionID["first"]?.skipped, true)
        XCTAssertEqual(payload.askUserAnswersByQuestionID["second"]?.customResponse, "answer")
        XCTAssertTrue(payload.hasStructuredAnswerObjects)
    }

    @MainActor
    func testSkipPlusAnswersStillRejectedForThirdPartyCallers() throws {
        let args: [String: Value] = [
            "op": .string("respond"),
            "session_id": .string("11111111-1111-1111-1111-111111111111"),
            "interaction_id": .string("22222222-2222-2222-2222-222222222222"),
            "skip": .bool(true),
            "answers": .object(["first": .array([.string("answer")])])
        ]

        XCTAssertThrowsError(try makeService().parseResponsePayload(args: args))
    }

    private func translatedRespondArgs(
        interactionID: String,
        payload: JSONValue
    ) throws -> [String: Value] {
        let frame = RemoteClientFrame(
            type: "respond",
            requestID: "req-respond",
            sessionID: "11111111-1111-1111-1111-111111111111",
            payload: payload
        )
        let call = try RemoteCommandTranslator().translate(frame)
        XCTAssertEqual(call.toolName, "agent_run")
        XCTAssertEqual(call.arguments["op"], .string("respond"))
        XCTAssertEqual(call.arguments["interaction_id"], .string(interactionID))
        return call.arguments
    }

    private func makeTwoQuestionInteraction() -> AgentAskUserInteraction {
        AgentAskUserInteraction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            remoteInteractionID: "remote-question",
            questions: [
                AgentAskUserQuestion(id: "first", question: "Skip this?", allowsCustom: true),
                AgentAskUserQuestion(id: "second", question: "Answer this", allowsCustom: true)
            ]
        )
    }

    @MainActor
    private func makeService() -> AgentRunMCPToolService {
        let window = WindowState()
        return AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "agent-run-respond-wire-contract-tests",
                    windowID: window.windowID,
                    actorRoutedRunTab: nil
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be reached")
            }
        )
    }
}
