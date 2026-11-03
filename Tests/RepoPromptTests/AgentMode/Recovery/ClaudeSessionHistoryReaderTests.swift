import Foundation
@testable import RepoPromptAgentCore
import XCTest

/// Lossless restart Phase 4 built-in Claude native-history subset (`nativeEntriesSubsetV2`) and the
/// history-only import planner. Fixtures are in-memory JSONL mirroring the pinned primary-source
/// constructors (`_make_transcript_entry` / `_parallel_tool_turn`, commit
/// 3cb0c27eca8caccdc153471a1b19f97fce4ada03): `type`, `uuid`, `parentUuid`, `sessionId`, `message`,
/// and `sourceToolAssistantUUID` on parallel tool results. Fixture-backed only: this is not
/// qualification of Claude's live format. File access is injected (no home); only the live-listing
/// boundary test uses a temporary directory.
final class ClaudeSessionHistoryReaderTests: XCTestCase {
    private typealias Reader = ClaudeSessionHistoryReader

    private let sessionID = "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f"
    private let identityA = AgentRecoveryHistoryFileIdentity(device: 1, inode: 10, birthSeconds: 100, birthNanoseconds: 0)
    private let identityB = AgentRecoveryHistoryFileIdentity(device: 1, inode: 11, birthSeconds: 200, birthNanoseconds: 0)
    private let projects = URL(fileURLWithPath: "/fixture/home/projects", isDirectory: true)

    // MARK: Fixture builders

    private func entry(
        _ type: String,
        uuid: String,
        parent: String?,
        content: Any,
        messageID: String? = nil,
        source: String? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var message: [String: Any] = ["role": type, "content": content]
        if let messageID { message["id"] = messageID }
        var object: [String: Any] = [
            "type": type,
            "uuid": uuid,
            "parentUuid": parent ?? NSNull(),
            "sessionId": sessionID,
            "message": message,
            "timestamp": "2026-10-22T00:00:00.000Z",
            "cwd": "/fixture/project",
            "version": "2.0.0",
            "isSidechain": false
        ]
        if let source { object["sourceToolAssistantUUID"] = source }
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }

    private func user(_ uuid: String, parent: String?, _ text: String) -> [String: Any] {
        entry("user", uuid: uuid, parent: parent, content: text)
    }

    private func assistantText(_ uuid: String, parent: String?, _ text: String, messageID: String? = nil) -> [String: Any] {
        entry("assistant", uuid: uuid, parent: parent, content: [["type": "text", "text": text]], messageID: messageID ?? "msg-\(uuid)")
    }

    private func toolUse(_ uuid: String, parent: String?, id: String, name: String, messageID: String) -> [String: Any] {
        entry(
            "assistant",
            uuid: uuid,
            parent: parent,
            content: [["type": "tool_use", "id": id, "name": name, "input": ["path": "/fixture/\(id)"]]],
            messageID: messageID
        )
    }

    private func toolResult(_ uuid: String, parent: String, toolUseID: String, text: String, source: String?) -> [String: Any] {
        entry(
            "user",
            uuid: uuid,
            parent: parent,
            content: [["type": "tool_result", "tool_use_id": toolUseID, "content": text]],
            source: source
        )
    }

    private func jsonl(_ entries: [[String: Any]], trailing: String = "") -> Data {
        var data = Data()
        for object in entries {
            data.append(try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            data.append(0x0A)
        }
        data.append(Data(trailing.utf8))
        return data
    }

    private func access(_ files: [(URL, AgentRecoveryHistoryFileIdentity, Data)]) -> Reader.FileAccess {
        Reader.FileAccess(
            candidates: { _, name in .listed(files.map(\.0).filter { $0.lastPathComponent == name }) },
            identity: { url in files.first { $0.0 == url }?.1 },
            capture: { url, maximumBytes in
                guard let file = files.first(where: { $0.0 == url }) else { throw Reader.CaptureError.unreadable("missing") }
                guard file.2.count <= maximumBytes else { throw Reader.CaptureError.tooLarge }
                return Reader.Capture(identity: file.1, bytes: file.2)
            }
        )
    }

    private func fileURL(project: String = "p") -> URL {
        projects.appendingPathComponent(project, isDirectory: true).appendingPathComponent("\(sessionID).jsonl")
    }

    private func read(
        _ data: Data?,
        identity: AgentRecoveryHistoryFileIdentity? = nil,
        mode: Reader.Mode,
        ledger: AgentSessionProviderHistoryRecovery? = nil
    ) -> Reader.Result {
        let files = data.map { [(fileURL(), identity ?? identityA, $0)] } ?? []
        return Reader.read(
            nativeSessionID: sessionID,
            projectsDirectories: [projects],
            mode: mode,
            ledger: ledger,
            fileAccess: access(files)
        )
    }

    /// A cursor at `offset` with an explicit byte-prefix proof (`nil` = a legacy cursor).
    private func cursor(
        file: AgentRecoveryHistoryFileIdentity?,
        offset: UInt64,
        proof: String?,
        importID: UUID = UUID()
    ) -> AgentRecoveryHistoryCursor {
        AgentRecoveryHistoryCursor(
            providerRaw: Reader.providerRaw,
            conversationID: sessionID,
            importID: importID,
            file: file,
            completeLineOffset: offset,
            prefixSHA256: proof,
            committedAt: AgentRecoveryTimestamp(Date(timeIntervalSince1970: 1000))
        )
    }

    /// A cursor just after exactly `prefix`, proven by its digest.
    private func cursor(file: AgentRecoveryHistoryFileIdentity?, over prefix: Data) -> AgentRecoveryHistoryCursor {
        cursor(file: file, offset: UInt64(prefix.count), proof: digest(prefix))
    }

    private func digest(_ data: Data) -> String {
        AgentSessionProviderHistoryRecovery.sha256Hex(data)
    }

    private func candidate(_ result: Reader.Result, file: StaticString = #filePath, line: UInt = #line) -> Reader.Candidate? {
        guard case let .candidate(value) = result else {
            XCTFail("expected a candidate, got \(result)", file: file, line: line)
            return nil
        }
        return value
    }

    private var fromStart: Reader.Mode {
        .importAfter(cursor(file: nil, over: Data()))
    }

    /// One parallel tool turn: two assistant tool-use entries sharing an API message ID (chained by
    /// parent), each result parented to its own call entry and naming it as its source.
    private func parallelTurn(order: [Int]) -> [[String: Any]] {
        let parts: [[String: Any]] = [
            toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "msg-parallel"),
            toolUse("a2", parent: "a1", id: "toolu_2", name: "Grep", messageID: "msg-parallel"),
            toolResult("r1", parent: "a1", toolUseID: "toolu_1", text: "one", source: "a1"),
            toolResult("r2", parent: "a2", toolUseID: "toolu_2", text: "two", source: "a2")
        ]
        return [user("u1", parent: nil, "read both")] + order.map { parts[$0] }
            + [assistantText("a3", parent: "r2", "done")]
    }

    // MARK: Parallel tool association (pinned orders)

    func testParallelToolTurnValidatesInEveryPinnedOrder() throws {
        let orders = [[0, 1, 2, 3], [0, 2, 1, 3], [0, 1, 3, 2], [1, 0, 3, 2]]
        var projections: [[String]] = []
        for order in orders {
            let result = read(jsonl(parallelTurn(order: order)), mode: fromStart)
            let value = try XCTUnwrap(candidate(result), "order \(order)")
            XCTAssertEqual(value.completion, .unconfirmed, "Claude completion is never confirmed")
            let calls = value.rows.filter { $0.kind == .toolCall }
            let results = value.rows.filter { $0.kind == .toolResult }
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(results.count, 2, "parallel results stay separate entries")
            for result in results {
                let call = try XCTUnwrap(calls.first { $0.toolUseID == result.toolUseID })
                XCTAssertEqual(call.toolInvocationID, result.toolInvocationID, "result joins its own call")
                XCTAssertEqual(result.toolName, call.toolName)
            }
            projections.append(value.rows.map { "\($0.nativeEntryID)|\($0.kind.rawValue)|\($0.localItemID?.uuidString ?? "-")" }.sorted())
        }
        XCTAssertEqual(Set(projections.map { $0.joined(separator: ",") }).count, 1, "identities are order-independent")
    }

