@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class ChatHistoryJSONOnlyTests: XCTestCase {
    func testCurrentChatSessionSaveLoadUsesCEWorkspaceRoot() async throws {
        let message = StoredMessage(
            isUser: false,
            rawText: "assistant reply",
            sequenceIndex: 0
        )
        let workspace = WorkspaceModel(name: "Chat JSON Only", repoPaths: ["/tmp/root"])
        let session = ChatSession(
            name: "Current Session",
            messages: [message],
            lastSendModelID: "custom:oracle-model",
            lastSendModelDisplayName: "Oracle Model"
        )
        let service = ChatDataService()

        let fileURL = try await service.saveChatSession(session, for: workspace)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().deletingLastPathComponent()) }

        // Default-path chats live under the shared workspaces root, which XCTest isolates from the
        // live CE store; the production root itself keeps the CE naming.
        XCTAssertTrue(fileURL.path.hasPrefix(WorkspaceStoragePaths.defaultRoot.path + "/"), fileURL.path)
        XCTAssertFalse(fileURL.path.hasPrefix(WorkspaceStorageRoot.productionRootURL().path), fileURL.path)
        let productionRoot = WorkspaceStorageRoot.productionRootURL().path
        XCTAssertTrue(productionRoot.hasSuffix("/Application Support/RepoPrompt CE/Workspaces"), productionRoot)

        let loaded = try await service.loadChatSession(from: fileURL)
        XCTAssertEqual(loaded.name, "Current Session")
        XCTAssertEqual(loaded.messages.count, 1)
        XCTAssertEqual(loaded.messages[0].rawText, "assistant reply")
        XCTAssertEqual(loaded.lastSendModelID, "custom:oracle-model")
        XCTAssertEqual(loaded.lastSendModelDisplayName, "Oracle Model")
        XCTAssertEqual(loaded.listStub().lastSendModelID, "custom:oracle-model")
        XCTAssertEqual(loaded.listStub().lastSendModelDisplayName, "Oracle Model")

        let metadata = try await service.recentSessions(for: workspace, limit: 1)
        XCTAssertEqual(metadata.first?.lastSendModelID, "custom:oracle-model")
        XCTAssertEqual(metadata.first?.lastSendModelDisplayName, "Oracle Model")
    }

    /// The lane binding an MCP `chat_id` continuation inherits must survive every load path.
    ///
    /// The lightweight header decoder is a separate `Decodable` with no compiler coupling to
    /// `ChatSession.CodingKeys`, so omitting the field there compiles cleanly and only shows up
    /// later: a hydrated stub would carry `nil` and the stub-safe save merge would then copy that
    /// `nil` over the correct on-disk value, silently destroying the binding.
    func testLastSendModelPresetIDSurvivesFullAndStubLoadPaths() async throws {
        let presetID = UUID()
        let message = StoredMessage(
            isUser: false,
            rawText: "assistant reply",
            sequenceIndex: 0
        )
        let workspace = WorkspaceModel(name: "Chat Lane Binding", repoPaths: ["/tmp/root"])
        let session = ChatSession(
            name: "Bound Lane",
            messages: [message],
            lastSendModelID: "custom:oracle-model",
            lastSendModelDisplayName: "Oracle Model",
            lastSendModelPresetID: presetID
        )
        let service = ChatDataService()

        let fileURL = try await service.saveChatSession(session, for: workspace)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().deletingLastPathComponent()) }

        // Full Codable path.
        let loaded = try await service.loadChatSession(from: fileURL)
        XCTAssertEqual(loaded.lastSendModelPresetID, presetID)

        // Lightweight header path used for session lists.
        let stub = try await service.loadChatSessionStub(from: fileURL)
        XCTAssertTrue(stub.isListStub, "Expected a lightweight stub so the header decoder is what is under test")
        XCTAssertEqual(
            stub.lastSendModelPresetID,
            presetID,
            "The lightweight header decoder dropped the lane binding; a stub-safe save would then erase it on disk"
        )

        // Attribution is one unit: a partial carry would manufacture a stale model/preset pair.
        XCTAssertEqual(stub.lastSendModelID, "custom:oracle-model")
        XCTAssertEqual(stub.lastSendModelDisplayName, "Oracle Model")
        XCTAssertEqual(stub.listStub().lastSendModelPresetID, presetID)
    }

    func testChatSessionLaneBindingIsEncodedAndAbsentLegacyKeyDecodesAsNil() throws {
        let presetID = UUID()
        let session = ChatSession(
            name: "Bound Lane",
            messages: [StoredMessage(isUser: false, rawText: "reply", sequenceIndex: 0)],
            lastSendModelID: "custom:oracle-model",
            lastSendModelDisplayName: "Oracle Model",
            lastSendModelPresetID: presetID
        )

        let encoded = try JSONEncoder().encode(session)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(
            encodedString.contains("lastSendModelPresetID"),
            "A missing CodingKeys case would silently drop the lane binding on save"
        )
        XCTAssertEqual(try JSONDecoder().decode(ChatSession.self, from: encoded).lastSendModelPresetID, presetID)

        // Sessions saved before the field existed must still load, with no binding to inherit.
        let legacyPayload = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Legacy Session",
          "savedAt": 0,
          "messages": [],
          "lastSendModelID": "custom:oracle-model",
          "lastSendModelDisplayName": "Oracle Model"
        }
        """
        let legacy = try JSONDecoder().decode(ChatSession.self, from: Data(legacyPayload.utf8))
        XCTAssertNil(legacy.lastSendModelPresetID)
        XCTAssertEqual(legacy.lastSendModelID, "custom:oracle-model")
    }

    func testStoredMessageOmitsLegacyDelegateAndCombinedTextFields() throws {
        let original = StoredMessage(
            isUser: false,
            rawText: "base",
            sequenceIndex: 2
        )

        let encoded = try JSONEncoder().encode(original)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("delegateResults"), encodedString)
        XCTAssertFalse(encodedString.contains("combinedRawText"), encodedString)

        let decoded = try JSONDecoder().decode(StoredMessage.self, from: encoded)
        XCTAssertEqual(decoded.rawText, "base")
    }

    func testLegacyDelegateResultPayloadIsIgnoredInsteadOfFlattened() throws {
        let delegateID = UUID()
        let messageID = UUID()
        let payload = """
        {
          "id": "\(messageID.uuidString)",
          "isUser": false,
          "rawText": "base",
          "combinedRawText": "stale combined should not persist",
          "timestamp": 0,
          "sequenceIndex": 0,
          "delegateResults": [
            { "id": "\(delegateID.uuidString)", "text": "legacy delegate" }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(StoredMessage.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.rawText, "base")

        let encoded = try JSONEncoder().encode(decoded)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("legacy delegate"), encodedString)
        XCTAssertFalse(encodedString.contains("combinedRawText"), encodedString)
        XCTAssertFalse(encodedString.contains("delegateResults"), encodedString)
    }

    func testLegacyChatSessionEditPayloadsAreIgnoredOnDecodeAndOmittedOnEncode() throws {
        let sessionID = UUID()
        let messageID = UUID()
        let payload = """
        {
          "id": "\(sessionID.uuidString)",
          "name": "Legacy Edit Session",
          "savedAt": 0,
          "messages": [
            {
              "id": "\(messageID.uuidString)",
              "isUser": false,
              "rawText": "assistant text",
              "timestamp": 0,
              "sequenceIndex": 0
            }
          ],
          "changedFilesByMessage": {
            "\(messageID.uuidString)": []
          },
          "delegateEditItemsByMessage": {
            "\(messageID.uuidString)": []
          }
        }
        """

        let decoded = try JSONDecoder().decode(ChatSession.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.messages.first?.rawText, "assistant text")
        XCTAssertNil(decoded.lastSendModelID)
        XCTAssertNil(decoded.lastSendModelDisplayName)

        let encoded = try JSONEncoder().encode(decoded)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(encodedString.contains("changedFilesByMessage"), encodedString)
        XCTAssertFalse(encodedString.contains("delegateEditItemsByMessage"), encodedString)
    }
}
