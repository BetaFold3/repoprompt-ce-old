@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AgentSessionProfilePersistenceTests: XCTestCase {
    func testKnowledgePolicyConstantsAreExact() {
        XCTAssertEqual(KnowledgeSessionPolicy.supportedProvidersOrdered, [.claudeCode, .codexExec])
        XCTAssertEqual(KnowledgeSessionPolicy.supportedProviders, [.claudeCode, .codexExec])
        XCTAssertEqual(
            KnowledgeSessionPolicy.allowedMCPToolNames,
            [
                "get_file_tree",
                "file_search",
                "read_file",
                "apply_edits",
                "oracle_utils",
                "ask_oracle",
                "oracle_chat_log",
                "agent_run",
                "workspace_steer"
            ]
        )
        XCTAssertEqual(
            KnowledgeSessionPolicy.allowedAgentRunOperations,
            ["start", "poll", "wait", "cancel", "steer", "respond"]
        )
    }

    func testAgentSessionRoundTripsKnowledgeProfileAsVersionSeven() throws {
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000201")),
            name: "Knowledge Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            autoEditEnabled: false,
            profile: .knowledge
        )

        let encoded = try JSONEncoder().encode(session)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(encodedString.contains(#""profile":"knowledge""#), encodedString)
        // Only the profile is stored; its tool allowlist is applied at run time, so allowlist
        // changes (such as adding workspace_steer) reach saved Knowledge sessions unmigrated.
        for toolName in KnowledgeSessionPolicy.allowedMCPToolNames {
            XCTAssertFalse(encodedString.contains(toolName), "\(toolName) persisted in \(encodedString)")
        }

        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)
        XCTAssertEqual(decoded.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(decoded.serializationVersion, 7)
        XCTAssertEqual(decoded.profile, .knowledge)
    }

    func testLegacyPersistenceDefaultsToStandardProfile() async throws {
        let sessionPayload = """
        {
          "id": "00000000-0000-0000-0000-000000000202",
          "serializationVersion": 6,
          "name": "Legacy Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """
        let decodedSession = try JSONDecoder().decode(AgentSession.self, from: Data(sessionPayload.utf8))
        XCTAssertEqual(decodedSession.profile, .standard)

        let metadataPayload = """
        {
          "schemaVersion": 5,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000203",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000203.json",
              "composeTabID": "00000000-0000-0000-0000-000000000204",
              "name": "Legacy Indexed Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """
        let decodedIndex = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(metadataPayload.utf8))
        XCTAssertEqual(decodedIndex.entries.first?.profile, .standard)
        XCTAssertEqual(decodedIndex.entries.first?.sidebarEntry()?.profile, .standard)

        let fileURL = try makeSessionFile(idSuffix: "205", profileRaw: nil)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let stub = try await AgentSessionDataService.shared.loadAgentSessionStub(from: fileURL)
        XCTAssertEqual(stub.profile, .standard)
    }

    func testUnknownPresentProfileFailsAllDecodePaths() async throws {
        let sessionPayload = """
        {
          "id": "00000000-0000-0000-0000-000000000206",
          "serializationVersion": 7,
          "name": "Future Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true,
          "profile": "future"
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSession.self, from: Data(sessionPayload.utf8)))

        let metadataPayload = """
        {
          "schemaVersion": 6,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000207",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000207.json",
              "name": "Future Indexed Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "profileRaw": "future",
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(metadataPayload.utf8)))

        let fileURL = try makeSessionFile(idSuffix: "208", profileRaw: "future")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        do {
            _ = try await AgentSessionDataService.shared.loadAgentSessionStub(from: fileURL)
            XCTFail("Expected an unknown present profile to fail lightweight header decoding")
        } catch {
            // Expected: the data service wraps the header decoding failure as loadFailed.
        }
    }

    func testExplicitNullProfileFailsAllDecodePaths() async throws {
        let sessionPayload = """
        {
          "id": "00000000-0000-0000-0000-000000000212",
          "serializationVersion": 7,
          "name": "Null Profile Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true,
          "profile": null
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSession.self, from: Data(sessionPayload.utf8)))

        let metadataPayload = """
        {
          "schemaVersion": 6,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000213",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000213.json",
              "name": "Null Profile Index Entry",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "profileRaw": null,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(metadataPayload.utf8)))

        let fileURL = try makeSessionFileWithRawProfile(idSuffix: "214", rawProfileJSON: "null")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        do {
            _ = try await AgentSessionDataService.shared.loadAgentSessionStub(from: fileURL)
            XCTFail("Expected an explicit null profile to fail lightweight header decoding")
        } catch {
            // Expected: the data service wraps the header validation failure as loadFailed.
        }
    }

    func testDataServiceStubMetadataAndSidebarExposeKnowledgeProfile() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000209"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000210"))
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Knowledge Metadata Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 20),
            itemCount: 1,
            autoEditEnabled: true,
            profile: .knowledge
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Knowledge Metadata Tab"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        XCTAssertEqual(stub.profile, .knowledge)
        XCTAssertEqual(sidebar.entriesBySessionID[sessionID]?.profile, .knowledge)
        XCTAssertEqual(sidebar.preferredSessionIDByTabID[tabID], sessionID)
    }

    func testDataServiceStubPreservesOhMyPiThinkingSelections() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let wireID = "cursor/persisted-model"
        var selections = OhMyPiThinkingSelections()
        selections.setValue(
            "high",
            for: wireID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 40)
        )
        let session = AgentSession(
            id: UUID(),
            workspaceID: workspace.id,
            name: "OMP Metadata Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 41),
            agentKind: AgentProviderKind.ohMyPi.rawValue,
            agentModel: wireID,
            ohMyPiThinkingSelections: selections
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let stub = try await service.loadAgentSessionStub(from: fileURL)

        XCTAssertEqual(stub.ohMyPiThinkingSelections, selections)
    }

    func testMetadataRecordMatchingIncludesProfile() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000211"))
        let fileURL = URL(fileURLWithPath: "/tmp/AgentSession-\(sessionID.uuidString).json")
        let standardSession = AgentSession(
            id: sessionID,
            name: "Profile Matching",
            savedAt: Date(timeIntervalSinceReferenceDate: 30),
            autoEditEnabled: true,
            profile: .standard
        )
        var knowledgeSession = standardSession
        knowledgeSession.profile = .knowledge

        let standardRecord = AgentSessionMetadataRecord.record(
            from: standardSession,
            fileURL: fileURL,
            observedFileSize: 100,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 31)
        )
        let knowledgeRecord = AgentSessionMetadataRecord.record(
            from: knowledgeSession,
            fileURL: fileURL,
            observedFileSize: 100,
            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 31)
        )

        XCTAssertEqual(standardRecord.profileRaw, AgentSessionProfile.standard.rawValue)
        XCTAssertEqual(knowledgeRecord.profileRaw, AgentSessionProfile.knowledge.rawValue)
        XCTAssertEqual(knowledgeRecord.profile, .knowledge)
        XCTAssertFalse(standardRecord.matchesIndexedSessionMetadata(knowledgeRecord))
        XCTAssertFalse(knowledgeRecord.matchesIndexedSessionMetadata(standardRecord))
    }

    private func makeSessionFile(idSuffix: String, profileRaw: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionProfilePersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "00000000-0000-0000-0000-000000000\(idSuffix)"
        let profileLine = profileRaw.map { #", "profile": "\#($0)""# } ?? ""
        let payload = """
        {
          "id": "\(id)",
          "serializationVersion": 7,
          "name": "Header Session",
          "savedAt": 0,
          "itemCount": 0,
          "autoEditEnabled": true\(profileLine)
        }
        """
        let fileURL = directory.appendingPathComponent("AgentSession-\(id).json")
        try Data(payload.utf8).write(to: fileURL)
        return fileURL
    }

    private func makeSessionFileWithRawProfile(
        idSuffix: String,
        rawProfileJSON: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionProfilePersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "00000000-0000-0000-0000-000000000\(idSuffix)"
        let payload = """
        {
          "id": "\(id)",
          "serializationVersion": 7,
          "name": "Header Session",
          "savedAt": 0,
          "itemCount": 0,
          "autoEditEnabled": true,
          "profile": \(rawProfileJSON)
        }
        """
        let fileURL = directory.appendingPathComponent("AgentSession-\(id).json")
        try Data(payload.utf8).write(to: fileURL)
        return fileURL
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionProfilePersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Agent Session Profile Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}
