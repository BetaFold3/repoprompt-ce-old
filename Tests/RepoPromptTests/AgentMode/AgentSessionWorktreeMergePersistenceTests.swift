@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AgentSessionWorktreeMergePersistenceTests: XCTestCase {
    func testOldAgentSessionJSONDecodesWithEmptyWorktreeMergeOperations() throws {
        let payload = """
        {
          "id": "00000000-0000-0000-0000-000000000201",
          "serializationVersion": 5,
          "name": "Legacy Merge Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true,
          "worktreeBindings": []
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(payload.utf8))

        XCTAssertEqual(decoded.serializationVersion, 5)
        XCTAssertTrue(decoded.worktreeMergeOperations.isEmpty)
    }

    func testAgentSessionRoundTripsActiveWorktreeMergeOperationsAsVersionSeven() throws {
        let operation = makeOperation(status: .awaitingCommit, conflictFiles: [])
        let session = try AgentSession(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000202")),
            name: "Merge Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 10),
            autoEditEnabled: false,
            worktreeMergeOperations: [operation]
        )

        let encoded = try JSONEncoder().encode(session)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(encodedString.contains("worktreeMergeOperations"), encodedString)

        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.serializationVersion, AgentSession.currentSerializationVersion)
        XCTAssertEqual(decoded.serializationVersion, 7)
        XCTAssertEqual(decoded.worktreeMergeOperations, [operation])
        XCTAssertEqual(decoded.worktreeMergeOperations.activeWorktreeMergeSummaries, try [XCTUnwrap(operation.activeSummary)])
    }

    func testDataServiceStubMetadataAndSidebarExposeActiveMergeSummaries() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: try XCTUnwrap(workspace.customStoragePath)) }
        let operation = makeOperation(status: .conflicted, conflictFiles: ["Sources/App.swift"])
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000203"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000204"))
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Merge Metadata Session",
            savedAt: Date(timeIntervalSinceReferenceDate: 20),
            itemCount: 2,
            autoEditEnabled: true,
            worktreeMergeOperations: [operation]
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 2
        )
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let metadata = try await service.listAgentSessionsMeta(for: workspace)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Merge Metadata Tab"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        let summary = try XCTUnwrap(operation.activeSummary)
        XCTAssertEqual(stub.worktreeMergeOperations, [operation])
        XCTAssertEqual(stub.worktreeMergeOperations.activeWorktreeMergeSummaries, [summary])
        XCTAssertEqual(metadata.first?.activeWorktreeMergeSummaries, [summary])
        XCTAssertEqual(sidebar.entriesBySessionID[sessionID]?.activeWorktreeMergeSummaries, [summary])
    }

    func testReconciliationCancelsAwaitingApproval() async {
        let operation = makeOperation(status: .awaitingApproval)

        let reconciled = await reconcile(operation) { _ in
            throw NSError(domain: "AgentSessionWorktreeMergePersistenceTests", code: 1)
        }

        XCTAssertEqual(reconciled.status, .cancelled)
        XCTAssertEqual(reconciled.completedAt, reconciliationNow)
        XCTAssertTrue(reconciled.lastError?.contains("approval") == true)
    }

    // MARK: - Step 5c preserved reviews

    func testReconciliationKeepsPreservedReviewAsHistoryWithoutContinuationOrInspection() async {
        var live = makeOperation(status: .awaitingApproval)
        live.reviewPreservation = .live

        let reconciled = await reconcile(live) { _ in
            XCTFail("A preserved review is never inspected or resumed on cold restore")
            throw NSError(domain: "AgentSessionWorktreeMergePersistenceTests", code: 2)
        }

        XCTAssertEqual(reconciled.status, .awaitingApproval, "Kept as history, not cancelled")
        XCTAssertTrue(reconciled.isHistoricalReview)
        XCTAssertEqual(reconciled.reviewPreservation?.endedReason, AgentSessionWorktreeMergeReconciler.relaunchEndedReviewReason)
        XCTAssertEqual(reconciled.reviewPreservation?.endedAt, reconciliationNow)
        XCTAssertEqual(reconciled.updatedAt, reconciliationNow)
        XCTAssertNil(reconciled.completedAt)
        XCTAssertEqual(reconciled.previewArtifacts, live.previewArtifacts, "Retained refs are kept unchanged")
        XCTAssertEqual(reconciled.activeSummary?.isHistoricalReview, true)

        let again = await reconcile(reconciled) { _ in
            XCTFail("History is never inspected")
            throw NSError(domain: "AgentSessionWorktreeMergePersistenceTests", code: 3)
        }
        XCTAssertEqual(again, reconciled, "An already-historical review is unchanged by later restores")
    }

    func testPreservationMarkerRoundTripsAndLegacyOperationsDecodeWithoutIt() throws {
        var historical = makeOperation(status: .awaitingApproval)
        historical.reviewPreservation = .historical(reason: "Ended", at: Date(timeIntervalSinceReferenceDate: 50))
        let decoded = try JSONDecoder().decode(
            AgentSessionWorktreeMergeOperation.self,
            from: JSONEncoder().encode(historical)
        )
        XCTAssertEqual(decoded, historical)
        XCTAssertTrue(decoded.isHistoricalReview)

        let legacy = makeOperation(status: .awaitingApproval)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(legacyObject["reviewPreservation"], "An unmarked operation writes no marker")
        let legacyDecoded = try JSONDecoder().decode(AgentSessionWorktreeMergeOperation.self, from: legacyData)
        XCTAssertNil(legacyDecoded.reviewPreservation)
        XCTAssertFalse(legacyDecoded.isHistoricalReview)
    }

    func testColdLoadRewritesPreservedReviewAsDiscoverableHistory() async throws {
        let workspace = makeTemporaryWorkspace()
        let storage = try XCTUnwrap(workspace.customStoragePath)
        let tombstones = storage.appendingPathComponent("tombstones", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let service = AgentSessionDataService(tombstoneRoot: tombstones)
        var live = makeOperation(status: .awaitingApproval)
        live.reviewPreservation = .live
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000205"))
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: UUID(),
            name: "Preserved Merge Review",
            savedAt: Date(timeIntervalSinceReferenceDate: 20),
            itemCount: 0,
            autoEditEnabled: true,
            worktreeMergeOperations: [live]
        )
        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )

        let loaded = try await service.loadAgentSession(from: fileURL)
        let restored = try XCTUnwrap(loaded.worktreeMergeOperations.first)
        XCTAssertEqual(restored.status, .awaitingApproval)
        XCTAssertTrue(restored.isHistoricalReview, "Cold restore keeps the approval as history, never live")
        XCTAssertEqual(restored.previewArtifacts, live.previewArtifacts)

        let stub = try await service.loadAgentSessionStub(from: fileURL)
        XCTAssertEqual(stub.worktreeMergeOperations, loaded.worktreeMergeOperations, "The historical marker is written back")
        XCTAssertEqual(stub.worktreeMergeOperations.activeWorktreeMergeSummaries.map(\.isHistoricalReview), [true])
        let metadata = try await service.listAgentSessionsMeta(for: workspace)
        XCTAssertEqual(
            metadata.first { $0.id == sessionID }?.activeWorktreeMergeSummaries.map(\.isHistoricalReview),
            [true],
            "Discoverable from session metadata without opening the transcript"
        )
    }

    func testReconciliationMapsApplyingConflictStateToConflicted() async {
        let operation = makeOperation(status: .applying)

        let reconciled = await reconcile(operation) { _ in
            .init(
                targetMergeInProgress: true,
                targetHead: operation.targetHeadBefore,
                conflictFiles: ["b.txt", "a.txt"]
            )
        }

        XCTAssertEqual(reconciled.status, .conflicted)
        XCTAssertEqual(reconciled.conflictFiles, ["a.txt", "b.txt"])
        XCTAssertNil(reconciled.completedAt)
    }

    func testReconciliationMapsApplyingCleanMergeStateToAwaitingCommit() async {
        let operation = makeOperation(status: .applying)

        let reconciled = await reconcile(operation) { _ in
            .init(targetMergeInProgress: true, targetHead: operation.targetHeadBefore, conflictFiles: [])
        }

        XCTAssertEqual(reconciled.status, .awaitingCommit)
        XCTAssertTrue(reconciled.conflictFiles.isEmpty)
        XCTAssertNil(reconciled.completedAt)
    }

    func testReconciliationMapsApplyingCompletedTargetHeadToCompleted() async {
        let operation = makeOperation(status: .applying)

        let reconciled = await reconcile(operation) { _ in
            .init(targetMergeInProgress: false, targetHead: "dddddddddddddddddddddddddddddddddddddddd", conflictFiles: [])
        }

        XCTAssertEqual(reconciled.status, .completed)
        XCTAssertEqual(reconciled.resultCommit, "dddddddddddddddddddddddddddddddddddddddd")
        XCTAssertEqual(reconciled.completedAt, reconciliationNow)
        XCTAssertTrue(reconciled.conflictFiles.isEmpty)
    }

    func testReconciliationRefreshesConflictedToAwaitingCommitAfterConflictsResolved() async {
        let operation = makeOperation(status: .conflicted, conflictFiles: ["old.txt"])

        let reconciled = await reconcile(operation) { _ in
            .init(targetMergeInProgress: true, targetHead: operation.targetHeadBefore, conflictFiles: [])
        }

        XCTAssertEqual(reconciled.status, .awaitingCommit)
        XCTAssertTrue(reconciled.conflictFiles.isEmpty)
        XCTAssertNil(reconciled.completedAt)
    }

    func testReconciliationRefreshesAwaitingCommitBackToConflictedWhenConflictsRemain() async {
        let operation = makeOperation(status: .awaitingCommit)

        let reconciled = await reconcile(operation) { _ in
            .init(targetMergeInProgress: true, targetHead: operation.targetHeadBefore, conflictFiles: ["conflict.txt"])
        }

        XCTAssertEqual(reconciled.status, .conflicted)
        XCTAssertEqual(reconciled.conflictFiles, ["conflict.txt"])
    }

    func testReconciliationMarksPreviewedStaleWhenArtifactsMissing() async {
        let operation = makeOperation(status: .previewed)

        let reconciled = await reconcile(operation) { _ in
            .init(
                targetMergeInProgress: false,
                targetHead: operation.targetHeadBefore,
                previewArtifactsAvailable: false,
                previewFingerprintsMatch: true
            )
        }

        XCTAssertEqual(reconciled.status, .stale)
        XCTAssertTrue(reconciled.lastError?.contains("artifacts") == true)
    }

    func testPreviewedOperationWithoutArtifactReferencesIsNotActiveAfterReconciliation() async {
        let operation = makeOperation(status: .previewed, previewArtifacts: nil)

        let reconciled = await reconcile(operation) { inspected in
            .init(
                targetMergeInProgress: false,
                targetHead: inspected.targetHeadBefore,
                previewArtifactsAvailable: inspected.previewArtifacts != nil,
                previewFingerprintsMatch: true
            )
        }

        XCTAssertEqual(reconciled.status, .stale)
        XCTAssertNil(reconciled.activeSummary)
    }

    func testFingerprintEqualityIgnoresGeneratedAtForPreviewRevalidation() {
        let old = GitDiffFingerprint(
            headSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            baseRef: "HEAD",
            statusHash: "clean",
            generatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let refreshed = GitDiffFingerprint(
            headSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            baseRef: "HEAD",
            statusHash: "clean",
            generatedAt: Date(timeIntervalSinceReferenceDate: 2)
        )

        XCTAssertEqual(old, refreshed)
    }

    private let reconciliationNow = Date(timeIntervalSinceReferenceDate: 999)

    private func reconcile(
        _ operation: AgentSessionWorktreeMergeOperation,
        inspect: @escaping @Sendable (AgentSessionWorktreeMergeOperation) async throws -> AgentSessionWorktreeMergeReconciliationInspection
    ) async -> AgentSessionWorktreeMergeOperation {
        await AgentSessionWorktreeMergeReconciler.reconcile(
            operation,
            now: reconciliationNow,
            hooks: AgentSessionWorktreeMergeReconciliationHooks(inspect: inspect)
        )
    }

    private func makeOperation(
        status: AgentSessionWorktreeMergeOperation.Status,
        conflictFiles: [String] = [],
        previewArtifacts: GitWorktreeMergePreviewArtifacts? = GitWorktreeMergePreviewArtifacts(
            snapshotID: "snapshot-1",
            snapshotDirectory: "/tmp/snapshot-1",
            manifestPath: "/tmp/snapshot-1/manifest.json",
            mapPath: "/tmp/snapshot-1/MAP.txt",
            allPatchPath: "/tmp/snapshot-1/diff/all.patch",
            sidecarPath: "/tmp/snapshot-1/merge_preview.json"
        )
    ) -> AgentSessionWorktreeMergeOperation {
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        let source = GitWorktreeMergeEndpoint(
            worktreeID: "wt_source",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            path: "/tmp/repo-source",
            name: "feature-worktree",
            branch: "feature/merge",
            head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            isMain: false
        )
        let target = GitWorktreeMergeEndpoint(
            worktreeID: "wt_target",
            repositoryID: "gitrepo_abc123",
            repoKey: "repo",
            path: "/tmp/repo-target",
            name: "main",
            branch: "main",
            head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            isMain: true
        )
        return AgentSessionWorktreeMergeOperation(
            id: "merge_test",
            source: source,
            target: target,
            mergeBase: "cccccccccccccccccccccccccccccccccccccccc",
            sourceHead: source.head,
            targetHeadBefore: target.head,
            sourceFingerprint: GitDiffFingerprint(
                headSHA: source.head,
                baseRef: "HEAD",
                statusHash: "source-clean",
                generatedAt: createdAt
            ),
            targetFingerprint: GitDiffFingerprint(
                headSHA: target.head,
                baseRef: "HEAD",
                statusHash: "target-clean",
                generatedAt: createdAt
            ),
            previewArtifacts: previewArtifacts,
            summary: GitWorktreeMergeSummary(commits: 2, files: 3, insertions: 10, deletions: 4),
            visualization: "target main <- source feature",
            status: status,
            conflictFiles: conflictFiles,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionWorktreeMergePersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Worktree Merge Persistence",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }
}