    func testLastTurnResultsInReversedOrderStillAssociate() throws {
        // The final turn writes its results in [1, 0] order and ends on the second result.
        let entries = [user("u1", parent: nil, "go")]
            + [
                toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "msg-last"),
                toolUse("a2", parent: "a1", id: "toolu_2", name: "Read", messageID: "msg-last"),
                toolResult("r2", parent: "a2", toolUseID: "toolu_2", text: "two", source: "a2"),
                toolResult("r1", parent: "a1", toolUseID: "toolu_1", text: "one", source: "a1")
            ]
        let value = try XCTUnwrap(candidate(read(jsonl(entries), mode: fromStart)))
        XCTAssertEqual(value.rows.filter { $0.kind == .toolResult }.map(\.nativeEntryID), ["r2", "r1"])
    }

    func testAssistantEntriesSharingMessageIDStaySeparateRows() throws {
        let entries = [
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "u1", "first", messageID: "msg-shared"),
            toolUse("a2", parent: "a1", id: "toolu_9", name: "Read", messageID: "msg-shared"),
            toolResult("r9", parent: "a2", toolUseID: "toolu_9", text: "ok", source: "a2"),
            assistantText("a3", parent: "r9", "second")
        ]
        let value = try XCTUnwrap(candidate(read(jsonl(entries), mode: fromStart)))
        XCTAssertEqual(value.rows.map(\.nativeEntryID), ["u1", "a1", "a2", "r9", "a3"])
        XCTAssertNil(value.rows[0].localItemID, "native user text is ledger-only")
        XCTAssertEqual(Set(value.rows.compactMap(\.localItemID)).count, 4)
    }

    // MARK: Whole-candidate rejection

    func testFileHistorySnapshotRejectsTheWholeCandidate() {
        let snapshot: [String: Any] = ["type": "file-history-snapshot", "messageId": "m", "snapshot": [String: String]()]
        let entries = [snapshot, user("u1", parent: nil, "hi")]
        XCTAssertEqual(read(jsonl(entries), mode: fromStart), .unsupported(.fileHistorySnapshot(line: 1)))
    }

    func testMalformedCompleteLineRejects() {
        var data = jsonl([user("u1", parent: nil, "hi")])
        data.append(Data("{not json\n".utf8))
        XCTAssertEqual(read(data, mode: fromStart), .unsupported(.malformedLine(line: 2)))
    }

    func testUnknownEntryTypeAndMetadataReject() {
        let system = entry("system", uuid: "s1", parent: nil, content: "x")
        XCTAssertEqual(read(jsonl([system]), mode: fromStart), .unsupported(.entryType("system", line: 1)))
        let sidechain = entry("user", uuid: "u1", parent: nil, content: "x", extra: ["isSidechain": true])
        XCTAssertEqual(read(jsonl([sidechain]), mode: fromStart), .unsupported(.metadata("isSidechain", line: 1)))
        let compacted = entry("user", uuid: "u1", parent: nil, content: "x", extra: ["logicalParentUuid": "zz"])
        XCTAssertEqual(read(jsonl([compacted]), mode: fromStart), .unsupported(.metadata("logicalParentUuid", line: 1)))
    }

    func testMissingParentRejects() {
        let entries = [user("u1", parent: nil, "hi"), assistantText("a1", parent: "ghost", "x")]
        XCTAssertEqual(read(jsonl(entries), mode: fromStart), .unsupported(.missingParent("a1")))
    }

    func testCycleRejects() {
        let entries = [
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "a2", "x"),
            assistantText("a2", parent: "a1", "y")
        ]
        XCTAssertEqual(read(jsonl(entries), mode: fromStart), .unsupported(.cycle))
    }

    func testAmbiguousBranchRejects() {
        let entries = [
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "u1", "x"),
            assistantText("a2", parent: "u1", "y")
        ]
        XCTAssertEqual(read(jsonl(entries), mode: fromStart), .unsupported(.ambiguousBranch("u1")))
    }

    func testAmbiguousToolAssociationRejects() {
        // A result whose source names a different call entry than its parent.
        let entries = [
            user("u1", parent: nil, "go"),
            toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "m"),
            toolUse("a2", parent: "a1", id: "toolu_2", name: "Read", messageID: "m"),
            toolResult("r1", parent: "a2", toolUseID: "toolu_1", text: "one", source: "a1")
        ]
        guard case .unsupported(.toolAssociation) = read(jsonl(entries), mode: fromStart) else {
            return XCTFail("expected a tool-association rejection")
        }
    }

    func testConflictingDuplicateEntryRejectsButIdenticalRepeatIsIdempotent() throws {
        let first = user("u1", parent: nil, "hi")
        let repeated = try XCTUnwrap(candidate(read(jsonl([first, first, assistantText("a1", parent: "u1", "x")]), mode: fromStart)))
        XCTAssertEqual(repeated.rows.count, 2)
        let conflicting = user("u1", parent: nil, "changed")
        XCTAssertEqual(read(jsonl([first, conflicting]), mode: fromStart), .unsupported(.conflictingDuplicate("u1")))
    }

    // MARK: Complete lines, cursor, rescan, dedup

    func testIncompleteTrailingLinePermitsTheValidatedPrefixOnly() throws {
        let complete = jsonl([user("u1", parent: nil, "hi"), assistantText("a1", parent: "u1", "x")])
        var data = complete
        data.append(Data("{\"type\":\"assistant\",\"uuid\":\"a2\"".utf8))
        let value = try XCTUnwrap(candidate(read(data, mode: fromStart)))
        XCTAssertEqual(value.completeLineOffset, UInt64(complete.count))
        XCTAssertEqual(value.rows.map(\.nativeEntryID), ["u1", "a1"])
    }

    func testBaselineOnMissingFileAndExistingFile() throws {
        let missing = try XCTUnwrap(candidate(read(nil, mode: .baseline)))
        XCTAssertNil(missing.file)
        XCTAssertEqual(missing.completeLineOffset, 0)
        let data = jsonl([user("u1", parent: nil, "hi")])
        let existing = try XCTUnwrap(candidate(read(data, mode: .baseline)))
        XCTAssertEqual(existing.file, identityA)
        XCTAssertEqual(existing.completeLineOffset, UInt64(data.count))
        XCTAssertTrue(existing.rows.isEmpty, "a baseline imports nothing")
        XCTAssertTrue(existing.validationRows.isEmpty, "a baseline projects nothing to validate")
        XCTAssertEqual(read(nil, mode: fromStart), .unavailable(.notFound))
    }

    func testBaselineAbsenceMustBeVerifiedNeverInferredFromAnInspectionFailure() {
        func read(_ access: Reader.FileAccess, roots: [URL]? = nil) -> Reader.Result {
            Reader.read(nativeSessionID: sessionID, projectsDirectories: roots ?? [projects], mode: .baseline, ledger: nil, fileAccess: access)
        }
        let failedRoot = Reader.FileAccess(
            candidates: { _, _ in .inspectionFailed("root unreadable") },
            identity: { _ in nil },
            capture: { _, _ in throw Reader.CaptureError.unreadable("unused") }
        )
        XCTAssertEqual(read(failedRoot), .unavailable(.inspectionFailed("root unreadable")), "a failed root is not an absent file")
        let listedURL = fileURL()
        let unidentifiedCandidate = Reader.FileAccess(
            candidates: { _, _ in .listed([listedURL]) },
            identity: { _ in nil },
            capture: { _, _ in throw Reader.CaptureError.unreadable("unused") }
        )
        guard case .unavailable(.inspectionFailed) = read(unidentifiedCandidate) else {
            return XCTFail("a listed candidate without identity is not absence")
        }
        guard case .unavailable(.inspectionFailed) = read(access([]), roots: []) else {
            return XCTFail("no authorized root establishes nothing")
        }
        XCTAssertNil(candidate(read(access([])))?.file, "verified absence (every root listed, nothing found) is a nil-file baseline")
    }

    func testBaselineRefusesAPartialTrailingRecordButAnImportWaitsForIt() throws {
        let complete = jsonl([user("u1", parent: nil, "hi")])
        let partial = jsonl([user("u1", parent: nil, "hi")], trailing: #"{"type":"assistant","uu"#)
        XCTAssertEqual(read(partial, mode: .baseline), .unavailable(.partialTrailingRecord))
        let whitespace = try XCTUnwrap(candidate(read(jsonl([user("u1", parent: nil, "hi")], trailing: " \r"), mode: .baseline)))
        XCTAssertEqual(whitespace.completeLineOffset, UInt64(complete.count), "trailing whitespace is not a record")
        let imported = try XCTUnwrap(candidate(read(partial, mode: fromStart)))
        XCTAssertEqual(imported.completeLineOffset, UInt64(complete.count), "an import decodes complete lines and waits")
    }

    func testLiveListingDistinguishesAMissingRootFromAnUninspectableOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionHistoryReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingRoot = root.appendingPathComponent("missing/projects", isDirectory: true)
        XCTAssertEqual(Reader.FileAccess.live.candidates([missingRoot], "\(sessionID).jsonl"), .listed([]), "a missing root holds nothing")
        let fileRoot = root.appendingPathComponent("projects-is-a-file")
        try Data("x".utf8).write(to: fileRoot)
        guard case .inspectionFailed = Reader.FileAccess.live.candidates([fileRoot], "\(sessionID).jsonl") else {
            return XCTFail("a root that cannot be listed is an inspection failure")
        }
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let project = projectsRoot.appendingPathComponent("-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: projectsRoot.appendingPathComponent("stray-file"))
        XCTAssertEqual(Reader.FileAccess.live.candidates([projectsRoot], "\(sessionID).jsonl"), .listed([]))
        let file = project.appendingPathComponent("\(sessionID).jsonl")
        try jsonl([user("u1", parent: nil, "hi")]).write(to: file)
        guard case let .listed(urls) = Reader.FileAccess.live.candidates([projectsRoot], "\(sessionID).jsonl") else {
            return XCTFail("listing failed")
        }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["\(sessionID).jsonl"])
    }

    func testSameFileImportReturnsOnlyRowsAfterTheCursor() throws {
        let prefix = jsonl([user("u1", parent: nil, "hi"), assistantText("a1", parent: "u1", "before")])
        let full = jsonl([
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "u1", "before"),
            user("u2", parent: "a1", "more"),
            assistantText("a2", parent: "u2", "after")
        ])
        let value = try XCTUnwrap(candidate(read(full, mode: .importAfter(cursor(file: identityA, over: prefix)))))
        XCTAssertFalse(value.isRescan)
        XCTAssertEqual(value.rows.map(\.nativeEntryID), ["u2", "a2"])
        // Step 4d3a: pre-frontier rows stay in the transient validation projection, in order.
        XCTAssertEqual(value.validationRows.map(\.nativeEntryID), ["u1", "a1", "u2", "a2"])
        XCTAssertEqual(Array(value.validationRows.suffix(2)), value.rows)
    }

    func testReplacementRescansOnlyWhenItsFencedPrefixVerifiesAndTruncationOrADifferentPrefixRefuses() throws {
        let entries = [
            user("u1", parent: nil, "hi"),
            assistantText("a1", parent: "u1", "before"),
            user("u2", parent: "a1", "more"),
            assistantText("a2", parent: "u2", "after")
        ]
        let firstBytes = jsonl(Array(entries.prefix(2)))
        let first = try XCTUnwrap(candidate(read(firstBytes, mode: fromStart)))
        let observation = Reader.observation(first)
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 2000)
        )
        XCTAssertEqual(plan.cursor.prefixSHA256, digest(firstBytes), "the cursor carries the proof of the bytes it was read from")
        XCTAssertEqual(plan.importCommit.target, plan.cursor.prefixFence, "the receipt binds the same target")
        // The file is replaced (new identity) with the same history plus a new turn: the fenced
        // prefix verifies byte-for-byte, so the strict rescan resumes exactly at the offset.
        let rescanned = try XCTUnwrap(candidate(read(
            jsonl(entries),
            identity: identityB,
            mode: .importAfter(plan.cursor),
            ledger: plan.ledger
        )))
        XCTAssertTrue(rescanned.isRescan)
        XCTAssertEqual(rescanned.rows.map(\.nativeEntryID), ["u2", "a2"], "known rows are never duplicated")
        // Truncation below the cursor refuses: no rewind, no ledger-based fallback.
        for identity in [identityA, identityB] {
            XCTAssertEqual(
                read(jsonl(Array(entries.prefix(1))), identity: identity, mode: .importAfter(plan.cursor), ledger: plan.ledger),
                .unsupported(.rewrittenHistory)
            )
        }
        // A replacement (or same-inode rewrite) whose prefix differs refuses before any ledger use.
        var rewritten = entries
        rewritten[1] = assistantText("a1", parent: "u1", "BEFORE")
        for identity in [identityA, identityB] {
            XCTAssertEqual(
                read(jsonl(rewritten), identity: identity, mode: .importAfter(plan.cursor), ledger: plan.ledger),
                .unsupported(.rewrittenHistory)
            )
        }
        // A legacy cursor without a proof is never trusted, even on the same file.
        XCTAssertEqual(
            read(jsonl(entries), mode: .importAfter(cursor(file: identityA, offset: UInt64(firstBytes.count), proof: nil)), ledger: plan.ledger),
            .unsupported(.prefixProofUnavailable)
        )
    }

    func testFileSelectionIsExactAndUnambiguous() {
        XCTAssertEqual(
            Reader.read(nativeSessionID: "NOT-A-UUID", projectsDirectories: [projects], mode: fromStart, ledger: nil, fileAccess: access([])),
            .unavailable(.invalidSessionID)
        )
        let data = jsonl([user("u1", parent: nil, "hi")])
        let two = access([(fileURL(project: "a"), identityA, data), (fileURL(project: "b"), identityB, data)])
        XCTAssertEqual(
            Reader.read(nativeSessionID: sessionID, projectsDirectories: [projects], mode: fromStart, ledger: nil, fileAccess: two),
            .unavailable(.ambiguous(count: 2))
        )
        let sameInode = access([(fileURL(project: "a"), identityA, data), (fileURL(project: "b"), identityA, data)])
        if case .candidate = Reader.read(nativeSessionID: sessionID, projectsDirectories: [projects], mode: fromStart, ledger: nil, fileAccess: sameInode) {} else {
            XCTFail("hard links to one file are one candidate")
        }
        XCTAssertEqual(
            Reader.read(nativeSessionID: sessionID, projectsDirectories: [projects], mode: fromStart, ledger: nil, fileAccess: access([(fileURL(), identityA, data)]), maximumBytes: 4),
            .unavailable(.tooLarge)
        )
    }

    func testDeterministicUUIDIsStableAndVersion8() {
        let one = Reader.deterministicUUID(namespace: "ns", components: ["a", "bc"])
        XCTAssertEqual(one, Reader.deterministicUUID(namespace: "ns", components: ["a", "bc"]))
        XCTAssertNotEqual(one, Reader.deterministicUUID(namespace: "ns", components: ["ab", "c"]), "length-prefixed components")
        let bytes = one.uuid
        XCTAssertEqual(bytes.6 >> 4, 0x8)
        XCTAssertEqual(bytes.8 >> 6, 0b10)
    }

    // MARK: Planner

    func testPlannerAppendsLabelledInertRowsOnceAndRecordsTheLedger() throws {
        let value = try XCTUnwrap(candidate(read(jsonl(parallelTurn(order: [0, 1, 2, 3])), mode: fromStart)))
        let observation = Reader.observation(value)
        XCTAssertFalse(observation.completionConfirmed)
        let importID = UUID()
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: importID,
            now: Date(timeIntervalSince1970: 3000)
        )
        XCTAssertEqual(plan.outcome, .importedUnconfirmed)
        XCTAssertEqual(plan.appendedItems.first?.kind, .system)
        XCTAssertEqual(plan.appendedItems.first?.text, AgentProviderHistoryImportPlanner.recoveredLabel)
        XCTAssertEqual(plan.appendedItems.dropFirst().map(\.kind), [.toolCall, .toolCall, .toolResult, .toolResult, .assistant])
        XCTAssertEqual(plan.ledger.nativeItems.count, value.rows.count, "user text is recorded ledger-only")
        XCTAssertEqual(plan.ledger.lastImportCommit?.importID, importID)
        XCTAssertEqual(plan.importCommit, plan.ledger.lastImportCommit)
        XCTAssertEqual(plan.cursor.importID, importID)
        XCTAssertNil(plan.previousImportID)

        let replay = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: Set(plan.appendedItems.map(\.id)),
            ledger: plan.ledger,
            previousCursor: plan.cursor,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 4000)
        )
        XCTAssertTrue(replay.appendedItems.isEmpty, "a replay appends nothing")
        XCTAssertEqual(replay.ledger.nativeItems.count, plan.ledger.nativeItems.count)
        XCTAssertEqual(replay.previousImportID, importID)
    }

    func testPlannerRecordsButNeverDuplicatesRowsAlreadyInTheTranscript() throws {
        let value = try XCTUnwrap(candidate(read(jsonl([user("u1", parent: nil, "hi"), assistantText("a1", parent: "u1", "x")]), mode: fromStart)))
        let observation = Reader.observation(value)
        let existing = try XCTUnwrap(observation.rows.compactMap(\.item).first?.id)
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: [existing],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date()
        )
        XCTAssertTrue(plan.appendedItems.isEmpty)
        XCTAssertEqual(plan.ledger.nativeItems.compactMap(\.localItemID), [existing])
    }

    // MARK: Step 4d2 capture-qualified single-text projection (sanitized, hand-written O19 shape)

    private static let contextSentinel = "SENTINEL-PRIVATE-CONTEXT-7f3a"
    private static let requestSentinel = "SENTINEL-REQUEST-BLOB-91c2"
    private let firstAttachmentTypes = ["environment", "model", "total_tokens_reminder", "budget_usd"]
    private let secondAttachmentTypes = ["session_context", "date", "credential_org", "prompt_snapshot"]

    /// A whitelisted nonrendering attachment whose payload is a private-context sentinel.
    private func attachment(
        _ uuid: String,
        parent: String?,
        type: String,
        payload: String = ClaudeSessionHistoryReaderTests.contextSentinel,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "type": "attachment",
            "uuid": uuid,
            "parentUuid": parent ?? NSNull(),
            "sessionId": sessionID,
            "attachment": ["type": type, "content": payload, "context": ["blob": payload]],
            "timestamp": "2026-10-23T00:00:00.000Z",
            "cwd": "/fixture/project",
            "version": "2.1.302",
            "isSidechain": false
        ]
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }

    /// An operational record (no graph identity) whose payload is a request-blob sentinel.
    private func operational(
        _ type: String,
        payload: String = ClaudeSessionHistoryReaderTests.requestSentinel,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "type": type,
            "sessionId": sessionID,
            "content": payload,
            "messages": [["role": "system", "content": payload]]
        ]
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }

    /// One O19-shaped turn: queue records, the caller's user entry, a chain of 8 whitelisted
    /// attachments interleaved with operational records, the one-text assistant reply, a trailing
    /// attachment after it, `last-prompt` naming that attachment, and `cost-state` (no session ID).
    private func o19Turn(
        caller: String = "c1",
        parent: String? = nil,
        assistant: String = "a1",
        prompt: String = "Reply with exactly: ALPHA-7",
        reply: String = "ALPHA-7",
        tag: String = "",
        contextPayload: String = ClaudeSessionHistoryReaderTests.contextSentinel,
        requestPayload: String = ClaudeSessionHistoryReaderTests.requestSentinel
    ) -> [[String: Any]] {
        var entries = [
            operational("queue-operation", payload: requestPayload, extra: ["operation": "enqueue"]),
            operational("queue-operation", payload: requestPayload, extra: ["operation": "dequeue"]),
            entry("user", uuid: caller, parent: parent, content: prompt, extra: ["promptId": "p\(tag)", "promptSource": "sdk"])
        ]
        var previous = caller
        for (index, type) in firstAttachmentTypes.enumerated() {
            let id = "n\(tag)\(index + 1)"
            entries.append(attachment(id, parent: previous, type: type, payload: contextPayload))
            previous = id
        }
        entries.append(operational("atis-latch", payload: requestPayload))
        for (index, type) in secondAttachmentTypes.enumerated() {
            let id = "n\(tag)\(index + 5)"
            entries.append(attachment(id, parent: previous, type: type, payload: contextPayload))
            previous = id
        }
        entries += [
            operational("api-request-shape", payload: requestPayload),
            operational("api-request-blob", payload: requestPayload),
            operational("api-request-blob", payload: requestPayload),
            operational("api-request", payload: requestPayload, extra: ["id": "req-\(tag)"]),
            entry(
                "assistant",
                uuid: assistant,
                parent: previous,
                content: [["type": "text", "text": reply]],
                messageID: "msg-\(assistant)",
                extra: ["requestId": "request-\(tag)"]
            ),
            attachment("t\(tag)", parent: assistant, type: "prompt_snapshot", payload: contextPayload),
            operational("last-prompt", payload: requestPayload, extra: ["leafUuid": "t\(tag)", "lastPrompt": prompt])
        ]
        var cost = operational("cost-state", payload: requestPayload)
        cost["sessionId"] = nil
        entries.append(cost)
        return entries
    }

    private func sha256(_ text: String) -> String {
        AgentSessionProviderHistoryRecovery.sha256Hex(Data(text.utf8))
    }

    private func rowSummary(_ rows: [Reader.Row]) -> [String] {
        rows.map { "\($0.nativeEntryID)|\($0.kind.rawValue)|\($0.ordinal)" }
    }

    func testCaptureQualifiedSingleTextTurnProjectsOnlyTheClaimedUserAndAssistantText() throws {
        let fixture = o19Turn()
        // This fixture and the S1 owner-profile one together cover every whitelisted attachment type
        // and every operational type.
        let s1 = s1Session()
        let covered = fixture + s1.firstTurn + s1.secondTurn
        let attachmentTypes = Set(covered.compactMap { ($0["attachment"] as? [String: Any])?["type"] as? String })
        XCTAssertEqual(attachmentTypes, Reader.attachmentTypes)
        XCTAssertEqual(Set(covered.compactMap { $0["type"] as? String }).subtracting(["user", "assistant", "attachment"]), Reader.operationalTypes)

        let data = jsonl(fixture)
        let value = try XCTUnwrap(candidate(read(data, mode: fromStart)))
        XCTAssertEqual(rowSummary(value.rows), ["c1|userText|0", "a1|assistantText|0"], "attachments and records never render")
        XCTAssertNil(value.rows[0].localItemID, "the native user entry is never projected")
        XCTAssertEqual(value.rows[1].text, "ALPHA-7")
        XCTAssertNotNil(value.rows[1].localItemID)
        for row in value.rows {
            XCTAssertTrue(AgentSessionProviderHistoryRecovery.isSHA256Hex(row.envelopeDigest))
        }
        XCTAssertNotEqual(value.rows[0].envelopeDigest, value.rows[1].envelopeDigest)
        XCTAssertEqual(value.userMessageEntries, [.init(nativeEntryID: "c1", textSHA256: sha256("Reply with exactly: ALPHA-7"))])
        XCTAssertEqual(value.completion, .unconfirmed, "the trailing attachment and last-prompt prove nothing")
        let observation = Reader.observation(value)
        XCTAssertEqual(observation.rows.compactMap(\.item).map(\.text), ["ALPHA-7"])
        XCTAssertEqual(observation.rows.map(\.envelopeDigest), value.rows.map { Optional($0.envelopeDigest) })
        XCTAssertEqual(observation.nativeUserEntries, value.userMessageEntries)

        // The same capture is a valid baseline (whole graph validated, no rows).
        let baseline = try XCTUnwrap(candidate(read(data, mode: .baseline)))
        XCTAssertEqual(baseline.completeLineOffset, UInt64(data.count))
        XCTAssertTrue(baseline.rows.isEmpty)
        XCTAssertTrue(baseline.validationRows.isEmpty)
        XCTAssertTrue(baseline.userMessageEntries.isEmpty)
    }

    /// S1 round 0: the CLI writes RepoPrompt's outbound user message as exactly one `{type, text}`
    /// block (K1's real prompt entries, with their prompt metadata keys); its text carries the same
    /// claim digest as string content. Any other array shape carries none, so it never matches a claim.
    func testASingleExactTextBlockUserEntryCarriesTheClaimDigestAndOtherArraysDoNot() throws {
        let text = "Reply with exactly: ALPHA-7"
        let promptMetadata: [String: Any] = [
            "promptId": "fixture-prompt", "promptSource": "sdk", "turnOrigin": "fixture", "turnPosition": 1,
            "permissionMode": "default", "entrypoint": "sdk-cli", "userType": "external", "gitBranch": "main"
        ]
        func digest(_ content: Any) throws -> String? {
            let value = try XCTUnwrap(candidate(read(
                jsonl([entry("user", uuid: "c1", parent: nil, content: content, extra: promptMetadata)]),
                mode: fromStart
            )))
            XCTAssertEqual(value.userMessageEntries.map(\.nativeEntryID), ["c1"])
            return value.userMessageEntries.first?.textSHA256
        }
        XCTAssertEqual(try digest([["type": "text", "text": text]]), sha256(text), "the CLI's outbound form")
        XCTAssertEqual(try digest(text), sha256(text))
        XCTAssertNil(try digest([["type": "text", "text": text, "cache_control": ["type": "ephemeral"]]]), "an extra block key")
        XCTAssertNil(try digest([["type": "text", "text": text], ["type": "text", "text": ""]]), "more than one block")
        XCTAssertNil(try digest([[String: Any]]()), "no block")
    }

    /// Step 4d3b parity: the live classifier's identity and proof for one O19 assistant text equal
    /// what this reader projects for the same native entry from the history file (same deterministic
    /// local ID, complete-envelope digest, ledger key and canonical row).
    func testLiveQualifiedTextMatchesTheHistoryProjectionOfTheSameEntry() throws {
        let value = try XCTUnwrap(candidate(read(jsonl(o19Turn()), mode: fromStart)))
        let historyRow = try XCTUnwrap(value.rows.first { $0.kind == .assistantText })
        var state = ClaudeLiveTranscriptProducerState(launchToken: UUID())
        state.markEligible()
        let outbound = UUID()
        state.noteOutbound(uuid: outbound, text: "Reply with exactly: ALPHA-7")
        let replay: [String: Any] = [
            "type": "user", "isReplay": true, "parent_tool_use_id": NSNull(), "session_id": sessionID,
            "uuid": outbound.uuidString.lowercased(), "message": ["role": "user", "content": "Reply with exactly: ALPHA-7"]
        ]
        let live: [String: Any] = [
            "type": "assistant", "uuid": "a1", "session_id": sessionID, "parent_tool_use_id": NSNull(),
            "message": [
                "id": "msg_live", "type": "message", "role": "assistant", "model": "claude-sonnet-5",
                "content": [["type": "text", "text": "ALPHA-7"]], "stop_reason": NSNull(), "stop_sequence": NSNull()
            ] as [String: Any]
        ]
        let replayData = try JSONSerialization.data(withJSONObject: replay)
        let liveData = try JSONSerialization.data(withJSONObject: live)
        XCTAssertEqual(state.classify(envelope: replayData, translated: [], turnInFlight: true), .benign)
        let outcome = state.classify(
            envelope: liveData,
            translated: [AIStreamResult(type: "content", text: "ALPHA-7")],
            turnInFlight: true
        )
        guard case let .attach(_, evidence) = outcome, case let .completeText(complete) = evidence.kind else {
            return XCTFail("expected an attachment, got \(outcome)")
        }
        XCTAssertEqual(complete.localItemID, historyRow.localItemID)
        XCTAssertEqual(complete.envelopeDigest, historyRow.envelopeDigest)
        XCTAssertEqual(
            complete.ledgerKey,
            AgentSessionProviderHistoryRecovery.rowKey(
                providerRaw: Reader.providerRaw,
                nativeSessionID: sessionID,
                nativeEntryID: historyRow.nativeEntryID,
                rowKindRaw: historyRow.kind.rawValue,
                ordinal: historyRow.ordinal
            )
        )
        let projected = try XCTUnwrap(Reader.item(for: historyRow))
        let canonical = try XCTUnwrap(complete.canonicalItem)
        XCTAssertEqual(canonical.id, projected.id)
        XCTAssertEqual(canonical.kind, projected.kind)
        XCTAssertEqual(canonical.text, projected.text)
        XCTAssertEqual(canonical.isStreaming, projected.isStreaming)
        // A known ledger entry with that proof is accepted by the reader; without it, refused.
        let proven = AgentSessionProviderHistoryRecovery(nativeItems: [complete.ledgerItem])
        XCTAssertNotNil(candidate(read(jsonl(o19Turn()), mode: fromStart, ledger: proven)))
        var invalidated = proven
        XCTAssertTrue(invalidated.invalidateClaudeEnvelopeProofs(forKeys: [complete.ledgerKey]))
        XCTAssertEqual(invalidated.nativeItems.map(\.key), proven.nativeItems.map(\.key))
        XCTAssertEqual(invalidated.nativeItems.map(\.localItemID), proven.nativeItems.map(\.localItemID))
        XCTAssertEqual(
            read(jsonl(o19Turn()), mode: fromStart, ledger: invalidated),
            .unsupported(.ledgerConflict("a1")),
            "a known entry without proof refuses"
        )
    }

    /// Step 4d3c: key-scoped invalidation clears only the listed Claude rows' proofs, typed and raw,
    /// keeping keys, local items and other members; an unlisted Claude row, a Codex row (even when its
    /// key is listed) and the ledger's receipt and extras are untouched; an empty set changes nothing.
    func testKeyScopedProofInvalidationTouchesOnlyListedClaudeRows() {
        typealias Item = AgentSessionProviderHistoryRecovery.NativeItem
        let typed = Item(
            providerRaw: "claude", nativeSessionID: "conv-1", nativeEntryID: "a1", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), envelopeDigest: String(repeating: "a", count: 64), extras: ["future": .bool(true)]
        )
        let raw = Item(
            providerRaw: "claude", nativeSessionID: "conv-1", nativeEntryID: "a2", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), extras: ["envelopeDigest": .string("NOT-HEX"), "future": .bool(true)]
        )
        let unlisted = Item(
            providerRaw: "claude", nativeSessionID: "conv-1", nativeEntryID: "a3", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), envelopeDigest: String(repeating: "c", count: 64)
        )
        let unlistedRaw = Item(
            providerRaw: "claude", nativeSessionID: "conv-1", nativeEntryID: "a4", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), extras: ["envelopeDigest": .string("NOT-HEX")]
        )
        let codex = Item(
            providerRaw: "codex", nativeSessionID: "t1", nativeEntryID: "i1", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), envelopeDigest: String(repeating: "b", count: 64)
        )
        let receipt = AgentSessionProviderHistoryRecovery.ImportCommit(
            importID: UUID(), providerRaw: "claude", conversationID: "conv-1", committedAt: Date(), rowCount: 0, target: nil
        )
        let original = AgentSessionProviderHistoryRecovery(
            nativeItems: [typed, raw, unlisted, unlistedRaw, codex], lastImportCommit: receipt, extras: ["ledgerFuture": .string("kept")]
        )
        var ledger = original
        XCTAssertFalse(ledger.invalidateClaudeEnvelopeProofs(forKeys: []), "an empty set changes nothing")
        XCTAssertEqual(ledger, original)
        XCTAssertFalse(ledger.invalidateClaudeEnvelopeProofs(forKeys: [codex.key, "unknown"]), "never a Codex row")
        XCTAssertEqual(ledger, original)

        XCTAssertTrue(ledger.invalidateClaudeEnvelopeProofs(forKeys: [typed.key, raw.key, codex.key]))
        XCTAssertEqual(ledger.nativeItems.map(\.key), original.nativeItems.map(\.key))
        XCTAssertEqual(ledger.nativeItems.map(\.localItemID), original.nativeItems.map(\.localItemID))
        XCTAssertEqual(
            ledger.nativeItems.map(\.envelopeDigest),
            [nil, nil, unlisted.envelopeDigest, nil, codex.envelopeDigest]
        )
        XCTAssertEqual(ledger.nativeItems[0].extras, ["future": .bool(true)])
        XCTAssertEqual(ledger.nativeItems[1].extras, ["future": .bool(true)], "the listed raw proof member is cleared")
        XCTAssertEqual(ledger.nativeItems[3].extras, unlistedRaw.extras, "an unlisted raw proof member is kept")
        XCTAssertEqual(ledger.nativeItems[4], codex)
        XCTAssertEqual(ledger.lastImportCommit, receipt)
        XCTAssertEqual(ledger.extras, ["ledgerFuture": .string("kept")])
        let once = ledger
        XCTAssertFalse(ledger.invalidateClaudeEnvelopeProofs(forKeys: [typed.key, raw.key]), "idempotent")
        XCTAssertEqual(ledger, once)
    }

    func testDirectChainProjectsInAncestorOrderWithOriginalIDsAndOrdinals() throws {
        // Two turns: the second user entry continues through the first turn's trailing attachment
        // (or, alternatively, from the assistant with that attachment as a side branch). File order
        // writes each assistant before its own user entry and the turns in reverse.
        let throughAttachment = o19Turn(tag: "x") + o19Turn(caller: "c2", parent: "tx", assistant: "a2", prompt: "Next", reply: "Done", tag: "y")
        let sideBranch = o19Turn(tag: "x") + o19Turn(caller: "c2", parent: "a1", assistant: "a2", prompt: "Next", reply: "Done", tag: "y")
        for (name, turns) in [("through", throughAttachment), ("side", sideBranch)] {
            let graph = turns.filter { $0["uuid"] != nil }
            let scrambled = Array(graph.reversed()) + turns.filter { $0["uuid"] == nil }
            let value = try XCTUnwrap(candidate(read(jsonl(scrambled), mode: fromStart)), name)
            XCTAssertEqual(
                rowSummary(value.rows),
                ["c1|userText|0", "a1|assistantText|0", "c2|userText|0", "a2|assistantText|0"],
                "\(name): ancestor order, not file order"
            )
            XCTAssertEqual(value.userMessageEntries.map(\.nativeEntryID), ["c1", "c2"], name)
        }
        // A two-block assistant keeps its native ordinals and one shared envelope digest.
        let twoBlocks = [
            user("u1", parent: nil, "hi"),
            entry("assistant", uuid: "a1", parent: "u1", content: [["type": "text", "text": "one"], ["type": "text", "text": "two"]], messageID: "m")
        ]
        let value = try XCTUnwrap(candidate(read(jsonl(twoBlocks), mode: fromStart)))
        XCTAssertEqual(rowSummary(value.rows), ["u1|userText|0", "a1|assistantText|0", "a1|assistantText|1"])
        XCTAssertEqual(value.rows[1].envelopeDigest, value.rows[2].envelopeDigest)
    }

    func testAttachmentAndRecordPayloadsNeverReachRowsDigestsOrRefusals() throws {
        let plain = try XCTUnwrap(candidate(read(jsonl(o19Turn()), mode: fromStart)))
        let other = try XCTUnwrap(candidate(read(
            jsonl(o19Turn(contextPayload: "other context", requestPayload: "other request")),
            mode: fromStart
        )))
        XCTAssertEqual(plain.rows, other.rows, "rows and digests are independent of nonrendering payloads")
        XCTAssertEqual(plain.userMessageEntries, other.userMessageEntries)
        let described = String(describing: plain)
        XCTAssertFalse(described.contains(Self.contextSentinel))
        XCTAssertFalse(described.contains(Self.requestSentinel))
        // A refusal names no payload, only the structural attachment type (P2-3).
        var unknown = o19Turn()
        unknown[4] = attachment("n2", parent: "n1", type: "hook_additional_context")
        let refusal = read(jsonl(unknown), mode: fromStart)
        XCTAssertEqual(refusal, .unsupported(.attachment(type: "hook_additional_context", line: 5)))
        XCTAssertFalse(String(describing: refusal).contains(Self.contextSentinel))
        // A type that isn't a short structural identifier is never carried.
        for freeText in ["has space", "PRIVATE/value", String(repeating: "a", count: 49), ""] {
            unknown[4] = attachment("n2", parent: "n1", type: freeText)
            XCTAssertEqual(read(jsonl(unknown), mode: fromStart), .unsupported(.attachment(type: nil, line: 5)), freeText)
        }
    }

    func testUnknownMalformedOrIdentityBearingNonrenderingRecordsRefuseTheWholeCandidate() {
        let root = user("u1", parent: nil, "hi")
        func refusal(_ entries: [[String: Any]]) -> Reader.Result {
            read(jsonl(entries), mode: fromStart)
        }
        XCTAssertEqual(
            refusal([root, attachment("n1", parent: "u1", type: "structured_output")]),
            .unsupported(.attachment(type: "structured_output", line: 2))
        )
        XCTAssertEqual(refusal([root, attachment("n1", parent: "u1", type: "hook_success")]), .unsupported(.attachment(type: "hook_success", line: 2)))
        XCTAssertEqual(refusal([root, entry("structured_output", uuid: "s1", parent: "u1", content: "x")]), .unsupported(.entryType("structured_output", line: 2)))
        var noAttachment = attachment("n1", parent: "u1", type: "date")
        noAttachment["attachment"] = nil
        XCTAssertEqual(refusal([root, noAttachment]), .unsupported(.attachment(type: nil, line: 2)))
        var numericType = attachment("n1", parent: "u1", type: "date")
        numericType["attachment"] = ["type": 7]
        XCTAssertEqual(refusal([root, numericType]), .unsupported(.attachment(type: nil, line: 2)))
        XCTAssertEqual(
            refusal([root, attachment("n1", parent: "u1", type: "date", extra: ["message": ["role": "user", "content": "x"]])]),
            .unsupported(.attachment(type: "date", line: 2)),
            "an attachment carrying a message is not the observed shape"
        )
        XCTAssertEqual(
            refusal([root, attachment("n1", parent: "u1", type: "date", extra: ["isSidechain": true])]),
            .unsupported(.metadata("isSidechain", line: 2))
        )
        XCTAssertEqual(refusal([root, attachment("n1", parent: "u1", type: "date", extra: ["sessionId": "other"])]), .unsupported(.sessionMismatch(line: 2)))
        XCTAssertEqual(refusal([root, attachment("n1", parent: "u1", type: "date", extra: ["uuid": 5])]), .unsupported(.malformedLine(line: 2)))
        // Operational records never carry graph identity (a null key still counts).
        XCTAssertEqual(refusal([operational("api-request", extra: ["uuid": "r1"]), root]), .unsupported(.operationalRecord("api-request", line: 1)))
        XCTAssertEqual(refusal([operational("last-prompt", extra: ["parentUuid": NSNull()]), root]), .unsupported(.operationalRecord("last-prompt", line: 1)))
        XCTAssertEqual(refusal([operational("cost-state", extra: ["sessionId": "other"]), root]), .unsupported(.sessionMismatch(line: 1)))
        XCTAssertEqual(refusal([operational("queue-operation-v2"), root]), .unsupported(.entryType("queue-operation-v2", line: 1)))
    }

    func testAttachmentsKeepEveryGraphSafeguard() {
        let root = user("u1", parent: nil, "hi")
        func refusal(_ entries: [[String: Any]]) -> Reader.Result {
            read(jsonl(entries), mode: fromStart)
        }
        XCTAssertEqual(refusal([root, attachment("n1", parent: "ghost", type: "date")]), .unsupported(.missingParent("n1")))
        XCTAssertEqual(
            refusal([root, attachment("n1", parent: "n2", type: "date"), attachment("n2", parent: "n1", type: "model")]),
            .unsupported(.cycle)
        )
        XCTAssertEqual(
            refusal([root, attachment("n1", parent: "u1", type: "date"), attachment("n1", parent: "u1", type: "model")]),
            .unsupported(.conflictingDuplicate("n1"))
        )
        XCTAssertEqual(refusal([attachment("n0", parent: nil, type: "date"), root]), .unsupported(.multipleRoots))
        // An attachment can't hide a second message branch.
        let hidden = [
            root,
            assistantText("a1", parent: "u1", "x"),
            attachment("n1", parent: "a1", type: "prompt_snapshot"),
            user("u2", parent: "n1", "branch one"),
            user("u3", parent: "a1", "branch two")
        ]
        XCTAssertEqual(refusal(hidden), .unsupported(.ambiguousBranch("a1")))
        // Two attachment-only side branches are not continuations.
        let sides = [
            root,
            attachment("n1", parent: "u1", type: "date"),
            attachment("n2", parent: "u1", type: "model"),
            assistantText("a1", parent: "u1", "x")
        ]
        XCTAssertEqual(rowSummary(candidate(refusal(sides))?.rows ?? []), ["u1|userText|0", "a1|assistantText|0"])
        // A tool result still needs its call as its direct parent: an attachment in between refuses.
        let interposed = [
            user("u1", parent: nil, "go"),
            toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "m"),
            attachment("n1", parent: "a1", type: "date"),
            toolResult("r1", parent: "n1", toolUseID: "toolu_1", text: "one", source: "a1")
        ]
        guard case .unsupported(.toolAssociation) = refusal(interposed) else {
            return XCTFail("tool association is never relaxed by an interposed attachment")
        }
        // Review A R2: an attachment-only sibling never turns a sequential result (no explicit
        // source) into a parallel fork; a genuine fork (two message-bearing children) still needs
        // its result's explicit source, with or without that sibling.
        let sequential = [
            user("u1", parent: nil, "go"),
            toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "m"),
            attachment("n1", parent: "a1", type: "date"),
            toolResult("r1", parent: "a1", toolUseID: "toolu_1", text: "one", source: nil),
            assistantText("a2", parent: "r1", "done")
        ]
        XCTAssertEqual(
            rowSummary(candidate(refusal(sequential))?.rows ?? []).map { $0.components(separatedBy: "|")[0] },
            ["u1", "a1", "r1", "a2"]
        )
        let fork = [
            user("u1", parent: nil, "go"),
            toolUse("a1", parent: "u1", id: "toolu_1", name: "Read", messageID: "m"),
            toolResult("r1", parent: "a1", toolUseID: "toolu_1", text: "one", source: nil),
            assistantText("a2", parent: "a1", "continued")
        ]
        XCTAssertEqual(refusal(fork), .unsupported(.toolAssociation("forked tool result without source r1")))
        XCTAssertEqual(
            refusal(fork + [attachment("n1", parent: "a1", type: "date")]),
            .unsupported(.toolAssociation("forked tool result without source r1"))
        )
    }

    func testDocumentedRetractionAndCompactionMarkersRefuseButAssistantThinkingIsSkipped() {
        let root = user("u1", parent: nil, "hi")
        func refusal(_ entries: [[String: Any]]) -> Reader.Result {
            read(jsonl(entries), mode: fromStart)
        }
        let superseding = entry("assistant", uuid: "a1", parent: "u1", content: [["type": "text", "text": "x"]], extra: ["supersedes": ["a0"]])
        XCTAssertEqual(refusal([root, superseding]), .unsupported(.semanticMarker("supersedes", line: 2)))
        var aborted = assistantText("a1", parent: "u1", "x")
        aborted["message"] = ["role": "assistant", "content": [["type": "text", "text": "x"]], "aborted": true]
        XCTAssertEqual(refusal([root, aborted]), .unsupported(.semanticMarker("aborted", line: 2)))
        let retraction = entry("user", uuid: "u2", parent: "u1", content: "y", extra: ["retracted_message_uuids": ["a0"]])
        XCTAssertEqual(refusal([root, retraction]), .unsupported(.semanticMarker("retracted_message_uuids", line: 2)))
        let notAborted = entry("assistant", uuid: "a1", parent: "u1", content: [["type": "text", "text": "x"]], extra: ["aborted": false])
        XCTAssertNotNil(candidate(refusal([root, notAborted])), "an explicit false is not a marker")
        // S1: assistant thinking is validated and skipped (no row, no ordinal, not in the digest); a
        // thinking-only entry stays a graph node that projects nothing.
        let thinking = entry("assistant", uuid: "a1", parent: "u1", content: [["type": "thinking", "thinking": "hmm", "signature": "s"]], messageID: "m")
        let reply = assistantText("a2", parent: "a1", "x", messageID: "m")
        XCTAssertEqual(rowSummary(candidate(refusal([root, thinking, reply]))?.rows ?? []), ["u1|userText|0", "a2|assistantText|0"])
        XCTAssertEqual(rowSummary(candidate(refusal([root, thinking]))?.rows ?? []), ["u1|userText|0"], "a thinking-only tip projects nothing")
        let mixed = entry("assistant", uuid: "a1", parent: "u1", content: [["type": "thinking", "thinking": "hmm"], ["type": "text", "text": "x"]])
        let mixedRows = candidate(refusal([root, mixed]))?.rows ?? []
        XCTAssertEqual(rowSummary(mixedRows), ["u1|userText|0", "a1|assistantText|0"], "the skipped block takes no ordinal")
        XCTAssertEqual(
            mixedRows.last?.envelopeDigest,
            Reader.singleTextAssistantRow(nativeSessionID: sessionID, nativeEntryID: "a1", text: "x")?.envelopeDigest,
            "thinking is outside the envelope digest"
        )
        XCTAssertFalse(String(describing: mixedRows).contains("hmm"), "thinking text is never kept")
        let summary = entry("user", uuid: "u2", parent: "u1", content: "s", extra: ["isCompactSummary": true])
        XCTAssertEqual(refusal([root, summary]), .unsupported(.metadata("isCompactSummary", line: 2)))
        let boundary = entry("system", uuid: "s1", parent: "u1", content: "x", extra: ["subtype": "compact_boundary"])
        XCTAssertEqual(refusal([root, boundary]), .unsupported(.entryType("system", line: 2)))
    }

    /// S1 keeps refusing every thinking shape except a plain assistant `thinking` block.
    func testRedactedThinkingUserThinkingAndMalformedThinkingStillRefuse() {
        let root = user("u1", parent: nil, "hi")
        func refusal(_ entries: [[String: Any]]) -> Reader.Result {
            read(jsonl(entries), mode: fromStart)
        }
        let redacted = entry("assistant", uuid: "a1", parent: "u1", content: [["type": "redacted_thinking", "data": "opaque"]])
        XCTAssertEqual(refusal([root, redacted]), .unsupported(.contentBlock("redacted_thinking", line: 2)))
        XCTAssertEqual(read(jsonl([root, redacted]), mode: .baseline), .unsupported(.contentBlock("redacted_thinking", line: 2)))
        let userThinking = entry("user", uuid: "u2", parent: "u1", content: [["type": "thinking", "thinking": "hmm"]])
        XCTAssertEqual(refusal([root, userThinking]), .unsupported(.contentBlock("thinking", line: 2)), "only an assistant thinks")
        let malformed = entry("assistant", uuid: "a1", parent: "u1", content: [["type": "thinking", "thinking": 7]])
        XCTAssertEqual(refusal([root, malformed]), .unsupported(.malformedLine(line: 2)))
        let missing = entry("assistant", uuid: "a1", parent: "u1", content: [["type": "thinking"]])
        XCTAssertEqual(refusal([root, missing]), .unsupported(.malformedLine(line: 2)))
    }

    // MARK: S1 owner-profile default-configuration shape (sanitized K1 structure, invented text)

    private func thinkingAssistant(_ uuid: String, parent: String, messageID: String) -> [String: Any] {
        entry(
            "assistant",
            uuid: uuid,
            parent: parent,
            content: [["type": "thinking", "thinking": Self.contextSentinel, "signature": "sig"]],
            messageID: messageID
        )
    }

    /// K1 lines 1–26 (the first turn: 10 attachments in one chain, request records, titles, a
    /// thinking-only entry and its one-text reply sharing an API message ID, a trailing snapshot) and
    /// a second turn: thinking → tool call (same message ID) → associated result → reply, plus the
    /// remaining owner-profile attachment and title records.
    private func s1Session() -> (firstTurn: [[String: Any]], secondTurn: [[String: Any]]) {
        var first: [[String: Any]] = [
            operational("queue-operation", extra: ["operation": "enqueue"]),
            operational("queue-operation", extra: ["operation": "dequeue"]),
            entry("user", uuid: "c1", parent: nil, content: [["type": "text", "text": "Warm up: reply OK"]], extra: ["promptId": "p1"])
        ]
        var previous = "c1"
        let types = [
            "environment", "model", "mcp_instructions_delta", "skill_listing", "total_tokens_reminder", "instructions",
            "session_context", "date", "remote_session_change", "prompt_snapshot"
        ]
        for (index, type) in types.enumerated() {
            if index == 5 { first.append(operational("atis-latch")) }
            first.append(attachment("s\(index)", parent: previous, type: type))
            previous = "s\(index)"
        }
        first += [
            operational("api-request-shape"),
            operational("api-request-blob"),
            operational("api-request"),
            operational("last-prompt", extra: ["leafUuid": previous]),
            operational("atis-latch"),
            operational("ai-title", extra: ["aiTitle": "Warm-up"]),
            thinkingAssistant("a1t", parent: previous, messageID: "msg-a1"),
            assistantText("a1", parent: "a1t", "OK", messageID: "msg-a1"),
            attachment("t1", parent: "a1", type: "prompt_snapshot"),
            operational("last-prompt", extra: ["leafUuid": "t1"]),
            operational("ai-title", extra: ["aiTitle": "Warm-up"]),
            operational("atis-latch")
        ]
        let second: [[String: Any]] = [
            operational("queue-operation", extra: ["operation": "enqueue"]),
            operational("queue-operation", extra: ["operation": "dequeue"]),
            entry("user", uuid: "c2", parent: "t1", content: [["type": "text", "text": "List the files"]], extra: ["promptId": "p2"]),
            attachment("s10", parent: "c2", type: "total_tokens_reminder"),
            attachment("s11", parent: "s10", type: "date"),
            attachment("s12", parent: "s11", type: "deferred_tools_delta"),
            attachment("s13", parent: "s12", type: "agent_listing_delta"),
            attachment("s14", parent: "s13", type: "thinking_drop"),
            operational("api-request-blob"),
            operational("api-request"),
            operational("custom-title", extra: ["customTitle": "Fixture"]),
            operational("agent-name", extra: ["agentName": "Fixture"]),
            thinkingAssistant("a2t", parent: "s14", messageID: "msg-a2"),
            toolUse("a2", parent: "a2t", id: "toolu_1", name: "Bash", messageID: "msg-a2"),
            toolResult("r2", parent: "a2", toolUseID: "toolu_1", text: "README.md", source: "a2"),
            assistantText("a3", parent: "r2", "One file.", messageID: "msg-a3")
        ]
        return (first, second)
    }

    func testOwnerProfileDefaultConfigurationSessionBaselinesAndImportsWithoutThinkingRows() throws {
        let session = s1Session()
        let firstData = jsonl(session.firstTurn)
        // Before S1 this refused at line 6 (`mcp_instructions_delta`), so no baseline was ever taken.
        let baseline = try XCTUnwrap(candidate(read(firstData, mode: .baseline)))
        XCTAssertEqual(baseline.completeLineOffset, UInt64(firstData.count))
        XCTAssertEqual(baseline.prefixSHA256, digest(firstData))

        let full = firstData + jsonl(session.secondTurn)
        let after = try XCTUnwrap(candidate(read(full, mode: .importAfter(cursor(file: identityA, over: firstData)))))
        XCTAssertEqual(
            rowSummary(after.rows),
            ["c2|userText|0", "a2|toolCall|0", "r2|toolResult|0", "a3|assistantText|0"],
            "thinking, attachments and records never render"
        )
        XCTAssertEqual(after.userMessageEntries.map(\.nativeEntryID), ["c2"])
        XCTAssertEqual(after.rows.first { $0.kind == .toolResult }?.toolName, "Bash")

        let whole = try XCTUnwrap(candidate(read(full, mode: fromStart)))
        XCTAssertEqual(
            rowSummary(whole.rows),
            ["c1|userText|0", "a1|assistantText|0", "c2|userText|0", "a2|toolCall|0", "r2|toolResult|0", "a3|assistantText|0"]
        )
        XCTAssertFalse(String(describing: whole).contains(Self.contextSentinel), "thinking and attachment payloads are never kept")
        XCTAssertNotNil(candidate(read(full, mode: .baseline)))

        // Title records still never carry graph identity.
        var identified = session.firstTurn
        identified[19] = operational("ai-title", extra: ["uuid": "x1"])
        XCTAssertEqual(read(jsonl(identified), mode: .baseline), .unsupported(.operationalRecord("ai-title", line: 20)))
    }

    func testRefusalsBeforeTheCursorStillRejectWithAKnownLedger() throws {
        let earlier = o19Turn(tag: "x")
        let later = o19Turn(caller: "c2", parent: "tx", assistant: "a2", prompt: "Next", reply: "Done", tag: "y")
        let full = try XCTUnwrap(candidate(read(jsonl(earlier + later), mode: fromStart)))
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: Reader.observation(full),
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 5000)
        )
        // An unsupported record in the region the cursor and ledger would skip still refuses.
        var poisoned = earlier
        poisoned[3] = attachment("nx1", parent: "c1", type: "hook_success")
        let prefix = jsonl(poisoned)
        XCTAssertEqual(
            read(jsonl(poisoned + later), mode: .importAfter(cursor(file: identityA, over: prefix)), ledger: plan.ledger),
            .unsupported(.attachment(type: "hook_success", line: 4))
        )
    }

    func testLedgerKnownEntriesMustMatchTheirCompleteEnvelopeBeforeSuppression() throws {
        let fixture = o19Turn()
        let first = try XCTUnwrap(candidate(read(jsonl(fixture), mode: fromStart)))
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: Reader.observation(first),
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 6000)
        )
        XCTAssertEqual(
            plan.ledger.nativeItems.map(\.envelopeDigest),
            first.rows.map { Optional($0.envelopeDigest) },
            "every row records its entry's proof"
        )
        let replay = try XCTUnwrap(candidate(read(jsonl(fixture), mode: fromStart, ledger: plan.ledger)))
        XCTAssertTrue(replay.rows.isEmpty, "a fully proven known entry is suppressed")
        // Step 4d3a: suppression never drops the known rows from the transient validation
        // projection, so their canonical payloads can be compared before overlap is accepted.
        XCTAssertEqual(replay.validationRows, first.rows, "known rows are retained for validation")
        let replayObservation = Reader.observation(replay)
        XCTAssertTrue(replayObservation.rows.isEmpty)
        func summary(_ rows: [AgentProviderHistoryRow]) -> [String] {
            // Item timestamps differ per projection; identity, payload and proof do not.
            rows.map { "\($0.nativeEntryID)|\($0.rowKindRaw)|\($0.ordinal)|\($0.item?.id.uuidString ?? "-")|\($0.item?.text ?? "-")|\($0.envelopeDigest ?? "-")" }
        }
        XCTAssertEqual(summary(replayObservation.validationRows), summary(Reader.observation(first).rows))
        XCTAssertEqual(
            replayObservation.validationRows.compactMap { $0.item?.id },
            plan.ledger.nativeItems.compactMap(\.localItemID),
            "each retained row carries the local ID its ledger row maps"
        )
        XCTAssertEqual(replay.userMessageEntries.map(\.nativeEntryID), ["c1"], "known user entries are still reported for claim matching")

        let changed = read(jsonl(o19Turn(reply: "ALPHA-8")), mode: fromStart, ledger: plan.ledger)
        XCTAssertEqual(changed, .unsupported(.ledgerConflict("a1")), "a changed payload under a known ID")

        func ledger(_ transform: ([AgentSessionProviderHistoryRecovery.NativeItem]) -> [AgentSessionProviderHistoryRecovery.NativeItem]) -> AgentSessionProviderHistoryRecovery {
            AgentSessionProviderHistoryRecovery(nativeItems: transform(plan.ledger.nativeItems), lastImportCommit: plan.ledger.lastImportCommit)
        }
        func item(_ source: AgentSessionProviderHistoryRecovery.NativeItem, entryID: String? = nil, ordinal: Int? = nil, digest: String??) -> AgentSessionProviderHistoryRecovery.NativeItem {
            .init(
                providerRaw: source.providerRaw,
                nativeSessionID: source.nativeSessionID,
                nativeEntryID: entryID ?? source.nativeEntryID,
                rowKindRaw: source.rowKindRaw,
                ordinal: ordinal ?? source.ordinal,
                localItemID: source.localItemID,
                envelopeDigest: digest ?? source.envelopeDigest
            )
        }
        let legacy = ledger { $0.map { item($0, digest: .some(nil)) } }
        XCTAssertEqual(read(jsonl(fixture), mode: fromStart, ledger: legacy), .unsupported(.ledgerConflict("c1")), "missing legacy proof")
        let superset = ledger { $0 + [item($0[1], ordinal: 1, digest: .none)] }
        XCTAssertEqual(read(jsonl(fixture), mode: fromStart, ledger: superset), .unsupported(.ledgerConflict("a1")), "known keys beyond the entry")
        let vanished = ledger { $0 + [item($0[1], entryID: "gone", digest: .none)] }
        XCTAssertEqual(read(jsonl(fixture), mode: fromStart, ledger: vanished), .unsupported(.ledgerConflict("gone")), "a known entry no longer present")

        // A partial keyset of a two-block entry refuses rather than importing the rest.
        let twoBlocks = [
            user("u1", parent: nil, "hi"),
            entry("assistant", uuid: "a1", parent: "u1", content: [["type": "text", "text": "one"], ["type": "text", "text": "two"]], messageID: "m")
        ]
        let whole = try XCTUnwrap(candidate(read(jsonl(twoBlocks), mode: fromStart)))
        let wholePlan = AgentProviderHistoryImportPlanner.plan(
            observation: Reader.observation(whole),
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 6100)
        )
        let partial = AgentSessionProviderHistoryRecovery(nativeItems: wholePlan.ledger.nativeItems.filter { !($0.nativeEntryID == "a1" && $0.ordinal == 1) })
        XCTAssertEqual(read(jsonl(twoBlocks), mode: fromStart, ledger: partial), .unsupported(.ledgerConflict("a1")))
    }

    /// Step 4d7: an agreed live row's ledger entry (the exact projection an import of the same native
    /// entry records) stays a known key that every later read validates even before the frontier.
    /// With the cursor past it, Claude's unchanged entry is suppressed; the same entry changed,
    /// missing, retracted, or known without a proof refuses (never skipped by the cursor).
    func testALiveAgreedEntryBeforeTheFrontierDeduplicatesOnlyWhileUnchanged() throws {
        let earlier = o19Turn(tag: "x")
        let later = o19Turn(caller: "c2", parent: "tx", assistant: "a2", prompt: "Next", reply: "Done", tag: "y")
        let live = try XCTUnwrap(ClaudeLiveTranscriptCompleteText.projecting(nativeSessionID: sessionID, nativeEntryID: "a1", text: "ALPHA-7"))
        let first = try XCTUnwrap(candidate(read(jsonl(earlier), mode: fromStart)))
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: Reader.observation(first),
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 6200)
        )
        XCTAssertEqual(plan.ledger.nativeItems.first { $0.nativeEntryID == "a1" }, live.ledgerItem, "the live projection is the import's entry")
        let agreed = AgentSessionProviderHistoryRecovery(nativeItems: [live.ledgerItem])
        func readAfter(_ prefix: [[String: Any]], ledger: AgentSessionProviderHistoryRecovery? = nil) -> Reader.Result {
            read(jsonl(prefix + later), mode: .importAfter(cursor(file: identityA, over: jsonl(prefix))), ledger: ledger ?? agreed)
        }

        let unchanged = try XCTUnwrap(candidate(readAfter(earlier)))
        XCTAssertFalse(unchanged.rows.contains { $0.nativeEntryID == "a1" }, "the agreed entry is never imported again")
        XCTAssertTrue(unchanged.rows.contains { $0.nativeEntryID == "a2" }, "later output is still read")

        XCTAssertEqual(readAfter(o19Turn(reply: "ALPHA-8", tag: "x")), .unsupported(.ledgerConflict("a1")), "changed")
        let gone = try XCTUnwrap(ClaudeLiveTranscriptCompleteText.projecting(nativeSessionID: sessionID, nativeEntryID: "gone", text: "ALPHA-7"))
        XCTAssertEqual(
            readAfter(earlier, ledger: AgentSessionProviderHistoryRecovery(nativeItems: [live.ledgerItem, gone.ledgerItem])),
            .unsupported(.ledgerConflict("gone")),
            "missing"
        )
        var retracted = earlier
        let replyIndex = try XCTUnwrap(retracted.firstIndex { $0["uuid"] as? String == "a1" })
        retracted[replyIndex]["supersedes"] = ["a0"]
        guard case .unsupported(.semanticMarker("supersedes", _)) = readAfter(retracted) else {
            return XCTFail("retracted: \(readAfter(retracted))")
        }
        let proofless = AgentSessionProviderHistoryRecovery(nativeItems: [.init(
            providerRaw: live.ledgerItem.providerRaw, nativeSessionID: live.ledgerItem.nativeSessionID,
            nativeEntryID: live.ledgerItem.nativeEntryID, rowKindRaw: live.ledgerItem.rowKindRaw,
            ordinal: live.ledgerItem.ordinal, localItemID: live.ledgerItem.localItemID, envelopeDigest: nil
        )])
        XCTAssertEqual(readAfter(earlier, ledger: proofless), .unsupported(.ledgerConflict("a1")), "proofless")
    }

    func testASameFileCursorMustStayOnARecordBoundaryAndNeverSplitTheGraph() {
        let prefix = jsonl([user("u1", parent: nil, "hi")])
        let full = jsonl([user("u1", parent: nil, "hi"), assistantText("a1", parent: "u1", "x")])
        XCTAssertEqual(
            read(full, mode: .importAfter(cursor(file: identityA, over: full.prefix(prefix.count - 1)))),
            .unsupported(.rewrittenHistory),
            "an in-place rewrite moved the boundary inside a record (even with a matching digest)"
        )
        // A rewrite that puts a child before the cursor and its parent after it.
        let reordered = jsonl([assistantText("a1", parent: "u1", "x"), user("u1", parent: nil, "hi")])
        let firstLine = jsonl([assistantText("a1", parent: "u1", "x")])
        XCTAssertEqual(
            read(reordered, mode: .importAfter(cursor(file: identityA, over: firstLine))),
            .unsupported(.rewrittenHistory)
        )
        XCTAssertNotNil(candidate(read(full, mode: .importAfter(cursor(file: identityA, over: prefix)))))
    }

    // MARK: Step 4d2 byte-prefix fences

    func testCandidatesCarryTheExactRawDigestOfTheirCompleteLinesOnly() throws {
        let complete = jsonl([user("u1", parent: nil, "hi"), assistantText("a1", parent: "u1", "x")])
        let baseline = try XCTUnwrap(candidate(read(complete, mode: .baseline)))
        XCTAssertEqual(baseline.prefixSHA256, digest(complete))
        var whitespace = complete
        whitespace.append(Data(" \r".utf8))
        XCTAssertEqual(try XCTUnwrap(candidate(read(whitespace, mode: .baseline))).prefixSHA256, digest(complete), "trailing whitespace is not hashed")
        // An appended partial tail is excluded from both the offset and the proof.
        var partial = complete
        partial.append(Data(#"{"type":"assistant","uu"#.utf8))
        let imported = try XCTUnwrap(candidate(read(partial, mode: fromStart)))
        XCTAssertEqual(imported.completeLineOffset, UInt64(complete.count))
        XCTAssertEqual(imported.prefixSHA256, digest(complete))
        XCTAssertEqual(Reader.observation(imported).prefixSHA256, digest(complete))
        // Original newlines, no normalization.
        let text = try XCTUnwrap(String(data: complete, encoding: .utf8))
        let crlf = Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let crlfBaseline = try XCTUnwrap(candidate(read(crlf, mode: .baseline)))
        XCTAssertEqual(crlfBaseline.prefixSHA256, digest(crlf))
        XCTAssertNotEqual(crlfBaseline.prefixSHA256, digest(complete))
        // Verified absence and an existing empty file both prove the empty prefix, never nil, and
        // stay distinguishable by their file identity.
        let absent = try XCTUnwrap(candidate(read(nil, mode: .baseline)))
        let empty = try XCTUnwrap(candidate(read(Data(), mode: .baseline)))
        XCTAssertEqual(absent.prefixSHA256, digest(Data()))
        XCTAssertEqual(empty.prefixSHA256, digest(Data()))
        XCTAssertNil(absent.file)
        XCTAssertEqual(empty.file, identityA)
        XCTAssertEqual(empty.completeLineOffset, 0)
    }

    func testASameLengthChangeBeforeTheBoundaryRefusesEvenInNonrenderingBytes() {
        let earlier = o19Turn(tag: "x")
        let later = o19Turn(caller: "c2", parent: "tx", assistant: "a2", prompt: "Next", reply: "Done", tag: "y")
        let boundaryBytes = jsonl(earlier)
        let boundary = cursor(file: identityA, over: boundaryBytes)
        XCTAssertNotNil(candidate(read(jsonl(earlier + later), mode: .importAfter(boundary))))
        // The same graph with one nonrendering payload changed at the same length: the semantic
        // envelope can't see it, the byte fence does (same inode).
        let contextChanged = o19Turn(tag: "x", contextPayload: "SENTINEL-PRIVATE-CONTEXT-7f3b")
        let recordChanged = o19Turn(tag: "x", requestPayload: "SENTINEL-REQUEST-BLOB-91c3")
        for changed in [contextChanged, recordChanged] {
            XCTAssertEqual(jsonl(changed).count, boundaryBytes.count)
            XCTAssertEqual(read(jsonl(changed + later), mode: .importAfter(boundary)), .unsupported(.rewrittenHistory))
        }
        // A malformed or missing proof fails closed.
        for proof in [nil, "ABC", digest(boundaryBytes).uppercased()] {
            XCTAssertEqual(
                read(jsonl(earlier + later), mode: .importAfter(cursor(file: identityA, offset: UInt64(boundaryBytes.count), proof: proof))),
                .unsupported(.prefixProofUnavailable)
            )
        }
    }

    func testEveryCallerFenceIsVerifiedOnTheSameBufferBesideTheBoundary() throws {
        let earlier = o19Turn(tag: "x")
        let later = o19Turn(caller: "c2", parent: "tx", assistant: "a2", prompt: "Next", reply: "Done", tag: "y")
        let boundary = cursor(file: identityA, over: Data())
        let target = AgentRecoveryHistoryPrefixFence(
            file: identityA,
            completeLineOffset: UInt64(jsonl(earlier).count),
            prefixSHA256: digest(jsonl(earlier))
        )
        func read(_ entries: [[String: Any]], fences: [AgentRecoveryHistoryPrefixFence], mode: Reader.Mode? = nil) -> Reader.Result {
            Reader.read(
                nativeSessionID: sessionID,
                projectsDirectories: [projects],
                mode: mode ?? .importAfter(boundary),
                ledger: nil,
                fences: fences,
                fileAccess: access([(fileURL(), identityA, jsonl(entries))])
            )
        }
        XCTAssertNotNil(candidate(read(earlier + later, fences: [target])))
        // A change AFTER the boundary but BEFORE a later fenced target refuses.
        let changed = o19Turn(tag: "x", contextPayload: "SENTINEL-PRIVATE-CONTEXT-7f3b")
        XCTAssertNotNil(candidate(read(changed + later, fences: [])), "the boundary alone can't see it")
        XCTAssertEqual(read(changed + later, fences: [target]), .unsupported(.rewrittenHistory))
        // A fence beyond the complete lines (truncation) or without a proof refuses.
        XCTAssertEqual(read(Array(earlier.prefix(3)), fences: [target]), .unsupported(.rewrittenHistory))
        let unproven = AgentRecoveryHistoryPrefixFence(file: identityA, completeLineOffset: 0, prefixSHA256: nil)
        XCTAssertEqual(read(earlier + later, fences: [unproven]), .unsupported(.prefixProofUnavailable))
        // A baseline verifies its fences too (and produces its own proof).
        XCTAssertEqual(
            try XCTUnwrap(candidate(read(earlier + later, fences: [target], mode: .baseline))).prefixSHA256,
            digest(jsonl(earlier + later))
        )
        XCTAssertEqual(read(changed + later, fences: [target], mode: .baseline), .unsupported(.rewrittenHistory))
        // Verified absence satisfies only an empty-prefix fence.
        let absent = Reader.read(
            nativeSessionID: sessionID, projectsDirectories: [projects], mode: .baseline, ledger: nil, fences: [target], fileAccess: access([])
        )
        XCTAssertEqual(absent, .unsupported(.rewrittenHistory))
        let emptyFence = AgentRecoveryHistoryPrefixFence(file: nil, completeLineOffset: 0, prefixSHA256: digest(Data()))
        XCTAssertNotNil(candidate(Reader.read(
            nativeSessionID: sessionID, projectsDirectories: [projects], mode: .baseline, ledger: nil, fences: [emptyFence], fileAccess: access([])
        )))
    }

    // MARK: Step 4d4 successful main-thread Read across a same-session resume (sanitized O20 shape)

    /// Modeled on the sanitized phase4d-tool-resume-capture O20 observations (CLI 2.1.302): no
    /// captured ids, paths, file contents, attachment or request payloads. Opaque payloads are the
    /// private-context / request sentinels, so they never reach rows or digests. Operational counts
    /// are reduced: api-request-shape, repeated request blobs and the later atis-latch are omitted;
    /// this is a semantic graph fixture, not an ordinal-for-ordinal capture copy.
    private static let o20Tokens = ["BRAVO-42", "CHARLIE-19", "DELTA-63"]

    private func o20Caller(_ exchange: Int) -> String {
        "c0000000-0000-4000-8000-00000000000\(exchange)"
    }

    private func o20ToolUseID(_ exchange: Int) -> String {
        "toolu_o20_\(exchange)"
    }

    private func settingMessage(_ object: [String: Any], _ extra: [String: Any]) -> [String: Any] {
        var object = object
        var message = object["message"] as? [String: Any] ?? [:]
        for (key, value) in extra {
            message[key] = value
        }
        object["message"] = message
        return object
    }

    /// One O20 exchange: queue records, the caller's string-content prompt (a new anchor), an
    /// attachment chain, the one-block `tool_use` Read assistant, its tool-result user entry (own
    /// UUID, parented DIRECTLY on the call, naming it as source, string content, no `is_error`,
    /// top-level `toolUseResult`/`permissionDecision` metadata), a second attachment chain, the
    /// one-text final assistant parented on the last attachment, and `last-prompt`. `nativeStops`
    /// sets native `stop_reason` (`tool_use`/`end_turn`); otherwise null as on stdout.
    private func o20Exchange(_ exchange: Int, parent: String?, nativeStops: Bool = true) -> [[String: Any]] {
        let caller = o20Caller(exchange)
        let call = "o20-u\(exchange)a", result = "o20-u\(exchange)b", answer = "o20-u\(exchange)c"
        let toolUseID = o20ToolUseID(exchange)
        let token = Self.o20Tokens[exchange - 1]
        let request = Self.requestSentinel
        var entries = [
            operational("queue-operation", extra: ["operation": "enqueue"]),
            operational("queue-operation", extra: ["operation": "dequeue"]),
            entry("user", uuid: caller, parent: parent, content: "Use Read on fixture\(exchange), then reply with its token.", extra: [
                "promptId": "o20-p\(exchange)", "promptSource": "sdk", "turnOrigin": "sdk", "permissionMode": "default",
                "turnPosition": ["promptIndex": exchange - 1, "turnIndex": exchange]
            ])
        ]
        var previous = caller
        // The first prompt carries the full context chain (with `atis-latch`); later ones, including
        // the resumed prompt, re-inject only the token/budget reminders.
        let leading = exchange == 1 ? firstAttachmentTypes + secondAttachmentTypes : ["total_tokens_reminder", "budget_usd"]
        for (index, type) in leading.enumerated() {
            let id = "o20-n\(exchange)-\(index)"
            entries.append(attachment(id, parent: previous, type: type))
            previous = id
            if exchange == 1, index == firstAttachmentTypes.count - 1 { entries.append(operational("atis-latch")) }
        }
        entries += [operational("api-request-blob"), operational("api-request", extra: ["id": "req-o20-\(exchange)a"])]
        entries.append(settingMessage(entry(
            "assistant",
            uuid: call,
            parent: previous,
            content: [["type": "tool_use", "id": toolUseID, "name": "Read", "input": ["file_path": "/fixture/workspace/fixture\(exchange)"]]],
            messageID: "msg-o20-\(exchange)a",
            extra: [
                "requestId": "request-o20-\(exchange)a", "wireToolInputs": [request], "apiBlockIndex": 0,
                "effort": "high", "perTurnEffort": "high", "requestedModel": "fixture-model", "version": "2.1.302"
            ]
        ), ["stop_reason": nativeStops ? "tool_use" : NSNull(), "model": "fixture-model"]))
        entries.append(entry(
            "user",
            uuid: result,
            parent: call,
            content: [["type": "tool_result", "tool_use_id": toolUseID, "content": token]],
            source: call,
            extra: [
                "promptId": "o20-p\(exchange)", "version": "2.1.302",
                "toolUseResult": ["type": "text", "file": [
                    "content": Self.contextSentinel, "filePath": "/fixture/workspace/fixture\(exchange)",
                    "numLines": 1, "startLine": 1, "totalLines": 1
                ] as [String: Any]] as [String: Any],
                "permissionDecision": ["decision": "accept", "source": "config", "reasonType": "fixture"]
            ]
        ))
        previous = result
        let trailing = exchange == 1 ? ["prompt_snapshot", "total_tokens_reminder", "budget_usd"] : ["total_tokens_reminder", "budget_usd"]
        for (index, type) in trailing.enumerated() {
            let id = "o20-m\(exchange)-\(index)"
            entries.append(attachment(id, parent: previous, type: type))
            previous = id
        }
        entries += [operational("api-request-blob"), operational("api-request", extra: ["id": "req-o20-\(exchange)c"])]
        if exchange == 2 { entries.append(operational("last-prompt", extra: ["leafUuid": previous])) }
        entries.append(settingMessage(entry(
            "assistant",
            uuid: answer,
            parent: previous,
            content: [["type": "text", "text": token]],
            messageID: "msg-o20-\(exchange)c",
            extra: ["requestId": "request-o20-\(exchange)c", "version": "2.1.302"]
        ), ["stop_reason": nativeStops ? "end_turn" : NSNull(), "model": "fixture-model"]))
        if exchange >= 2 { entries.append(operational("last-prompt", extra: ["leafUuid": answer])) }
        return entries
    }

    /// The exact observed `mode` record: only `type`, `mode` and `sessionId`.
    private func o20ModeRecord(_ adjust: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var object: [String: Any] = ["type": "mode", "mode": "normal", "sessionId": sessionID]
        adjust(&object)
        return object
    }

    private func o20CostState() -> [String: Any] {
        var cost = operational("cost-state")
        cost["sessionId"] = nil
        return cost
    }

    /// Process 1 (two exchanges) and the resumed process 2 append (one exchange, then `mode`).
    private func o20Processes(nativeStops: Bool = true, mode: [String: Any]? = nil) -> (first: [[String: Any]], second: [[String: Any]]) {
        let first = o20Exchange(1, parent: nil, nativeStops: nativeStops)
            + o20Exchange(2, parent: "o20-u1c", nativeStops: nativeStops) + [o20CostState()]
        let second = o20Exchange(3, parent: "o20-u2c", nativeStops: nativeStops) + [mode ?? o20ModeRecord(), o20CostState()]
        return (first, second)
    }

    func testO20ReadExchangesAcrossASameSessionResumeProjectThroughTheExistingToolAssociation() throws {
        let (first, second) = o20Processes()
        let firstBytes = jsonl(first), fullBytes = jsonl(first + second)
        XCTAssertEqual(fullBytes.prefix(firstBytes.count), firstBytes, "process 2 only appends (byte-exact prefix)")
        let value = try XCTUnwrap(candidate(read(fullBytes, mode: fromStart)))
        XCTAssertEqual(rowSummary(value.rows), (1 ... 3).flatMap { n in
            ["\(o20Caller(n))|userText|0", "o20-u\(n)a|toolCall|0", "o20-u\(n)b|toolResult|0", "o20-u\(n)c|assistantText|0"]
        }, "attachments, operational records and mode never render; one Read per prompt")
        for exchange in 1 ... 3 {
            let rows = value.rows.filter { $0.nativeEntryID.hasSuffix("u\(exchange)a") || $0.nativeEntryID.hasSuffix("u\(exchange)b") }
            let call = try XCTUnwrap(rows.first { $0.kind == .toolCall })
            let result = try XCTUnwrap(rows.first { $0.kind == .toolResult })
            let toolUseID = o20ToolUseID(exchange)
            // Native assistant UUID identity; the tool-result user has its own, distinct UUID.
            XCTAssertEqual(call.localItemID, Reader.deterministicUUID(
                namespace: "rpce-claude-history-row-v1",
                components: [Reader.providerRaw, sessionID, "o20-u\(exchange)a", "toolCall", "0"]
            ))
            XCTAssertEqual(result.localItemID, Reader.deterministicUUID(
                namespace: "rpce-claude-history-row-v1",
                components: [Reader.providerRaw, sessionID, "o20-u\(exchange)b", "toolResult", "0"]
            ))
            XCTAssertNotEqual(result.nativeEntryID, call.nativeEntryID)
            XCTAssertNotEqual(result.nativeEntryID, o20Caller(exchange), "a tool result is never a caller anchor")
            // The shared tool_use_id alone derives the pairing invocation ID.
            let invocation = Reader.deterministicUUID(namespace: "rpce-claude-history-tool-v1", components: [Reader.providerRaw, sessionID, toolUseID])
            XCTAssertEqual(call.toolUseID, toolUseID)
            XCTAssertEqual(result.toolUseID, toolUseID)
            XCTAssertEqual(call.toolInvocationID, invocation)
            XCTAssertEqual(result.toolInvocationID, invocation)
            XCTAssertEqual(call.toolName, "Read")
            XCTAssertEqual(result.toolName, "Read")
            XCTAssertEqual(call.toolInputJSON, #"{"file_path":"\/fixture\/workspace\/fixture\#(exchange)"}"#)
            XCTAssertEqual(result.text, Self.o20Tokens[exchange - 1])
            XCTAssertNil(result.toolIsError, "an absent is_error stays unknown, never false")
        }
        XCTAssertEqual(Set(value.rows.compactMap(\.toolInvocationID)).count, 3)
        XCTAssertEqual(value.rows.filter { $0.kind == .assistantText }.map(\.text), Self.o20Tokens)
        XCTAssertTrue(value.rows.filter { $0.kind == .userText }.allSatisfy { $0.localItemID == nil })
        for row in value.rows {
            XCTAssertFalse(row.text?.contains("SENTINEL") ?? false)
            XCTAssertFalse(row.toolInputJSON?.contains("SENTINEL") ?? false)
        }
        // Caller UUIDs are the only prompt anchors (tool-result users never are).
        XCTAssertEqual(value.userMessageEntries.map(\.nativeEntryID), (1 ... 3).map(o20Caller))
        XCTAssertEqual(
            value.userMessageEntries.map(\.textSHA256),
            (1 ... 3).map { Optional(sha256("Use Read on fixture\($0), then reply with its token.")) }
        )
        XCTAssertEqual(value.completion, .unconfirmed, "last-prompt, mode and cost-state prove nothing")

        // Native stop_reason (tool_use/end_turn) vs stdout null: identical rows, IDs and digests.
        let stdoutShaped = o20Processes(nativeStops: false)
        let nullStops = try XCTUnwrap(candidate(read(jsonl(stdoutShaped.first + stdoutShaped.second), mode: fromStart)))
        XCTAssertNotEqual(jsonl(stdoutShaped.first + stdoutShaped.second), fullBytes)
        XCTAssertEqual(nullStops.rows, value.rows)
    }

    func testO20ResumedAppendImportsOnlyTheNewExchangeAndReplaysAsANoOp() throws {
        let (first, second) = o20Processes()
        let firstBytes = jsonl(first), fullBytes = jsonl(first + second)
        // Process 1 imported from the start.
        let initial = try XCTUnwrap(candidate(read(firstBytes, mode: fromStart)))
        XCTAssertEqual(initial.completeLineOffset, UInt64(firstBytes.count))
        let firstPlan = AgentProviderHistoryImportPlanner.plan(
            observation: Reader.observation(initial),
            existingItemIDs: [],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 5000)
        )
        XCTAssertEqual(firstPlan.appendedItems.filter { $0.kind != .system }.map(\.kind), [.toolCall, .toolResult, .assistant, .toolCall, .toolResult, .assistant])
        // The resumed append (same file, byte-exact prefix): only process 2 rows, after the cursor.
        let resumed = try XCTUnwrap(candidate(read(fullBytes, mode: .importAfter(firstPlan.cursor), ledger: firstPlan.ledger)))
        XCTAssertFalse(resumed.isRescan)
        XCTAssertEqual(resumed.rows.map(\.nativeEntryID), [o20Caller(3), "o20-u3a", "o20-u3b", "o20-u3c"])
        XCTAssertEqual(resumed.validationRows.count, 12, "the whole graph (both processes) is validated")
        XCTAssertEqual(resumed.userMessageEntries.map(\.nativeEntryID), [o20Caller(3)], "only the resumed caller is a new anchor")
        let resumedPlan = AgentProviderHistoryImportPlanner.plan(
            observation: Reader.observation(resumed),
            existingItemIDs: Set(firstPlan.appendedItems.map(\.id)),
            ledger: firstPlan.ledger,
            previousCursor: firstPlan.cursor,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 6000)
        )
        let appended = resumedPlan.appendedItems.filter { $0.kind != .system }
        XCTAssertEqual(appended.map(\.kind), [.toolCall, .toolResult, .assistant])
        XCTAssertEqual(appended[0].toolInvocationID, appended[1].toolInvocationID)
        XCTAssertEqual(appended.map(\.id), resumed.rows.compactMap(\.localItemID))
        XCTAssertEqual(resumedPlan.ledger.nativeItems.count, 12)
        // Re-reading the same bytes after the latest cursor yields nothing, and replaying the same
        // observation over the transcript appends nothing.
        let again = try XCTUnwrap(candidate(read(fullBytes, mode: .importAfter(resumedPlan.cursor), ledger: resumedPlan.ledger)))
        XCTAssertTrue(again.rows.isEmpty)
        let existing = Set(firstPlan.appendedItems.map(\.id)).union(resumedPlan.appendedItems.map(\.id))
        let replay = AgentProviderHistoryImportPlanner.plan(
            observation: Reader.observation(resumed),
            existingItemIDs: existing,
            ledger: resumedPlan.ledger,
            previousCursor: resumedPlan.cursor,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 7000)
        )
        XCTAssertTrue(replay.appendedItems.isEmpty, "a replay appends nothing")
        XCTAssertEqual(replay.ledger.nativeItems.count, resumedPlan.ledger.nativeItems.count)
    }

    func testO20ModeRecordIsAcceptedOnlyInItsExactObservedShape() {
        XCTAssertFalse(Reader.operationalTypes.contains("mode"), "mode is not a generic operational type")
        let accepted = o20Processes()
        XCTAssertNotNil(candidate(read(jsonl(accepted.first + accepted.second), mode: fromStart)))
        XCTAssertNotNil(candidate(read(jsonl(accepted.first + accepted.second), mode: .baseline)))
        func refusal(_ mode: [String: Any]) -> Reader.Result {
            let (first, second) = o20Processes(mode: mode)
            return read(jsonl(first + second), mode: fromStart)
        }
        let line = accepted.first.count + accepted.second.count - 1 // mode precedes the trailing cost-state
        XCTAssertEqual(accepted.second[accepted.second.count - 2]["type"] as? String, "mode")
        // Unknown fields refuse (the first unknown key in sorted order is named).
        XCTAssertEqual(refusal(o20ModeRecord { $0["permissionMode"] = "default" }), .unsupported(.metadata("permissionMode", line: line)))
        let twoUnknown = o20ModeRecord {
            $0["timestamp"] = "t"
            $0["content"] = "x"
        }
        XCTAssertEqual(refusal(twoUnknown), .unsupported(.metadata("content", line: line)))
        // Other mode values or types refuse.
        for value in ["plan", "Normal", "", 1, NSNull()] as [Any] {
            XCTAssertEqual(refusal(o20ModeRecord { $0["mode"] = value }), .unsupported(.metadata("mode", line: line)), "\(value)")
        }
        XCTAssertEqual(refusal(o20ModeRecord { $0["mode"] = nil }), .unsupported(.metadata("mode", line: line)))
        // Graph identity keys refuse, even null.
        for key in ["uuid", "parentUuid"] {
            for value in [NSNull(), "o20-u3c"] as [Any] {
                XCTAssertEqual(refusal(o20ModeRecord { $0[key] = value }), .unsupported(.operationalRecord("mode", line: line)), key)
            }
        }
        // A missing, non-string or different session refuses.
        XCTAssertEqual(refusal(o20ModeRecord { $0["sessionId"] = nil }), .unsupported(.sessionMismatch(line: line)))
        XCTAssertEqual(refusal(o20ModeRecord { $0["sessionId"] = NSNull() }), .unsupported(.sessionMismatch(line: line)))
        XCTAssertEqual(refusal(o20ModeRecord { $0["sessionId"] = "11111111-2222-4333-8444-555555555555" }), .unsupported(.sessionMismatch(line: line)))
        // A marker key is just another unknown field here; an unknown type stays strictly refused.
        XCTAssertEqual(refusal(o20ModeRecord { $0["supersedes"] = "o20-u3c" }), .unsupported(.metadata("supersedes", line: line)))
        XCTAssertEqual(refusal(o20ModeRecord { $0["type"] = "mode-v2" }), .unsupported(.entryType("mode-v2", line: line)))
    }

    func testO20WrongToolResultIdSourceOrParentRefusesTheWholeCandidate() {
        func refusal(_ adjust: (inout [String: Any]) -> Void) -> Reader.Result {
            let processes = o20Processes()
            var second = processes.second
            if let index = second.firstIndex(where: { ($0["uuid"] as? String) == "o20-u3b" }) {
                adjust(&second[index])
            } else {
                XCTFail("fixture lost the resumed tool result")
            }
            return read(jsonl(processes.first + second), mode: fromStart)
        }
        let unassociated = Reader.Result.unsupported(.toolAssociation("unassociated tool result o20-u3b"))
        XCTAssertEqual(refusal { $0["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_o20_9", "content": "DELTA-63"]]] }, unassociated)
        XCTAssertEqual(refusal { $0["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_o20_1", "content": "DELTA-63"]]] }, unassociated, "an earlier call's id")
        XCTAssertEqual(refusal { $0["sourceToolAssistantUUID"] = "o20-u2a" }, unassociated)
        XCTAssertEqual(refusal { $0["parentUuid"] = "o20-n3-1" }, unassociated, "result re-parented onto a pre-call attachment")
        XCTAssertEqual(refusal { $0["parentUuid"] = o20Caller(3) }, unassociated)
    }

    /// Step 4d5: the live producer's single-entry projections of each O20 call, result and final text
    /// are exactly the reader's rows of the full history (IDs, pairing ID, name, payload, error status
    /// and digest). An import over live rows recorded under those projections appends nothing and
    /// keeps their ledger entries, and the preflight's payload comparison holds every imported item
    /// against the live rows.
    func testO20LiveProjectionsAreTheReadersRowsAndAnImportOverLiveRowsAppendsNothing() throws {
        let (first, _) = o20Processes(nativeStops: false)
        let value = try XCTUnwrap(candidate(read(jsonl(first), mode: fromStart)))
        var liveItems: [AgentChatItem] = []
        var liveLedger = AgentSessionProviderHistoryRecovery()
        for exchange in 1 ... 2 {
            func row(_ suffix: String) throws -> Reader.Row {
                try XCTUnwrap(value.rows.first { $0.nativeEntryID == "o20-u\(exchange)\(suffix)" })
            }
            let call = try row("a"), result = try row("b"), answer = try row("c")
            let liveCall = try XCTUnwrap(ClaudeLiveTranscriptToolRow.projecting(
                nativeSessionID: sessionID, nativeEntryID: call.nativeEntryID, kind: .toolCall,
                toolUseID: o20ToolUseID(exchange), toolName: "Read", payload: XCTUnwrap(call.toolInputJSON)
            ))
            let liveResult = try XCTUnwrap(ClaudeLiveTranscriptToolRow.projecting(
                nativeSessionID: sessionID, nativeEntryID: result.nativeEntryID, kind: .toolResult,
                toolUseID: o20ToolUseID(exchange), toolName: "Read", payload: XCTUnwrap(result.text)
            ))
            XCTAssertEqual(liveCall.projectedRow, call, "exchange \(exchange): the call")
            XCTAssertEqual(liveResult.projectedRow, result, "exchange \(exchange): the result")
            XCTAssertTrue(liveCall.matchesProjection)
            XCTAssertTrue(liveResult.matchesProjection)
            let liveAnswer = try XCTUnwrap(Reader.singleTextAssistantRow(nativeSessionID: sessionID, nativeEntryID: answer.nativeEntryID, text: XCTUnwrap(answer.text)))
            XCTAssertEqual(liveAnswer, answer, "exchange \(exchange): the final text")
            let complete = try ClaudeLiveTranscriptCompleteText(
                nativeSessionID: sessionID, nativeEntryID: answer.nativeEntryID, localItemID: XCTUnwrap(answer.localItemID),
                text: XCTUnwrap(answer.text), envelopeDigest: answer.envelopeDigest
            )
            liveItems += try [XCTUnwrap(liveCall.canonicalItem), XCTUnwrap(liveResult.canonicalItem), XCTUnwrap(complete.canonicalItem)]
            liveLedger.nativeItems += [liveCall.ledgerItem, liveResult.ledgerItem, complete.ledgerItem]
        }
        let observation = Reader.observation(value)
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: observation,
            existingItemIDs: Set(liveItems.map(\.id)),
            ledger: liveLedger,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 5000)
        )
        XCTAssertTrue(plan.appendedItems.isEmpty, "the live rows are already the import's rows")
        for item in liveLedger.nativeItems {
            XCTAssertEqual(plan.ledger.nativeItem(forKey: item.key), item, "the live entry and proof are kept")
        }
        let canonical = AgentProviderHistoryCanonicalView(transcript: .empty, suffixItems: liveItems)
        let imported = observation.rows.compactMap(\.item)
        XCTAssertEqual(imported.map(\.id), liveItems.map(\.id))
        for item in imported {
            XCTAssertTrue(AgentProviderHistoryAssociationPreflight.holdsCanonicalPayload(item, in: canonical), "\(item.kind)")
        }
        // A changed payload, a streaming copy or a duplicated ID never holds.
        var changed = liveItems
        changed[1].toolResultJSON = "changed"
        XCTAssertFalse(AgentProviderHistoryAssociationPreflight.holdsCanonicalPayload(imported[1], in: .init(transcript: .empty, suffixItems: changed)))
        var streaming = liveItems
        streaming[2].isStreaming = true
        XCTAssertFalse(AgentProviderHistoryAssociationPreflight.holdsCanonicalPayload(imported[2], in: .init(transcript: .empty, suffixItems: streaming)))
        XCTAssertFalse(AgentProviderHistoryAssociationPreflight.holdsCanonicalPayload(imported[0], in: .init(transcript: .empty, suffixItems: liveItems + [liveItems[0]])))
    }
}
