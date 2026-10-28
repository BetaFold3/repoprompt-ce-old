import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Lossless restart Phase 4 reconciliation seams: Codex controller-owned observation, the Claude
/// dangling-resume disposition, and the DataService history-import commit and stale-snapshot fence.
/// Fixtures only: no provider process, home directory or live transport is touched.
@MainActor
final class AgentRecoveryReconciliationTests: XCTestCase {
    // MARK: Codex observation (pure parsing)

    func testCodexObservationReportsOnlyTheExpectedTurnsOwnTerminalStatus() {
        let turns: [[String: Any]] = [
            ["id": "turn-latest", "status": "completed"],
            [
                "id": "turn-expected",
                "status": "completed",
                "items": [
                    ["id": "u1", "type": "userMessage"],
                    ["id": "a1", "type": "agentMessage", "text": "Done."]
                ]
            ]
        ]
        let observation = CodexNativeSessionController.recoveryObservation(
            threadID: "thread-1",
            expectedTurnID: "turn-expected",
            turns: turns,
            source: .turnsList,
            transportGeneration: 3
        )
        XCTAssertEqual(observation.turnID, "turn-expected")
        XCTAssertEqual(observation.terminal, .completed)
        XCTAssertEqual(observation.items, [
            .init(nativeItemID: "u1", kind: .userMessage, text: nil),
            .init(nativeItemID: "a1", kind: .agentMessage, text: "Done.")
        ])
        XCTAssertEqual(observation.transportGeneration, 3)
    }

    /// 9-live R2: an interrupted turn found with tool items is unusable but named as found (its own
    /// text), unlike a turn that isn't there at all.
    func testCodexAdapterTellsAFoundTurnWithToolItemsFromAMissingTurn() {
        let turns: [[String: Any]] = [[
            "id": "turn-expected",
            "status": "interrupted",
            "items": [
                ["id": "u1", "type": "userMessage"],
                ["id": "f1", "type": "commandExecution", "command": "sleep 900"],
                ["id": "a1", "type": "agentMessage", "text": "Running it."]
            ]
        ]]
        func observe(_ expectedTurnID: String) -> CodexRecoveryObservation {
            CodexNativeSessionController.recoveryObservation(
                threadID: "thread-1",
                expectedTurnID: expectedTurnID,
                turns: turns,
                source: .turnsList,
                transportGeneration: 1
            )
        }
        let found = observe("turn-expected")
        XCTAssertEqual(found.turnID, "turn-expected")
        XCTAssertEqual(found.terminal, .interrupted)
        XCTAssertNil(CodexRecoveryAdapter.historyObservation(found), "tool items are never imported")
        XCTAssertEqual(
            CodexRecoveryAdapter.unusableObservationText(found),
            "Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported."
        )

        let missing = observe("turn-other")
        XCTAssertNil(CodexRecoveryAdapter.historyObservation(missing))
        XCTAssertEqual(CodexRecoveryAdapter.unusableObservationText(missing), "Codex has no matching record of the interrupted turn.")
    }

    func testCodexObservationNeverInfersCompletionFromLatestIdleOrAmbiguousTurns() {
        func observe(_ turns: [[String: Any]]) -> CodexRecoveryObservation {
            CodexNativeSessionController.recoveryObservation(
                threadID: "thread-1",
                expectedTurnID: "turn-expected",
                turns: turns,
                source: .threadRead,
                transportGeneration: 1
            )
        }
        let missing = observe([["id": "turn-latest", "status": "completed"]])
        XCTAssertEqual(missing.terminal, .unconfirmed, "the latest turn is never evidence")
        XCTAssertNil(missing.turnID)
        XCTAssertNil(missing.items)

        let running = observe([["id": "turn-expected", "status": "inProgress"]])
        XCTAssertEqual(running.terminal, .unconfirmed)

        let ambiguous = observe([["id": "turn-expected", "status": "completed"], ["id": "turn-expected", "status": "failed"]])
        XCTAssertEqual(ambiguous.terminal, .unconfirmed)

        let interrupted = observe([["id": "turn-expected", "status": "interrupted", "error": ["message": "Stopped by user"]]])
        XCTAssertEqual(interrupted.terminal, .interrupted)
        XCTAssertEqual(interrupted.abortDetail, "Stopped by user")

        let withTool = observe([[
            "id": "turn-expected",
            "status": "completed",
            "items": [["id": "a1", "type": "agentMessage", "text": "x"], ["id": "c1", "type": "commandExecution"]]
        ]])
        XCTAssertEqual(withTool.terminal, .completed)
        XCTAssertNil(withTool.items, "unsupported items make the list unavailable, never partial")

        let duplicateItem = observe([[
            "id": "turn-expected",
            "status": "completed",
            "items": [["id": "a1", "type": "agentMessage", "text": "x"], ["id": "a1", "type": "agentMessage", "text": "y"]]
        ]])
        XCTAssertNil(duplicateItem.items)
    }

    // MARK: Codex observation (controller gate)

    func testCodexObservationRequiresARegisteredTransportAndOnlyReads() async throws {
        let requests = ReconciliationRequestLog()
        let client = CodexAppServerClient(mcpHost: ServerNetworkManager.shared, livenessProbe: { _ in true })
        await client.debugInstallTestTransport()
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: "/tmp/workspace",
            options: CodexNativeSessionController.Options(
                requestTimeout: 5,
                configOverridesProvider: { [:] },
                launchEnvironmentProvider: { [:] },
                approvalPolicyProvider: { .never },
                sandboxModeProvider: { .readOnly },
                approvalReviewerProvider: { .user },
                authTokensRefreshHandler: nil
            ),
            requestExecutor: { method, _, _ in
                requests.append(method)
                return ["data": [["id": "turn-expected", "status": "failed", "error": ["message": "boom"]]]]
            }
        )

        do {
            _ = try await controller.observeRecovery(threadID: "thread-1", expectedTurnID: "turn-expected", timeout: 5)
            XCTFail("an unregistered transport must fail closed")
        } catch {
            XCTAssertEqual(error as? CodexRecoveryObservationError, .registeredTransportRequired)
        }
        do {
            _ = try await controller.observeRecovery(threadID: " ", expectedTurnID: "turn-expected", timeout: 5)
            XCTFail("missing identity")
        } catch {
            XCTAssertEqual(error as? CodexRecoveryObservationError, .missingIdentity)
        }
        XCTAssertEqual(requests.methods, [], "nothing was requested before the gates passed")

        controller.recoveryObservationTreatsTransportAsRegisteredForTesting = true
        let observation = try await controller.observeRecovery(threadID: "thread-1", expectedTurnID: "turn-expected", timeout: 5)
        XCTAssertEqual(observation.terminal, .failed)
        XCTAssertEqual(observation.abortDetail, "boom")
        XCTAssertEqual(observation.source, .turnsList)
        XCTAssertEqual(requests.methods, ["thread/turns/list"], "observation never resumes, starts, steers or interrupts")
        await client.stop()
    }

    // MARK: Claude dangling --resume

    func testClaudeResumeFailureRequiresAnExplicitChoiceOnlyForTheSuppressedConversation() {
        let failure = NativeAgentRuntimeControllerError.processNotRunning
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(after: failure, existingSessionID: "conv-1", suppressedConversationID: nil),
            .retryFresh
        )
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(after: failure, existingSessionID: "conv-1", suppressedConversationID: "conv-1"),
            .requireExplicitChoice(conversationID: "conv-1"),
            "a recovery dispatch never falls back to an implicit fresh conversation"
        )
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(after: failure, existingSessionID: "conv-1", suppressedConversationID: "conv-2"),
            .retryFresh
        )
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(
                after: NativeAgentRuntimeControllerError.liveModelSwitchRequiresRestart,
                existingSessionID: "conv-1",
                suppressedConversationID: "conv-1"
            ),
            .rethrow
        )
        XCTAssertEqual(
            ClaudeAgentModeCoordinator.resumeFailureDisposition(after: failure, existingSessionID: nil, suppressedConversationID: nil),
            .rethrow
        )
    }

    // MARK: History import commit and stale-snapshot fence

    func testHistoryImportCommitsLedgerAndReceiptInOneSaveAndFencesStaleSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRecoveryReconciliationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tombstones = root.appendingPathComponent("AgentRecovery/v1/tombstones", isDirectory: true)
        let workspace = WorkspaceModel(
            name: "History",
            repoPaths: ["/tmp/repo"],
            customStoragePath: root.appendingPathComponent("workspace", isDirectory: true)
        )
        let service = AgentSessionDataService(tombstoneRoot: tombstones)
        let sessionID = UUID()
        let load = try await service.prepareInitialAgentSessionPersistence(
            initialSession: AgentSession(id: sessionID, workspaceID: workspace.id, name: "History"),
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 0
        )
        let files = try await service.listAgentSessions(for: workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent == "AgentSession-\(sessionID.uuidString).json" })
        let initialBytes = try Data(contentsOf: fileURL)

        let commit = AgentSessionProviderHistoryRecovery.ImportCommit(
            importID: UUID(),
            providerRaw: "claude",
            conversationID: "conv-1",
            committedAt: Date(timeIntervalSince1970: 1000),
            rowCount: 1
        )
        let ledger = AgentSessionProviderHistoryRecovery(
            nativeItems: [.init(
                providerRaw: "claude",
                nativeSessionID: "conv-1",
                nativeEntryID: "entry-1",
                rowKindRaw: "assistantText",
                ordinal: 0,
                localItemID: UUID()
            )],
            lastImportCommit: commit
        )

        // A payload that does not carry exactly its own receipt is refused before any write.
        var mismatched = load.session
        mismatched.providerHistoryRecovery = AgentSessionProviderHistoryRecovery(nativeItems: ledger.nativeItems)
        do {
            _ = try await service.commitProviderHistoryImport(mismatched, for: workspace, importCommit: commit, persistenceState: load.persistenceState)
            XCTFail("receipt mismatch must refuse")
        } catch {
            XCTAssertEqual(error as? AgentSessionHistoryImportError, .receiptMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), initialBytes)

        var imported = load.session
        imported.providerHistoryRecovery = ledger
        let saved = try await service.commitProviderHistoryImport(imported, for: workspace, importCommit: commit, persistenceState: load.persistenceState)
        XCTAssertEqual(saved.disposition, .written)
        let reloaded = try await AgentSessionDataService(tombstoneRoot: tombstones).loadAgentSession(id: sessionID, for: workspace)
        XCTAssertEqual(reloaded?.providerHistoryRecovery, ledger, "ledger and receipt committed together")
        let committedBytes = try Data(contentsOf: fileURL)

        // An older snapshot (without the committed receipt) can never clobber the import.
        do {
            _ = try await service.saveAgentSession(load.session, for: workspace, persistenceState: saved.persistenceState)
            XCTFail("a stale snapshot must be refused")
        } catch {
            XCTAssertEqual(error as? AgentSessionHistoryImportError, .staleHistorySnapshot)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), committedBytes)

        // A later ordinary save that carries the committed receipt proceeds.
        var later = imported
        later.name = "History renamed"
        let laterCommit = try await service.saveAgentSession(later, for: workspace, persistenceState: saved.persistenceState)
        XCTAssertEqual(laterCommit.disposition, .written)
        let afterLater = try await AgentSessionDataService(tombstoneRoot: tombstones).loadAgentSession(id: sessionID, for: workspace)
        XCTAssertEqual(afterLater?.providerHistoryRecovery, ledger)
    }

    func testHistoryLedgerMemberIsOptionalAndRoundTripsUnknownMembers() throws {
        var session = AgentSession(id: UUID(), name: "Envelope")
        let empty = try JSONSerialization.jsonObject(with: AgentSessionDataCodec.encodeSession(session)) as? [String: Any]
        XCTAssertNil(empty?["providerHistoryRecovery"], "absent when empty")

        let json = #"{"nativeItems":[{"provider":"claude","nativeSessionID":"s","nativeEntryID":"e","rowKind":"assistantText","ordinal":0,"future":1}],"lastImportCommit":{"importID":"\#(UUID().uuidString)","provider":"claude","conversationID":"s","committedAt":0,"rowCount":0},"futureTop":"x"}"#
        let decoded = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.extras["futureTop"], .string("x"))
        XCTAssertEqual(decoded.nativeItems.first?.extras["future"], .number(1))
        session.providerHistoryRecovery = decoded
        let reencoded = try JSONDecoder().decode(
            AgentSessionProviderHistoryRecovery.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(reencoded, decoded)
        XCTAssertEqual(
            AgentSessionProviderHistoryRecovery.rowKey(providerRaw: "a|b", nativeSessionID: "", nativeEntryID: "c", rowKindRaw: "d", ordinal: 1),
            "3:a|b|0:|1:c|1:d|1:1"
        )
    }

    /// Step 4d2: the native row's complete-envelope proof is an optional known member, omitted when
    /// nil, typed only when valid, and compatible with older JSON and unknown members.
    func testNativeItemEnvelopeDigestIsOptionalAndKeepsUnknownMembers() throws {
        typealias NativeItem = AgentSessionProviderHistoryRecovery.NativeItem
        let digest = AgentSessionProviderHistoryRecovery.sha256Hex(Data("abc".utf8))
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let proven = NativeItem(
            providerRaw: "claude",
            nativeSessionID: "s",
            nativeEntryID: "e",
            rowKindRaw: "assistantText",
            ordinal: 0,
            localItemID: UUID(),
            envelopeDigest: digest,
            extras: ["future": .object(["v": .number(2)])]
        )
        let encoded = try JSONEncoder().encode(proven)
        let encodedJSON = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(encodedJSON?["envelopeDigest"] as? String, digest)
        XCTAssertEqual(try JSONDecoder().decode(NativeItem.self, from: encoded), proven)
        let legacy = NativeItem(providerRaw: "claude", nativeSessionID: "s", nativeEntryID: "e", rowKindRaw: "userText", ordinal: 0, localItemID: nil)
        let legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        XCTAssertNotNil(legacyJSON)
        XCTAssertNil(legacyJSON?["envelopeDigest"], "omitted when nil")
        let older = #"{"provider":"claude","nativeSessionID":"s","nativeEntryID":"e","rowKind":"assistantText","ordinal":0,"other":true}"#
        let decodedOlder = try JSONDecoder().decode(NativeItem.self, from: Data(older.utf8))
        XCTAssertNil(decodedOlder.envelopeDigest)
        XCTAssertEqual(decodedOlder.extras["other"], .bool(true))
    }

    /// JSON fragments of malformed optional proofs (wrong case, length, alphabet, type, or null).
    private static func malformedProofFragments(valid digest: String) -> [String] {
        ["\"\(digest.uppercased())\"", "\"\(digest.dropLast())\"", "\"\(String(repeating: "g", count: 64))\"", "\"\"", "null", "5", "{\"x\":1}"]
    }

    private func jsonValue(_ fragment: String) throws -> AgentScheduledSendJSONValue {
        try XCTUnwrap(JSONDecoder().decode([String: AgentScheduledSendJSONValue].self, from: Data(#"{"v":\#(fragment)}"#.utf8))["v"])
    }

    private func members(_ value: some Encodable) throws -> [String: AgentScheduledSendJSONValue] {
        try JSONDecoder().decode([String: AgentScheduledSendJSONValue].self, from: JSONEncoder().encode(value))
    }

    /// Step 4d2 main decision 4: a malformed optional proof (envelope digest, baseline prefix,
    /// receipt target) never fails the member, the ledger or the session. It is unusable (`nil`) and
    /// its exact raw value stays an unknown member, re-encoded unchanged; a valid typed value
    /// overwrites a preserved raw one, and `nil` never erases it. Claude qualification refuses it.
    func testMalformedOptionalProofsLoadRoundTripVerbatimAndClaudeRefusesThem() throws {
        typealias Recovery = AgentSessionProviderHistoryRecovery
        let digest = Recovery.sha256Hex(Data("abc".utf8))
        let item = #""provider":"claude","nativeSessionID":"s","nativeEntryID":"e","rowKind":"assistantText","ordinal":0"#
        let baselineMembers = #""dispatchID":"\#(UUID().uuidString)","transcriptResetGeneration":0,"provider":"claude","conversationID":"c","completeLineOffset":0,"baselineCommitID":"\#(UUID().uuidString)","profile":"nativeEntriesSubsetV2","status":"captured","recordedAtMs":0"#
        let receiptMembers = #""importID":"\#(UUID().uuidString)","provider":"claude","conversationID":"c","committedAt":0,"rowCount":0"#
        let badTargets = Self.malformedProofFragments(valid: digest) + [
            #"{"completeLineOffset":0,"prefixSHA256":"\#(digest.uppercased())"}"#,
            #"{"prefixSHA256":"\#(digest)"}"#,
            #"{"completeLineOffset":0,"prefixSHA256":"\#(digest)","future":1}"#,
            #"{"fileDevice":1,"completeLineOffset":0,"prefixSHA256":"\#(digest)"}"#
        ]
        for fragment in Self.malformedProofFragments(valid: digest) {
            let raw = try jsonValue(fragment)
            let native = try JSONDecoder().decode(Recovery.NativeItem.self, from: Data("{\(item),\"envelopeDigest\":\(fragment)}".utf8))
            XCTAssertNil(native.envelopeDigest, fragment)
            XCTAssertEqual(native.extras["envelopeDigest"], raw, fragment)
            XCTAssertEqual(try members(native)["envelopeDigest"], raw, "\(fragment) re-encodes unchanged")
            let baseline = try JSONDecoder().decode(Recovery.DispatchBaseline.self, from: Data("{\(baselineMembers),\"prefixSHA256\":\(fragment)}".utf8))
            XCTAssertNil(baseline.prefixSHA256, fragment)
            XCTAssertEqual(try members(baseline)["prefixSHA256"], raw, fragment)
            XCTAssertNil(baseline.cursor?.prefixSHA256, "a malformed proof is never a boundary proof")
        }
        for fragment in badTargets {
            let receipt = try JSONDecoder().decode(Recovery.ImportCommit.self, from: Data("{\(receiptMembers),\"target\":\(fragment)}".utf8))
            XCTAssertNil(receipt.target, fragment)
            XCTAssertEqual(try members(receipt)["target"], try jsonValue(fragment), "\(fragment) re-encodes unchanged")
        }
        // Valid values are typed (absence and an existing file stay distinct) and overwrite raw extras.
        let absentTarget = try JSONDecoder().decode(
            Recovery.ImportCommit.self,
            from: Data(#"{\#(receiptMembers),"target":{"completeLineOffset":0,"prefixSHA256":"\#(digest)"}}"#.utf8)
        )
        XCTAssertEqual(absentTarget.target, AgentRecoveryHistoryPrefixFence(file: nil, completeLineOffset: 0, prefixSHA256: digest))
        // A non-power-of-two above 2^53 (not exactly representable as a Double) survives exactly
        // (review B P3-03).
        let largeInode: UInt64 = (1 << 60) + 3
        let file = AgentRecoveryHistoryFileIdentity(device: 1, inode: largeInode, birthSeconds: 3, birthNanoseconds: nil)
        let fileTarget = AgentRecoveryHistoryPrefixFence(file: file, completeLineOffset: 9, prefixSHA256: digest)
        let typedReceipt = Recovery.ImportCommit(
            importID: UUID(), providerRaw: "claude", conversationID: "c", committedAt: Date(timeIntervalSince1970: 0), rowCount: 0,
            target: fileTarget, extras: ["target": .string("stale raw")]
        )
        let reloadedReceipt = try JSONDecoder().decode(Recovery.ImportCommit.self, from: JSONEncoder().encode(typedReceipt))
        XCTAssertEqual(reloadedReceipt.target, fileTarget)
        XCTAssertEqual(reloadedReceipt.target?.file?.inode, largeInode, "the large inode is exact")
        XCTAssertTrue(reloadedReceipt.extras.isEmpty, "the typed target replaced the raw one")
        let literalReceipt = try JSONDecoder().decode(
            Recovery.ImportCommit.self,
            from: Data(#"{\#(receiptMembers),"target":{"fileDevice":1,"fileInode":\#(largeInode),"fileBirthSeconds":3,"completeLineOffset":9,"prefixSHA256":"\#(digest)"}}"#.utf8)
        )
        XCTAssertEqual(literalReceipt.target?.file?.inode, largeInode, "a literal large inode decodes exactly")
        let typedNative = Recovery.NativeItem(
            providerRaw: "claude", nativeSessionID: "s", nativeEntryID: "e", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: nil, envelopeDigest: digest, extras: ["envelopeDigest": .number(5)]
        )
        XCTAssertEqual(try members(typedNative)["envelopeDigest"], .string(digest))

        // The whole session loads and round-trips with every malformed proof preserved.
        let ledgerJSON = #"{"nativeItems":[{\#(item),"envelopeDigest":"BAD"}],"lastImportCommit":{\#(receiptMembers),"target":{"completeLineOffset":"x"}},"dispatchBaselines":[{\#(baselineMembers),"prefixSHA256":7}]}"#
        let ledger = try JSONDecoder().decode(Recovery.self, from: Data(ledgerJSON.utf8))
        XCTAssertEqual(ledger.dispatchBaselines.count, 1, "a malformed proof never makes a baseline unreadable")
        XCTAssertTrue(ledger.unreadableDispatchBaselines.isEmpty)
        var session = AgentSession(id: UUID(), name: "Proofs")
        session.providerHistoryRecovery = ledger
        let encoded = try AgentSessionDataCodec.encodeSession(session)
        let loaded = try AgentSessionDataCodec.decodeSession(from: encoded)
        XCTAssertEqual(loaded.providerHistoryRecovery, ledger)
        let reencoded = try AgentSessionDataCodec.decodeSession(from: AgentSessionDataCodec.encodeSession(loaded))
        XCTAssertEqual(reencoded.providerHistoryRecovery?.nativeItems.first?.extras["envelopeDigest"], .string("BAD"))
        XCTAssertEqual(reencoded.providerHistoryRecovery?.lastImportCommit?.extras["target"], .object(["completeLineOffset": .string("x")]))
        XCTAssertEqual(reencoded.providerHistoryRecovery?.dispatchBaselines.first?.extras["prefixSHA256"], .number(7))

        // Claude qualification refuses each one: a ledger row without a usable proof, a boundary
        // without one, and a latest receipt without a usable target.
        let conversation = "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f"
        let history = try [
            historyEntry("user", uuid: "u1", parent: nil, text: "hi"),
            historyEntry("assistant", uuid: "a1", parent: "u1", text: "x")
        ].reduce(into: Data()) { data, object in
            try data.append(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            data.append(0x0A)
        }
        let capture = ClaudeSessionHistoryReader.Capture(
            identity: AgentRecoveryHistoryFileIdentity(device: 1, inode: 2, birthSeconds: nil, birthNanoseconds: nil),
            bytes: history
        )
        func boundary(_ proof: String?) -> AgentRecoveryHistoryCursor {
            AgentRecoveryHistoryCursor(
                providerRaw: "claude", conversationID: conversation, importID: UUID(), file: nil, completeLineOffset: 0,
                prefixSHA256: proof, committedAt: AgentRecoveryTimestamp(Date(timeIntervalSince1970: 0))
            )
        }
        func decode(_ cursor: AgentRecoveryHistoryCursor, ledger: Recovery? = nil, fences: [AgentRecoveryHistoryPrefixFence] = []) -> ClaudeSessionHistoryReader.Result {
            ClaudeSessionHistoryReader.decode(capture: capture, nativeSessionID: conversation, mode: .importAfter(cursor), ledger: ledger, fences: fences)
        }
        let empty = Recovery.sha256Hex(Data())
        guard case let .candidate(first) = decode(boundary(empty)) else { return XCTFail("the proven boundary reads") }
        let malformedRows = try JSONDecoder().decode(
            [Recovery.NativeItem].self,
            from: JSONEncoder().encode(first.rows.map { row in
                Recovery.NativeItem(
                    providerRaw: "claude", nativeSessionID: conversation, nativeEntryID: row.nativeEntryID, rowKindRaw: row.kind.rawValue,
                    ordinal: row.ordinal, localItemID: row.localItemID, extras: ["envelopeDigest": .string(row.envelopeDigest.uppercased())]
                )
            })
        )
        XCTAssertEqual(decode(boundary(empty), ledger: Recovery(nativeItems: malformedRows)), .unsupported(.ledgerConflict("u1")))
        XCTAssertEqual(decode(boundary(nil)), .unsupported(.prefixProofUnavailable))
        let legacyReceipt = Recovery(lastImportCommit: .init(
            importID: UUID(), providerRaw: "claude", conversationID: conversation, committedAt: Date(timeIntervalSince1970: 0), rowCount: 0
        ))
        let fences = AgentProviderHistoryAssociationPreflight.claudePrefixFences(window: [], ledger: legacyReceipt, conversationID: conversation)
        XCTAssertEqual(decode(boundary(empty), fences: fences), .unsupported(.prefixProofUnavailable))
    }

    /// Step 4d2: the fences a Claude import verifies (the attempt's captured baselines plus the
    /// latest saved Claude receipt of this conversation, proofless when legacy) and the one a new
    /// baseline verifies (only a proven latest target).
    func testClaudePrefixFencesCoverTheWindowAndTheLatestSavedTargetOnly() {
        typealias Preflight = AgentProviderHistoryAssociationPreflight
        let proof = AgentSessionProviderHistoryRecovery.sha256Hex(Data("p".utf8))
        let first = baseline(prefixSHA256: proof)
        let steering = baseline(prefixSHA256: nil)
        let unsupported = baseline(conversationID: nil, status: .unsupported("no identity"))
        let target = AgentRecoveryHistoryPrefixFence(file: nil, completeLineOffset: 3, prefixSHA256: proof)
        func receipt(provider: String = "claude", conversation: String = "conv-1", target: AgentRecoveryHistoryPrefixFence?) -> AgentSessionProviderHistoryRecovery {
            AgentSessionProviderHistoryRecovery(lastImportCommit: .init(
                importID: UUID(), providerRaw: provider, conversationID: conversation, committedAt: Date(), rowCount: 1, target: target
            ))
        }
        // A captured baseline of another conversation fences nothing here (review B P3-01): the
        // preflight reports its target mismatch instead of a masked rewritten history.
        let foreign = baseline(conversationID: "conv-other", prefixSHA256: proof)
        XCTAssertNotNil(foreign.cursor?.prefixFence)
        let window = [first, steering, unsupported, foreign]
        XCTAssertEqual(
            Preflight.claudePrefixFences(window: window, ledger: receipt(target: target), conversationID: "conv-1"),
            [first.cursor?.prefixFence, steering.cursor?.prefixFence].compactMap(\.self) + [target],
            "every captured baseline of this conversation (a legacy one stays proofless) plus the latest target"
        )
        let proofless = AgentRecoveryHistoryPrefixFence(file: nil, completeLineOffset: 0, prefixSHA256: nil)
        XCTAssertEqual(Preflight.claudePrefixFences(window: [], ledger: receipt(target: nil), conversationID: "conv-1"), [proofless], "never backfilled")
        XCTAssertEqual(Preflight.claudePrefixFences(window: [], ledger: receipt(conversation: "other", target: target), conversationID: "conv-1"), [])
        XCTAssertEqual(Preflight.claudePrefixFences(window: [], ledger: receipt(provider: "codex", target: nil), conversationID: "conv-1"), [])
        XCTAssertEqual(Preflight.claudeBaselineFences(ledger: receipt(target: target), conversationID: "conv-1"), [target])
        XCTAssertEqual(Preflight.claudeBaselineFences(ledger: receipt(target: nil), conversationID: "conv-1"), [], "a fresh first baseline stays allowed")
        XCTAssertEqual(Preflight.claudeBaselineFences(ledger: receipt(conversation: "other", target: target), conversationID: "conv-1"), [])
        XCTAssertEqual(Preflight.claudeBaselineFences(ledger: nil, conversationID: "conv-1"), [])

        func imported(_ ledger: AgentSessionProviderHistoryRecovery) -> AgentSessionProviderHistoryRecovery {
            var ledger = ledger
            ledger.nativeItems = [.init(
                providerRaw: "claude", nativeSessionID: "conv-1", nativeEntryID: "a1", rowKindRaw: "assistantText", ordinal: 0,
                localItemID: UUID(), envelopeDigest: proof
            )]
            return ledger
        }
        // Imported Claude history of this conversation whose last saved target is no longer
        // available (absent, another provider or conversation, or no valid target) is a proofless
        // fence for imports AND baselines, never a quiet omission.
        let lost = [
            ("no receipt", imported(AgentSessionProviderHistoryRecovery())),
            ("codex receipt", imported(receipt(provider: "codex", target: nil))),
            ("other conversation", imported(receipt(conversation: "other", target: target))),
            ("no target", imported(receipt(target: nil)))
        ]
        for (name, ledger) in lost {
            XCTAssertEqual(Preflight.claudePrefixFences(window: [], ledger: ledger, conversationID: "conv-1"), [proofless], name)
            XCTAssertEqual(Preflight.claudeBaselineFences(ledger: ledger, conversationID: "conv-1"), [proofless], name)
        }
        XCTAssertEqual(Preflight.claudeBaselineFences(ledger: imported(receipt(target: target)), conversationID: "conv-1"), [target])
        XCTAssertEqual(
            Preflight.claudeBaselineFences(ledger: imported(AgentSessionProviderHistoryRecovery()), conversationID: "other"),
            [],
            "another conversation's imported rows never block this one"
        )
    }

    // MARK: Dispatch baselines (model)

    private func baseline(
        dispatchID: UUID = UUID(),
        runAttemptID: UUID? = UUID(),
        generation: UInt64 = 0,
        conversationID: String? = "conv-1",
        userItemIDs: [UUID] = [UUID()],
        status: AgentSessionProviderHistoryRecovery.DispatchBaseline.Status = .captured,
        outboundUserMessage: AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage? = nil,
        prefixSHA256: String? = nil
    ) -> AgentSessionProviderHistoryRecovery.DispatchBaseline {
        AgentSessionProviderHistoryRecovery.DispatchBaseline(
            dispatchID: dispatchID,
            runAttemptID: runAttemptID,
            transcriptResetGeneration: generation,
            providerRaw: "claude",
            conversationID: conversationID,
            userItemIDs: userItemIDs,
            file: status == .captured ? AgentRecoveryHistoryFileIdentity(device: 7, inode: 1 << 60, birthSeconds: 5, birthNanoseconds: 6) : nil,
            completeLineOffset: status == .captured ? 42 : 0,
            prefixSHA256: prefixSHA256,
            baselineCommitID: status == .captured ? UUID() : nil,
            profileName: ClaudeSessionHistoryReader.profileName,
            status: status,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
            outboundUserMessage: outboundUserMessage
        )
    }

    func testDispatchBaselinesRoundTripAndKeepUnreadableEntriesVerbatim() throws {
        let captured = baseline()
        let unsupported = baseline(conversationID: nil, status: .unsupported("no identity"))
        let ledger = AgentSessionProviderHistoryRecovery(dispatchBaselines: [captured, unsupported])
        XCTAssertNotNil(ledger.nilIfEmpty, "a baseline alone is persisted")
        let decoded = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
        XCTAssertEqual(decoded.dispatchBaselines.first?.file?.inode, 1 << 60, "file identity survives exactly")
        XCTAssertEqual(decoded.dispatchBaselines.first?.cursor?.importID, captured.baselineCommitID)
        XCTAssertNil(decoded.dispatchBaselines.last?.cursor, "an unsupported capture is never a boundary")

        // Unknown status and an incomplete capture stay verbatim, never usable, never failing the session.
        let json = #"{"dispatchBaselines":[{"dispatchID":"\#(UUID().uuidString)","transcriptResetGeneration":0,"provider":"claude","completeLineOffset":0,"profile":"p","status":"futureStatus","recordedAtMs":0,"future":true},{"dispatchID":"\#(UUID().uuidString)","transcriptResetGeneration":0,"provider":"claude","completeLineOffset":0,"profile":"p","status":"captured","recordedAtMs":0}]}"#
        let partial = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: Data(json.utf8))
        XCTAssertTrue(partial.dispatchBaselines.isEmpty)
        XCTAssertEqual(partial.unreadableDispatchBaselines.count, 2)
        let roundTripped = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: JSONEncoder().encode(partial))
        XCTAssertEqual(roundTripped, partial)
        XCTAssertNotNil(partial.nilIfEmpty)
    }

    /// Step 4d1: the outbound claim round-trips with the baseline's unknown members; a legacy
    /// baseline decodes with no claim; a malformed claim makes that baseline unreadable (kept
    /// verbatim), never a claim.
    func testOutboundUserMessageClaimRoundTripsWithUnknownMembersAndLegacyStaysUnclaimed() throws {
        let dispatchID = UUID()
        var claim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(
            uuid: dispatchID,
            providerBoundText: "héllo\n"
        )
        XCTAssertEqual(
            AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(uuid: dispatchID, providerBoundText: "abc").textSHA256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "lowercase hex SHA-256 of the UTF-8 bytes"
        )
        XCTAssertEqual(claim.textSHA256.count, 64)
        XCTAssertEqual(claim.textSHA256, claim.textSHA256.lowercased())
        XCTAssertNotEqual(
            claim.textSHA256,
            AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(uuid: dispatchID, providerBoundText: "héllo").textSHA256,
            "the digest covers the exact text"
        )
        // An unknown member INSIDE the claim survives decode and re-encode.
        claim.extras["futureClaimMember"] = .object(["v": .number(2)])
        let legacy = baseline(dispatchID: dispatchID)
        let claimed = AgentSessionProviderHistoryRecovery.DispatchBaseline(
            dispatchID: legacy.dispatchID,
            runAttemptID: legacy.runAttemptID,
            transcriptResetGeneration: legacy.transcriptResetGeneration,
            providerRaw: legacy.providerRaw,
            conversationID: legacy.conversationID,
            userItemIDs: legacy.userItemIDs,
            file: legacy.file,
            completeLineOffset: legacy.completeLineOffset,
            baselineCommitID: legacy.baselineCommitID,
            profileName: legacy.profileName,
            status: legacy.status,
            recordedAt: legacy.recordedAt,
            outboundUserMessage: claim,
            extras: ["futureMember": .string("kept")]
        )
        let decoded = try JSONDecoder().decode(
            AgentSessionProviderHistoryRecovery.DispatchBaseline.self,
            from: JSONEncoder().encode(claimed)
        )
        XCTAssertEqual(decoded, claimed)
        XCTAssertEqual(decoded.outboundUserMessage, claim)
        XCTAssertEqual(decoded.outboundUserMessage?.extras["futureClaimMember"], .object(["v": .number(2)]))
        XCTAssertEqual(decoded.extras["futureMember"], .string("kept"))
        let reencoded = try JSONDecoder().decode(
            AgentSessionProviderHistoryRecovery.DispatchBaseline.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(reencoded, claimed, "a second save keeps the nested unknown member")

        let legacyDecoded = try JSONDecoder().decode(
            AgentSessionProviderHistoryRecovery.DispatchBaseline.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(legacyDecoded.outboundUserMessage, "a legacy baseline never gains a claim")
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(legacyObject["outboundUserMessage"], "no claim key is written when absent")

        // Malformed claims (bad UUID, or a digest that is not exactly 64 lowercase hex digits) make
        // that baseline unreadable, kept verbatim, never a claim.
        let goodDigest = String(repeating: "a", count: 64)
        let malformedClaims = [
            #"{"uuid":"not-a-uuid","textSHA256":"\#(goodDigest)"}"#,
            #"{"uuid":"\#(UUID().uuidString)","textSHA256":"\#(goodDigest.uppercased())"}"#,
            #"{"uuid":"\#(UUID().uuidString)","textSHA256":"\#(goodDigest.dropLast())"}"#,
            #"{"uuid":"\#(UUID().uuidString)","textSHA256":"\#(goodDigest.dropLast())g"}"#,
            #"{"uuid":"\#(UUID().uuidString)"}"#
        ]
        for malformedClaim in malformedClaims {
            let malformed = #"{"dispatchBaselines":[{"dispatchID":"\#(UUID().uuidString)","transcriptResetGeneration":0,"provider":"claude","conversationID":"c","completeLineOffset":0,"baselineCommitID":"\#(UUID().uuidString)","profile":"p","status":"captured","recordedAtMs":0,"outboundUserMessage":\#(malformedClaim)}]}"#
            let ledger = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: Data(malformed.utf8))
            XCTAssertTrue(ledger.dispatchBaselines.isEmpty, malformedClaim)
            XCTAssertEqual(ledger.unreadableDispatchBaselines.count, 1, malformedClaim)
        }
        // Positive control: the same shape with a valid lowercase digest decodes as a claim.
        let valid = #"{"dispatchBaselines":[{"dispatchID":"\#(UUID().uuidString)","transcriptResetGeneration":0,"provider":"claude","conversationID":"c","completeLineOffset":0,"baselineCommitID":"\#(UUID().uuidString)","profile":"p","status":"captured","recordedAtMs":0,"outboundUserMessage":{"uuid":"\#(UUID().uuidString)","textSHA256":"\#(goodDigest)"}}]}"#
        let validLedger = try JSONDecoder().decode(AgentSessionProviderHistoryRecovery.self, from: Data(valid.utf8))
        XCTAssertEqual(validLedger.dispatchBaselines.first?.outboundUserMessage?.textSHA256, goodDigest)
        XCTAssertTrue(validLedger.unreadableDispatchBaselines.isEmpty)
    }

    // MARK: Association preflight (pure)

    private func observation(
        _ rows: [AgentProviderHistoryRow],
        conversationID: String = "conv-1",
        validation: [AgentProviderHistoryRow]? = nil
    ) -> AgentProviderHistoryObservation {
        AgentProviderHistoryObservation(
            provider: .claude,
            conversationID: conversationID,
            rows: rows,
            validationRows: validation,
            file: nil,
            completeLineOffset: 0,
            completionConfirmed: false
        )
    }

    private func assistantRow(_ entry: String, text: String = "Done.") -> AgentProviderHistoryRow {
        AgentProviderHistoryRow(
            nativeSessionID: "conv-1",
            nativeEntryID: entry,
            rowKindRaw: "assistantText",
            ordinal: 0,
            item: AgentChatItem.assistant(text).replacingID(ClaudeSessionHistoryReader.deterministicUUID(
                namespace: "fixture",
                components: [entry]
            ))
        )
    }

    /// A projected row carrying exactly `item` (its local ID included).
    private func projectedRow(_ entry: String, kind: String, item: AgentChatItem) -> AgentProviderHistoryRow {
        AgentProviderHistoryRow(nativeSessionID: "conv-1", nativeEntryID: entry, rowKindRaw: kind, ordinal: 0, item: item)
    }

    /// A ledger row mapping `entry` to `localItemID`, with no envelope digest.
    private func mappedNative(_ entry: String, kind: String, localItemID: UUID) -> AgentSessionProviderHistoryRecovery.NativeItem {
        .init(providerRaw: "claude", nativeSessionID: "conv-1", nativeEntryID: entry, rowKindRaw: kind, ordinal: 0, localItemID: localItemID)
    }

    private func nativeUserRow(_ entry: String) -> AgentProviderHistoryRow {
        AgentProviderHistoryRow(nativeSessionID: "conv-1", nativeEntryID: entry, rowKindRaw: "userText", ordinal: 0, item: nil)
    }

    private func preflight(
        _ observation: AgentProviderHistoryObservation,
        baseline: AgentSessionProviderHistoryRecovery.DispatchBaseline?,
        runAttemptID: UUID?,
        generation: UInt64 = 0,
        transcript: AgentTranscript = .empty,
        items: [AgentChatItem],
        ledger: AgentSessionProviderHistoryRecovery? = nil,
        hasUnreadable: Bool = false
    ) -> AgentProviderHistoryAssociationRefusal? {
        AgentProviderHistoryAssociationPreflight.check(
            observation: observation,
            baseline: baseline,
            hasUnreadableBaselines: hasUnreadable,
            expectedRunAttemptID: runAttemptID,
            transcriptResetGeneration: generation,
            canonical: AgentProviderHistoryCanonicalView(transcript: transcript, suffixItems: items),
            ledger: ledger
        )
    }

    /// An explicit ledger association of the dispatch's local user item to a native user row of
    /// `conversationID` (review A P1-05: every user constituent must be positively associated).
    private func userAssociation(
        _ userItem: AgentChatItem,
        conversationID: String = "conv-1",
        rowKindRaw: String = "userText",
        localItemID: UUID?? = .none
    ) -> AgentSessionProviderHistoryRecovery.NativeItem {
        .init(
            providerRaw: "claude",
            nativeSessionID: conversationID,
            nativeEntryID: "u-\(userItem.id.uuidString)",
            rowKindRaw: rowKindRaw,
            ordinal: 0,
            localItemID: localItemID ?? userItem.id
        )
    }

    private func userLedger(_ userItem: AgentChatItem) -> AgentSessionProviderHistoryRecovery {
        AgentSessionProviderHistoryRecovery(nativeItems: [userAssociation(userItem)])
    }

    /// The native user row `userAssociation(userItem)` maps, as the validation projection carries it
    /// (Step 4d3a: a mapped user row is an order anchor and must be in the projection).
    private func userRow(_ userItem: AgentChatItem) -> AgentProviderHistoryRow {
        nativeUserRow("u-\(userItem.id.uuidString)")
    }

    func testPreflightRequiresPositiveAssociationOfEveryUserConstituent() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let steer = AgentChatItem.user("Also this")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let empty = observation([])
        XCTAssertEqual(
            preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem]),
            .nativeUserAssociationUnavailable,
            "no empty-output shortcut: an unassociated user item refuses"
        )
        for unassociated in [
            userAssociation(userItem, localItemID: .some(nil)),
            userAssociation(userItem, conversationID: "conv-other"),
            userAssociation(userItem, rowKindRaw: "assistantText")
        ] {
            XCTAssertEqual(
                preflight(
                    empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem],
                    ledger: AgentSessionProviderHistoryRecovery(nativeItems: [unassociated])
                ),
                .nativeUserAssociationUnavailable
            )
        }
        XCTAssertNil(preflight(
            observation([], validation: [userRow(userItem)]), baseline: captured, runAttemptID: runAttemptID,
            items: [userItem], ledger: userLedger(userItem)
        ))
        XCTAssertEqual(
            preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem], ledger: userLedger(userItem)),
            .canonicalPayloadUnavailable,
            "Step 4d3a: a mapped native user row must be in the validation projection to anchor order"
        )
        // Every constituent: a steered second user item without its own association refuses.
        let both = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id, steer.id])
        XCTAssertEqual(
            preflight(empty, baseline: both, runAttemptID: runAttemptID, items: [userItem, steer], ledger: userLedger(userItem)),
            .nativeUserAssociationUnavailable
        )
        let bothAssociated = AgentSessionProviderHistoryRecovery(nativeItems: [userAssociation(userItem), userAssociation(steer)])
        XCTAssertNil(preflight(
            observation([], validation: [userRow(userItem), userRow(steer)]), baseline: both, runAttemptID: runAttemptID,
            items: [userItem, steer], ledger: bothAssociated
        ))
        XCTAssertEqual(
            preflight(
                observation([], validation: [userRow(steer), userRow(userItem)]), baseline: both, runAttemptID: runAttemptID,
                items: [userItem, steer], ledger: bothAssociated
            ),
            .canonicalPayloadMismatch,
            "Step 4d3a: mapped user rows keep the native relative order"
        )
    }

    func testPreflightRequiresTheAttemptsOwnCapturedBaseline() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let empty = observation([])
        XCTAssertEqual(preflight(empty, baseline: nil, runAttemptID: runAttemptID, items: [userItem]), .baselineUnavailable)
        XCTAssertEqual(
            preflight(empty, baseline: baseline(runAttemptID: runAttemptID, status: .unsupported("x")), runAttemptID: runAttemptID, items: [userItem]),
            .baselineUnavailable,
            "an unsupported capture is never backfilled"
        )
        XCTAssertEqual(
            preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: [userItem], hasUnreadable: true),
            .baselineUnavailable
        )
        XCTAssertEqual(preflight(empty, baseline: captured, runAttemptID: UUID(), items: [userItem]), .baselineTargetMismatch)
        XCTAssertEqual(preflight(empty, baseline: captured, runAttemptID: runAttemptID, generation: 1, items: [userItem]), .baselineTargetMismatch)
        XCTAssertEqual(
            preflight(observation([], conversationID: "conv-other"), baseline: captured, runAttemptID: runAttemptID, items: [userItem]),
            .baselineTargetMismatch
        )
        XCTAssertEqual(preflight(empty, baseline: captured, runAttemptID: runAttemptID, items: []), .baselineTargetMismatch)
        XCTAssertNil(preflight(
            observation([], validation: [userRow(userItem)]), baseline: captured, runAttemptID: runAttemptID,
            items: [userItem], ledger: userLedger(userItem)
        ))
    }

    func testPreflightNeverAssumesNativeUserOrLiveOutputAssociations() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        // A native user entry is never mapped to the local user item, even with a ledger whose
        // `localItemID == nil` entries look like "known" user rows.
        let nilLedger = AgentSessionProviderHistoryRecovery(nativeItems: [.init(
            providerRaw: "claude",
            nativeSessionID: "conv-1",
            nativeEntryID: "u0",
            rowKindRaw: "userText",
            ordinal: 0,
            localItemID: nil
        )])
        XCTAssertEqual(
            preflight(observation([nativeUserRow("u1"), assistantRow("a1")]), baseline: captured, runAttemptID: runAttemptID, items: [userItem], ledger: nilLedger),
            .nativeUserAssociationUnavailable
        )
        // A persisted live assistant row with a different local ID blocks the import, even with
        // identical text.
        let live = AgentChatItem.assistant("Done.")
        XCTAssertEqual(
            preflight(
                observation([assistantRow("a1", text: "Done.")]), baseline: captured, runAttemptID: runAttemptID,
                items: [userItem, live], ledger: userLedger(userItem)
            ),
            .canonicalOutputAssociationUnavailable
        )
        // Output before the dispatch's user item is not this dispatch's output.
        XCTAssertNil(preflight(
            observation([assistantRow("a1")], validation: [userRow(userItem), assistantRow("a1")]), baseline: captured,
            runAttemptID: runAttemptID, items: [live, userItem], ledger: userLedger(userItem)
        ))
        // An explicit ledger association of the live row passes when its canonical payload equals
        // the provider's (Step 4d3a), and the planner deduplicates.
        let associated = AgentSessionProviderHistoryRecovery(nativeItems: [userAssociation(userItem), .init(
            providerRaw: "claude",
            nativeSessionID: "conv-1",
            nativeEntryID: "a0",
            rowKindRaw: "assistantText",
            ordinal: 0,
            localItemID: live.id
        )])
        let provided = observation(
            [assistantRow("a1")],
            validation: [userRow(userItem), projectedRow("a0", kind: "assistantText", item: live), assistantRow("a1")]
        )
        XCTAssertNil(preflight(provided, baseline: captured, runAttemptID: runAttemptID, items: [userItem, live], ledger: associated))
        XCTAssertEqual(
            preflight(observation([assistantRow("a1")]), baseline: captured, runAttemptID: runAttemptID, items: [userItem, live], ledger: associated),
            .canonicalPayloadUnavailable,
            "an association is never accepted without the provider's payload to compare"
        )
    }

    /// Step 4d3a: before overlap or deduplication is accepted, every ledger-mapped projected row (a
    /// nil digest included) and every observation row already in the canonical transcript must match
    /// the provider's payload and relative order across persisted full turns and the suffix. Anything
    /// unavailable or different refuses; presentation fields never matter.
    // swiftlint:disable:next function_body_length
    func testPreflightComparesEveryMappedRowsCanonicalPayloadAndOrder() throws {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        var answer = AgentChatItem.assistant("First.")
        answer.sequenceIndex = 1
        var call = AgentChatItem.toolCall(name: "Read", invocationID: UUID(), argsJSON: #"{"path":"a"}"#)
        call.sequenceIndex = 2
        var result = AgentChatItem.toolResult(name: "Read", invocationID: call.toolInvocationID, resultJSON: "contents", isError: false)
        result.sequenceIndex = 3
        var closing = AgentChatItem.assistant("Second.")
        closing.sequenceIndex = 4
        let mapped = [("a0", "assistantText", answer), ("t0", "toolCall", call), ("t1", "toolResult", result), ("a1", "assistantText", closing)]
        let mappedRows = mapped.map { projectedRow($0.0, kind: $0.1, item: $0.2) }
        // Native order: the mapped user row first (the suffix cases), or after the output (the
        // earlier-turn cases, where that output predates the dispatch).
        let validation = [userRow(userItem)] + mappedRows
        let outputBeforeUser = mappedRows + [userRow(userItem)]
        var ledger = userLedger(userItem)
        ledger.nativeItems += mapped.map { mappedNative($0.0, kind: $0.1, localItemID: $0.2.id) }
        XCTAssertTrue(ledger.nativeItems.allSatisfy { $0.envelopeDigest == nil })
        func check(
            _ items: [AgentChatItem],
            transcript: AgentTranscript = .empty,
            validation order: [AgentProviderHistoryRow]? = nil,
            observation value: AgentProviderHistoryObservation? = nil
        ) -> AgentProviderHistoryAssociationRefusal? {
            preflight(
                value ?? observation([], validation: order ?? validation), baseline: captured, runAttemptID: runAttemptID,
                transcript: transcript, items: items, ledger: ledger
            )
        }
        let suffix = [userItem, answer, call, result, closing]
        func replacing(_ target: AgentChatItem, _ change: (inout AgentChatItem) -> Void) -> [AgentChatItem] {
            suffix.map { item in
                var copy = item
                if copy.id == target.id { change(&copy) }
                return copy
            }
        }
        XCTAssertNil(check(suffix), "equal payloads in provider order pass")
        XCTAssertNil(
            check(replacing(answer) { item in
                item.sequenceIndex = 99
                item.isStreaming = true
            }),
            "sequence and streaming are presentation only"
        )
        XCTAssertEqual(
            check(suffix, observation: observation([])),
            .canonicalPayloadUnavailable,
            "known rows must be retained in the validation projection"
        )

        // Same ID, changed canonical text, kind or tool fields.
        let changes: [(String, [AgentChatItem])] = [
            ("text", replacing(answer) { $0.text = "Edited." }),
            ("kind", replacing(answer) { $0.kind = .assistantInline }),
            ("tool args", replacing(call) { $0.toolArgsJSON = #"{"path":"b"}"# }),
            ("tool name", replacing(call) { $0.toolName = "Write" }),
            ("tool invocation", replacing(call) { $0.toolInvocationID = UUID() }),
            ("tool result", replacing(result) { $0.toolResultJSON = "other" }),
            ("tool error", replacing(result) { $0.toolIsError = true })
        ]
        for (label, items) in changes {
            XCTAssertEqual(check(items), .canonicalPayloadMismatch, label)
        }
        XCTAssertEqual(check([userItem, closing, answer, call, result]), .canonicalPayloadMismatch, "reversed relative order")

        // Missing, ambiguous, unavailable or summary-only payloads.
        XCTAssertEqual(check(suffix.filter { $0.id != closing.id }), .canonicalPayloadUnavailable, "a missing mapped row")
        XCTAssertEqual(check(suffix + [answer]), .canonicalPayloadUnavailable, "an ambiguous mapped row")
        XCTAssertEqual(check(replacing(call) { $0.toolArgsJSON = nil }), .canonicalPayloadUnavailable, "dropped tool arguments")
        XCTAssertEqual(check(replacing(result) { $0.toolResultJSON = nil }), .canonicalPayloadUnavailable, "dropped tool result")
        XCTAssertEqual(
            check(replacing(result) { $0.toolResultJSON = #"{"summary_only":true,"summary":"Read a"}"# }),
            .canonicalPayloadUnavailable,
            "a tool result compacted to its summary"
        )

        // Persisted turns: an earlier turn (before the dispatch) holds the mapped rows.

        func activity(_ item: AgentChatItem, summaryOnly: Bool = false) -> AgentTranscriptActivity {
            let isTool = item.kind == .toolCall || item.kind == .toolResult
            return AgentTranscriptActivity(from: item, toolExecution: isTool ? AgentTranscriptToolExecution(
                stableExecutionID: item.id.uuidString,
                toolName: item.toolName,
                invocationID: item.toolInvocationID,
                argsJSON: item.toolArgsJSON,
                resultJSON: item.toolResultJSON,
                toolIsError: item.toolIsError,
                status: .success,
                summaryOnly: summaryOnly
            ) : nil)
        }
        func turn(
            _ items: [AgentChatItem],
            request: AgentChatItem? = nil,
            tier: AgentTranscriptRetentionTier = .full,
            summaryOnly: Bool = false
        ) -> AgentTranscriptTurn {
            AgentTranscriptTurn(
                request: request.map(AgentTranscriptRequestAnchor.init(from:)),
                responseSpans: items.isEmpty ? [] : [AgentTranscriptProviderResponseSpan(
                    startedAt: Date(timeIntervalSince1970: 0),
                    activities: items.map { activity($0, summaryOnly: summaryOnly) }
                )],
                retentionTier: tier,
                startedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let earlier = [answer, call, result, closing]
        XCTAssertNil(
            check([userItem], transcript: AgentTranscript(turns: [turn(earlier)]), validation: outputBeforeUser),
            "a full turn's payloads compare"
        )
        XCTAssertNil(
            check([userItem], transcript: AgentTranscript(turns: [turn(earlier)])),
            "output is ordered among output only, never against user anchors (review A R1 / B F1, option a)"
        )
        XCTAssertEqual(
            check([userItem], transcript: AgentTranscript(turns: [turn(earlier, tier: .condensed)]), validation: outputBeforeUser),
            .canonicalPayloadUnavailable,
            "a compacted turn's stored rows are not full detail"
        )
        XCTAssertEqual(
            check([userItem], transcript: AgentTranscript(turns: [turn([], tier: .summary)]), validation: outputBeforeUser),
            .canonicalPayloadUnavailable,
            "a structurally compacted turn stores no rows"
        )
        XCTAssertEqual(
            check([userItem], transcript: AgentTranscript(turns: [turn(earlier, summaryOnly: true)]), validation: outputBeforeUser),
            .canonicalPayloadUnavailable,
            "a summary-only tool execution"
        )

        // Full turns plus suffix: the newest persisted turn repeats the suffix. The suffix copy is
        // authoritative, and a turn-only row of an earlier turn precedes it.
        let answerFirst = [mappedRows[0], userRow(userItem)] + mappedRows.dropFirst()
        let overlapping = AgentTranscript(turns: [turn([answer]), turn([call, result, closing], request: userItem)])
        let overlapSuffix = [userItem, call, result, closing]
        XCTAssertNil(check(overlapSuffix, transcript: overlapping, validation: answerFirst))
        var editedClosing = closing
        editedClosing.text = "Edited."
        XCTAssertEqual(
            check([userItem, call, result, editedClosing], transcript: overlapping, validation: answerFirst),
            .canonicalPayloadMismatch,
            "the authoritative suffix copy is compared"
        )
        let reversedAcrossTurns = AgentTranscript(turns: [turn([closing]), turn([answer, call, result], request: userItem)])
        XCTAssertEqual(
            check([userItem, answer, call, result], transcript: reversedAcrossTurns),
            .canonicalPayloadMismatch,
            "a turn-only row precedes the suffix"
        )
        // A turn-only row inside a turn that also holds suffix items has no determined place.
        let mixedTurn = AgentTranscript(turns: [turn([answer, call, result, closing], request: userItem)])
        XCTAssertEqual(
            check(overlapSuffix, transcript: mixedTurn),
            .canonicalPayloadUnavailable,
            "ambiguous placement refuses rather than guess"
        )

        // Deduplication: an observation row already present is compared before it is accepted.
        let fresh = assistantRow("a2", text: "Third.")
        let present = try XCTUnwrap(fresh.item)
        let withFresh = observation([fresh], validation: validation + [fresh])
        XCTAssertNil(check(suffix + [present], observation: withFresh))
        var editedPresent = present
        editedPresent.text = "Other."
        XCTAssertEqual(check(suffix + [editedPresent], observation: withFresh), .canonicalPayloadMismatch)
        XCTAssertEqual(check([userItem, answer, call, result, present, closing], observation: withFresh), .canonicalPayloadMismatch)
        XCTAssertEqual(
            check(suffix + [present], observation: observation([fresh], validation: validation)),
            .canonicalPayloadUnavailable,
            "a present row outside the validation projection"
        )
    }

    func testPreflightCannotLoseCompactedCanonicalOutput() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let compacted = AgentTranscriptTurn(
            request: AgentTranscriptRequestAnchor(from: userItem),
            retentionTier: .summary,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        var transcript = AgentTranscript.empty
        transcript.turns = [compacted]
        XCTAssertEqual(
            preflight(
                observation([assistantRow("a1")]), baseline: captured, runAttemptID: runAttemptID,
                transcript: transcript, items: [], ledger: userLedger(userItem)
            ),
            .canonicalOutputAssociationUnavailable,
            "a dispatch inside a compacted turn has output that cannot be enumerated"
        )
    }

    /// Step 4d3a: the attempt's exactly matched claims anchor each claimed native user entry to its
    /// dispatch's ordered local constituents. Anchors are ordered among themselves and output rows
    /// among themselves, never output against anchors: the importer's own append-at-end order
    /// `[first, steer, reply]` passes (review A R1 / B F1, option a), while reordered provider output
    /// or user constituents still refuse. User payloads are never compared.
    func testClaimedUserConstituentsAnchorTheirOwnOrderAndOutputKeepsItsOwn() throws {
        typealias Claim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage
        let runAttemptID = UUID()
        let first = AgentChatItem.user("Do it")
        let steer = AgentChatItem.user("Also this")
        let firstDispatch = UUID()
        let steerDispatch = UUID()
        let window = [
            baseline(
                dispatchID: firstDispatch, runAttemptID: runAttemptID, userItemIDs: [first.id],
                outboundUserMessage: Claim(uuid: firstDispatch, providerBoundText: "Do it")
            ),
            baseline(
                dispatchID: steerDispatch, runAttemptID: runAttemptID, userItemIDs: [steer.id],
                outboundUserMessage: Claim(uuid: steerDispatch, providerBoundText: "Also this")
            )
        ]
        let entries = [(firstDispatch, "Do it"), (steerDispatch, "Also this")].map { id, text in
            AgentProviderHistoryNativeUserEntry(
                nativeEntryID: id.uuidString.lowercased(),
                textSHA256: AgentSessionProviderHistoryRecovery.sha256Hex(Data(text.utf8))
            )
        }
        // Both replies were imported earlier (ledger-known, so not new rows); natively the first lies
        // between the two claimed entries.
        let reply = assistantRow("a1")
        let replyItem = try XCTUnwrap(reply.item)
        let later = assistantRow("a2", text: "Also done.")
        let laterItem = try XCTUnwrap(later.item)
        let ledger = AgentSessionProviderHistoryRecovery(nativeItems: [
            mappedNative("a1", kind: "assistantText", localItemID: replyItem.id),
            mappedNative("a2", kind: "assistantText", localItemID: laterItem.id)
        ])
        let userRows = entries.map { nativeUserRow($0.nativeEntryID) }
        func check(_ items: [AgentChatItem], validation: [AgentProviderHistoryRow]? = nil) -> AgentProviderHistoryAssociationRefusal? {
            AgentProviderHistoryAssociationPreflight.check(
                observation: AgentProviderHistoryObservation(
                    provider: .claude,
                    conversationID: "conv-1",
                    rows: userRows,
                    validationRows: validation ?? [userRows[0], reply, userRows[1], later],
                    file: nil,
                    completeLineOffset: 0,
                    completionConfirmed: false,
                    nativeUserEntries: entries
                ),
                baseline: window[0],
                hasUnreadableBaselines: false,
                expectedRunAttemptID: runAttemptID,
                transcriptResetGeneration: 0,
                canonical: AgentProviderHistoryCanonicalView(transcript: .empty, suffixItems: items),
                ledger: ledger,
                dispatchWindow: window
            )
        }
        XCTAssertNil(check([first, steer, replyItem, laterItem]), "the importer's append-at-end order")
        XCTAssertNil(check([first, replyItem, steer, laterItem]), "the native interleaving")
        XCTAssertEqual(
            check([first, steer, laterItem, replyItem]),
            .canonicalPayloadMismatch,
            "reordered provider output"
        )
        XCTAssertEqual(
            check([steer, first, replyItem, laterItem]),
            .outboundClaimUnmatched,
            "reordered claimed user constituents"
        )
        var localText = first
        localText.text = "Do it (as typed locally)"
        XCTAssertNil(check([localText, steer, replyItem, laterItem]), "the local user text is never compared")
        XCTAssertEqual(
            check([first, steer, replyItem, laterItem], validation: [userRows[0], reply, later]),
            .canonicalPayloadUnavailable,
            "every claimed entry must be anchored in the projection"
        )
        XCTAssertEqual(
            check([first, steer, replyItem, laterItem], validation: [userRows[0], reply, userRows[1], userRows[1], later]),
            .canonicalPayloadUnavailable,
            "an ambiguous anchor refuses"
        )
    }

    /// Step 4d3a (review B P3 F3): turn-only tool copies built by the real transcript builder compare
    /// equal to the provider's projected call and result (no hand-built activity). The builder stores
    /// the normalized tool name (`Read` → `read`) and nothing else differs; only that exact transform
    /// is accepted, and only for a turn copy.
    func testRealTranscriptBuilderToolCopiesCompareEqual() {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        var call = AgentChatItem.toolCall(name: "Read", invocationID: UUID(), argsJSON: #"{"path":"a"}"#)
        call.sequenceIndex = 1
        var result = AgentChatItem.toolResult(name: "Read", invocationID: call.toolInvocationID, resultJSON: "contents", isError: false)
        result.sequenceIndex = 2
        let built = AgentTranscriptIO.buildTranscript(from: [userItem, call, result], compact: false)
        var ledger = userLedger(userItem)
        ledger.nativeItems += [
            mappedNative("t0", kind: "toolCall", localItemID: call.id),
            mappedNative("t1", kind: "toolResult", localItemID: result.id)
        ]
        let validation = [
            userRow(userItem),
            projectedRow("t0", kind: "toolCall", item: call),
            projectedRow("t1", kind: "toolResult", item: result)
        ]
        func check(transcript: AgentTranscript, items: [AgentChatItem]) -> AgentProviderHistoryAssociationRefusal? {
            preflight(
                observation([], validation: validation), baseline: captured, runAttemptID: runAttemptID,
                transcript: transcript, items: items, ledger: ledger
            )
        }
        XCTAssertEqual(built.turns.first?.allActivities.first?.toItem().toolName, "read", "the builder normalizes the name")
        XCTAssertNil(check(transcript: built, items: []))
        var renamed = call
        renamed.toolName = "Write"
        XCTAssertEqual(
            check(transcript: AgentTranscriptIO.buildTranscript(from: [userItem, renamed, result], compact: false), items: []),
            .canonicalPayloadMismatch,
            "another tool's name still differs in a turn copy"
        )
        var normalizedInSuffix = call
        normalizedInSuffix.toolName = "read"
        XCTAssertEqual(
            check(transcript: .empty, items: [userItem, normalizedInSuffix, result]),
            .canonicalPayloadMismatch,
            "a suffix copy keeps the provider's name verbatim"
        )
    }

    /// Step 4d3a, Q4: a Claude import plans against every canonical ID (persisted turns, requests
    /// included, plus the suffix) after the preflight. A row whose deterministic item is held only by
    /// a full persisted turn is compared first, then recorded, never appended again.
    func testClaudeImportNeverReappendsARowHeldOnlyByAPersistedTurn() throws {
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let captured = baseline(runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let row = assistantRow("a2", text: "Held by a turn.")
        var held = try XCTUnwrap(row.item)
        held.sequenceIndex = 1
        func canonical(_ item: AgentChatItem) -> AgentProviderHistoryCanonicalView {
            AgentProviderHistoryCanonicalView(
                transcript: AgentTranscript(turns: [AgentTranscriptTurn(
                    request: AgentTranscriptRequestAnchor(from: userItem),
                    responseSpans: [AgentTranscriptProviderResponseSpan(
                        startedAt: Date(timeIntervalSince1970: 0),
                        activities: [AgentTranscriptActivity(from: item)]
                    )],
                    startedAt: Date(timeIntervalSince1970: 0)
                )]),
                suffixItems: []
            )
        }
        let value = observation([row], validation: [userRow(userItem), row])
        func check(_ view: AgentProviderHistoryCanonicalView) -> AgentProviderHistoryAssociationRefusal? {
            AgentProviderHistoryAssociationPreflight.check(
                observation: value,
                baseline: captured,
                hasUnreadableBaselines: false,
                expectedRunAttemptID: runAttemptID,
                transcriptResetGeneration: 0,
                canonical: view,
                ledger: userLedger(userItem)
            )
        }
        let view = canonical(held)
        XCTAssertNil(check(view))
        func plan(existing: Set<UUID>) -> AgentProviderHistoryImportPlan {
            AgentProviderHistoryImportPlanner.plan(
                observation: value,
                existingItemIDs: existing,
                ledger: userLedger(userItem),
                previousCursor: nil,
                importID: UUID(),
                now: Date(timeIntervalSince1970: 0)
            )
        }
        let planned = plan(existing: Set(AgentProviderHistoryAssociationPreflight.canonicalItemIDs(view)))
        XCTAssertTrue(planned.appendedItems.isEmpty, "the turn's row is not appended again")
        XCTAssertEqual(planned.ledger.nativeItems.last?.localItemID, held.id, "it is recorded against the existing item")
        XCTAssertEqual(
            plan(existing: Set(view.suffixItems.map(\.id))).appendedItems.map(\.id).last,
            held.id,
            "the suffix-only set would have appended it twice"
        )
        var changed = held
        changed.text = "Changed in the turn."
        XCTAssertEqual(check(canonical(changed)), .canonicalPayloadMismatch, "a differing turn copy refuses first")
    }

    /// Step 4d2: the attempt's outbound claims associate native user entries only on an exact match
    /// (one entry per claim, its own UUID, dispatch order, equal text digest, nothing unclaimed, every
    /// constituent in the transcript in order). A claim never proves a write.
    func testOutboundClaimsAssociateOnlyAnExactNativeUserMatch() {
        typealias Claim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage
        let runAttemptID = UUID()
        let first = AgentChatItem.user("Do it")
        let steer = AgentChatItem.user("Also this")
        let firstDispatch = UUID()
        let steerDispatch = UUID()
        let firstBaseline = baseline(
            dispatchID: firstDispatch, runAttemptID: runAttemptID, userItemIDs: [first.id],
            outboundUserMessage: Claim(uuid: firstDispatch, providerBoundText: "Do it")
        )
        let steerBaseline = baseline(
            dispatchID: steerDispatch, runAttemptID: runAttemptID, userItemIDs: [steer.id],
            outboundUserMessage: Claim(uuid: steerDispatch, providerBoundText: "Also this")
        )
        func native(_ dispatchID: UUID, _ text: String?) -> AgentProviderHistoryNativeUserEntry {
            .init(
                nativeEntryID: dispatchID.uuidString.lowercased(),
                textSHA256: text.map { AgentSessionProviderHistoryRecovery.sha256Hex(Data($0.utf8)) }
            )
        }
        func claimed(_ entries: [AgentProviderHistoryNativeUserEntry]) -> AgentProviderHistoryObservation {
            AgentProviderHistoryObservation(
                provider: .claude,
                conversationID: "conv-1",
                rows: entries.map { nativeUserRow($0.nativeEntryID) } + [assistantRow("a1")],
                file: nil,
                completeLineOffset: 0,
                completionConfirmed: false,
                nativeUserEntries: entries
            )
        }
        func check(
            _ observation: AgentProviderHistoryObservation,
            window: [AgentSessionProviderHistoryRecovery.DispatchBaseline]? = nil,
            items: [AgentChatItem]? = nil
        ) -> AgentProviderHistoryAssociationRefusal? {
            let window = window ?? [firstBaseline, steerBaseline]
            return AgentProviderHistoryAssociationPreflight.check(
                observation: observation,
                baseline: window.first,
                hasUnreadableBaselines: false,
                expectedRunAttemptID: runAttemptID,
                transcriptResetGeneration: 0,
                canonical: AgentProviderHistoryCanonicalView(transcript: .empty, suffixItems: items ?? [first, steer]),
                ledger: nil,
                dispatchWindow: window
            )
        }
        let exact = [native(firstDispatch, "Do it"), native(steerDispatch, "Also this")]
        XCTAssertNil(check(claimed(exact)))
        let plan = AgentProviderHistoryImportPlanner.plan(
            observation: claimed(exact),
            existingItemIDs: [first.id, steer.id],
            ledger: nil,
            previousCursor: nil,
            importID: UUID(),
            now: Date(timeIntervalSince1970: 7000)
        )
        XCTAssertEqual(plan.appendedItems.map(\.kind), [.system, .assistant], "consumed claimed users are never re-created")
        XCTAssertEqual(plan.ledger.nativeItems.filter { $0.rowKindRaw == "userText" }.map(\.localItemID), [nil, nil])

        XCTAssertEqual(check(claimed([exact[0]])), .outboundClaimUnmatched, "a missing claimed steering entry")
        XCTAssertEqual(check(claimed([native(firstDispatch, "Do it!"), exact[1]])), .outboundClaimUnmatched, "text digest mismatch")
        XCTAssertEqual(check(claimed([native(firstDispatch, nil), exact[1]])), .outboundClaimUnmatched, "non-string native content")
        XCTAssertEqual(check(claimed([exact[1], exact[0]])), .outboundClaimUnmatched, "reordered entries")
        XCTAssertEqual(check(claimed(exact + [native(UUID(), "Extra")])), .outboundClaimUnmatched, "an unclaimed native user entry")
        XCTAssertEqual(
            check(claimed([exact[0], exact[0]]), window: [firstBaseline, firstBaseline]),
            .outboundClaimUnmatched,
            "ambiguous duplicate claims"
        )
        XCTAssertEqual(check(claimed(exact), items: [first]), .outboundClaimUnmatched, "a constituent missing from the transcript")
        XCTAssertEqual(check(claimed(exact), items: [steer, first]), .outboundClaimUnmatched, "constituents out of order")
        let legacySteer = baseline(dispatchID: steerDispatch, runAttemptID: runAttemptID, userItemIDs: [steer.id])
        XCTAssertEqual(
            check(claimed(exact), window: [firstBaseline, legacySteer]),
            .nativeUserAssociationUnavailable,
            "a dispatch without a claim leaves no claim association"
        )
        let foreign = baseline(
            dispatchID: steerDispatch, runAttemptID: runAttemptID, conversationID: "conv-other", userItemIDs: [steer.id],
            outboundUserMessage: Claim(uuid: steerDispatch, providerBoundText: "Also this")
        )
        XCTAssertEqual(check(claimed(exact), window: [firstBaseline, foreign]), .baselineTargetMismatch)
        // A same-attempt steer recorded unsupported (e.g. read mid-write) has no usable claim: no
        // claim association, never a false "doesn't belong" (review B P2-03).
        let unsupportedSteer = baseline(
            dispatchID: steerDispatch, runAttemptID: runAttemptID, userItemIDs: [steer.id],
            status: .unsupported("Claude's history ends in an incomplete record")
        )
        XCTAssertEqual(
            check(claimed(exact), window: [firstBaseline, unsupportedSteer]),
            .nativeUserAssociationUnavailable,
            "an unsupported same-attempt dispatch leaves no claim association"
        )
        XCTAssertEqual(
            check(claimed(exact), items: [first, steer, .assistant("Done.")]),
            .canonicalOutputAssociationUnavailable,
            "saved live output under its own ID still refuses"
        )
        XCTAssertEqual(
            preflight(claimed(exact), baseline: firstBaseline, runAttemptID: runAttemptID, items: [first, steer]),
            .nativeUserAssociationUnavailable,
            "callers without a dispatch window keep the ledger-only contract"
        )
    }

    /// Review A R1: once a dispatch's first user item is passed, every later persisted turn's output
    /// is canonical output to associate, whatever that turn's own request. Only the turn holding the
    /// first user item filters output before it. The helper is shared with the Codex overlap check.
    func testCanonicalOutputOfEveryLaterPersistedTurnIsChecked() {
        typealias Claim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage
        let runAttemptID = UUID()
        let older = AgentChatItem.user("Earlier")
        var before = AgentChatItem.assistant("Before.")
        before.sequenceIndex = 1
        var first = AgentChatItem.user("Do it")
        first.sequenceIndex = 2
        let steer = AgentChatItem.user("Also this")
        var live = AgentChatItem.assistant("Done.")
        live.sequenceIndex = 4
        let firstDispatch = UUID()
        let steerDispatch = UUID()
        let window = [
            baseline(
                dispatchID: firstDispatch, runAttemptID: runAttemptID, userItemIDs: [first.id],
                outboundUserMessage: Claim(uuid: firstDispatch, providerBoundText: "Do it")
            ),
            baseline(
                dispatchID: steerDispatch, runAttemptID: runAttemptID, userItemIDs: [steer.id],
                outboundUserMessage: Claim(uuid: steerDispatch, providerBoundText: "Also this")
            )
        ]
        let entries = [(firstDispatch, "Do it"), (steerDispatch, "Also this")].map { id, text in
            AgentProviderHistoryNativeUserEntry(
                nativeEntryID: id.uuidString.lowercased(),
                textSHA256: AgentSessionProviderHistoryRecovery.sha256Hex(Data(text.utf8))
            )
        }
        let claimed = AgentProviderHistoryObservation(
            provider: .claude,
            conversationID: "conv-1",
            rows: entries.map { nativeUserRow($0.nativeEntryID) } + [assistantRow("a1")],
            file: nil,
            completeLineOffset: 0,
            completionConfirmed: false,
            nativeUserEntries: entries
        )
        func spans(_ items: [AgentChatItem]) -> [AgentTranscriptProviderResponseSpan] {
            [AgentTranscriptProviderResponseSpan(startedAt: Date(timeIntervalSince1970: 0), activities: items.map { AgentTranscriptActivity(from: $0) })]
        }
        func canonical(secondTurn: [AgentChatItem]) -> AgentProviderHistoryCanonicalView {
            // Turn 1 (request `older`): pre-dispatch output, then the dispatch's first user item.
            // Turn 2 (request: the claimed steer): `secondTurn` output.
            AgentProviderHistoryCanonicalView(
                transcript: AgentTranscript(turns: [
                    AgentTranscriptTurn(
                        request: AgentTranscriptRequestAnchor(from: older),
                        responseSpans: spans([before, first]),
                        startedAt: Date(timeIntervalSince1970: 0)
                    ),
                    AgentTranscriptTurn(
                        request: AgentTranscriptRequestAnchor(from: steer),
                        responseSpans: spans(secondTurn),
                        startedAt: Date(timeIntervalSince1970: 1)
                    )
                ]),
                suffixItems: []
            )
        }
        func check(_ canonical: AgentProviderHistoryCanonicalView) -> AgentProviderHistoryAssociationRefusal? {
            AgentProviderHistoryAssociationPreflight.check(
                observation: claimed,
                baseline: window[0],
                hasUnreadableBaselines: false,
                expectedRunAttemptID: runAttemptID,
                transcriptResetGeneration: 0,
                canonical: canonical,
                ledger: nil,
                dispatchWindow: window
            )
        }
        XCTAssertNil(check(canonical(secondTurn: [])), "first-turn output before the dispatch's user item is excluded")
        XCTAssertEqual(
            check(canonical(secondTurn: [live])),
            .canonicalOutputAssociationUnavailable,
            "unassociated live output in a later persisted turn refuses"
        )
        XCTAssertEqual(
            AgentProviderHistoryAssociationPreflight.outputItemIDs(after: [first.id], in: canonical(secondTurn: [live])),
            .enumerated([live.id])
        )

        // Codex (same helper): live output in a later persisted turn overlaps; output before the
        // interrupted turn's user item in its own turn does not.
        let codexRow = AgentProviderHistoryRow(
            nativeSessionID: "thread-1", nativeEntryID: "item-1", rowKindRaw: "agentMessage", ordinal: 0,
            item: AgentChatItem.assistant("Codex reply")
        )
        let codex = AgentProviderHistoryObservation(
            provider: .codex, conversationID: "thread-1", rows: [codexRow], file: nil, completeLineOffset: 0, completionConfirmed: false
        )
        func codexOverlap(_ canonical: AgentProviderHistoryCanonicalView) -> AgentProviderHistoryAssociationRefusal? {
            AgentProviderHistoryAssociationPreflight.codexOverlapRefusal(
                observation: codex, turnUserItemIDs: [first.id], canonical: canonical, ledger: nil
            )
        }
        XCTAssertNil(codexOverlap(canonical(secondTurn: [])))
        XCTAssertEqual(codexOverlap(canonical(secondTurn: [live])), .canonicalOutputAssociationUnavailable)
    }

    // MARK: Baseline producer and reconcile refusal (view model, real persistence)

    private let conversationID = "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f"
    private let qualified = AgentRecoveryActionQualification(
        sameConversationResume: true,
        historyReconciliation: true,
        freshClaudeConversation: true,
        safeRestart: true
    )

    @MainActor
    private struct ProducerHarness {
        let viewModel: AgentModeViewModel
        let session: AgentTabSession
        let lane: AgentRecoverySessionLane
        let service: AgentSessionDataService
        let workspace: WorkspaceModel
        let home: URL
        let recoveryRoot: URL

        var historyFile: URL {
            home.appendingPathComponent("projects/-fixture-project", isDirectory: true)
                .appendingPathComponent("0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f.jsonl")
        }

        func appendHistory(_ objects: [[String: Any]]) throws {
            try FileManager.default.createDirectory(at: historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = (try? Data(contentsOf: historyFile)) ?? Data()
            for object in objects {
                try data.append(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                data.append(0x0A)
            }
            try data.write(to: historyFile)
        }

        func cursor() async -> AgentRecoveryHistoryCursor? {
            guard case let .success(.supported(record)) = await lane.readRecord() else { return nil }
            return record.historyCursor(providerRaw: "claude", conversationID: "0f8d6a3e-6f0a-4c43-9d0e-2a1b3c4d5e6f")
        }

        func persisted() async throws -> AgentSession? {
            let id = try XCTUnwrap(session.activeAgentSessionID)
            return try await service.loadAgentSession(id: id, for: workspace)
        }
    }

    private func makeProducerHarness(
        windowID: Int,
        qualified isQualified: Bool = true,
        codexFactory: CodexAgentModeCoordinator.CodexControllerFactory? = nil,
        claudeController: LifecycleFakeNativeController? = nil,
        relaunching previous: ProducerHarness? = nil
    ) async throws -> ProducerHarness {
        let storageURL: URL
        let home: URL
        let recoveryRoot: URL
        if let previous {
            // A relaunch: the earlier composition's roots, read by a new store instance.
            storageURL = try XCTUnwrap(previous.workspace.customStoragePath)
            home = previous.home
            recoveryRoot = previous.recoveryRoot
        } else {
            storageURL = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineWorkspace")
            home = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineHome")
            recoveryRoot = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineStore")
                .appendingPathComponent("AgentRecovery/v1", isDirectory: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: storageURL)
                try? FileManager.default.removeItem(at: home)
                try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent().deletingLastPathComponent())
            }
        }
        let store = previous == nil
            ? AgentRecoveryStore(rootURL: recoveryRoot)
            : AgentRecoveryStore(rootURL: recoveryRoot, appInstanceID: UUID())
        let service = AgentSessionDataService(
            tombstoneRoot: recoveryRoot.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
        let coordinator = try AgentRecoveryCoordinator(
            store: store,
            dataService: service,
            reconcile: { _ in .empty },
            makeComposerController: { store, gate in
                AgentRecoveryComposerPersistenceController(store: store, gate: gate, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
            }
        )
        coordinator.startIfNeeded()
        guard await coordinator.awaitStartup() == .ready else { throw RecoveryLaneFixtureError.startupNotReady }
        let workspace = previous?.workspace ?? WorkspaceModel(name: "Baseline", repoPaths: [storageURL.path], customStoragePath: storageURL)
        let viewModel = if let claudeController {
            // Step 4d1 composition: only the injected fake Claude controller (never a real process),
            // with inert MCP policy/routing hooks, as the run-service lifecycle harness does.
            AgentModeViewModel(
                testWindowID: windowID,
                testWorkspacePath: storageURL.path,
                testWorkspaceDirectory: storageURL,
                codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
                codexControllerFactoryWithComputerUse: codexFactory,
                claudeControllerFactory: { _, _, _, _ in claudeController },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                mcpRunRoutingCleaner: { _, _, _ in }
            )
        } else {
            AgentModeViewModel(
                testWindowID: windowID,
                testWorkspacePath: storageURL.path,
                testWorkspaceDirectory: storageURL,
                codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
                codexControllerFactoryWithComputerUse: codexFactory
            )
        }
        viewModel.test_initializeRunService()
        viewModel.installRecoveryCoordinator(coordinator)
        viewModel.test_establishPersistenceWorkspace(workspace)
        if isQualified {
            viewModel.recoveryActionRunner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        }
        let homePath = home.path
        viewModel.test_recoveryClaudeHistoryHomes = { _ in [homePath] }
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = try await viewModel.ensureSessionReady(tabID: tabID)
        if let previous {
            // The new tab is bound to the saved session and hydrated by this composition's own load.
            let sessionID = try XCTUnwrap(previous.session.activeAgentSessionID)
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
            session.hasLoadedPersistedState = false
            let outcome = await viewModel.loadSessionFromDisk(for: session)
            XCTAssertEqual(outcome.disposition, .applied)
            XCTAssertEqual(session.providerSessionID, conversationID)
        } else {
            session.selectedAgent = .claudeCode
            session.providerSessionID = conversationID
            session.appendItem(.user("Earlier turn"))
            let saved = await viewModel.flushSave(for: tabID)
            XCTAssertTrue(saved)
        }
        let lane = try XCTUnwrap(session.recoveryLane)
        return ProducerHarness(
            viewModel: viewModel, session: session, lane: lane, service: service, workspace: workspace, home: home, recoveryRoot: recoveryRoot
        )
    }

    private func historyEntry(_ type: String, uuid: String, parent: String?, text: String) -> [String: Any] {
        [
            "type": type,
            "uuid": uuid,
            "parentUuid": parent ?? NSNull(),
            "sessionId": conversationID,
            "message": ["role": type, "content": type == "user" ? text as Any : [["type": "text", "text": text]] as Any],
            "isSidechain": false
        ]
    }

    func testBaselineProducerIsInertWhenHistoryReconciliationIsNotQualified() async throws {
        let harness = try await makeProducerHarness(windowID: 4970, qualified: false)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(admission, .notCaptured)
        let admitted = await harness.viewModel.admitClaudeDispatchBaseline(
            identity,
            outboundUserMessage: .init(uuid: identity.dispatchID, providerBoundText: "hi"),
            session: harness.session
        )
        XCTAssertEqual(admitted, .admittedWithoutIdentity, "production keeps the ordinary send, with no outbound identity")
        XCTAssertEqual(harness.viewModel.test_recoveryClaudeHistoryAccessCount, 0, "zero history lookups or reads")
        XCTAssertNil(harness.session.providerHistoryRecovery, "zero extra writes")
        XCTAssertNil(harness.session.pendingHistoryImportCommit)
        let cursor = await harness.cursor()
        XCTAssertNil(cursor)
    }

    func testBaselineCommitsAZeroRowReceiptBeforeAdmittingAndKeepsEachDispatchsBoundary() async throws {
        let harness = try await makeProducerHarness(windowID: 4971)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let firstSize = try UInt64(Data(contentsOf: harness.historyFile).count)
        let first = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let firstAdmission = await harness.viewModel.captureClaudeDispatchBaseline(first, session: harness.session)
        XCTAssertEqual(firstAdmission, .committed)
        let firstBaseline = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: first.dispatchID))
        XCTAssertEqual(firstBaseline.status, .captured)
        XCTAssertEqual(firstBaseline.completeLineOffset, firstSize)
        XCTAssertNotNil(firstBaseline.file)
        XCTAssertEqual(harness.session.committedHistoryImportID, firstBaseline.baselineCommitID, "the exact receipt committed before admission")
        XCTAssertNil(harness.session.pendingHistoryImportCommit)
        let persisted = try await harness.persisted()
        XCTAssertEqual(persisted?.providerHistoryRecovery?.dispatchBaselines, [firstBaseline], "a zero-row baseline is a real session commit")
        XCTAssertEqual(persisted?.providerHistoryRecovery?.lastImportCommit?.rowCount, 0)
        let seeded = await harness.cursor()
        XCTAssertEqual(seeded, firstBaseline.cursor, "the cursor is seeded only after the session commit")

        // The same dispatch re-entering admission reuses its boundary without reading again.
        let accessCount = harness.viewModel.test_recoveryClaudeHistoryAccessCount
        let repeated = await harness.viewModel.captureClaudeDispatchBaseline(first, session: harness.session)
        XCTAssertEqual(repeated, .alreadyRecorded)
        XCTAssertEqual(harness.viewModel.test_recoveryClaudeHistoryAccessCount, accessCount)

        // A later dispatch records its own boundary; the first one and the existing cursor stay.
        try harness.appendHistory([historyEntry("assistant", uuid: "a1", parent: "u1", text: "ok")])
        let second = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let secondAdmission = await harness.viewModel.captureClaudeDispatchBaseline(second, session: harness.session)
        XCTAssertEqual(secondAdmission, .committed)
        let baselines = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaselines)
        XCTAssertEqual(baselines.count, 2)
        XCTAssertEqual(baselines.first, firstBaseline, "an older attempt's boundary is never overwritten")
        XCTAssertGreaterThan(baselines[1].completeLineOffset, firstBaseline.completeLineOffset)
        let cursorAfter = await harness.cursor()
        XCTAssertEqual(cursorAfter, firstBaseline.cursor, "the cursor is not the attempt-boundary authority")
    }

    func testMissingIdentityOrLocationIsRecordedUnsupportedAndNeverBackfilled() async throws {
        let harness = try await makeProducerHarness(windowID: 4972)
        harness.session.providerSessionID = nil
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let missingID = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        guard case .unsupported = missingID else { return XCTFail("expected unsupported, got \(missingID)") }
        XCTAssertTrue(missingID.admitsWrite, "the ordinary send proceeds")
        XCTAssertEqual(harness.viewModel.test_recoveryClaudeHistoryAccessCount, 0)

        // The identity appearing later does not backfill this dispatch's boundary.
        harness.session.providerSessionID = conversationID
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let later = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(later, .alreadyRecorded)
        guard case .unsupported = harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)?.status else {
            return XCTFail("still unsupported")
        }

        harness.viewModel.test_recoveryClaudeHistoryHomes = { _ in [] }
        let noHome = await harness.viewModel.captureClaudeDispatchBaseline(
            AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()]),
            session: harness.session
        )
        guard case .unsupported = noHome else { return XCTFail("an unknown home is unsupported, never a guessed default") }
        let cursor = await harness.cursor()
        XCTAssertNil(cursor)
    }

    /// O42: no home recorded yet at the first read; one registry refresh later it is, and the
    /// baseline is captured from it.
    func testBaselineRetriesTheRecordedHomeOnceThenCaptures() async throws {
        let harness = try await makeProducerHarness(windowID: 4976)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let homePath = harness.home.path
        var lookups = 0
        var refreshes = 0
        // The home becomes recorded only through the refresh: removing it fails this test.
        harness.viewModel.test_recoveryRefreshHistoryRegistry = { refreshes += 1 }
        harness.viewModel.test_recoveryClaudeHistoryHomes = { _ in
            lookups += 1
            return refreshes > 0 ? [homePath] : []
        }
        harness.viewModel.test_recoveryClaudeHistoryLocatorHomes = {
            XCTFail("a home recorded after the refresh never reaches the fallback search")
            return []
        }
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(admission, .committed)
        XCTAssertEqual(refreshes, 1, "exactly one refresh")
        XCTAssertEqual(lookups, 2, "exactly one re-read after the refresh")
        XCTAssertEqual(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)?.status, .captured)
    }

    /// O42: with no recorded home, the fallback search's single hit is the history root.
    func testBaselineFallsBackToTheLocatorsSingleHome() async throws {
        let harness = try await makeProducerHarness(windowID: 4977)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let emptyHome = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineEmptyHome")
        addTeardownBlock { try? FileManager.default.removeItem(at: emptyHome) }
        let candidates = [emptyHome.path, harness.home.path]
        harness.viewModel.test_recoveryClaudeHistoryHomes = { _ in [] }
        harness.viewModel.test_recoveryClaudeHistoryLocatorHomes = { candidates }
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(admission, .committed)
        let baseline = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID))
        XCTAssertEqual(baseline.status, .captured)
        XCTAssertNotNil(baseline.file)
        XCTAssertEqual(baseline.completeLineOffset, try UInt64(Data(contentsOf: harness.historyFile).count))
    }

    /// O42: the same conversation file under two homes is refused (recorded unsupported), never guessed.
    func testBaselineRefusesAConversationFileFoundUnderTwoHomes() async throws {
        let harness = try await makeProducerHarness(windowID: 4978)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let copyHome = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineCopyHome")
        addTeardownBlock { try? FileManager.default.removeItem(at: copyHome) }
        let copy = copyHome.appendingPathComponent("projects/-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: harness.historyFile, to: copy.appendingPathComponent(harness.historyFile.lastPathComponent))
        let candidates = [harness.home.path, copyHome.path]
        harness.viewModel.test_recoveryClaudeHistoryHomes = { _ in [] }
        harness.viewModel.test_recoveryClaudeHistoryLocatorHomes = { candidates }
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(admission, .unsupported(AgentModeViewModel.recoveryClaudeHistoryAmbiguousReason))
        XCTAssertTrue(admission.admitsWrite, "the ordinary send proceeds")
        XCTAssertEqual(
            harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)?.status,
            .unsupported(AgentModeViewModel.recoveryClaudeHistoryAmbiguousReason)
        )
    }

    /// O42 review A P2: a fallback candidate that couldn't be inspected leaves a single hit unproven:
    /// recorded unsupported, the send still allowed.
    func testBaselineRecordsUnsupportedWhenAFallbackCandidateCantBeInspected() async throws {
        let harness = try await makeProducerHarness(windowID: 4985)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let lockedHome = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryBaselineLockedHome")
        let lockedProjects = lockedHome.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedProjects, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedProjects.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedProjects.path)
            try? FileManager.default.removeItem(at: lockedHome)
        }
        let candidates = [lockedHome.path, harness.home.path]
        harness.viewModel.test_recoveryClaudeHistoryHomes = { _ in [] }
        harness.viewModel.test_recoveryClaudeHistoryLocatorHomes = { candidates }
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(admission, .unsupported(AgentModeViewModel.recoveryClaudeHistoryUninspectableReason))
        XCTAssertTrue(admission.admitsWrite, "the ordinary send proceeds")
    }

    func testFailedInspectionIsNotAnAbsentFileBaseline() async throws {
        let harness = try await makeProducerHarness(windowID: 4973)
        try Data("not a directory".utf8).write(to: harness.home.appendingPathComponent("projects"))
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        guard case .unsupported = admission else { return XCTFail("expected unsupported, got \(admission)") }
        XCTAssertNil(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)?.cursor)
    }

    func testBaselinePersistenceFailureRefusesTheWrite() async throws {
        let harness = try await makeProducerHarness(windowID: 4974)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let files = try await harness.service.listAgentSessions(for: harness.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent == "AgentSession-\(sessionID.uuidString).json" })
        try FileManager.default.removeItem(at: fileURL)
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [UUID()])
        let admitted = await harness.viewModel.admitClaudeDispatchBaseline(identity, outboundUserMessage: nil, session: harness.session)
        XCTAssertEqual(admitted, .denied, "an enabled baseline that cannot be persisted sends zero bytes")
        let cursor = await harness.cursor()
        XCTAssertNil(cursor, "the cursor never moves ahead of the session commit")
    }

    // MARK: Step 4d1 outbound user-message claim (host admission)

    /// A complete identity whose constituents are canonical user items, admitted with a claim:
    /// the claim is committed with the baseline's exact receipt before the UUID is returned; the
    /// same dispatch re-admitted (a retry) gets no UUID and the baseline is unchanged.
    func testNewlyCapturedBaselineCommitsTheOutboundClaimBeforeReturningItsUUIDAndARetryOmitsIt() async throws {
        let harness = try await makeProducerHarness(windowID: 4980)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let first = AgentChatItem.user("Do it")
        let second = AgentChatItem.user("And this")
        harness.session.appendItem(first)
        harness.session.appendItem(second)
        let identity = AgentDispatchBaselineIdentity(
            dispatchID: UUID(),
            runAttemptID: UUID(),
            userItemIDs: [first.id, second.id],
            hasCompleteUserItems: true
        )
        let claim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(
            uuid: identity.dispatchID,
            providerBoundText: "Do it\n\nAnd this"
        )

        let admitted = await harness.viewModel.admitClaudeDispatchBaseline(identity, outboundUserMessage: claim, session: harness.session)

        XCTAssertEqual(admitted, .admitted(outboundUserMessageUUID: identity.dispatchID))
        let baseline = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID))
        XCTAssertEqual(baseline.outboundUserMessage, claim)
        XCTAssertEqual(baseline.userItemIDs, [first.id, second.id], "every ordered constituent is kept")
        XCTAssertEqual(harness.session.committedHistoryImportID, baseline.baselineCommitID, "the claim's exact receipt committed first")
        let persisted = try await harness.persisted()
        XCTAssertEqual(
            persisted?.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)?.outboundUserMessage,
            claim,
            "the claim is durable in the owner session before any byte"
        )

        let retried = await harness.viewModel.admitClaudeDispatchBaseline(identity, outboundUserMessage: claim, session: harness.session)
        XCTAssertEqual(retried, .admittedWithoutIdentity, "a retry never reuses the UUID")
        XCTAssertEqual(harness.session.providerHistoryRecovery?.dispatchBaselines.count, 1)
        XCTAssertEqual(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID), baseline)
    }

    /// All-or-nothing: an incomplete identity, a constituent missing from (or not a user item in)
    /// the canonical transcript, or a claim for another UUID captures the ordinary baseline with no
    /// claim and no UUID; an existing legacy baseline is never upgraded.
    func testIncompleteOrNonCanonicalConstituentsAndLegacyBaselinesNeverCarryAClaim() async throws {
        let harness = try await makeProducerHarness(windowID: 4981)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let present = AgentChatItem.user("present")
        let assistant = AgentChatItem.assistant("not a user item")
        harness.session.appendItem(present)
        harness.session.appendItem(assistant)
        let cases: [(String, AgentDispatchBaselineIdentity, UUID?)] = [
            ("incomplete", .init(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [present.id]), nil),
            ("missing constituent", .init(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [present.id, UUID()], hasCompleteUserItems: true), nil),
            ("non-user constituent", .init(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [present.id, assistant.id], hasCompleteUserItems: true), nil),
            ("duplicate constituent", .init(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [present.id, present.id], hasCompleteUserItems: true), nil),
            ("empty", .init(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [], hasCompleteUserItems: true), nil),
            ("foreign uuid", .init(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [present.id], hasCompleteUserItems: true), UUID())
        ]
        for (label, identity, foreignUUID) in cases {
            let claim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(
                uuid: foreignUUID ?? identity.dispatchID,
                providerBoundText: label
            )
            let admitted = await harness.viewModel.admitClaudeDispatchBaseline(identity, outboundUserMessage: claim, session: harness.session)
            XCTAssertEqual(admitted, .admittedWithoutIdentity, label)
            let baseline = harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID)
            XCTAssertEqual(baseline?.status, .captured, "\(label): the existing capture policy is unchanged")
            XCTAssertNil(baseline?.outboundUserMessage, label)
        }

        // Legacy: recorded without a claim, later admitted with one: unchanged, no UUID.
        let legacy = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [present.id], hasCompleteUserItems: true)
        let unclaimed = await harness.viewModel.captureClaudeDispatchBaseline(legacy, session: harness.session)
        XCTAssertEqual(unclaimed, .committed)
        let legacyBaseline = harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: legacy.dispatchID)
        let readmitted = await harness.viewModel.admitClaudeDispatchBaseline(
            legacy,
            outboundUserMessage: .init(uuid: legacy.dispatchID, providerBoundText: "present"),
            session: harness.session
        )
        XCTAssertEqual(readmitted, .admittedWithoutIdentity)
        XCTAssertEqual(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: legacy.dispatchID), legacyBaseline)
        XCTAssertNil(legacyBaseline?.outboundUserMessage, "a legacy baseline is never upgraded")
    }

    /// Two admissions of one dispatch, forced to overlap: A passes its first baseline lookup and is
    /// held in its history-home lookup while B records and commits the claimed boundary; released, A
    /// re-checks before appending and joins as already recorded. One boundary; only B has the UUID.
    func testConcurrentAdmissionsOfOneDispatchNeverBothMintTheClaim() async throws {
        let harness = try await makeProducerHarness(windowID: 4982)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let item = AgentChatItem.user("once")
        harness.session.appendItem(item)
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [item.id], hasCompleteUserItems: true)
        let claim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(uuid: identity.dispatchID, providerBoundText: "once")
        let viewModel = harness.viewModel
        let session = harness.session
        let gate = LifecycleAsyncGate()
        let lookups = LifecycleRecorder()
        let homePath = harness.home.path
        viewModel.test_recoveryClaudeHistoryHomes = { _ in
            lookups.record("homes")
            if lookups.events.count == 1 {
                await gate.arriveAndWait()
            }
            return [homePath]
        }

        let first = Task { await viewModel.admitClaudeDispatchBaseline(identity, outboundUserMessage: claim, session: session) }
        await gate.waitUntilArrived()
        XCTAssertNil(session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID), "A passed its first lookup")
        let second = await viewModel.admitClaudeDispatchBaseline(identity, outboundUserMessage: claim, session: session)
        XCTAssertEqual(second, .admitted(outboundUserMessageUUID: identity.dispatchID), "B newly committed the claim")
        await gate.release()
        let firstResult = await first.value

        XCTAssertEqual(firstResult, .admittedWithoutIdentity, "A re-checked after its awaits: already recorded, no UUID")
        XCTAssertEqual(lookups.events.count, 2, "both admissions reached the history lookup")
        let recorded = harness.session.providerHistoryRecovery?.dispatchBaselines.filter { $0.dispatchID == identity.dispatchID }
        XCTAssertEqual(recorded?.count, 1, "one boundary per dispatch")
        XCTAssertEqual(recorded?.first?.outboundUserMessage, claim)
    }

    /// Composition (review B P2-3): a real committed durable dispatch sent through the real Claude
    /// coordinator, the real host baseline producer (no DEBUG admission override; qualified runner,
    /// fixture history home, real owner-session persistence) and a managed-transport fake controller
    /// that encodes with the production codec. The frame carries the dispatch's own ID, and the
    /// durable baseline carries the claim over exactly the provider-bound text that was encoded.
    func testRealCoordinatorDispatchCommitsTheClaimThroughTheHostProducerAndEncodesItsUUID() async throws {
        let recorder = LifecycleRecorder()
        let controller = LifecycleFakeNativeController(
            recorder: recorder,
            sessionID: conversationID,
            invokesWriteAdmission: true,
            outboundIdentityEligible: true
        )
        let harness = try await makeProducerHarness(windowID: 4984, claudeController: controller)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let session = harness.session
        XCTAssertNil(harness.viewModel.test_claudeDispatchBaselineAdmission, "the real host producer decides")
        let userItem = AgentChatItem.user("Ship it")
        session.appendItem(userItem)
        let admitted = try await harness.lane.admitQueued(AgentRecoveryAdmission(
            binding: harness.lane.binding,
            userItemID: userItem.id,
            origin: .mcp,
            target: .session,
            original: RecoveryTestSupport.content("Ship it")
        )).get()
        let identity = AgentQueuedInputIdentity(receipt: admitted.receipt)
        session.claudeController = controller
        session.runState = .running
        session.runID = UUID()
        let ownership = session.beginRunAttempt(source: "test.p4d1.composition")
        let handoff = try await AgentProviderHandoff.begin(
            session: session,
            constituents: [identity],
            ownership: ownership,
            processRunID: session.runID
        ).get()
        let dispatchID = try XCTUnwrap(handoff.dispatchBaselineIdentity?.dispatchID)

        let sent = await harness.viewModel.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "Ship it",
            attachments: [],
            handoff: handoff
        )

        XCTAssertTrue(sent, "\(recorder.events)")
        let sentMessages = await controller.recordedSentMessages()
        let providerBoundText = try XCTUnwrap(sentMessages.first)
        XCTAssertEqual(sentMessages.count, 1)
        let frames = await controller.recordedUserFrames()
        XCTAssertEqual(frames.count, 1, "one admission, one write")
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(frames.first)) as? [String: Any])
        XCTAssertEqual(frame["uuid"] as? String, dispatchID.uuidString.lowercased())
        let expectedClaim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(
            uuid: dispatchID,
            providerBoundText: providerBoundText
        )
        let baseline = try XCTUnwrap(session.providerHistoryRecovery?.dispatchBaseline(dispatchID: dispatchID))
        XCTAssertEqual(baseline.status, .captured)
        XCTAssertEqual(baseline.userItemIDs, [userItem.id])
        XCTAssertEqual(baseline.outboundUserMessage, expectedClaim)
        let persisted = try await harness.persisted()
        XCTAssertEqual(
            persisted?.providerHistoryRecovery?.dispatchBaseline(dispatchID: dispatchID)?.outboundUserMessage,
            expectedClaim,
            "the claim was durable in the owner session"
        )
    }

    /// A claim whose receipt cannot be saved is refused (zero bytes); re-admitting that dispatch
    /// joins the existing pending receipt and never returns the UUID.
    func testClaimWhoseReceiptCannotBeSavedIsRefusedAndARetryNeverReturnsItsUUID() async throws {
        let harness = try await makeProducerHarness(windowID: 4983)
        try harness.appendHistory([historyEntry("user", uuid: "u1", parent: nil, text: "hi")])
        let item = AgentChatItem.user("unsaved")
        harness.session.appendItem(item)
        _ = await harness.viewModel.flushSave(for: harness.session.tabID)
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let files = try await harness.service.listAgentSessions(for: harness.workspace)
        let fileURL = try XCTUnwrap(files.first { $0.lastPathComponent == "AgentSession-\(sessionID.uuidString).json" })
        try FileManager.default.removeItem(at: fileURL)
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: UUID(), userItemIDs: [item.id], hasCompleteUserItems: true)
        let claim = AgentSessionProviderHistoryRecovery.DispatchBaseline.OutboundUserMessage(uuid: identity.dispatchID, providerBoundText: "unsaved")

        let refused = await harness.viewModel.admitClaudeDispatchBaseline(identity, outboundUserMessage: claim, session: harness.session)
        XCTAssertEqual(refused, .denied)

        let retried = await harness.viewModel.admitClaudeDispatchBaseline(identity, outboundUserMessage: claim, session: harness.session)
        XCTAssertNotEqual(retried, .admitted(outboundUserMessageUUID: identity.dispatchID), "a retry never carries the UUID")
        XCTAssertTrue(retried == .denied || retried == .admittedWithoutIdentity, "\(retried)")
        XCTAssertEqual(harness.session.providerHistoryRecovery?.dispatchBaselines.count { $0.dispatchID == identity.dispatchID }, 1)
    }

    func testReconcileRefusesWithoutAssociationsAndChangesNothing() async throws {
        let harness = try await makeProducerHarness(windowID: 4975)
        try harness.appendHistory([historyEntry("user", uuid: "u0", parent: nil, text: "Earlier turn")])
        let runAttemptID = UUID()
        let userItem = AgentChatItem.user("Do it")
        let identity = AgentDispatchBaselineIdentity(dispatchID: UUID(), runAttemptID: runAttemptID, userItemIDs: [userItem.id])
        let admission = await harness.viewModel.captureClaudeDispatchBaseline(identity, session: harness.session)
        XCTAssertEqual(admission, .committed)
        // The live run persisted its own user and assistant rows; Claude wrote its own entries.
        harness.session.appendItem(userItem)
        harness.session.appendItem(.assistant("Done."))
        _ = await harness.viewModel.flushSave(for: harness.session.tabID)
        try harness.appendHistory([
            historyEntry("user", uuid: "u1", parent: "u0", text: "Do it"),
            historyEntry("assistant", uuid: "a1", parent: "u1", text: "Done.")
        ])
        let itemsBefore = harness.session.items.map(\.id)
        let ledgerBefore = harness.session.providerHistoryRecovery
        let cursorBefore = await harness.cursor()

        func action(runAttemptID: UUID?) -> AgentRecoveryAction {
            AgentRecoveryAction(
                actionID: UUID(),
                itemKey: AgentRecoveryCardKey(kind: .run, incarnationID: harness.lane.binding.incarnationID, transcriptResetGeneration: 0, entityID: "run"),
                kindRaw: AgentRecoveryActionKind.reconcileOnly.rawValue,
                expectedRevision: nil,
                incarnationID: harness.lane.binding.incarnationID,
                transcriptResetGeneration: harness.lane.binding.transcriptResetGeneration,
                sourceIntentIDs: [],
                sourceRunAttemptID: runAttemptID,
                sourceInteractionID: nil,
                target: harness.viewModel.recoveryActionTarget(for: harness.session),
                text: nil,
                plannedUserItemID: nil,
                appInstanceID: UUID(),
                reservedAt: AgentRecoveryTimestamp(Date())
            )
        }
        let refused = await harness.viewModel.reconcileRecoveryHistory(
            action(runAttemptID: runAttemptID),
            session: harness.session,
            lane: harness.lane,
            codexTurnID: nil
        )
        XCTAssertEqual(
            refused,
            .associationUnavailable(.nativeUserAssociationUnavailable, AgentModeViewModel.recoveryAssociationText(.nativeUserAssociationUnavailable))
        )
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "zero transcript changes")
        XCTAssertEqual(harness.session.providerHistoryRecovery, ledgerBefore, "zero ledger changes")
        let cursorAfter = await harness.cursor()
        XCTAssertEqual(cursorAfter, cursorBefore, "no cursor advance")

        // Another attempt has no baseline of its own: refused before any history read.
        let accessCount = harness.viewModel.test_recoveryClaudeHistoryAccessCount
        let unavailable = await harness.viewModel.reconcileRecoveryHistory(
            action(runAttemptID: UUID()),
            session: harness.session,
            lane: harness.lane,
            codexTurnID: nil
        )
        XCTAssertEqual(unavailable, .associationUnavailable(.baselineUnavailable, AgentModeViewModel.recoveryAssociationText(.baselineUnavailable)))
        XCTAssertEqual(harness.viewModel.test_recoveryClaudeHistoryAccessCount, accessCount)
    }

    // MARK: Step 9-check through the real view-model Reconcile

    /// Check and resolve (checks active) sends the open session's run card through the window's
    /// real Reconcile (lane lookup, shared working state, `performRecoveryResumeAction`, runner,
    /// Claude history preflight) and reports from the runner's typed result. The attempt has no
    /// pre-send baseline, so the observation is "association unavailable": needs you, never failed
    /// and never resolved, and nothing is imported.
    func testCheckReportsTheRealReconcileTypedResult() async throws {
        let harness = try await makeProducerHarness(windowID: 4979)
        let viewModel = harness.viewModel
        let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let ownership = RecoveryTestSupport.ownership(sessionID: sessionID)
        let turnID = UUID()
        _ = try await harness.lane.ensureRunAttempt(
            ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: harness.session.selectedAgent.rawValue
        ).get()
        await harness.lane.recordTerminalEvidence(
            RecoveryTestSupport.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(sessionID.uuidString)-\(turnID.uuidString)"
        let listed = await RecoveryTestSupport.eventually { coordinator.catalog.item(id: itemID)?.attention == .informational }
        XCTAssertTrue(listed)
        XCTAssertTrue(viewModel.recoveryChecksActive)
        let itemsBefore = harness.session.items.map(\.id)
        let rows = viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: harness.session)
        XCTAssertTrue(AgentModeViewModel.recoveryCheckItems(rows).contains { $0.id == itemID })

        let task = try XCTUnwrap(viewModel.startRecoveryCheck(rows: rows))
        let result = await task.value
        let status = try XCTUnwrap(result)
        let entry = try XCTUnwrap(status.entries.first { $0.itemID == itemID })
        XCTAssertEqual(
            entry.outcome,
            .needsYou("Continue it or dismiss the note. \(AgentModeViewModel.recoveryAssociationText(.baselineUnavailable))")
        )
        XCTAssertTrue(status.headerText.contains(AgentRecoveryCheckStatus.restrictionWarningText))
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "nothing imported or sent")
        XCTAssertNotEqual(coordinator.catalogActionStates[itemID], .working, "the row is no longer busy")
    }

    /// Round-0 review P1-1: a choice whose target names another provider than the session's
    /// current one (here a cached request built before the session switched from Codex to Claude
    /// Code) is refused through the real `performRecoveryResumeAction` before the runner: nothing
    /// is reserved, written or sent, and the stale request is dropped.
    func testProviderMismatchedTargetIsRefusedBeforeTheRunner() async throws {
        let harness = try await makeProducerHarness(windowID: 4981)
        let viewModel = harness.viewModel
        let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        XCTAssertEqual(harness.session.selectedAgent, .claudeCode)
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let ownership = RecoveryTestSupport.ownership(sessionID: sessionID)
        let turnID = UUID()
        _ = try await harness.lane.ensureRunAttempt(
            ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: harness.session.selectedAgent.rawValue
        ).get()
        await harness.lane.recordTerminalEvidence(
            RecoveryTestSupport.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(sessionID.uuidString)-\(turnID.uuidString)"
        let listed = await RecoveryTestSupport.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed)
        let key = try XCTUnwrap(coordinator.catalog.item(id: itemID)?.acknowledgement?.key)
        guard case let .success(.supported(before)) = await harness.lane.readRecord() else {
            return XCTFail("expected a supported record")
        }
        let stale = AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: key,
            kind: .continueWithText,
            expectedRevision: before.revision,
            sourceRunAttemptID: ownership.attemptID,
            target: AgentRecoveryActionTarget(providerKindRaw: AgentProviderKind.codexExec.rawValue, providerConversationID: "thread-old"),
            text: AgentModeViewModel.recoveryContinueDefaultText,
            plannedUserItemID: UUID()
        )
        let slot = AgentModeViewModel.RecoveryActionSlot(item: key, kindRaw: AgentRecoveryActionKind.continueWithText.rawValue)
        viewModel.recoveryActionRequestsBySlot[slot] = stale
        let itemsBefore = harness.session.items.map(\.id)

        let failure = await viewModel.performRecoveryResumeAction(rowID: itemID, action: .continueTurn)
        XCTAssertEqual(
            failure,
            "This card is from a \(AgentProviderKind.codexExec.displayName) run, but the session now uses \(AgentProviderKind.claudeCode.displayName). Switch back to act on it. Nothing was changed."
        )
        XCTAssertNil(viewModel.recoveryActionRequestsBySlot[slot], "the stale request is dropped")
        guard case let .success(.supported(after)) = await harness.lane.readRecord() else {
            return XCTFail("expected a supported record")
        }
        XCTAssertEqual(after.revision, before.revision, "nothing is written")
        XCTAssertTrue(after.actions.isEmpty, "nothing is reserved")
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "nothing is sent")
        XCTAssertFalse(coordinator.isCoveredByRecoveryAction(sessionID: sessionID))
        XCTAssertNil(
            AgentModeViewModel.recoveryProviderMismatchText(
                target: viewModel.recoveryActionTarget(for: harness.session), current: harness.session.selectedAgent
            ),
            "a target built now names the current provider"
        )
    }

    /// A run card in the open session, whose run attempt recorded `providerKindRaw` at run start
    /// (`nil`: a run recorded before the provider was captured). Returns the card's row ID.
    private func makeRunCard(_ harness: ProducerHarness, providerKindRaw: String?) async throws -> String {
        let coordinator = try XCTUnwrap(harness.viewModel.recoveryCoordinator)
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let ownership = RecoveryTestSupport.ownership(sessionID: sessionID)
        let turnID = UUID()
        _ = try await harness.lane.ensureRunAttempt(
            ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: providerKindRaw
        ).get()
        await harness.lane.recordTerminalEvidence(
            RecoveryTestSupport.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(sessionID.uuidString)-\(turnID.uuidString)"
        let listed = await RecoveryTestSupport.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed)
        return itemID
    }

    /// Asserts Continue and Reconcile on `itemID` are both refused with `expected` through the real
    /// `performRecoveryResumeAction`, before the runner: nothing reserved, written or sent.
    private func assertRunActionsRefused(
        _ harness: ProducerHarness,
        itemID: String,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        guard case let .success(.supported(before)) = await harness.lane.readRecord() else {
            return XCTFail("expected a supported record", file: file, line: line)
        }
        let itemsBefore = harness.session.items.map(\.id)
        for action in [AgentRecoveryListRowProps.Action.continueTurn, .reconcileHistory] {
            let report = RecoveryResumeActionReport()
            let failure = await harness.viewModel.performRecoveryResumeAction(rowID: itemID, action: action, report: report)
            XCTAssertEqual(failure, expected, "\(action)", file: file, line: line)
            XCTAssertNil(report.result, "\(action) never reaches the runner", file: file, line: line)
        }
        guard case let .success(.supported(after)) = await harness.lane.readRecord() else {
            return XCTFail("expected a supported record", file: file, line: line)
        }
        XCTAssertEqual(after.revision, before.revision, "nothing is written", file: file, line: line)
        XCTAssertTrue(after.actions.isEmpty, "nothing is reserved", file: file, line: line)
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "nothing is sent", file: file, line: line)
        XCTAssertTrue(harness.viewModel.recoveryActionRequestsBySlot.isEmpty, "no request is cached", file: file, line: line)
    }

    /// P1-1: a run card whose run was started by Codex is refused once the session uses Claude Code,
    /// naming the recorded provider, for both Continue and Reconcile.
    func testRunCardFromASwitchedProviderIsRefusedNamingTheRecordedProvider() async throws {
        let harness = try await makeProducerHarness(windowID: 5091)
        XCTAssertEqual(harness.session.selectedAgent, .claudeCode)
        let itemID = try await makeRunCard(harness, providerKindRaw: AgentProviderKind.codexExec.rawValue)
        try await assertRunActionsRefused(
            harness,
            itemID: itemID,
            expected: "This card is from a \(AgentProviderKind.codexExec.displayName) run, but the session now uses \(AgentProviderKind.claudeCode.displayName). Switch back to act on it. Nothing was changed."
        )
    }

    /// P1-1: a run recorded before the provider was captured is refused rather than guessed.
    func testRunCardWithoutARecordedProviderIsRefused() async throws {
        let harness = try await makeProducerHarness(windowID: 5092)
        let itemID = try await makeRunCard(harness, providerKindRaw: nil)
        try await assertRunActionsRefused(
            harness,
            itemID: itemID,
            expected: "This card's provider wasn't recorded, so RepoPrompt can't act on it safely. Nothing was changed."
        )
    }

    /// 9-live R4b/R5: the Continue editor's text is kept per row in the window, outside the row
    /// view: the row reopens with it, and a refused continuation keeps it (here through the real
    /// `performRecoveryListContinuation`, refused before the runner).
    func testRefusedContinuationKeepsTheEditorDraftForTheRow() async throws {
        let harness = try await makeProducerHarness(windowID: 5094)
        let viewModel = harness.viewModel
        let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        let itemID = try await makeRunCard(harness, providerKindRaw: nil)
        let item = try XCTUnwrap(coordinator.catalog.item(id: itemID))
        func row() -> AgentRecoveryListRowProps {
            viewModel.recoveryListRow(for: item, coordinator: coordinator, activeSession: harness.session)
        }
        XCTAssertTrue(row().actions.contains(.continueTurn), "\(row().actions)")
        XCTAssertEqual(row().continuationText, AgentModeViewModel.recoveryContinueDefaultText, "no draft, no unsent text")
        XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: itemID))

        let typed = "RPCE continue: reply OK"
        viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: typed)
        XCTAssertEqual(viewModel.recoveryContinuationDraft(rowID: itemID), typed)
        XCTAssertEqual(row().continuationText, typed, "the row reopens with the draft")

        await viewModel.performRecoveryListContinuation(rowID: itemID, action: .continueTurn, text: typed, acknowledgedWarning: nil)
        XCTAssertEqual(coordinator.catalogActionStates[itemID], .failed(AgentModeViewModel.recoveryRunProviderNotRecordedText))
        XCTAssertEqual(viewModel.recoveryContinuationDraft(rowID: itemID), typed, "a refusal keeps the draft")
        XCTAssertEqual(row().continuationText, typed)
        XCTAssertEqual(row().error, AgentModeViewModel.recoveryRunProviderNotRecordedText, "no unsent text recorded, so no note")
        // Review B L2: the draft is app-wide (the coordinator's), so another window reopens with it.
        XCTAssertEqual(coordinator.continuationDraftsByRowID[itemID], typed)
        let otherWindow = AgentModeViewModel(
            testWindowID: 5194,
            testWorkspacePath: harness.workspace.customStoragePath?.path,
            testWorkspaceDirectory: harness.workspace.customStoragePath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) }
        )
        otherWindow.installRecoveryCoordinator(coordinator)
        XCTAssertEqual(otherWindow.recoveryContinuationDraft(rowID: itemID), typed)
    }

    /// O46: a saved message settled by a crash-hold confirmation keeps its title, says its run
    /// exited and it won't be sent again, is informational, and offers View (its kept text), Edit,
    /// Remove and Dismiss. Send saved is never offered for possibly delivered input.
    func testSettledMessageRowIsInformationalAndNeverOffersSendSaved() async throws {
        let harness = try await makeProducerHarness(windowID: 5095)
        let viewModel = harness.viewModel
        let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        let sessionID = harness.lane.sessionID
        let intent = AgentRecoveryIntent(
            intentID: UUID(), userItemID: UUID(), origin: .composer, target: .session,
            createdAt: AgentRecoveryTimestamp(millisecondsSince1970: 1), appInstanceID: UUID(),
            transcriptResetGeneration: harness.lane.binding.transcriptResetGeneration, deliveryState: .deliveryUnknown,
            payload: RecoveryTestSupport.content("possibly delivered"), scheduleReference: nil
        )
        func item(settled: Bool) -> AgentRecoveryCatalogItem {
            AgentRecoveryCatalogItem(
                id: "intent-\(sessionID.uuidString)-\(intent.intentID.uuidString)",
                kind: .savedInput,
                sessionID: sessionID,
                workspaceID: nil,
                sessionName: nil,
                composeTabID: harness.session.tabID,
                payload: .intent(intent, AgentRecoveryCatalogIntentContext(
                    isEarlierLaunch: true, heldReason: nil, sameGeneration: true, isRemote: false
                )),
                acknowledgement: AgentRecoveryCatalogAcknowledgement(
                    key: AgentRecoveryCardKey(
                        kind: .savedInput, incarnationID: harness.lane.binding.incarnationID,
                        transcriptResetGeneration: intent.transcriptResetGeneration, entityID: intent.intentID.uuidString
                    ),
                    freshness: AgentRecoveryCatalogProjection.intentFreshness(intent, held: false),
                    isAcknowledged: false
                ),
                actionFacts: AgentRecoveryCatalogActionFacts(settledByExitProof: settled)
            )
        }
        let settled = item(settled: true)
        let settledRow = viewModel.recoveryListRow(for: settled, coordinator: coordinator, activeSession: harness.session)
        XCTAssertEqual(settled.attention, .informational)
        XCTAssertFalse(settled.isOpenNeedsAction, "not counted as needing the user")
        XCTAssertEqual(settledRow.title, "Message may have been delivered")
        XCTAssertEqual(settledRow.detail, AgentModeViewModel.recoveryListSettledByExitProofDetail)
        XCTAssertEqual(settledRow.text, "possibly delivered", "View shows the kept text")
        XCTAssertEqual(settledRow.actions, [.edit, .remove, .dismiss])

        let unsettled = item(settled: false)
        XCTAssertEqual(unsettled.attention, .needsAction)
        XCTAssertEqual(
            viewModel.recoveryListRow(for: unsettled, coordinator: coordinator, activeSession: harness.session).actions,
            [.remove, .dismiss]
        )
        for state in AgentRecoveryDeliveryState.allCases {
            for settledByExitProof in [false, true] {
                for sameGeneration in [false, true] {
                    XCTAssertFalse(
                        AgentModeViewModel.recoveryListIntentActions(
                            state, sameGeneration: sameGeneration, settledByExitProof: settledByExitProof
                        ).contains(.sendSaved),
                        "\(state)"
                    )
                }
            }
        }
        XCTAssertFalse(viewModel.recoveryIntentActions(intent, facts: settled.actionFacts).contains(.sendSaved))
    }

    /// Review A LIST-02, B L3: through the real `performRecoveryListContinuation` (runner result
    /// controlled), a recorded outcome whose record holds the text clears the sent draft, and an
    /// edit made during the await is newer and survives. Nothing goes to the message box.
    func testRecordedContinuationClearsOnlyTheSentDraft() async throws {
        let harness = try await makeProducerHarness(windowID: 5095)
        let viewModel = harness.viewModel
        let itemID = try await makeRunCard(harness, providerKindRaw: harness.session.selectedAgent.rawValue)
        let typed = "RPCE continue: reply OK"
        let results: [AgentRecoveryActionResult] = [
            .completed(.dispatched, reason: nil),
            .outcomeUnrecorded(.dispatched, reason: nil),
            .completed(.notDispatched, reason: "No history position was saved.")
        ]
        for result in results {
            viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: typed)
            viewModel.test_recoveryActionResult = { request in
                XCTAssertEqual(request.text, typed, "the exact edited text is the request's")
                return result
            }
            await viewModel.performRecoveryListContinuation(rowID: itemID, action: .continueTurn, text: typed, acknowledgedWarning: nil)
            XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: itemID), "\(result): the sent draft is cleared")

            viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: typed)
            viewModel.test_recoveryActionResult = { _ in
                viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: "newer edit")
                return result
            }
            await viewModel.performRecoveryListContinuation(rowID: itemID, action: .continueTurn, text: typed, acknowledgedWarning: nil)
            XCTAssertEqual(viewModel.recoveryContinuationDraft(rowID: itemID), "newer edit", "\(result): a newer edit survives")
            viewModel.recoveryCoordinator?.continuationDraftsByRowID[itemID] = nil
        }
        XCTAssertEqual(harness.session.draftText, "", "a text the record holds never goes to the message box")
    }

    /// Review B L1: a continuation that finds the turn already finished resolves the card without
    /// sending, so its typed text moves to the session's message box (alone when it is empty, after
    /// a blank line otherwise) and the row says so. The default text is not moved. An unsent choice
    /// whose outcome couldn't be recorded moves its text the same way.
    func testContinuationThatFindsTheTurnFinishedMovesTheTypedTextToTheMessageBox() async throws {
        let harness = try await makeProducerHarness(windowID: 5096)
        let viewModel = harness.viewModel
        let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        let itemID = try await makeRunCard(harness, providerKindRaw: harness.session.selectedAgent.rawValue)
        let tabID = harness.session.tabID
        XCTAssertEqual(viewModel.currentTabID, tabID)
        XCTAssertEqual(harness.session.draftText, "")
        let finished = AgentRecoveryActionResult.completed(.importedCompleted, reason: AgentRecoveryActionRunner.verifiedCompletionText)
        viewModel.test_recoveryActionResult = { _ in finished }

        let typed = "RPCE continue: reply OK"
        viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: typed)
        await viewModel.performRecoveryListContinuation(rowID: itemID, action: .continueTurn, text: typed, acknowledgedWarning: nil)
        XCTAssertEqual(harness.session.draftText, typed, "an empty message box gets the text alone")
        XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: itemID))
        XCTAssertEqual(coordinator.catalogActionStates[itemID], .failed(AgentModeViewModel.recoveryContinuationFinishedMovedText))
        XCTAssertEqual(viewModel.draftRestorationEvent?.tabID, tabID)
        XCTAssertEqual(viewModel.draftRestorationEvent?.text, typed)
        XCTAssertEqual(viewModel.draftRestorationEvent?.strategy, .appendAfterBlankLine(result: typed))

        viewModel.storeDraftText(for: tabID, "my own text")
        await viewModel.performRecoveryListContinuation(rowID: itemID, action: .continueTurn, text: "second", acknowledgedWarning: nil)
        XCTAssertEqual(harness.session.draftText, "my own text\n\nsecond", "current text is kept; the message follows a blank line")

        await viewModel.performRecoveryListContinuation(
            rowID: itemID, action: .continueTurn, text: AgentModeViewModel.recoveryContinueDefaultText, acknowledgedWarning: nil
        )
        XCTAssertEqual(harness.session.draftText, "my own text\n\nsecond", "the default text is not moved")
        XCTAssertEqual(coordinator.catalogActionStates[itemID], .failed(AgentRecoveryActionRunner.verifiedCompletionText))

        viewModel.test_recoveryActionResult = { _ in .outcomeUnrecorded(.notDispatched, reason: nil) }
        await viewModel.performRecoveryListContinuation(rowID: itemID, action: .continueTurn, text: "third", acknowledgedWarning: nil)
        XCTAssertEqual(harness.session.draftText, "my own text\n\nsecond\n\nthird")
        XCTAssertEqual(coordinator.catalogActionStates[itemID], .failed(AgentModeViewModel.recoveryContinuationUnrecordedMovedText))
    }

    /// Records `request` with `outcome` in the lane, as the runner would, so the card really
    /// resolves (`resolvedByAction`) and stops offering Continue.
    private func recordAction(
        _ request: AgentRecoveryActionRequest,
        outcome: AgentRecoveryActionOutcomeKind,
        lane: AgentRecoverySessionLane
    ) async {
        guard case .success = await lane.reserveRecoveryAction(request) else { return XCTFail("reservation failed") }
        guard case .success = await lane.completeRecoveryAction(actionID: request.actionID, outcome: outcome, reason: nil) else {
            return XCTFail("outcome write failed")
        }
    }

    /// Review B N1: a Continue draft typed and left in a closed editor moves to the message box
    /// when Reconcile proves the turn finished (the card resolves and no longer offers Continue).
    func testReconcileThatResolvesTheCardMovesTheLeftoverContinueDraftToTheMessageBox() async throws {
        let harness = try await makeProducerHarness(windowID: 5097)
        let viewModel = harness.viewModel
        let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        let itemID = try await makeRunCard(harness, providerKindRaw: harness.session.selectedAgent.rawValue)
        let typed = "RPCE continue: typed, editor closed"
        viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: typed)
        let lane = harness.lane
        viewModel.test_recoveryActionResult = { [self] request in
            XCTAssertEqual(request.kind, .reconcileOnly)
            await recordAction(request, outcome: .importedCompleted, lane: lane)
            return .completed(.importedCompleted, reason: AgentRecoveryActionRunner.verifiedCompletionText)
        }

        await viewModel.performRecoveryListAction(rowID: itemID, action: .reconcileHistory)
        XCTAssertEqual(coordinator.catalog.item(id: itemID)?.actionFacts.resolvedByAction, true, "the card resolved")
        XCTAssertEqual(harness.session.draftText, typed, "the typed text is in the message box")
        XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: itemID))
        XCTAssertEqual(coordinator.catalogActionStates[itemID], .failed(AgentModeViewModel.recoveryContinuationLeftoverMovedText))
    }

    /// Review A R1-01: a newer edit made during a dispatched Continue lands in the message box once
    /// the card resolves; the sent text (already dispatched) never does.
    func testNewerEditDuringADispatchedContinueMovesToTheMessageBoxNotTheSentText() async throws {
        let harness = try await makeProducerHarness(windowID: 5098)
        let viewModel = harness.viewModel
        let itemID = try await makeRunCard(harness, providerKindRaw: harness.session.selectedAgent.rawValue)
        let sent = "RPCE continue: the sent text"
        let newer = "RPCE continue: a newer edit"
        viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: sent)
        let lane = harness.lane
        viewModel.test_recoveryActionResult = { [self] request in
            await recordAction(request, outcome: .dispatched, lane: lane)
            viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: newer)
            return .completed(.dispatched, reason: nil)
        }

        await viewModel.performRecoveryListContinuation(rowID: itemID, action: .continueTurn, text: sent, acknowledgedWarning: nil)
        XCTAssertEqual(harness.session.draftText, newer, "only the newer edit moves")
        XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: itemID))
        XCTAssertEqual(
            viewModel.recoveryCoordinator?.catalogActionStates[itemID],
            .failed(AgentModeViewModel.recoveryContinuationLeftoverMovedText)
        )
    }

    /// Review A R1-01: when a Continue finds the turn finished, neither the submitted text nor a
    /// newer edit made during the await was sent: both move, the submitted text first.
    func testNewerEditDuringAFinishedContinueMovesTheSubmittedTextThenTheNewerEdit() async throws {
        let harness = try await makeProducerHarness(windowID: 5099)
        let viewModel = harness.viewModel
        let itemID = try await makeRunCard(harness, providerKindRaw: harness.session.selectedAgent.rawValue)
        let lane = harness.lane
        viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: "older")
        viewModel.test_recoveryActionResult = { [self] request in
            await recordAction(request, outcome: .importedCompleted, lane: lane)
            viewModel.updateRecoveryContinuationDraft(rowID: itemID, text: "newest")
            return .completed(.importedCompleted, reason: AgentRecoveryActionRunner.verifiedCompletionText)
        }
        await viewModel.performRecoveryListContinuation(rowID: itemID, action: .continueTurn, text: "older", acknowledgedWarning: nil)
        XCTAssertEqual(harness.session.draftText, "older\n\nnewest")
        XCTAssertEqual(viewModel.draftRestorationEvent?.strategy, .appendAfterBlankLine(result: "older\n\nnewest"), "one placement")
        XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: itemID))
        XCTAssertEqual(
            viewModel.recoveryCoordinator?.catalogActionStates[itemID],
            .failed(AgentModeViewModel.recoveryContinuationFinishedMovedText)
        )
    }

    /// Review A R2-02 / B P1-A: an action on another row of the same session leaves alone the draft
    /// of a Continue still in flight, even though its dispatched outcome already resolved its card;
    /// the row stays working, and its own completion disposes of the (sent) draft.
    func testActionOnAnotherRowLeavesAnInFlightContinueDraftAlone() async throws {
        let harness = try await makeProducerHarness(windowID: 5100)
        let viewModel = harness.viewModel
        let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        let provider = harness.session.selectedAgent.rawValue
        let rowA = try await makeRunCard(harness, providerKindRaw: provider)
        let rowB = try await makeRunCard(harness, providerKindRaw: provider)
        let sent = "RPCE continue: sent from row B"
        viewModel.updateRecoveryContinuationDraft(rowID: rowB, text: sent)
        let lane = harness.lane
        let latch = RecoveryGateLatch()
        viewModel.test_recoveryActionResult = { [self] request in
            await recordAction(request, outcome: .dispatched, lane: lane)
            await latch.pause()
            return .completed(.dispatched, reason: nil)
        }
        let continuation = Task {
            await viewModel.performRecoveryListContinuation(rowID: rowB, action: .continueTurn, text: sent, acknowledgedWarning: nil)
        }
        await latch.waitUntilPaused()
        let resolved = await RecoveryTestSupport.eventually { coordinator.catalog.item(id: rowB)?.actionFacts.resolvedByAction == true }
        XCTAssertTrue(resolved, "row B's dispatched outcome is written")

        // Any list action on row A runs the helper for the session (Copy on a run card does nothing else).
        await viewModel.performRecoveryListAction(rowID: rowA, action: .copyProposal)
        XCTAssertEqual(viewModel.recoveryContinuationDraft(rowID: rowB), sent, "row B's draft is not moved")
        XCTAssertEqual(coordinator.catalogActionStates[rowB], .working, "row B is still working")
        XCTAssertEqual(harness.session.draftText, "")

        await latch.open()
        await continuation.value
        XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: rowB), "row B's completion clears its sent draft")
        XCTAssertEqual(harness.session.draftText, "", "the sent text never reaches the message box")
    }

    /// Review A R2-01 / B P1-B: two drafts moved in one pass (two placements in one main-actor
    /// turn) both stay in the stored draft, and the last event alone shows both, so an input bar
    /// that sees only the coalesced last event loses nothing.
    func testTwoPlacementsInOneTurnKeepBothTexts() async throws {
        let harness = try await makeProducerHarness(windowID: 5101)
        let viewModel = harness.viewModel
        let provider = harness.session.selectedAgent.rawValue
        let rowA = try await makeRunCard(harness, providerKindRaw: provider)
        let rowB = try await makeRunCard(harness, providerKindRaw: provider)
        viewModel.updateRecoveryContinuationDraft(rowID: rowA, text: "text A")
        viewModel.updateRecoveryContinuationDraft(rowID: rowB, text: "text B")
        let lane = harness.lane
        viewModel.test_recoveryActionResult = { [self] request in
            await recordAction(request, outcome: .importedCompleted, lane: lane)
            return .completed(.importedCompleted, reason: AgentRecoveryActionRunner.verifiedCompletionText)
        }
        // Row B resolves without the list's draft handling, so both drafts are left for one pass.
        _ = await viewModel.performRecoveryResumeAction(rowID: rowB, action: .reconcileHistory)
        await viewModel.performRecoveryListAction(rowID: rowA, action: .reconcileHistory)

        let expected = [rowA, rowB].sorted().map { $0 == rowA ? "text A" : "text B" }.joined(separator: "\n\n")
        XCTAssertEqual(harness.session.draftText, expected, "both texts are stored")
        XCTAssertEqual(viewModel.draftRestorationEvent?.strategy, .appendAfterBlankLine(result: expected), "the last event shows both")
        XCTAssertEqual(AgentModeViewModel.recoveryComposerAppendUpdate(live: "", result: expected), expected)
        XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: rowA))
        XCTAssertNil(viewModel.recoveryContinuationDraft(rowID: rowB))
    }

    /// Round-1 B F1: the guard fails closed. A card without a run attempt (a legacy interrupted turn's
    /// `runAttemptID` is nil) or whose attempt is not in the record is refused as not recorded; only
    /// the found attempt's recorded provider decides.
    func testRunProviderGuardFailsClosedWithoutAKnownRunAttempt() {
        let notRecorded = AgentModeViewModel.recoveryRunProviderNotRecordedText
        let stamp = AgentRecoveryTimestamp(millisecondsSince1970: 1000)
        let recordedID = UUID()
        let recorded = AgentRecoveryRunAttempt(
            runAttemptID: recordedID, transcriptResetGeneration: 0, processRunID: nil, transcriptTurnID: nil, startedAt: stamp,
            extras: [AgentRecoveryRunAttempt.providerKindExtrasKey: .string(AgentProviderKind.claudeCode.rawValue)]
        )
        func refusal(_ id: UUID?) -> String? {
            AgentModeViewModel.recoveryRunProviderRefusal(sourceRunAttemptID: id, runAttempts: [recorded], current: .claudeCode)
        }
        XCTAssertEqual(refusal(nil), notRecorded, "no run attempt (legacy interrupted turn)")
        XCTAssertEqual(refusal(UUID()), notRecorded, "an attempt not in the record")
        XCTAssertNil(refusal(recordedID), "the found attempt's matching recorded provider proceeds")
    }

    /// P1-1: a run card recorded by the session's current provider proceeds to the runner.
    func testRunCardFromTheCurrentProviderProceedsToTheRunner() async throws {
        let harness = try await makeProducerHarness(windowID: 5093)
        let itemID = try await makeRunCard(harness, providerKindRaw: harness.session.selectedAgent.rawValue)
        let report = RecoveryResumeActionReport()
        let failure = await harness.viewModel.performRecoveryResumeAction(rowID: itemID, action: .reconcileHistory, report: report)
        XCTAssertNotNil(report.result, "the choice reached the runner (got \(String(describing: failure)))")
        XCTAssertNotEqual(failure, AgentModeViewModel.recoveryRunProviderNotRecordedText)
        XCTAssertFalse(failure?.hasPrefix("This card is from a") == true, "\(String(describing: failure))")
    }

    // MARK: Step 4d2 capture-qualified import (view model, real persistence and reader)

    private static let historySentinel = "SENTINEL-PRIVATE-CONTEXT-4d2"

    /// A sanitized, hand-written O19-shaped native turn (no raw capture contents): queue records,
    /// the caller's user entry, eight whitelisted attachments with `atis-latch` between them, the
    /// request records, the one-text reply, a trailing attachment, `last-prompt` and `cost-state`.
    /// Every nonrendering payload is a private sentinel.
    private func o19History(caller: String, parent: String?, assistant: String, prompt: String, reply: String, tag: String) -> [[String: Any]] {
        func attachment(_ uuid: String, parent: String, type: String) -> [String: Any] {
            [
                "type": "attachment",
                "uuid": uuid,
                "parentUuid": parent,
                "sessionId": conversationID,
                "isSidechain": false,
                "attachment": ["type": type, "content": Self.historySentinel]
            ]
        }
        func record(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var object: [String: Any] = ["type": type, "sessionId": conversationID, "content": Self.historySentinel]
            for (key, value) in extra {
                object[key] = value
            }
            return object
        }
        var entries = [
            record("queue-operation", ["operation": "enqueue"]),
            record("queue-operation", ["operation": "dequeue"]),
            historyEntry("user", uuid: caller, parent: parent, text: prompt)
        ]
        var previous = caller
        let types = ["environment", "model", "total_tokens_reminder", "budget_usd", "session_context", "date", "credential_org", "prompt_snapshot"]
        for (index, type) in types.enumerated() {
            if index == 4 { entries.append(record("atis-latch")) }
            let id = "\(tag)-n\(index + 1)"
            entries.append(attachment(id, parent: previous, type: type))
            previous = id
        }
        entries += [
            record("api-request-shape"),
            record("api-request-blob"),
            record("api-request-blob"),
            record("api-request"),
            historyEntry("assistant", uuid: assistant, parent: previous, text: reply),
            attachment("\(tag)-t", parent: assistant, type: "prompt_snapshot"),
            record("last-prompt", ["leafUuid": "\(tag)-t"]),
            record("cost-state")
        ]
        return entries
    }

    /// Admits one claimed dispatch through the real host producer (a newly captured baseline).
    private func admitClaimedDispatch(
        _ harness: ProducerHarness,
        runAttemptID: UUID,
        text: String
    ) async throws -> (AgentChatItem, AgentDispatchBaselineIdentity) {
        let userItem = AgentChatItem.user(text)
        harness.session.appendItem(userItem)
        let identity = AgentDispatchBaselineIdentity(
            dispatchID: UUID(),
            runAttemptID: runAttemptID,
            userItemIDs: [userItem.id],
            hasCompleteUserItems: true
        )
        let admitted = await harness.viewModel.admitClaudeDispatchBaseline(
            identity,
            outboundUserMessage: .init(uuid: identity.dispatchID, providerBoundText: text),
            session: harness.session
        )
        XCTAssertEqual(admitted, .admitted(outboundUserMessageUUID: identity.dispatchID))
        return (userItem, identity)
    }

    /// Real import composition (test-only qualified runner, real session persistence, recovery store,
    /// reader and planner; no process): a claimed baseline with no live output imports the reply once,
    /// committing rows + ledger + receipt in the session save before the cursor; a repeat, and a replay
    /// after a lost cursor commit, are no-ops; a changed payload, a ledger keyset beyond the entry, or
    /// a ledger without envelope proofs refuses with no state change.
    func testClaimedBaselineImportsTheCaptureQualifiedReplyOnceAndRefusesUnprovenLedgers() async throws {
        let harness = try await makeProducerHarness(windowID: 4990)
        let prompt = "Reply with exactly: ALPHA-7"
        let (userItem, identity) = try await admitClaimedDispatch(harness, runAttemptID: UUID(), text: prompt)
        let baseline = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID))
        XCTAssertNil(baseline.file, "verified absence before the first turn")
        let caller = identity.dispatchID.uuidString.lowercased()
        try harness.appendHistory(o19History(caller: caller, parent: nil, assistant: "a1", prompt: prompt, reply: "ALPHA-7", tag: "t1"))
        let action = reconcileAction(harness, runAttemptID: identity.runAttemptID)
        func reconcile() async -> AgentRecoveryReconcileResult {
            await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: nil)
        }
        let itemsBefore = harness.session.items.map(\.id)

        let imported = await reconcile()
        XCTAssertEqual(imported, .imported(completion: .unconfirmed, rowCount: 2))
        let appended = Array(harness.session.items.dropFirst(itemsBefore.count))
        XCTAssertEqual(appended.map(\.kind), [.system, .assistant])
        XCTAssertEqual(appended.first?.text, AgentProviderHistoryImportPlanner.recoveredLabel)
        XCTAssertEqual(appended.last?.text, "ALPHA-7")
        XCTAssertEqual(harness.session.items.count { $0.id == userItem.id }, 1, "the claimed user is consumed, not re-created")
        let ledger = try XCTUnwrap(harness.session.providerHistoryRecovery)
        XCTAssertEqual(ledger.nativeItems.map(\.nativeEntryID), [caller, "a1"])
        XCTAssertEqual(ledger.nativeItems.map(\.localItemID), [nil, appended.last?.id])
        XCTAssertTrue(ledger.nativeItems.allSatisfy { $0.envelopeDigest.map(AgentSessionProviderHistoryRecovery.isSHA256Hex) == true })
        let receipt = try XCTUnwrap(ledger.lastImportCommit)
        XCTAssertEqual(receipt.rowCount, 2)
        let persisted = try await harness.persisted()
        XCTAssertEqual(persisted?.providerHistoryRecovery, ledger, "rows, ledger and receipt committed in the session save")
        XCTAssertTrue(Set(appended.map(\.id)).isSubset(of: Set(persisted?.items.map(\.id) ?? [])), "the imported rows are in the same save")
        let importedCursor = await harness.cursor()
        XCTAssertEqual(importedCursor?.importID, receipt.importID, "the cursor followed the committed receipt")
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let files = try await harness.service.listAgentSessions(for: harness.workspace)
        let sessionFile = try XCTUnwrap(files.first { $0.lastPathComponent == "AgentSession-\(sessionID.uuidString).json" })
        XCTAssertNil(try Data(contentsOf: sessionFile).range(of: Data(Self.historySentinel.utf8)), "no nonrendering payload persisted")

        func assertUnchanged(
            items: [UUID],
            ledger expectedLedger: AgentSessionProviderHistoryRecovery?,
            cursor expectedCursor: AgentRecoveryHistoryCursor?,
            _ message: String,
            line: UInt = #line
        ) async {
            XCTAssertEqual(harness.session.items.map(\.id), items, message, line: line)
            XCTAssertEqual(harness.session.providerHistoryRecovery, expectedLedger, message, line: line)
            let cursor = await harness.cursor()
            XCTAssertEqual(cursor, expectedCursor, message, line: line)
        }
        let importedItems = harness.session.items.map(\.id)
        let noNewHistory = AgentRecoveryReconcileResult.nothingImported("The provider has no new history for this conversation.")
        let repeated = await reconcile()
        XCTAssertEqual(repeated, noNewHistory)
        await assertUnchanged(items: importedItems, ledger: ledger, cursor: importedCursor, "a second reconcile is a no-op")

        // Crash after the durable session save, before the cursor CAS: the replay is a no-op.
        let boundary = try XCTUnwrap(baseline.cursor)
        _ = await harness.lane.commitHistoryCursor(expectedPreviousImportID: receipt.importID, cursor: boundary)
        let replay = await reconcile()
        XCTAssertEqual(replay, noNewHistory)
        await assertUnchanged(items: importedItems, ledger: ledger, cursor: boundary, "a replay after a lost cursor commit")

        // A changed payload under the known IDs refuses.
        let original = try Data(contentsOf: harness.historyFile)
        try FileManager.default.removeItem(at: harness.historyFile)
        try harness.appendHistory(o19History(caller: caller, parent: nil, assistant: "a1", prompt: prompt, reply: "ALPHA-8", tag: "t1"))
        let changed = await reconcile()
        XCTAssertEqual(changed, .blocked(AgentModeViewModel.recoveryHistoryChangedText))
        await assertUnchanged(items: importedItems, ledger: ledger, cursor: boundary, "changed text")
        try original.write(to: harness.historyFile)

        func mutatedLedger(
            _ transform: (AgentSessionProviderHistoryRecovery.NativeItem) -> [AgentSessionProviderHistoryRecovery.NativeItem]
        ) -> AgentSessionProviderHistoryRecovery {
            AgentSessionProviderHistoryRecovery(
                nativeItems: ledger.nativeItems.flatMap(transform),
                lastImportCommit: ledger.lastImportCommit,
                dispatchBaselines: ledger.dispatchBaselines,
                extras: ledger.extras
            )
        }
        // A known keyset beyond the observed entry, or rows without envelope proof, refuse.
        let partial = mutatedLedger { item in
            guard item.nativeEntryID == "a1" else { return [item] }
            return [item, .init(
                providerRaw: item.providerRaw,
                nativeSessionID: item.nativeSessionID,
                nativeEntryID: item.nativeEntryID,
                rowKindRaw: item.rowKindRaw,
                ordinal: 1,
                localItemID: nil,
                envelopeDigest: item.envelopeDigest
            )]
        }
        let unproven = mutatedLedger { item in
            [.init(
                providerRaw: item.providerRaw,
                nativeSessionID: item.nativeSessionID,
                nativeEntryID: item.nativeEntryID,
                rowKindRaw: item.rowKindRaw,
                ordinal: item.ordinal,
                localItemID: item.localItemID
            )]
        }
        for (name, mutated) in [("keyset beyond the entry", partial), ("missing envelope proof", unproven)] {
            harness.session.providerHistoryRecovery = mutated
            let refused = await reconcile()
            XCTAssertEqual(refused, .blocked(AgentModeViewModel.recoveryHistoryChangedText), name)
            await assertUnchanged(items: importedItems, ledger: mutated, cursor: boundary, name)
            harness.session.providerHistoryRecovery = ledger
        }
    }

    /// Step 4d3b: delivers qualified live complete text for `entry` through the real owner path.
    private func deliverLiveComplete(
        _ harness: ProducerHarness,
        entry: String,
        text: String,
        producer: UUID,
        runID: UUID,
        attemptID: UUID
    ) async throws -> ClaudeLiveTranscriptCompleteText {
        let row = try XCTUnwrap(ClaudeSessionHistoryReader.singleTextAssistantRow(nativeSessionID: conversationID, nativeEntryID: entry, text: text))
        let complete = try ClaudeLiveTranscriptCompleteText(
            nativeSessionID: conversationID,
            nativeEntryID: entry,
            localItemID: XCTUnwrap(row.localItemID),
            text: text,
            envelopeDigest: row.envelopeDigest
        )
        var result = AIStreamResult(type: "content", text: text)
        result.claudeLiveTranscriptEvidence = .init(producerLaunchToken: producer, kind: .completeText(complete))
        await harness.viewModel.test_handleStreamResult(result, session: harness.session, runID: runID, runAttemptID: attemptID)
        return complete
    }

    private func liveDisqualification(producer: UUID) -> AIStreamResult {
        var result = AIStreamResult(type: AIStreamResult.lifecycleType, text: nil)
        result.claudeLiveTranscriptEvidence = .init(producerLaunchToken: producer, kind: .disqualified(.unsupportedPayload))
        return result
    }

    /// Step 4d3b, real composition: a qualified live row and its proof persist coherently in the
    /// ordinary session save; the later import of the same native entry records it with no duplicate.
    /// A disqualification then clears the proof the producer inserted durably (Step 4d3c: the
    /// imported user row it never created keeps its proof); with Claude's history unchanged the next
    /// reconcile refuses, and after a reload a new producer never heals the conversation.
    func testLiveQualifiedRowRoundTripsAndInvalidationRefusesWithoutHealing() async throws {
        let harness = try await makeProducerHarness(windowID: 4996)
        let prompt = "Reply with exactly: ALPHA-7"
        let runID = UUID()
        harness.session.runID = runID
        harness.session.runState = .running
        let attemptID = harness.session.beginRunAttempt(source: "test.liveRoundTrip").attemptID
        let (_, identity) = try await admitClaimedDispatch(harness, runAttemptID: attemptID, text: prompt)
        let caller = identity.dispatchID.uuidString.lowercased()
        let producer = UUID()
        let complete = try await deliverLiveComplete(harness, entry: "a1", text: "ALPHA-7", producer: producer, runID: runID, attemptID: attemptID)
        XCTAssertEqual(harness.session.items.last?.id, complete.localItemID)
        let savedLive = await harness.viewModel.flushSave(for: harness.session.tabID)
        XCTAssertTrue(savedLive)
        let persistedLive = try await harness.persisted()
        XCTAssertEqual(persistedLive?.providerHistoryRecovery?.nativeItem(forKey: complete.ledgerKey), complete.ledgerItem)
        XCTAssertTrue(persistedLive?.items.contains { $0.id == complete.localItemID && $0.text == "ALPHA-7" } ?? false, "row and proof in one save")

        // The run ends; Claude's history holds the same turn.
        harness.session.runState = .completed
        try harness.appendHistory(o19History(caller: caller, parent: nil, assistant: "a1", prompt: prompt, reply: "ALPHA-7", tag: "t1"))
        let action = reconcileAction(harness, runAttemptID: attemptID)
        func reconcile() async -> AgentRecoveryReconcileResult {
            await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: nil)
        }
        let imported = await reconcile()
        XCTAssertEqual(imported, .imported(completion: .unconfirmed, rowCount: 0), "recorded, never appended again")
        XCTAssertEqual(harness.session.items.count { $0.kind == .assistant && $0.text == "ALPHA-7" }, 1)
        let ledger = try XCTUnwrap(harness.session.providerHistoryRecovery)
        XCTAssertEqual(ledger.nativeItem(forKey: complete.ledgerKey), complete.ledgerItem)
        XCTAssertEqual(ledger.nativeItems.map(\.nativeEntryID), ["a1", caller])

        // Disqualification during the same run: the proof is cleared and saved.
        harness.session.runState = .running
        await harness.viewModel.test_handleStreamResult(liveDisqualification(producer: producer), session: harness.session, runID: runID, runAttemptID: attemptID)
        let savedInvalidation = await harness.viewModel.flushSave(for: harness.session.tabID)
        XCTAssertTrue(savedInvalidation)
        harness.session.runState = .completed
        let persistedSession = try await harness.persisted()
        let persisted = try XCTUnwrap(persistedSession?.providerHistoryRecovery)
        XCTAssertNil(persisted.nativeItem(forKey: complete.ledgerKey)?.envelopeDigest, "the producer's own proof is cleared")
        XCTAssertEqual(
            persisted.nativeItems.filter { $0.key != complete.ledgerKey },
            ledger.nativeItems.filter { $0.key != complete.ledgerKey },
            "the imported row it never created keeps its proof"
        )
        XCTAssertEqual(persisted.nativeItems.map(\.key), ledger.nativeItems.map(\.key), "keys are kept")
        XCTAssertEqual(persisted.lastImportCommit, ledger.lastImportCommit, "the receipt is kept")
        let itemsBefore = harness.session.items.map(\.id)
        let cursorBefore = await harness.cursor()
        let refused = await reconcile()
        XCTAssertEqual(refused, .blocked(AgentModeViewModel.recoveryHistoryChangedText), "unchanged native history refuses")
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore)
        XCTAssertEqual(harness.session.providerHistoryRecovery, persisted)
        let cursorAfter = await harness.cursor()
        XCTAssertEqual(cursorAfter, cursorBefore)

        // Reload the persisted ledger: a new producer's complete text is shown unidentified.
        harness.session.providerHistoryRecovery = persisted
        harness.session.claudeLiveTranscriptRefusedProducers = []
        harness.session.claudeLiveTranscriptOwnedKeys = [:]
        harness.session.runState = .running
        let later = try await deliverLiveComplete(harness, entry: "a2", text: "BRAVO", producer: UUID(), runID: runID, attemptID: attemptID)
        harness.viewModel.flushPendingAssistantDelta(harness.session)
        XCTAssertEqual(harness.session.items.last?.text, "BRAVO")
        XCTAssertNotEqual(harness.session.items.last?.id, later.localItemID)
        XCTAssertNil(harness.session.providerHistoryRecovery?.nativeItem(forKey: later.ledgerKey), "never healed")
        harness.viewModel.clearPendingAssistantDelta(harness.session)
    }

    /// Step 4d7, actual save and relaunch: a live row whose turn agreed exactly is no longer owned,
    /// so the launch's later refusal (an unsupported payload in the same run) keeps its proof in
    /// memory and in the ordinary save. A fresh composition hydrates it from disk; the import of
    /// Claude's unchanged native turn records it with no duplicate, while a changed native reply
    /// under the same key still refuses with nothing imported (rows, ledger and cursor unchanged).
    func testAnAgreedLiveRowSurvivesALaterRefusalAndDeduplicatesOnlyUnchangedHistoryAfterRelaunch() async throws {
        for (index, reply) in ["ALPHA-7", "ALPHA-8"].enumerated() {
            let harness = try await makeProducerHarness(windowID: 4960 + 2 * index)
            let prompt = "Reply with exactly: ALPHA-7"
            let runID = UUID()
            harness.session.runID = runID
            harness.session.runState = .running
            let attemptID = harness.session.beginRunAttempt(source: "test.liveAgreedRefusal").attemptID
            let (_, identity) = try await admitClaimedDispatch(harness, runAttemptID: attemptID, text: prompt)
            let caller = identity.dispatchID.uuidString.lowercased()
            let producer = UUID()
            let complete = try await deliverLiveComplete(harness, entry: "a1", text: "ALPHA-7", producer: producer, runID: runID, attemptID: attemptID)
            var agreement = AIStreamResult(type: AIStreamResult.lifecycleType, text: nil)
            agreement.claudeLiveTranscriptEvidence = .init(
                producerLaunchToken: producer, kind: .resultAgreement(localItemID: complete.localItemID, text: "ALPHA-7")
            )
            await harness.viewModel.test_handleStreamResult(agreement, session: harness.session, runID: runID, runAttemptID: attemptID)
            XCTAssertTrue(harness.session.claudeLiveTranscriptOwnedKeys.isEmpty, "\(reply): the exact agreement ends ownership")
            await harness.viewModel.test_handleStreamResult(
                liveDisqualification(producer: producer), session: harness.session, runID: runID, runAttemptID: attemptID
            )
            XCTAssertTrue(harness.session.claudeLiveTranscriptRefusedProducers.contains(producer), reply)
            XCTAssertEqual(harness.session.providerHistoryRecovery?.nativeItem(forKey: complete.ledgerKey), complete.ledgerItem, "\(reply): kept")
            harness.session.runState = .completed
            let saved = await harness.viewModel.flushSave(for: harness.session.tabID)
            XCTAssertTrue(saved, reply)
            let persistedSession = try await harness.persisted()
            XCTAssertEqual(
                persistedSession?.providerHistoryRecovery?.nativeItem(forKey: complete.ledgerKey), complete.ledgerItem, "\(reply): saved"
            )

            try harness.appendHistory(o19History(caller: caller, parent: nil, assistant: "a1", prompt: prompt, reply: reply, tag: "t1"))
            let relaunched = try await makeProducerHarness(windowID: 4961 + 2 * index, relaunching: harness)
            XCTAssertFalse(relaunched.service === harness.service, reply)
            XCTAssertEqual(relaunched.session.items.count { $0.id == complete.localItemID }, 1, "\(reply): back from disk once")
            XCTAssertTrue(relaunched.session.claudeLiveTranscriptOwnedKeys.isEmpty, reply)
            let ledgerBefore = try XCTUnwrap(relaunched.session.providerHistoryRecovery, reply)
            XCTAssertEqual(ledgerBefore.nativeItem(forKey: complete.ledgerKey), complete.ledgerItem, "\(reply): the proof on disk")
            relaunched.session.runState = .completed
            let itemsBefore = relaunched.session.items.filter { $0.kind != .system }
            let cursorBefore = await relaunched.cursor()
            let result = await relaunched.viewModel.reconcileRecoveryHistory(
                reconcileAction(relaunched, runAttemptID: attemptID), session: relaunched.session, lane: relaunched.lane, codexTurnID: nil
            )
            XCTAssertEqual(relaunched.session.items.filter { $0.kind != .system }, itemsBefore, "\(reply): no row is appended")
            if reply == "ALPHA-7" {
                XCTAssertEqual(result, .imported(completion: .unconfirmed, rowCount: 0), "recorded, never appended again")
                XCTAssertEqual(relaunched.session.items.count { $0.kind == .assistant && $0.text == "ALPHA-7" }, 1)
                XCTAssertEqual(relaunched.session.providerHistoryRecovery?.nativeItem(forKey: complete.ledgerKey), complete.ledgerItem)
            } else {
                XCTAssertEqual(result, .blocked(AgentModeViewModel.recoveryHistoryChangedText), "a changed native reply refuses")
                XCTAssertEqual(relaunched.session.providerHistoryRecovery, ledgerBefore)
                let cursorAfter = await relaunched.cursor()
                XCTAssertEqual(cursorAfter, cursorBefore)
            }
        }
    }

    /// Step 4d5: a sanitized O20-shaped native Read turn (no capture contents): the caller's prompt,
    /// the one-block `tool_use` Read assistant, its tool-result user entry (own UUID, parented on and
    /// naming the call, string content, no `is_error`) and the one-text final assistant.
    private func o20History(
        caller: String, prompt: String, toolUseID: String, path: String, output: String, reply: String, callOnly: Bool = false
    ) -> [[String: Any]] {
        func entry(_ type: String, uuid: String, parent: String?, content: Any, source: String? = nil) -> [String: Any] {
            var object: [String: Any] = [
                "type": type, "uuid": uuid, "parentUuid": parent ?? NSNull(), "sessionId": conversationID,
                "message": ["role": type, "content": content], "isSidechain": false
            ]
            if let source { object["sourceToolAssistantUUID"] = source }
            return object
        }
        let call = [
            entry("user", uuid: caller, parent: nil, content: prompt),
            entry("assistant", uuid: "c1", parent: caller, content: [["type": "tool_use", "id": toolUseID, "name": "Read", "input": ["file_path": path]]])
        ]
        guard !callOnly else { return call }
        return call + [
            entry("user", uuid: "r1", parent: "c1", content: [["type": "tool_result", "tool_use_id": toolUseID, "content": output]], source: "c1"),
            entry("assistant", uuid: "a1", parent: "r1", content: [["type": "text", "text": reply]])
        ]
    }

    /// Step 4d5: one qualified live Read chain (call, result and final text, each the reader's
    /// projection) delivered through the owner, then the ordinary terminal session save (its
    /// pending-tool repair runs for a finished run).
    private struct LiveReadChainSaved {
        let caller: String
        let attemptID: UUID
        let call: ClaudeLiveTranscriptToolRow
        let result: ClaudeLiveTranscriptToolRow
        let answer: ClaudeLiveTranscriptCompleteText
        let persisted: AgentSession
        let history: [[String: Any]]

        var liveIDs: [UUID] {
            [call.localItemID, result.localItemID, answer.localItemID]
        }

        var ledgerItems: [AgentSessionProviderHistoryRecovery.NativeItem] {
            [call.ledgerItem, result.ledgerItem, answer.ledgerItem]
        }

        func holds(_ canonicalItem: AgentChatItem?, in canonical: AgentProviderHistoryCanonicalView) -> Bool {
            canonicalItem.map { AgentProviderHistoryAssociationPreflight.holdsCanonicalPayload($0, in: canonical) } ?? false
        }
    }

    private func deliverLiveReadChainAndSave(_ harness: ProducerHarness, terminal: Bool = true) async throws -> LiveReadChainSaved {
        let prompt = "Use Read on notes.txt, then reply with its token."
        let path = "/fixture/workspace/notes.txt", output = Self.readOutput, toolUseID = "toolu_fixture_1"
        let runID = UUID()
        harness.session.runID = runID
        harness.session.runState = .running
        let attemptID = harness.session.beginRunAttempt(source: "test.liveReadRoundTrip").attemptID
        let (_, identity) = try await admitClaimedDispatch(harness, runAttemptID: attemptID, text: prompt)
        let caller = identity.dispatchID.uuidString.lowercased()

        let inputJSON = try XCTUnwrap(ClaudeSessionHistoryReader.canonicalToolInputJSON(["file_path": path] as NSDictionary))
        let call = try XCTUnwrap(ClaudeLiveTranscriptToolRow.projecting(
            nativeSessionID: conversationID, nativeEntryID: "c1", kind: .toolCall, toolUseID: toolUseID, toolName: "Read", payload: inputJSON
        ))
        let result = try XCTUnwrap(ClaudeLiveTranscriptToolRow.projecting(
            nativeSessionID: conversationID, nativeEntryID: "r1", kind: .toolResult, toolUseID: toolUseID, toolName: "Read", payload: output
        ))
        let answerRow = try XCTUnwrap(ClaudeSessionHistoryReader.singleTextAssistantRow(nativeSessionID: conversationID, nativeEntryID: "a1", text: "BRAVO-42"))
        let answer = try ClaudeLiveTranscriptCompleteText(
            nativeSessionID: conversationID, nativeEntryID: "a1", localItemID: XCTUnwrap(answerRow.localItemID),
            text: "BRAVO-42", envelopeDigest: answerRow.envelopeDigest
        )
        let producer = UUID(), invocation = UUID()
        func evidence(_ result: AIStreamResult, _ kind: ClaudeLiveTranscriptEvidence.Kind) -> AIStreamResult {
            var result = result
            result.claudeLiveTranscriptEvidence = .init(producerLaunchToken: producer, kind: kind)
            return result
        }
        let deliveries = [
            evidence(AIStreamResult(type: "tool_call", text: nil, toolName: "Read", toolArgs: inputJSON, toolInvocationID: invocation, toolArgsJSON: inputJSON), .readToolCall(call)),
            evidence(
                AIStreamResult(type: "tool_result", text: nil, toolName: "Read", toolOutput: output, toolInvocationID: invocation, toolResultJSON: output),
                .readToolResult(result, call: call)
            ),
            evidence(AIStreamResult(type: "content", text: "BRAVO-42"), .readAnswer(answer, call: call, result: result))
        ]
        for delivery in deliveries {
            await harness.viewModel.test_handleStreamResult(delivery, session: harness.session, runID: runID, runAttemptID: attemptID)
        }
        XCTAssertEqual(harness.session.items.suffix(3).map(\.id), [call.localItemID, result.localItemID, answer.localItemID])

        harness.session.runState = terminal ? .completed : .running
        let saved = await harness.viewModel.flushSave(for: harness.session.tabID)
        XCTAssertTrue(saved)
        let persistedSession = try await harness.persisted()
        return try LiveReadChainSaved(
            caller: caller, attemptID: attemptID, call: call, result: result, answer: answer, persisted: XCTUnwrap(persistedSession),
            history: o20History(caller: caller, prompt: prompt, toolUseID: toolUseID, path: path, output: output, reply: "BRAVO-42")
        )
    }

    /// Step 4d5 terminal save: the rows (the call row never finalized) and their proofs are in the
    /// same save; the answer keeps its exact canonical payload, while the ordinary tool-result
    /// persistence policy stores the tool rows summarized (not the reader's payloads). Then, with the
    /// persisted ledger over the session's in-memory rows (not a hydration; see the next test), the
    /// import of the same native turn records it with no duplicate and keeps every live proof.
    func testLiveReadChainTerminalSaveAndInMemoryImportIsANoOp() async throws {
        let harness = try await makeProducerHarness(windowID: 4999)
        let chain = try await deliverLiveReadChainAndSave(harness)
        let persisted = chain.persisted
        for item in chain.ledgerItems {
            XCTAssertEqual(persisted.providerHistoryRecovery?.nativeItem(forKey: item.key), item, "row proof in the same save")
        }
        let persistedItems = persisted.items.map { $0.toItem() }
        XCTAssertEqual(persistedItems.suffix(3).map(\.id), chain.liveIDs, "rows in the same save")
        XCTAssertEqual(persistedItems.suffix(3).map(\.kind), [.toolCall, .toolResult, .assistant], "neither the save nor the read-back load repair finalizes the call")
        let persistedView = AgentProviderHistoryCanonicalView(transcript: persisted.transcript ?? .empty, suffixItems: persistedItems)
        XCTAssertTrue(chain.holds(chain.answer.canonicalItem, in: persistedView), "the answer's exact payload")
        XCTAssertFalse(chain.holds(chain.call.canonicalItem, in: persistedView), "tool rows are persisted summarized (existing policy)")
        XCTAssertFalse(chain.holds(chain.result.canonicalItem, in: persistedView))

        // The persisted ledger over the in-memory rows (transient ownership gone), then the import.
        harness.session.providerHistoryRecovery = persisted.providerHistoryRecovery
        harness.session.claudeLiveTranscriptOwnedKeys = [:]
        try harness.appendHistory(chain.history)
        let action = reconcileAction(harness, runAttemptID: chain.attemptID)
        let itemsBefore = harness.session.items
        let imported = await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: nil)
        XCTAssertEqual(imported, .imported(completion: .unconfirmed, rowCount: 0), "recorded, never appended again")
        XCTAssertEqual(harness.session.items.filter { $0.kind != .system }, itemsBefore.filter { $0.kind != .system })
        let ledger = try XCTUnwrap(harness.session.providerHistoryRecovery)
        for item in chain.ledgerItems {
            XCTAssertEqual(ledger.nativeItem(forKey: item.key), item, "the live proof is kept")
        }
        XCTAssertEqual(ledger.nativeItems.map(\.nativeEntryID), ["c1", "r1", "a1", chain.caller])
    }

    /// A data service of its own: no in-memory state shared with the harness's.
    private func freshService() throws -> AgentSessionDataService {
        let root = try RecoveryTestSupport.makeTemporaryRoot("AgentRecoveryFreshService")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AgentSessionDataService(
            tombstoneRoot: root.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: AgentRecoveryStore(rootURL: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true))
        )
    }

    /// The stored session read back by a fresh data service, with its file's bytes.
    private func freshlyStored(_ harness: ProducerHarness) async throws -> (session: AgentSession, bytes: String) {
        let id = try XCTUnwrap(harness.session.activeAgentSessionID)
        let loaded = try await freshService().loadAgentSession(id: id, for: harness.workspace)
        let session = try XCTUnwrap(loaded)
        return try (session, String(contentsOf: XCTUnwrap(session.fileURL), encoding: .utf8))
    }

    /// The fixture's Read output: its second line is a sentinel that appears nowhere else (not in
    /// the answer, the prompt or the path), so any stored fragment of the output is visible.
    private static let outputOnlySentinel = "OUTPUT-ONLY-SENTINEL-7Q4"
    private static let readOutput = "     1\tBRAVO-42\n     2\t\(outputOnlySentinel)\n"

    /// Disk holds the Read rows only in the ordinary policy's summarized form: no arguments, a
    /// summary-only execution, and never the Read output itself. A stored result is exactly the
    /// current summary literal (written out here, independent of the code under test).
    private func assertStoredSummarized(_ harness: ProducerHarness, toolIDs: [UUID], _ label: String) async throws {
        let (stored, bytes) = try await freshlyStored(harness)
        let activities = (stored.transcript?.turns ?? []).flatMap(\.allActivities)
        for id in toolIDs {
            let activity = try XCTUnwrap(activities.first { $0.id == id }, label)
            XCTAssertEqual(activity.toolExecution?.summaryOnly, true, label)
            XCTAssertNil(activity.toolExecution?.argsJSON, label)
            if activity.itemKind == .toolResult {
                XCTAssertEqual(activity.toolExecution?.resultJSON, #"{"status":"unknown","summary_only":true,"summary_text":"read • unknown"}"#, label)
                XCTAssertEqual(activity.toolExecution?.summaryText, "read • unknown", label)
            }
        }
        XCTAssertFalse(bytes.contains("1\\tBRAVO-42"), "\(label): the Read output is never stored")
        XCTAssertFalse(bytes.contains(Self.outputOnlySentinel), "\(label): no fragment of the Read output is stored")
    }

    /// A relaunch (a fresh recovery store instance, data service, coordinator and view model on the
    /// same roots; the earlier composition stays idle) whose new tab is hydrated from disk by the
    /// fresh service's ordinary load, then reconciles there: every `rowIDs` row comes back exactly
    /// once, the call stays a call, each proof is the one on disk, and nothing is owned.
    private func relaunchAndReconcile(
        _ previous: ProducerHarness,
        windowID: Int,
        attemptID: UUID,
        rowIDs: [UUID],
        callID: UUID,
        exchange: [AgentChatItem],
        _ label: String
    ) async throws -> (harness: ProducerHarness, result: AgentRecoveryReconcileResult) {
        let harness = try await makeProducerHarness(windowID: windowID, relaunching: previous)
        XCTAssertFalse(harness.service === previous.service, label)
        for id in rowIDs {
            XCTAssertEqual(harness.session.items.count { $0.id == id }, 1, "\(label): \(id) back from disk once")
        }
        XCTAssertEqual(harness.session.items.first { $0.id == callID }?.kind, .toolCall, "\(label): never finalized")
        XCTAssertTrue(harness.session.claudeLiveTranscriptOwnedKeys.isEmpty, "\(label): ownership is never persisted")
        let ledgerBefore = try XCTUnwrap(harness.session.providerHistoryRecovery, label)
        try assertGeneratedRepresentations(harness, exchange: exchange, "\(label) hydrated")
        harness.session.runState = .completed
        let action = reconcileAction(harness, runAttemptID: attemptID)
        let itemsBefore = harness.session.items.filter { $0.kind != .system }
        let result = await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: nil)
        // Nothing appended, removed or reordered, and every other row unchanged. A proven Read tool row
        // may move only between whole generated representations of its own native exchange (a save
        // re-hiding a result a later row hides), in its backing and its suffix copy alike.
        let itemsAfter = harness.session.items.filter { $0.kind != .system }
        XCTAssertEqual(itemsAfter.map(\.id), itemsBefore.map(\.id), "\(label): nothing appended")
        XCTAssertEqual(itemsAfter.map(\.kind), itemsBefore.map(\.kind), label)
        let exchangeIDs = Set(exchange.map(\.id))
        XCTAssertEqual(
            itemsAfter.filter { !exchangeIDs.contains($0.id) }, itemsBefore.filter { !exchangeIDs.contains($0.id) },
            "\(label): other rows unchanged"
        )
        try assertGeneratedRepresentations(harness, exchange: exchange, "\(label) reconciled")
        let ledger = try XCTUnwrap(harness.session.providerHistoryRecovery, label)
        for native in ledgerBefore.nativeItems where native.localItemID.map(rowIDs.contains) ?? false {
            XCTAssertEqual(ledger.nativeItem(forKey: native.key), native, "\(label): proof kept")
            XCTAssertNotNil(native.envelopeDigest, label)
        }
        XCTAssertTrue(harness.session.claudeLiveTranscriptOwnedKeys.isEmpty, "\(label): never owned")
        return (harness, result)
    }

    /// Each Read tool row of `exchange` (the proven native exchange's projected rows, call first) is,
    /// in its one canonical backing and in its suffix copy, one complete current-pipeline
    /// representation of that exchange (the same whole-representation test as the import's).
    private func assertGeneratedRepresentations(_ harness: ProducerHarness, exchange: [AgentChatItem], _ label: String) throws {
        let images = try XCTUnwrap(AgentTranscriptPolicyPipeline.storageComparisonActivities(exchange), label)
        let activities = harness.session.transcript.turns.flatMap(\.allActivities)
        func sameProjected(_ actual: AgentChatItem, _ image: AgentTranscriptActivity) -> Bool {
            let expected = image.toItem()
            return actual.kind == expected.kind && actual.text == expected.text && actual.toolName == expected.toolName
                && actual.toolInvocationID == expected.toolInvocationID && actual.toolArgsJSON == expected.toolArgsJSON
                && actual.toolResultJSON == expected.toolResultJSON && actual.toolIsError == expected.toolIsError
        }
        for native in exchange {
            let rowImages = try XCTUnwrap(images[native.id], "\(label): \(native.kind)")
            let backings = activities.filter { $0.id == native.id }
            XCTAssertEqual(backings.count, 1, "\(label): one backing for \(native.kind)")
            let backing = try XCTUnwrap(backings.first, label)
            XCTAssertTrue(
                rowImages.contains { image in
                    backing.itemKind == image.itemKind && backing.text == image.text
                        && backing.toolExecution == image.toolExecution && sameProjected(backing.toItem(), image)
                },
                "\(label): the \(native.kind) backing is a whole generated representation: \(String(describing: backing.toolExecution))"
            )
            let copies = harness.session.items.filter { $0.id == native.id }
            XCTAssertEqual(copies.count, 1, "\(label): one suffix copy for \(native.kind)")
            for copy in copies {
                XCTAssertTrue(rowImages.contains { sameProjected(copy, $0) }, "\(label): the \(native.kind) suffix copy is a whole representation")
            }
        }
    }

    /// Step 4d5 stored-projection contract: a live Read chain saved terminally or mid-run is stored
    /// summarized, and after each of two relaunch/hydration/save cycles the import of the same native
    /// turn records it with no duplicate, keeping every proof. The live owner's exact check still
    /// finds the summarized tool rows not held.
    func testLiveReadChainSurvivesRepeatedSaveAndHydrationAndItsImportIsANoOp() async throws {
        for terminal in [true, false] {
            let label = terminal ? "terminal" : "running"
            var harness = try await makeProducerHarness(windowID: terminal ? 4988 : 4987)
            let chain = try await deliverLiveReadChainAndSave(harness, terminal: terminal)
            let toolIDs = [chain.call.localItemID, chain.result.localItemID]
            let exchange = try [XCTUnwrap(chain.call.canonicalItem), XCTUnwrap(chain.result.canonicalItem)]
            try await assertStoredSummarized(harness, toolIDs: toolIDs, label)
            try harness.appendHistory(chain.history)
            for cycle in 1 ... 2 {
                let cycleLabel = "\(label) cycle \(cycle)"
                let relaunched = try await relaunchAndReconcile(
                    harness, windowID: (terminal ? 4910 : 4920) + cycle,
                    attemptID: chain.attemptID, rowIDs: chain.liveIDs, callID: chain.call.localItemID, exchange: exchange, cycleLabel
                )
                harness = relaunched.harness
                // The first import records the claimed caller (ledger only); the next finds nothing new.
                // Both are reached only after the association preflight accepted every proven row.
                XCTAssertEqual(
                    relaunched.result,
                    cycle == 1 ? .imported(completion: .unconfirmed, rowCount: 0) : .nothingImported(Self.noNewHistoryText),
                    cycleLabel
                )
                let view = AgentProviderHistoryCanonicalView(transcript: harness.session.transcript, suffixItems: harness.session.items)
                XCTAssertFalse(chain.holds(chain.call.canonicalItem, in: view), "\(cycleLabel): the live check stays exact")
                XCTAssertFalse(chain.holds(chain.result.canonicalItem, in: view), cycleLabel)
                XCTAssertTrue(chain.holds(chain.answer.canonicalItem, in: view), cycleLabel)
                harness.session.isDirty = true
                let saved = await harness.viewModel.flushSave(for: harness.session.tabID)
                XCTAssertTrue(saved, cycleLabel)
                try await assertStoredSummarized(harness, toolIDs: toolIDs, cycleLabel)
            }
            // A tampered hydrated backing matches no generated representation: refused, nothing changed.
            var tampered = harness.session.transcript
            var didTamper = false
            for turn in tampered.turns.indices {
                for span in tampered.turns[turn].responseSpans.indices {
                    for activity in tampered.turns[turn].responseSpans[span].activities.indices
                        where tampered.turns[turn].responseSpans[span].activities[activity].id == chain.result.localItemID
                    {
                        tampered.turns[turn].responseSpans[span].activities[activity].toolExecution?.summaryText = "read • changed"
                        didTamper = true
                    }
                }
            }
            XCTAssertTrue(didTamper, "\(label): tampered backing")
            harness.session.transcript = tampered
            let itemsBefore = harness.session.items
            let ledgerBefore = harness.session.providerHistoryRecovery
            let refused = await harness.viewModel.reconcileRecoveryHistory(
                reconcileAction(harness, runAttemptID: chain.attemptID), session: harness.session, lane: harness.lane, codexTurnID: nil
            )
            guard case .associationUnavailable(.canonicalPayloadMismatch, _) = refused else {
                return XCTFail("\(label) tampered: \(refused)")
            }
            XCTAssertEqual(harness.session.items, itemsBefore, "\(label) tampered: nothing changed")
            XCTAssertEqual(harness.session.providerHistoryRecovery, ledgerBefore, "\(label) tampered: ledger unchanged")
            XCTAssertTrue(harness.session.claudeLiveTranscriptOwnedKeys.isEmpty, label)
        }
    }

    private static let noNewHistoryText = "The provider has no new history for this conversation."

    /// Step 4d5: Read rows recovered by an import (a whole chain, or a call alone; the planner's
    /// recovered label first) are stored summarized, and after two relaunch/hydration/save cycles
    /// their re-import appends nothing; they are never owned. A cold restore never cancels a protected
    /// call alone, and the native result and answer that arrive later import after it.
    func testImportedReadRowsSurviveRepeatedSaveAndHydrationAndReimportAsANoOp() async throws {
        for callOnly in [false, true] {
            let label = callOnly ? "call only" : "whole chain"
            var harness = try await makeProducerHarness(windowID: callOnly ? 4986 : 4985)
            let runID = UUID()
            harness.session.runID = runID
            harness.session.runState = .running
            let attemptID = harness.session.beginRunAttempt(source: "test.importedReadRoundTrip").attemptID
            let prompt = "Use Read on notes.txt, then reply with its token."
            let (_, identity) = try await admitClaimedDispatch(harness, runAttemptID: attemptID, text: prompt)
            harness.session.runState = .completed
            try harness.appendHistory(o20History(
                caller: identity.dispatchID.uuidString.lowercased(), prompt: prompt, toolUseID: "toolu_fixture_1",
                path: "/fixture/workspace/notes.txt", output: Self.readOutput, reply: "BRAVO-42", callOnly: callOnly
            ))
            let itemsBefore = harness.session.items.map(\.id)
            let first = await harness.viewModel.reconcileRecoveryHistory(
                reconcileAction(harness, runAttemptID: attemptID), session: harness.session, lane: harness.lane, codexTurnID: nil
            )
            // The planner prepends one recovered label to the native output rows.
            XCTAssertEqual(first, .imported(completion: .unconfirmed, rowCount: callOnly ? 2 : 4), label)
            let ledger = try XCTUnwrap(harness.session.providerHistoryRecovery, label)
            func localID(_ entry: String) throws -> UUID {
                try XCTUnwrap(ledger.nativeItems.first { $0.nativeEntryID == entry }?.localItemID, "\(label): \(entry)")
            }
            let callID = try localID("c1")
            let rowIDs = try callOnly ? [callID] : [callID, localID("r1"), localID("a1")]
            let appended = Array(harness.session.items.dropFirst(itemsBefore.count))
            XCTAssertEqual(harness.session.items.prefix(itemsBefore.count).map(\.id), itemsBefore, label)
            let importID = try XCTUnwrap(ledger.lastImportCommit?.importID, label)
            let labelID = ClaudeSessionHistoryReader.deterministicUUID(
                namespace: "rpce-history-import-label-v1",
                components: ["claude", conversationID, importID.uuidString.lowercased()]
            )
            XCTAssertEqual(appended.map(\.id), [labelID] + rowIDs, "\(label): the label, then the native output in order")
            XCTAssertEqual(appended.first?.kind, .system, label)
            XCTAssertEqual(appended.first?.text, AgentProviderHistoryImportPlanner.recoveredLabel, label)
            XCTAssertEqual(appended.dropFirst().map(\.kind), callOnly ? [.toolCall] : [.toolCall, .toolResult, .assistant], label)
            let caller = identity.dispatchID.uuidString.lowercased()
            XCTAssertEqual(ledger.nativeItems.map(\.nativeEntryID), callOnly ? [caller, "c1"] : [caller, "c1", "r1", "a1"], label)
            XCTAssertNil(ledger.nativeItems.first { $0.nativeEntryID == caller }?.localItemID, "\(label): the caller is ledger only")
            let toolIDs = try callOnly ? [callID] : [callID, localID("r1")]
            // Before any save the imported tool rows are the reader's exact projections (the proven
            // native exchange); their stored forms must stay generated representations of these.
            let exchange = try toolIDs.map { id in try XCTUnwrap(harness.session.items.first { $0.id == id }, label) }
            XCTAssertNotNil(exchange.first?.toolArgsJSON, "\(label): imported raw")
            XCTAssertTrue(harness.session.claudeLiveTranscriptOwnedKeys.isEmpty, label)
            harness.session.isDirty = true
            let saved = await harness.viewModel.flushSave(for: harness.session.tabID)
            XCTAssertTrue(saved, label)
            try await assertStoredSummarized(harness, toolIDs: toolIDs, label)
            for cycle in 1 ... 2 {
                let cycleLabel = "\(label) cycle \(cycle)"
                let relaunched = try await relaunchAndReconcile(
                    harness, windowID: (callOnly ? 4940 : 4930) + cycle, attemptID: attemptID, rowIDs: rowIDs, callID: callID,
                    exchange: exchange, cycleLabel
                )
                harness = relaunched.harness
                // A call alone stays protected through the cold restore (never cancelled or errored).
                XCTAssertEqual(relaunched.result, .nothingImported(Self.noNewHistoryText), cycleLabel)
                harness.session.isDirty = true
                let savedAgain = await harness.viewModel.flushSave(for: harness.session.tabID)
                XCTAssertTrue(savedAgain, cycleLabel)
                try await assertStoredSummarized(harness, toolIDs: toolIDs, cycleLabel)
            }
            guard callOnly else { continue }
            // Partial history continues: the native result and answer arrive after the relaunches and
            // import after the protected call (its own recovered label first); the call is unchanged.
            let callBefore = try XCTUnwrap(harness.session.items.first { $0.id == callID }, label)
            let full = o20History(
                caller: caller, prompt: prompt, toolUseID: "toolu_fixture_1",
                path: "/fixture/workspace/notes.txt", output: Self.readOutput, reply: "BRAVO-42"
            )
            try harness.appendHistory(Array(full.suffix(2)))
            harness.session.runState = .completed
            let countBefore = harness.session.items.count
            let continued = await harness.viewModel.reconcileRecoveryHistory(
                reconcileAction(harness, runAttemptID: attemptID), session: harness.session, lane: harness.lane, codexTurnID: nil
            )
            XCTAssertEqual(continued, .imported(completion: .unconfirmed, rowCount: 3), "\(label): continued")
            let continuedLedger = try XCTUnwrap(harness.session.providerHistoryRecovery, label)
            XCTAssertEqual(continuedLedger.nativeItems.map(\.nativeEntryID), [caller, "c1", "r1", "a1"], label)
            let continuedImportID = try XCTUnwrap(continuedLedger.lastImportCommit?.importID, label)
            let continuedLabelID = ClaudeSessionHistoryReader.deterministicUUID(
                namespace: "rpce-history-import-label-v1",
                components: ["claude", conversationID, continuedImportID.uuidString.lowercased()]
            )
            func continuedLocalID(_ entry: String) throws -> UUID {
                try XCTUnwrap(continuedLedger.nativeItems.first { $0.nativeEntryID == entry }?.localItemID, "\(label): \(entry)")
            }
            let added = Array(harness.session.items.dropFirst(countBefore))
            XCTAssertEqual(added.map(\.id), try [continuedLabelID, continuedLocalID("r1"), continuedLocalID("a1")], label)
            XCTAssertEqual(added.map(\.kind), [.system, .toolResult, .assistant], label)
            XCTAssertEqual(added.last?.text, "BRAVO-42", label)
            XCTAssertEqual(harness.session.items.first { $0.id == callID }, callBefore, "\(label): the call is never converted")
            let callKey = try XCTUnwrap(ledger.nativeItems.first { $0.nativeEntryID == "c1" }?.key, label)
            XCTAssertEqual(continuedLedger.nativeItem(forKey: callKey), ledger.nativeItem(forKey: callKey), "\(label): the call's proof is kept")
            XCTAssertTrue(harness.session.claudeLiveTranscriptOwnedKeys.isEmpty, label)

            // The continued state (call, then the later label, result and answer) survives one more
            // save, relaunch and reconcile: nothing new, each tool row a whole generated representation.
            let resultID = try continuedLocalID("r1")
            let continuedExchange = try [exchange[0], XCTUnwrap(harness.session.items.first { $0.id == resultID }, label)]
            XCTAssertEqual(continuedExchange[1].toolResultJSON, Self.readOutput, "\(label): the result imported raw")
            harness.session.isDirty = true
            let savedContinued = await harness.viewModel.flushSave(for: harness.session.tabID)
            XCTAssertTrue(savedContinued, label)
            try await assertStoredSummarized(harness, toolIDs: [callID, resultID], "\(label) continued")
            let relaunched = try await relaunchAndReconcile(
                harness, windowID: 4950, attemptID: attemptID, rowIDs: [callID, resultID, continuedLocalID("a1")], callID: callID,
                exchange: continuedExchange, "\(label) continued relaunch"
            )
            XCTAssertEqual(relaunched.result, .nothingImported(Self.noNewHistoryText), "\(label) continued relaunch")
        }
    }

    // MARK: Step 4d5 stored-projection comparison (pure preflight)

    private enum StoredReadFixture {
        static let session = "conv-1"
        static let inputJSON = #"{"file_path":"\/fixture\/workspace\/notes.txt"}"#
        static let output = "     1\tBRAVO-42\n"
    }

    private func readerRow(
        _ row: ClaudeSessionHistoryReader.Row,
        ordinal: Int? = nil,
        toolIsError: Bool?? = nil,
        envelopeDigest: String? = nil
    ) -> ClaudeSessionHistoryReader.Row {
        ClaudeSessionHistoryReader.Row(
            nativeEntryID: row.nativeEntryID, kind: row.kind, ordinal: ordinal ?? row.ordinal, localItemID: row.localItemID,
            text: row.text, toolName: row.toolName, toolUseID: row.toolUseID, toolInvocationID: row.toolInvocationID,
            toolInputJSON: row.toolInputJSON, toolIsError: toolIsError ?? row.toolIsError, envelopeDigest: envelopeDigest ?? row.envelopeDigest
        )
    }

    private func readObservation(_ rows: [ClaudeSessionHistoryReader.Row], newRows: Bool = false) -> AgentProviderHistoryObservation {
        ClaudeSessionHistoryReader.observation(ClaudeSessionHistoryReader.Candidate(
            nativeSessionID: StoredReadFixture.session, file: nil, completeLineOffset: 0, prefixSHA256: "",
            rows: newRows ? rows : [], validationRows: rows, userMessageEntries: [], completion: .unconfirmed, isRescan: false
        ))
    }

    /// The ledger proving `rows` (their own digests unless `digest` overrides).
    private func readLedger(_ rows: [ClaudeSessionHistoryReader.Row], digest: String?? = nil) -> AgentSessionProviderHistoryRecovery {
        AgentSessionProviderHistoryRecovery(nativeItems: rows.map {
            .init(
                providerRaw: "claude", nativeSessionID: StoredReadFixture.session, nativeEntryID: $0.nativeEntryID,
                rowKindRaw: $0.kind.rawValue, ordinal: $0.ordinal, localItemID: $0.localItemID, envelopeDigest: digest ?? $0.envelopeDigest
            )
        })
    }

    /// `items` (after a user turn) through the real save and load: the hydrated transcript and its
    /// working (suffix) items.
    private func storedView(
        _ items: [AgentChatItem],
        terminalState: AgentSessionRunState? = nil
    ) -> (transcript: AgentTranscript, suffix: [AgentChatItem]) {
        var sequenced = [AgentChatItem.user("Use Read on notes.txt")] + items
        for index in sequenced.indices {
            sequenced[index].sequenceIndex = index
        }
        let built = AgentTranscriptIO.buildTranscript(
            from: sequenced, terminalState: terminalState, nextSequenceIndex: sequenced.count, policy: .canonical
        )
        let stored = AgentTranscriptPolicyPipeline.persistedTranscript(from: built).transcript
        let loaded = AgentTranscriptPolicyPipeline.runtimeTranscriptOnly(AgentTranscriptIO.runtimeNormalizedTranscript(stored))
        return (loaded, AgentTranscriptIO.workingSourceItems(from: loaded))
    }

    /// Step 4d5: only a proven singleton Read row in its exact stored form (a full, intact backing
    /// activity whose complete execution agrees, and an agreeing suffix copy) passes; every other
    /// stored, changed, unproven, ambiguous, compacted or unsupported case refuses, and the live
    /// owner's exact check never holds a stored copy.
    func testStoredReadProjectionIsAcceptedOnlyForAProvenExactStoredForm() throws {
        let call = try XCTUnwrap(ClaudeSessionHistoryReader.singleToolUseRow(
            nativeSessionID: StoredReadFixture.session, nativeEntryID: "c1", toolUseID: "toolu_1", name: "Read", inputJSON: StoredReadFixture.inputJSON
        ))
        let result = try XCTUnwrap(ClaudeSessionHistoryReader.singleToolResultRow(
            nativeSessionID: StoredReadFixture.session, nativeEntryID: "r1", toolUseID: "toolu_1", toolName: "Read", text: StoredReadFixture.output
        ))
        let callItem = try XCTUnwrap(ClaudeSessionHistoryReader.item(for: call))
        let resultItem = try XCTUnwrap(ClaudeSessionHistoryReader.item(for: result))
        let rows = [call, result]
        let stored = storedView([callItem, resultItem])
        func refusal(
            _ rows: [ClaudeSessionHistoryReader.Row],
            transcript: AgentTranscript,
            suffix: [AgentChatItem],
            ledger: AgentSessionProviderHistoryRecovery?,
            newRows: Bool = false
        ) -> AgentProviderHistoryAssociationRefusal? {
            AgentProviderHistoryAssociationPreflight.canonicalPayloadRefusal(
                observation: readObservation(rows, newRows: newRows),
                canonical: AgentProviderHistoryCanonicalView(transcript: transcript, suffixItems: suffix),
                ledger: ledger
            )
        }
        XCTAssertEqual(readObservation(rows).storageComparableReadItemIDs, [callItem.id, resultItem.id])
        let summarizedResult = try XCTUnwrap(stored.suffix.first { $0.id == resultItem.id })
        XCTAssertNotEqual(summarizedResult.toolResultJSON, StoredReadFixture.output, "the fixture is the summarized stored form")

        // Accepted: suffix plus backing, persisted-prefix only, and a call alone.
        XCTAssertNil(refusal(rows, transcript: stored.transcript, suffix: stored.suffix, ledger: readLedger(rows)))
        XCTAssertNil(refusal(rows, transcript: stored.transcript, suffix: [], ledger: readLedger(rows)), "prefix only")
        let callOnly = storedView([callItem])
        XCTAssertNil(refusal([call], transcript: callOnly.transcript, suffix: callOnly.suffix, ledger: readLedger([call])), "call only")
        // The raw copy keeps the unchanged exact path.
        XCTAssertNil(refusal(rows, transcript: .empty, suffix: [callItem, resultItem], ledger: readLedger(rows)))

        // The other generated representations, each as the real pipeline produces it: a result a later
        // answer hides (runtime-sanitized), and a turn rebuilt from its working items.
        let hidden = AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
            stored.transcript, preservedVisibleToolResultRowIDs: [], purpose: .runtimePresentation
        ).transcript
        let hiddenSuffix = AgentTranscriptIO.workingSourceItems(from: hidden)
        let hiddenResult = try XCTUnwrap(hidden.turns.flatMap(\.allActivities).first { $0.id == resultItem.id })
        let visibleResult = try XCTUnwrap(stored.transcript.turns.flatMap(\.allActivities).first { $0.id == resultItem.id })
        XCTAssertNotEqual(hiddenResult.toolExecution?.resultJSON, visibleResult.toolExecution?.resultJSON, "the fixture hides the result")
        XCTAssertNotEqual(hiddenResult.text, visibleResult.text, "the hidden text differs")
        XCTAssertEqual(
            AgentToolResultPersistencePolicy.sanitizeTranscriptWithMetrics(
                hidden, preservedVisibleToolResultRowIDs: [], purpose: .runtimePresentation
            ).transcript,
            hidden,
            "the runtime sanitizer is idempotent (the hidden forms rely on it)"
        )
        XCTAssertNil(refusal(rows, transcript: hidden, suffix: hiddenSuffix, ledger: readLedger(rows)), "hidden")
        let rebuilt = AgentTranscriptPolicyPipeline.runtimeTranscriptOnly(AgentTranscriptIO.buildTranscript(
            from: stored.suffix, nextSequenceIndex: stored.suffix.count, policy: .canonical
        ))
        let rebuiltCall = try XCTUnwrap(rebuilt.turns.flatMap(\.allActivities).first { $0.id == callItem.id })
        XCTAssertEqual(rebuiltCall.toolExecution?.summaryOnly, false, "the fixture rebuilds the call")
        XCTAssertNil(refusal(rows, transcript: rebuilt, suffix: AgentTranscriptIO.workingSourceItems(from: rebuilt), ledger: readLedger(rows)), "rebuilt")
        XCTAssertNil(
            refusal(rows, transcript: stored.transcript, suffix: hiddenSuffix, ledger: readLedger(rows)),
            "a suffix copy and its backing each match a whole representation of their own"
        )

        // The live owner's exact check never holds a stored copy.
        let view = AgentProviderHistoryCanonicalView(transcript: stored.transcript, suffixItems: stored.suffix)
        XCTAssertFalse(AgentProviderHistoryAssociationPreflight.holdsCanonicalPayload(callItem, in: view))
        XCTAssertFalse(AgentProviderHistoryAssociationPreflight.holdsCanonicalPayload(resultItem, in: view))

        // Unproven: a cleared proof, a changed native entry, or no ledger entry at all.
        XCTAssertEqual(refusal(rows, transcript: stored.transcript, suffix: stored.suffix, ledger: readLedger(rows, digest: .some(nil))), .canonicalPayloadUnavailable)
        XCTAssertEqual(
            refusal(rows, transcript: stored.transcript, suffix: stored.suffix, ledger: readLedger(rows, digest: String(repeating: "c", count: 64))),
            .canonicalPayloadUnavailable,
            "a native entry changed since its proof"
        )
        XCTAssertEqual(refusal(rows, transcript: stored.transcript, suffix: stored.suffix, ledger: nil, newRows: true), .canonicalPayloadUnavailable)

        // Changed stored form: the suffix copy, or the backing execution behind an intact suffix.
        var alteredSuffix = stored.suffix
        let resultIndex = try XCTUnwrap(alteredSuffix.firstIndex { $0.id == resultItem.id })
        alteredSuffix[resultIndex].toolResultJSON = alteredSuffix[resultIndex].toolResultJSON?.replacingOccurrences(of: "unknown", with: "success")
        alteredSuffix[resultIndex].text = alteredSuffix[resultIndex].toolResultJSON ?? ""
        XCTAssertEqual(refusal(rows, transcript: stored.transcript, suffix: alteredSuffix, ledger: readLedger(rows)), .canonicalPayloadMismatch)
        func alteringBacking(_ change: (inout AgentTranscriptActivity) -> Void) throws -> AgentTranscript {
            var transcript = stored.transcript
            for turn in transcript.turns.indices {
                for span in transcript.turns[turn].responseSpans.indices {
                    for activity in transcript.turns[turn].responseSpans[span].activities.indices
                        where transcript.turns[turn].responseSpans[span].activities[activity].id == resultItem.id
                    {
                        change(&transcript.turns[turn].responseSpans[span].activities[activity])
                        return transcript
                    }
                }
            }
            XCTFail("no backing activity")
            return transcript
        }
        let alteredExecution = try alteringBacking { $0.toolExecution?.summaryText = "read • changed" }
        XCTAssertEqual(refusal(rows, transcript: alteredExecution, suffix: stored.suffix, ledger: readLedger(rows)), .canonicalPayloadMismatch)
        let alteredFlag = try alteringBacking { $0.toolExecution?.summaryOnly = false }
        XCTAssertEqual(refusal(rows, transcript: alteredFlag, suffix: stored.suffix, ledger: readLedger(rows)), .canonicalPayloadMismatch)
        // Mixed representations: fields each allowed by some image, but together matching none.
        let mixedResult = try alteringBacking { $0.text = hiddenResult.text }
        XCTAssertEqual(refusal(rows, transcript: mixedResult, suffix: stored.suffix, ledger: readLedger(rows)), .canonicalPayloadMismatch, "hidden text, visible execution")
        var mixedCall = stored.transcript
        for turn in mixedCall.turns.indices {
            for span in mixedCall.turns[turn].responseSpans.indices {
                for activity in mixedCall.turns[turn].responseSpans[span].activities.indices
                    where mixedCall.turns[turn].responseSpans[span].activities[activity].id == callItem.id
                {
                    mixedCall.turns[turn].responseSpans[span].activities[activity].toolExecution?.summaryOnly = false
                }
            }
        }
        XCTAssertNotEqual(mixedCall, stored.transcript)
        XCTAssertEqual(refusal(rows, transcript: mixedCall, suffix: stored.suffix, ledger: readLedger(rows)), .canonicalPayloadMismatch, "rebuilt flag, loaded summary")

        // A repeated or competing ledger mapping never lends its proof to the stored comparison, in
        // either order; a mapping to another row's item is a mismatch.
        let proofs = readLedger(rows).nativeItems
        for repeated in [proofs + [proofs[1]], [proofs[1]] + proofs] {
            XCTAssertEqual(
                refusal(rows, transcript: stored.transcript, suffix: stored.suffix, ledger: AgentSessionProviderHistoryRecovery(nativeItems: repeated)),
                .canonicalPayloadUnavailable,
                "a duplicate proof"
            )
        }
        var competing = proofs
        competing[0] = .init(
            providerRaw: proofs[0].providerRaw, nativeSessionID: proofs[0].nativeSessionID, nativeEntryID: proofs[0].nativeEntryID,
            rowKindRaw: proofs[0].rowKindRaw, ordinal: proofs[0].ordinal, localItemID: resultItem.id, envelopeDigest: proofs[0].envelopeDigest
        )
        XCTAssertEqual(
            refusal(rows, transcript: stored.transcript, suffix: stored.suffix, ledger: AgentSessionProviderHistoryRecovery(nativeItems: competing)),
            .canonicalPayloadMismatch,
            "two mappings to one item"
        )

        // Reordered canonical output.
        XCTAssertEqual(
            refusal(rows, transcript: stored.transcript, suffix: Array(stored.suffix.reversed()), ledger: readLedger(rows)),
            .canonicalPayloadMismatch,
            "a reordered suffix"
        )

        // Missing, ambiguous or compacted backing.
        XCTAssertEqual(refusal(rows, transcript: .empty, suffix: stored.suffix, ledger: readLedger(rows)), .canonicalPayloadUnavailable, "no backing")
        var duplicated = stored.transcript
        let lastTurn = try XCTUnwrap(duplicated.turns.indices.last)
        let backing = try XCTUnwrap(duplicated.turns[lastTurn].allActivities.first { $0.id == resultItem.id })
        duplicated.turns.append(AgentTranscriptTurn(responseSpans: [AgentTranscriptProviderResponseSpan(startedAt: Date(), activities: [backing])], startedAt: Date()))
        XCTAssertEqual(refusal(rows, transcript: duplicated, suffix: stored.suffix, ledger: readLedger(rows)), .canonicalPayloadUnavailable, "ambiguous")
        var condensed = stored.transcript
        for turn in condensed.turns.indices {
            condensed.turns[turn].retentionTier = .condensed
        }
        XCTAssertEqual(refusal(rows, transcript: condensed, suffix: stored.suffix, ledger: readLedger(rows)), .canonicalPayloadUnavailable, "non-full")

        /// Unsupported shapes never qualify, each in its own exact stored form.
        func unsupported(_ label: String, call: ClaudeSessionHistoryReader.Row, result: ClaudeSessionHistoryReader.Row?) throws {
            let rows = [call] + (result.map { [$0] } ?? [])
            XCTAssertTrue(readObservation(rows).storageComparableReadItemIDs.isEmpty, label)
            let items = try rows.map { try XCTUnwrap(ClaudeSessionHistoryReader.item(for: $0), label) }
            let view = storedView(items)
            XCTAssertEqual(refusal(rows, transcript: view.transcript, suffix: view.suffix, ledger: readLedger(rows)), .canonicalPayloadUnavailable, label)
        }
        func toolUse(_ name: String, _ inputJSON: String) throws -> ClaudeSessionHistoryReader.Row {
            try XCTUnwrap(ClaudeSessionHistoryReader.singleToolUseRow(
                nativeSessionID: StoredReadFixture.session, nativeEntryID: "c1", toolUseID: "toolu_1", name: name, inputJSON: inputJSON
            ))
        }
        try unsupported("another tool", call: toolUse("Bash", #"{"command":"ls"}"#), result: nil)
        try unsupported("another input", call: toolUse("Read", #"{"file_path":"\/fixture\/workspace\/notes.txt","limit":5}"#), result: nil)
        try unsupported("an empty path", call: toolUse("Read", #"{"file_path":""}"#), result: nil)
        try unsupported("an error result", call: call, result: readerRow(result, toolIsError: .some(true)))
        try unsupported("a result whose digest is not its singleton entry's", call: call, result: readerRow(result, envelopeDigest: String(repeating: "d", count: 64)))
        XCTAssertTrue(readObservation([call, readerRow(call, ordinal: 1)]).storageComparableReadItemIDs.isEmpty, "a multiblock entry")
        XCTAssertTrue(readObservation([call, result, readerRow(result, ordinal: 0)]).storageComparableReadItemIDs.isEmpty, "two results")
    }

    /// Step 4d3b save ordering: a save whose snapshot predates an invalidation may write the old proof,
    /// but the invalidation's own dirty mark and save request leave the fresh snapshot last on disk.
    func testAnInFlightOlderSaveNeverOutlivesALiveProofInvalidation() async throws {
        let harness = try await makeProducerHarness(windowID: 4997)
        let runID = UUID()
        harness.session.runID = runID
        harness.session.runState = .running
        let attemptID = harness.session.beginRunAttempt(source: "test.liveSaveOrder").attemptID
        let producer = UUID()
        let complete = try await deliverLiveComplete(harness, entry: "a1", text: "ALPHA-7", producer: producer, runID: runID, attemptID: attemptID)
        let saved = await harness.viewModel.flushSave(for: harness.session.tabID)
        XCTAssertTrue(saved)

        // The next save is held after its snapshot; the invalidation lands while it is in flight.
        harness.session.appendItem(.user("Later"))
        harness.session.isDirty = true
        var hookRuns = 0
        harness.viewModel.test_saveSessionBeforeWriteHook = { [harness] held in
            guard held.tabID == harness.session.tabID else { return }
            hookRuns += 1
            guard hookRuns == 1 else { return }
            await harness.viewModel.test_handleStreamResult(
                self.liveDisqualification(producer: producer), session: held, runID: runID, runAttemptID: attemptID
            )
        }
        _ = await harness.viewModel.flushSave(for: harness.session.tabID)
        harness.viewModel.test_saveSessionBeforeWriteHook = nil
        XCTAssertEqual(hookRuns, 1)
        XCTAssertNil(harness.session.providerHistoryRecovery?.nativeItem(forKey: complete.ledgerKey)?.envelopeDigest)
        let fresh = await harness.viewModel.flushSave(for: harness.session.tabID)
        XCTAssertTrue(fresh)
        let persisted = try await harness.persisted()
        let entry = try XCTUnwrap(persisted?.providerHistoryRecovery?.nativeItem(forKey: complete.ledgerKey))
        XCTAssertNil(entry.envelopeDigest, "the older snapshot never restores the cleared proof")
        XCTAssertEqual(entry.localItemID, complete.localItemID)
        XCTAssertTrue(persisted?.items.contains { $0.text == "Later" } ?? false)
    }

    /// Step 4d3c (review B F1, option b): an accepted persisted hydration replaces the ledger from
    /// disk but keeps live-producer ownership (hydration does not detach the tab's Claude
    /// controller), so the still-attached producer's later between-run refusal revokes the proof it
    /// inserted, durably, while an unrelated imported proof is kept.
    func testPersistedHydrationKeepsLiveOwnershipSoALaterRefusalStillRevokesItsProof() async throws {
        let harness = try await makeProducerHarness(windowID: 4998)
        let imported = AgentSessionProviderHistoryRecovery.NativeItem(
            providerRaw: "claude", nativeSessionID: "conv-0", nativeEntryID: "o1", rowKindRaw: "assistantText", ordinal: 0,
            localItemID: UUID(), envelopeDigest: String(repeating: "a", count: 64)
        )
        harness.session.providerHistoryRecovery = AgentSessionProviderHistoryRecovery(nativeItems: [imported])
        let runID = UUID()
        harness.session.runID = runID
        harness.session.runState = .running
        let attemptID = harness.session.beginRunAttempt(source: "test.liveOwnershipHydration").attemptID
        let producer = UUID()
        let complete = try await deliverLiveComplete(harness, entry: "a1", text: "ALPHA-7", producer: producer, runID: runID, attemptID: attemptID)
        XCTAssertEqual(harness.session.claudeLiveTranscriptOwnedKeys, [producer: [complete.ledgerKey]])
        harness.session.runState = .completed
        let saved = await harness.viewModel.flushSave(for: harness.session.tabID)
        XCTAssertTrue(saved)

        // An accepted persisted hydration: the in-memory-only marker shows the ledger came from disk.
        var marked = try XCTUnwrap(harness.session.providerHistoryRecovery)
        marked.extras["inMemoryOnly"] = .bool(true)
        harness.session.providerHistoryRecovery = marked
        harness.session.hasLoadedPersistedState = false
        let outcome = await harness.viewModel.loadSessionFromDisk(for: harness.session)
        XCTAssertEqual(outcome.disposition, .applied)
        let hydrated = try XCTUnwrap(harness.session.providerHistoryRecovery)
        XCTAssertNil(hydrated.extras["inMemoryOnly"], "the ledger was replaced from disk")
        XCTAssertEqual(hydrated.nativeItem(forKey: complete.ledgerKey), complete.ledgerItem)
        XCTAssertEqual(hydrated.nativeItem(forKey: imported.key), imported)
        XCTAssertEqual(harness.session.claudeLiveTranscriptOwnedKeys, [producer: [complete.ledgerKey]], "ownership survives hydration")

        // The still-attached producer's later between-run refusal revokes only its own proof.
        await harness.viewModel.test_handleBackgroundNativeStreamResult(liveDisqualification(producer: producer), session: harness.session)
        XCTAssertTrue(harness.session.claudeLiveTranscriptRefusedProducers.contains(producer))
        XCTAssertTrue(harness.session.claudeLiveTranscriptOwnedKeys.isEmpty)
        let revoked = try XCTUnwrap(harness.session.providerHistoryRecovery)
        XCTAssertNil(revoked.nativeItem(forKey: complete.ledgerKey)?.envelopeDigest, "its own proof is revoked")
        XCTAssertEqual(revoked.nativeItem(forKey: complete.ledgerKey)?.localItemID, complete.localItemID)
        XCTAssertEqual(revoked.nativeItem(forKey: imported.key), imported, "the unrelated imported proof is kept")
        let savedRevocation = await harness.viewModel.flushSave(for: harness.session.tabID)
        XCTAssertTrue(savedRevocation)
        let persistedSession = try await harness.persisted()
        let persisted = try XCTUnwrap(persistedSession?.providerHistoryRecovery)
        XCTAssertNil(persisted.nativeItem(forKey: complete.ledgerKey)?.envelopeDigest, "the revocation is durable")
        XCTAssertEqual(persisted.nativeItem(forKey: imported.key), imported)
    }

    /// Step 4d7 hydration guard through the existing entrypoint (no forced reload): the ordinary load
    /// of an already-loaded session returns before touching rows, ledger or ownership, so the turn's
    /// later exact agreement still ends ownership and a later refusal keeps the agreed proof.
    func testAnAlreadyLoadedLoadKeepsLiveOwnershipForTheTurnsLaterAgreement() async throws {
        let harness = try await makeProducerHarness(windowID: 4964)
        XCTAssertTrue(harness.session.hasLoadedPersistedState, "precondition: the ordinary already-loaded tab")
        let runID = UUID()
        harness.session.runID = runID
        harness.session.runState = .running
        let attemptID = harness.session.beginRunAttempt(source: "test.liveAlreadyLoaded").attemptID
        let producer = UUID()
        let complete = try await deliverLiveComplete(harness, entry: "a1", text: "ALPHA-7", producer: producer, runID: runID, attemptID: attemptID)
        let items = harness.session.items
        let ledger = harness.session.providerHistoryRecovery
        XCTAssertEqual(harness.session.claudeLiveTranscriptOwnedKeys, [producer: [complete.ledgerKey]])

        _ = await harness.viewModel.loadSessionFromDisk(for: harness.session)
        XCTAssertEqual(harness.session.items, items, "the already-loaded load changes no rows")
        XCTAssertEqual(harness.session.providerHistoryRecovery, ledger, "nor the ledger")
        XCTAssertEqual(harness.session.claudeLiveTranscriptOwnedKeys, [producer: [complete.ledgerKey]], "nor ownership")

        var agreement = AIStreamResult(type: AIStreamResult.lifecycleType, text: nil)
        agreement.claudeLiveTranscriptEvidence = .init(
            producerLaunchToken: producer, kind: .resultAgreement(localItemID: complete.localItemID, text: "ALPHA-7")
        )
        await harness.viewModel.test_handleStreamResult(agreement, session: harness.session, runID: runID, runAttemptID: attemptID)
        XCTAssertTrue(harness.session.claudeLiveTranscriptOwnedKeys.isEmpty, "the later agreement still consumes")
        await harness.viewModel.test_handleStreamResult(
            liveDisqualification(producer: producer), session: harness.session, runID: runID, runAttemptID: attemptID
        )
        XCTAssertEqual(harness.session.providerHistoryRecovery?.nativeItem(forKey: complete.ledgerKey), complete.ledgerItem)
        harness.viewModel.clearPendingAssistantDelta(harness.session)
    }

    /// A steering dispatch of the same attempt whose claimed native user entry never appeared
    /// refuses the whole import with no state change (never read as non-delivery, never resent).
    func testAMissingClaimedSteeringEntryRefusesWithoutChangingAnything() async throws {
        let harness = try await makeProducerHarness(windowID: 4991)
        let runAttemptID = UUID()
        let (_, first) = try await admitClaimedDispatch(harness, runAttemptID: runAttemptID, text: "Do it")
        try harness.appendHistory(o19History(
            caller: first.dispatchID.uuidString.lowercased(),
            parent: nil,
            assistant: "a1",
            prompt: "Do it",
            reply: "Done.",
            tag: "t1"
        ))
        _ = try await admitClaimedDispatch(harness, runAttemptID: runAttemptID, text: "Also this")
        XCTAssertEqual(harness.session.providerHistoryRecovery?.dispatchBaselines.count { $0.runAttemptID == runAttemptID }, 2)
        let itemsBefore = harness.session.items.map(\.id)
        let ledgerBefore = harness.session.providerHistoryRecovery
        let cursorBefore = await harness.cursor()
        let result = await harness.viewModel.reconcileRecoveryHistory(
            reconcileAction(harness, runAttemptID: runAttemptID),
            session: harness.session,
            lane: harness.lane,
            codexTurnID: nil
        )
        XCTAssertEqual(
            result,
            .associationUnavailable(.outboundClaimUnmatched, AgentModeViewModel.recoveryAssociationText(.outboundClaimUnmatched))
        )
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore)
        XCTAssertEqual(harness.session.providerHistoryRecovery, ledgerBefore)
        let cursorAfter = await harness.cursor()
        XCTAssertEqual(cursorAfter, cursorBefore)
    }

    /// Step 4d3a, real composition: once a reply is imported, a later reconcile with new native output
    /// first compares the imported row's canonical payload. A rewritten imported row refuses with no
    /// item, ledger or cursor change; with the row restored, the same import proceeds.
    func testAChangedImportedRowRefusesTheNextImportWithoutChangingAnything() async throws {
        let harness = try await makeProducerHarness(windowID: 4995)
        let prompt = "Reply with exactly: ALPHA-7"
        let (_, identity) = try await admitClaimedDispatch(harness, runAttemptID: UUID(), text: prompt)
        let caller = identity.dispatchID.uuidString.lowercased()
        try harness.appendHistory(o19History(caller: caller, parent: nil, assistant: "a1", prompt: prompt, reply: "ALPHA-7", tag: "t1"))
        let action = reconcileAction(harness, runAttemptID: identity.runAttemptID)
        func reconcile() async -> AgentRecoveryReconcileResult {
            await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: nil)
        }
        let imported = await reconcile()
        XCTAssertEqual(imported, .imported(completion: .unconfirmed, rowCount: 2))
        let importedID = try XCTUnwrap(harness.session.providerHistoryRecovery?.nativeItems.first { $0.nativeEntryID == "a1" }?.localItemID)
        let importedIndex = try XCTUnwrap(harness.session.items.firstIndex { $0.id == importedID })
        // Claude wrote more output for the same turn after the import.
        try harness.appendHistory([historyEntry("assistant", uuid: "a2", parent: "t1-t", text: "More.")])
        let itemsBefore = harness.session.items.map(\.id)
        let ledgerBefore = harness.session.providerHistoryRecovery
        let cursorBefore = await harness.cursor()
        let original = harness.session.items[importedIndex]
        var rewritten = original
        rewritten.text = "ALPHA-8"
        harness.session.replaceItem(at: importedIndex, with: rewritten)

        let refused = await reconcile()
        XCTAssertEqual(
            refused,
            .associationUnavailable(.canonicalPayloadMismatch, AgentModeViewModel.recoveryAssociationText(.canonicalPayloadMismatch))
        )
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "zero transcript changes")
        XCTAssertEqual(harness.session.items[importedIndex].text, "ALPHA-8", "the refusal rewrites nothing")
        XCTAssertEqual(harness.session.providerHistoryRecovery, ledgerBefore, "zero ledger changes")
        let cursorAfterRefusal = await harness.cursor()
        XCTAssertEqual(cursorAfterRefusal, cursorBefore, "no cursor advance")

        harness.session.replaceItem(at: importedIndex, with: original)
        let resumed = await reconcile()
        XCTAssertEqual(resumed, .imported(completion: .unconfirmed, rowCount: 2), "the refusal blocked a real import")
        XCTAssertEqual(harness.session.items.last?.text, "More.")
        let cursorAfterImport = await harness.cursor()
        XCTAssertNotEqual(cursorAfterImport, cursorBefore)
    }

    /// Review A R1, real composition: the initial dispatch and its claimed steer sit in two persisted
    /// turns, and both claims match Claude's history exactly. Live output saved under its own ID in
    /// the SECOND turn is still unassociated canonical output, so the import refuses with no item,
    /// ledger or cursor change (it was skipped before, letting native output be appended twice).
    func testUnassociatedLiveOutputInALaterPersistedTurnRefusesWithoutChangingAnything() async throws {
        let harness = try await makeProducerHarness(windowID: 4994)
        let runAttemptID = UUID()
        let (first, firstIdentity) = try await admitClaimedDispatch(harness, runAttemptID: runAttemptID, text: "Do it")
        try harness.appendHistory(o19History(
            caller: firstIdentity.dispatchID.uuidString.lowercased(),
            parent: nil,
            assistant: "a1",
            prompt: "Do it",
            reply: "Done.",
            tag: "t1"
        ))
        let (steer, steerIdentity) = try await admitClaimedDispatch(harness, runAttemptID: runAttemptID, text: "Also this")
        try harness.appendHistory(o19History(
            caller: steerIdentity.dispatchID.uuidString.lowercased(),
            parent: "t1-t",
            assistant: "a2",
            prompt: "Also this",
            reply: "Also done.",
            tag: "t2"
        ))
        let live = AgentChatItem.assistant("Also done.")
        harness.session.transcript = AgentTranscript(turns: [
            AgentTranscriptTurn(request: AgentTranscriptRequestAnchor(from: first), startedAt: Date(timeIntervalSince1970: 0)),
            AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(from: steer),
                responseSpans: [AgentTranscriptProviderResponseSpan(
                    startedAt: Date(timeIntervalSince1970: 1),
                    activities: [AgentTranscriptActivity(from: live)]
                )],
                startedAt: Date(timeIntervalSince1970: 1)
            )
        ])
        let itemsBefore = harness.session.items.map(\.id)
        let ledgerBefore = harness.session.providerHistoryRecovery
        let cursorBefore = await harness.cursor()
        let result = await harness.viewModel.reconcileRecoveryHistory(
            reconcileAction(harness, runAttemptID: runAttemptID),
            session: harness.session,
            lane: harness.lane,
            codexTurnID: nil
        )
        XCTAssertEqual(
            result,
            .associationUnavailable(
                .canonicalOutputAssociationUnavailable,
                AgentModeViewModel.recoveryAssociationText(.canonicalOutputAssociationUnavailable)
            )
        )
        XCTAssertEqual(harness.session.items.map(\.id), itemsBefore)
        XCTAssertEqual(harness.session.providerHistoryRecovery, ledgerBefore)
        let cursorAfter = await harness.cursor()
        XCTAssertEqual(cursorAfter, cursorBefore)

        // Positive control: the same two turns without that live output import both replies.
        harness.session.transcript = AgentTranscript(turns: [
            AgentTranscriptTurn(request: AgentTranscriptRequestAnchor(from: first), startedAt: Date(timeIntervalSince1970: 0)),
            AgentTranscriptTurn(request: AgentTranscriptRequestAnchor(from: steer), startedAt: Date(timeIntervalSince1970: 1))
        ])
        let imported = await harness.viewModel.reconcileRecoveryHistory(
            reconcileAction(harness, runAttemptID: runAttemptID),
            session: harness.session,
            lane: harness.lane,
            codexTurnID: nil
        )
        guard case .imported = imported else { return XCTFail("expected an import, got \(imported)") }
        XCTAssertEqual(
            harness.session.items.dropFirst(itemsBefore.count).filter { $0.kind == .assistant }.map(\.text),
            ["Done.", "Also done."]
        )

        // Step 4d3a regression (review A R1 / B F1): the import appended both replies after the
        // claimed steer, although "Done." natively precedes it. Its own unchanged replay must not
        // refuse: output is ordered among output, and the claimed anchors among themselves.
        func reconcile() async -> AgentRecoveryReconcileResult {
            await harness.viewModel.reconcileRecoveryHistory(
                reconcileAction(harness, runAttemptID: runAttemptID),
                session: harness.session,
                lane: harness.lane,
                codexTurnID: nil
            )
        }
        let importedItems = harness.session.items.map(\.id)
        let importedLedger = try XCTUnwrap(harness.session.providerHistoryRecovery)
        let receipt = try XCTUnwrap(importedLedger.lastImportCommit)
        let importedCursor = await harness.cursor()
        XCTAssertEqual(importedCursor?.importID, receipt.importID)
        let noNewHistory = AgentRecoveryReconcileResult.nothingImported("The provider has no new history for this conversation.")
        let repeated = await reconcile()
        XCTAssertEqual(repeated, noNewHistory, "an unchanged second reconcile is a no-op")
        XCTAssertEqual(harness.session.items.map(\.id), importedItems)
        XCTAssertEqual(harness.session.providerHistoryRecovery, importedLedger)
        let cursorAfterRepeat = await harness.cursor()
        XCTAssertEqual(cursorAfterRepeat, importedCursor)

        // A lost cursor CAS: the record cursor is back at the boundary; the replay is a no-op.
        let boundary = try XCTUnwrap(importedLedger.dispatchBaseline(dispatchID: firstIdentity.dispatchID)?.cursor)
        _ = await harness.lane.commitHistoryCursor(expectedPreviousImportID: receipt.importID, cursor: boundary)
        let replay = await reconcile()
        XCTAssertEqual(replay, noNewHistory, "a replay after a lost cursor commit is a no-op")
        XCTAssertEqual(harness.session.items.map(\.id), importedItems)
        XCTAssertEqual(harness.session.providerHistoryRecovery, importedLedger)
        let cursorAfterReplay = await harness.cursor()
        XCTAssertEqual(cursorAfterReplay, boundary)

        // Append-only later output of the same attempt is accepted and appended once.
        try harness.appendHistory([historyEntry("assistant", uuid: "a3", parent: "t2-t", text: "Later.")])
        let grown = await reconcile()
        XCTAssertEqual(grown, .imported(completion: .unconfirmed, rowCount: 2))
        XCTAssertEqual(
            harness.session.items.dropFirst(importedItems.count).map(\.kind),
            [.system, .assistant]
        )
        XCTAssertEqual(harness.session.items.last?.text, "Later.")
        XCTAssertEqual(harness.session.items.count { $0.text == "Done." }, 1, "nothing earlier is appended again")
        let grownCursor = await harness.cursor()
        XCTAssertEqual(grownCursor?.importID, harness.session.providerHistoryRecovery?.lastImportCommit?.importID)
    }

    /// Step 4d2 prefix fences, real composition (no process): the import receipt durably binds its
    /// exact target in the session save, so after a crash between that save and the cursor CAS the
    /// record cursor is older but the saved target still fences the next import. A same-length
    /// rewrite after the OLD cursor and before the saved target (in nonrendering bytes no envelope
    /// proof covers) refuses; a normal replay is a no-op; append-only growth imports under a new
    /// receipt after verifying the previous target; a legacy proof fails closed. No refusal changes
    /// anything, and no nonrendering payload is persisted (only digests).
    func testTheLatestSavedTargetFencesTheImportAfterALostCursorCommit() async throws {
        let harness = try await makeProducerHarness(windowID: 4992)
        let prompt = "Reply with exactly: ALPHA-7"
        let (_, identity) = try await admitClaimedDispatch(harness, runAttemptID: UUID(), text: prompt)
        let baseline = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: identity.dispatchID))
        let emptyProof = AgentSessionProviderHistoryRecovery.sha256Hex(Data())
        XCTAssertNil(baseline.file)
        XCTAssertEqual(baseline.prefixSHA256, emptyProof, "verified absence proves the empty prefix, never nil")
        XCTAssertEqual(baseline.profileName, "nativeEntriesSubsetV2")
        let boundary = try XCTUnwrap(baseline.cursor)
        XCTAssertEqual(harness.session.providerHistoryRecovery?.lastImportCommit?.target, boundary.prefixFence, "the zero-row receipt binds its baseline")
        let seededCursor = await harness.cursor()
        XCTAssertEqual(seededCursor, boundary)
        let caller = identity.dispatchID.uuidString.lowercased()
        try harness.appendHistory(o19History(caller: caller, parent: nil, assistant: "a1", prompt: prompt, reply: "ALPHA-7", tag: "t1"))
        let action = reconcileAction(harness, runAttemptID: identity.runAttemptID)
        func reconcile() async -> AgentRecoveryReconcileResult {
            await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: nil)
        }
        let imported = await reconcile()
        XCTAssertEqual(imported, .imported(completion: .unconfirmed, rowCount: 2))
        let firstBytes = try Data(contentsOf: harness.historyFile)
        let ledger = try XCTUnwrap(harness.session.providerHistoryRecovery)
        let receipt = try XCTUnwrap(ledger.lastImportCommit)
        XCTAssertEqual(receipt.target?.completeLineOffset, UInt64(firstBytes.count))
        XCTAssertEqual(receipt.target?.prefixSHA256, AgentSessionProviderHistoryRecovery.sha256Hex(firstBytes))
        XCTAssertNotNil(receipt.target?.file)
        let importedCursor = await harness.cursor()
        XCTAssertEqual(importedCursor?.prefixFence, receipt.target, "the cursor carries the same target")
        let persistedAfterImport = try await harness.persisted()
        XCTAssertEqual(persistedAfterImport?.providerHistoryRecovery?.lastImportCommit, receipt, "the target is durable with the rows")

        func assertUnchanged(
            items: [UUID],
            ledger expectedLedger: AgentSessionProviderHistoryRecovery?,
            cursor expectedCursor: AgentRecoveryHistoryCursor?,
            _ message: String,
            line: UInt = #line
        ) async {
            XCTAssertEqual(harness.session.items.map(\.id), items, message, line: line)
            XCTAssertEqual(harness.session.providerHistoryRecovery, expectedLedger, message, line: line)
            let cursor = await harness.cursor()
            XCTAssertEqual(cursor, expectedCursor, message, line: line)
        }
        // Crash after the durable session save, before the cursor CAS: the record cursor is the OLD one.
        _ = await harness.lane.commitHistoryCursor(expectedPreviousImportID: receipt.importID, cursor: boundary)
        let items = harness.session.items.map(\.id)
        let replay = await reconcile()
        XCTAssertEqual(replay, .nothingImported("The provider has no new history for this conversation."))
        await assertUnchanged(items: items, ledger: ledger, cursor: boundary, "a normal replay is a no-op")

        // CRITICAL: a same-length rewrite after the old cursor but before the saved target, in an
        // attachment payload that no envelope proof covers.
        let sentinel = try XCTUnwrap(firstBytes.range(of: Data(Self.historySentinel.utf8)))
        XCTAssertGreaterThan(sentinel.lowerBound, Int(boundary.completeLineOffset))
        var rewritten = firstBytes
        rewritten.replaceSubrange(sentinel, with: Data("SENTINEL-PRIVATE-CONTEXT-4d3".utf8))
        XCTAssertEqual(rewritten.count, firstBytes.count)
        try rewritten.write(to: harness.historyFile)
        let refused = await reconcile()
        XCTAssertEqual(refused, .blocked(AgentModeViewModel.recoveryHistoryChangedText))
        await assertUnchanged(items: items, ledger: ledger, cursor: boundary, "rewrite before the saved target")
        // Truncated below the saved target refuses too (no rewind to the old cursor).
        try firstBytes.prefix(firstBytes.count / 2).write(to: harness.historyFile)
        let truncated = await reconcile()
        XCTAssertEqual(truncated, .blocked(AgentModeViewModel.recoveryHistoryChangedText))
        await assertUnchanged(items: items, ledger: ledger, cursor: boundary, "truncated below the saved target")
        // Step 4d7: a record this version doesn't support (here appended after the saved target) is the
        // generic unsupported refusal: blocked, so a continuation never dispatches; nothing changes.
        let unsupportedRecord = try JSONSerialization.data(withJSONObject: historyEntry("system", uuid: "s1", parent: "a1", text: "x"))
        try (firstBytes + unsupportedRecord + Data("\n".utf8)).write(to: harness.historyFile)
        let unsupported = await reconcile()
        XCTAssertEqual(unsupported, .blocked(AgentModeViewModel.recoveryHistoryUnsupportedText))
        await assertUnchanged(items: items, ledger: ledger, cursor: boundary, "an unsupported record")

        // Legacy proofs fail closed: a latest receipt without a target, a boundary without a proof.
        try firstBytes.write(to: harness.historyFile)
        let legacyReceipt = AgentSessionProviderHistoryRecovery(
            nativeItems: ledger.nativeItems,
            lastImportCommit: .init(
                importID: receipt.importID,
                providerRaw: receipt.providerRaw,
                conversationID: receipt.conversationID,
                committedAt: receipt.committedAt,
                rowCount: receipt.rowCount
            ),
            dispatchBaselines: ledger.dispatchBaselines
        )
        let legacyBaseline = AgentSessionProviderHistoryRecovery(
            nativeItems: ledger.nativeItems,
            lastImportCommit: receipt,
            dispatchBaselines: ledger.dispatchBaselines.map { recorded in
                .init(
                    dispatchID: recorded.dispatchID,
                    runAttemptID: recorded.runAttemptID,
                    transcriptResetGeneration: recorded.transcriptResetGeneration,
                    providerRaw: recorded.providerRaw,
                    conversationID: recorded.conversationID,
                    userItemIDs: recorded.userItemIDs,
                    file: recorded.file,
                    completeLineOffset: recorded.completeLineOffset,
                    baselineCommitID: recorded.baselineCommitID,
                    profileName: "nativeEntriesSubsetV1",
                    status: recorded.status,
                    recordedAt: recorded.recordedAt,
                    outboundUserMessage: recorded.outboundUserMessage
                )
            }
        )
        for (name, legacy) in [("legacy receipt", legacyReceipt), ("legacy baseline", legacyBaseline)] {
            harness.session.providerHistoryRecovery = legacy
            let unproven = await reconcile()
            XCTAssertEqual(unproven, .blocked(AgentModeViewModel.recoveryHistoryUnprovenText), name)
            await assertUnchanged(items: items, ledger: legacy, cursor: boundary, name)
            harness.session.providerHistoryRecovery = ledger
        }

        // Append-only growth (the reply continues after the trailing attachment) imports under a new
        // receipt after the previous saved target verified; its partial tail waits.
        try harness.appendHistory([historyEntry("assistant", uuid: "a2", parent: "t1-t", text: "BETA-3")])
        let grownComplete = try Data(contentsOf: harness.historyFile)
        var withTail = grownComplete
        withTail.append(Data(#"{"type":"assistant","uuid":"a3""#.utf8))
        try withTail.write(to: harness.historyFile)
        let grown = await reconcile()
        XCTAssertEqual(grown, .imported(completion: .unconfirmed, rowCount: 2))
        XCTAssertEqual(harness.session.items.last?.text, "BETA-3")
        let grownReceipt = try XCTUnwrap(harness.session.providerHistoryRecovery?.lastImportCommit)
        XCTAssertNotEqual(grownReceipt.importID, receipt.importID, "a durable import ID never gets a new target")
        XCTAssertEqual(grownReceipt.target?.completeLineOffset, UInt64(grownComplete.count), "the partial tail is excluded")
        XCTAssertEqual(grownReceipt.target?.prefixSHA256, AgentSessionProviderHistoryRecovery.sha256Hex(grownComplete))
        let grownCursor = await harness.cursor()
        XCTAssertEqual(grownCursor?.importID, grownReceipt.importID)
        XCTAssertEqual(grownCursor?.prefixFence, grownReceipt.target)

        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let files = try await harness.service.listAgentSessions(for: harness.workspace)
        let sessionFile = try XCTUnwrap(files.first { $0.lastPathComponent == "AgentSession-\(sessionID.uuidString).json" })
        let sessionBytes = try Data(contentsOf: sessionFile)
        XCTAssertNil(sessionBytes.range(of: Data(Self.historySentinel.utf8)), "no nonrendering payload persisted")
        XCTAssertNil(sessionBytes.range(of: Data("SENTINEL".utf8)), "nor any rewritten one")
    }

    /// Step 4d2 conservative multi-conversation limit and the record cursor's own proof (real
    /// composition, no process). Once Claude rows of a conversation were imported, its last saved
    /// target must still be the latest receipt: if another provider's or conversation's receipt (or
    /// none) replaced it, a returning import refuses and a new baseline is recorded unsupported
    /// without a claim (never a fresh proof over the lost target). The persisted record cursor is an
    /// extra fence: a changed or missing proof refuses even when the baseline and the latest receipt
    /// verify; a different file identity with the same prefix is accepted as before.
    func testALostSavedTargetAndTheRecordCursorProofFailClosed() async throws {
        let harness = try await makeProducerHarness(windowID: 4993)
        let prompt = "Reply with exactly: ALPHA-7"
        let (_, identity) = try await admitClaimedDispatch(harness, runAttemptID: UUID(), text: prompt)
        try harness.appendHistory(o19History(
            caller: identity.dispatchID.uuidString.lowercased(),
            parent: nil,
            assistant: "a1",
            prompt: prompt,
            reply: "ALPHA-7",
            tag: "t1"
        ))
        let action = reconcileAction(harness, runAttemptID: identity.runAttemptID)
        func reconcile() async -> AgentRecoveryReconcileResult {
            await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: nil)
        }
        let imported = await reconcile()
        XCTAssertEqual(imported, .imported(completion: .unconfirmed, rowCount: 2))
        let ledger = try XCTUnwrap(harness.session.providerHistoryRecovery)
        let items = harness.session.items.map(\.id)
        let noNewHistory = AgentRecoveryReconcileResult.nothingImported("The provider has no new history for this conversation.")

        // The record cursor's own proof is verified (the attempt baseline stays the boundary).
        let importedCursor = await harness.cursor()
        var current = try XCTUnwrap(importedCursor)
        func replaceCursor(file: AgentRecoveryHistoryFileIdentity?, proof: String?) async throws -> AgentRecoveryHistoryCursor {
            let next = AgentRecoveryHistoryCursor(
                providerRaw: current.providerRaw,
                conversationID: current.conversationID,
                importID: UUID(),
                file: file,
                completeLineOffset: current.completeLineOffset,
                prefixSHA256: proof,
                committedAt: current.committedAt
            )
            _ = try await harness.lane.commitHistoryCursor(expectedPreviousImportID: current.importID, cursor: next).get()
            current = next
            return next
        }
        let wrongProof = try await replaceCursor(file: current.file, proof: AgentSessionProviderHistoryRecovery.sha256Hex(Data("other".utf8)))
        let changed = await reconcile()
        XCTAssertEqual(changed, .blocked(AgentModeViewModel.recoveryHistoryChangedText), "a changed record-cursor proof refuses")
        XCTAssertEqual(harness.session.items.map(\.id), items)
        XCTAssertEqual(harness.session.providerHistoryRecovery, ledger)
        let afterChanged = await harness.cursor()
        XCTAssertEqual(afterChanged, wrongProof)
        let noProof = try await replaceCursor(file: current.file, proof: nil)
        let unproven = await reconcile()
        XCTAssertEqual(unproven, .blocked(AgentModeViewModel.recoveryHistoryUnprovenText), "a missing record-cursor proof refuses")
        let afterUnproven = await harness.cursor()
        XCTAssertEqual(afterUnproven, noProof)
        let target = try XCTUnwrap(ledger.lastImportCommit?.target)
        _ = try await replaceCursor(
            file: AgentRecoveryHistoryFileIdentity(device: 9, inode: 9, birthSeconds: nil, birthNanoseconds: nil),
            proof: target.prefixSHA256
        )
        let otherIdentity = await reconcile()
        XCTAssertEqual(otherIdentity, noNewHistory, "a different identity with the same verified prefix is unchanged")

        func receipt(provider: String, conversation: String) -> AgentSessionProviderHistoryRecovery.ImportCommit {
            .init(importID: UUID(), providerRaw: provider, conversationID: conversation, committedAt: Date(), rowCount: 0)
        }
        // Imported A, then the latest receipt became Codex's, another conversation's, or none.
        let superseded: [(String, AgentSessionProviderHistoryRecovery.ImportCommit?)] = [
            ("codex receipt", receipt(provider: "codex", conversation: "thread-b")),
            ("other conversation", receipt(provider: "claude", conversation: "11111111-2222-4333-8444-555555555555")),
            ("no receipt", nil)
        ]
        for (name, latest) in superseded {
            var lostTarget = ledger
            lostTarget.lastImportCommit = latest
            harness.session.providerHistoryRecovery = lostTarget
            let returning = await reconcile()
            XCTAssertEqual(returning, .blocked(AgentModeViewModel.recoveryHistoryUnprovenText), name)
            XCTAssertEqual(harness.session.items.map(\.id), items, name)
            XCTAssertEqual(harness.session.providerHistoryRecovery, lostTarget, name)
        }

        // A new A baseline can't renew qualification over the lost target: recorded unsupported, no
        // claim UUID, no fresh proof, and the ordinary send proceeds.
        var lostTarget = ledger
        lostTarget.lastImportCommit = receipt(provider: "codex", conversation: "thread-b")
        harness.session.providerHistoryRecovery = lostTarget
        let userItem = AgentChatItem.user("Again")
        harness.session.appendItem(userItem)
        let renewal = AgentDispatchBaselineIdentity(
            dispatchID: UUID(),
            runAttemptID: UUID(),
            userItemIDs: [userItem.id],
            hasCompleteUserItems: true
        )
        let admitted = await harness.viewModel.admitClaudeDispatchBaseline(
            renewal,
            outboundUserMessage: .init(uuid: renewal.dispatchID, providerBoundText: "Again"),
            session: harness.session
        )
        XCTAssertEqual(admitted, .admittedWithoutIdentity)
        let recorded = try XCTUnwrap(harness.session.providerHistoryRecovery?.dispatchBaseline(dispatchID: renewal.dispatchID))
        guard case .unsupported = recorded.status else { return XCTFail("expected an unsupported baseline") }
        XCTAssertNil(recorded.outboundUserMessage)
        XCTAssertNil(recorded.prefixSHA256)
        XCTAssertEqual(harness.session.providerHistoryRecovery?.lastImportCommit, lostTarget.lastImportCommit, "no fresh proof minted")
        XCTAssertEqual(harness.session.providerHistoryRecovery?.nativeItems, ledger.nativeItems, "rows and raw data kept")
    }

    @MainActor
    private final class ReconcileGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool {
            continuation != nil
        }

        func wait() async {
            await withCheckedContinuation { self.continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Review A P1-01 / B F3a at the view model: while an explicit recovery action of the session is
    /// between its reservation and its recorded outcome (here, inside its reconciliation), the
    /// scheduler's busy state and the workspace's new-session gate (also consulted by
    /// `runAlongsideOtherSessions`) report it, and both clear with the recorded outcome.
    func testInFlightRecoveryActionHoldsAutomaticWorkUntilItsOutcome() async throws {
        let harness = try await makeProducerHarness(windowID: 5080)
        let session = harness.session
        let workspaceID = harness.workspace.id
        XCTAssertFalse(harness.viewModel.scheduledSendHasUnresolvedRecovery(session))
        XCTAssertFalse(harness.viewModel.scheduledSendBusyState(tabID: session.tabID).isBusy)
        XCTAssertFalse(harness.viewModel.hasUnresolvedRecoverySession(inWorkspace: workspaceID, excluding: UUID()))

        var revision: AgentRecoveryRecordRevision?
        if case let .success(.supported(record)) = await harness.lane.readRecord() { revision = record.revision }
        let request = AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: AgentRecoveryCardKey(
                kind: .run,
                incarnationID: harness.lane.binding.incarnationID,
                transcriptResetGeneration: harness.lane.binding.transcriptResetGeneration,
                entityID: UUID().uuidString
            ),
            kind: .reconcileOnly,
            expectedRevision: revision,
            target: harness.viewModel.recoveryActionTarget(for: session)
        )
        let gate = ReconcileGate()
        let performers = AgentRecoveryActionPerformers(reconcile: { _ in
            await gate.wait()
            return .nothingImported("none")
        }) { _, _ in .notDispatched("Reconcile never dispatches.") }
        let runner = harness.viewModel.recoveryActionRunner
        let lane = harness.lane
        let running = Task { await runner.perform(request, lane: lane, performers: performers) }
        var polls = 0
        while !gate.isWaiting, polls < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        XCTAssertTrue(gate.isWaiting, "the reconciliation is in flight")
        XCTAssertTrue(harness.viewModel.scheduledSendHasUnresolvedRecovery(session))
        XCTAssertTrue(harness.viewModel.scheduledSendBusyState(tabID: session.tabID).isBusy, "a due schedule waits")
        XCTAssertTrue(
            harness.viewModel.hasUnresolvedRecoverySession(inWorkspace: workspaceID, excluding: UUID()),
            "new sessions in the workspace stay paused, runAlongside included"
        )

        gate.open()
        let result = await running.value
        XCTAssertEqual(result, .completed(.notDispatched, reason: "none"))
        XCTAssertFalse(harness.viewModel.scheduledSendHasUnresolvedRecovery(session), "the hold ends with the recorded outcome")
        XCTAssertFalse(harness.viewModel.scheduledSendBusyState(tabID: session.tabID).isBusy)
    }

    /// Review B F3b/F4 and A P1-06 at the row seam: Continue is offered only for an unresolved
    /// interruption of the lane's own reset generation whose input was handed off; Reconcile stays.
    func testRunRowOffersContinueOnlyForAnUnresolvedHandedOffInterruption() async throws {
        let harness = try await makeProducerHarness(windowID: 5081)
        let session = harness.session
        let generation = harness.lane.binding.transcriptResetGeneration
        let vm = harness.viewModel
        XCTAssertEqual(
            vm.recoveryRunActions(session: session, status: .interrupted, facts: .init(runTranscriptResetGeneration: generation)),
            [.continueTurn, .reconcileHistory]
        )
        XCTAssertEqual(vm.recoveryRunActions(session: session, status: .interrupted, facts: .init()), [.continueTurn, .reconcileHistory])
        for status: AgentRecoveryInterruptedTurn.Status in [.completedTailMayBeMissing, .failed, .cancelledByUser, .stopped, .unknown] {
            XCTAssertEqual(vm.recoveryRunActions(session: session, status: status, facts: .init()), [.reconcileHistory], "\(status)")
        }
        for facts in [
            AgentRecoveryCatalogActionFacts(resolvedByAction: true),
            AgentRecoveryCatalogActionFacts(runNeverHandedOff: true),
            AgentRecoveryCatalogActionFacts(runTranscriptResetGeneration: generation + 1)
        ] {
            XCTAssertEqual(vm.recoveryRunActions(session: session, status: .interrupted, facts: facts), [.reconcileHistory], "\(facts)")
        }
    }

    // MARK: Cold Codex recovery observation (coordinator transaction)

    private func codexObservation(
        turnID: String?,
        terminal: CodexRecoveryObservation.Terminal,
        items: [CodexRecoveryObservation.Item]?
    ) -> CodexRecoveryObservation {
        CodexRecoveryObservation(
            threadID: "thread-c",
            turnID: turnID,
            terminal: terminal,
            abortDetail: nil,
            items: items,
            source: .turnsList,
            transportGeneration: 1
        )
    }

    /// The existing producer harness as an idle Codex session after a relaunch (no controller), its
    /// factory handing out `controllers` in order and recording every creation.
    private func makeColdCodexHarness(
        windowID: Int,
        controllers: [LifecycleNoopCodexController]
    ) async throws -> (ProducerHarness, CodexObservationFactoryLog) {
        let log = CodexObservationFactoryLog(controllers)
        let harness = try await makeProducerHarness(windowID: windowID, codexFactory: { runID, _, _, workspacePath, permissionProfile, sessionProfile, taskLabelKind, _ in
            log.make(runID: runID, workspacePath: workspacePath, permissionProfile: permissionProfile, sessionProfile: sessionProfile, taskLabelKind: taskLabelKind)
        })
        harness.session.selectedAgent = .codexExec
        harness.session.codexConversationID = "thread-c"
        XCTAssertNil(harness.session.codexController, "cold: no controller after a relaunch")
        return (harness, log)
    }

    private func reconcileAction(_ harness: ProducerHarness, runAttemptID: UUID?) -> AgentRecoveryAction {
        AgentRecoveryAction(
            actionID: UUID(),
            itemKey: AgentRecoveryCardKey(kind: .run, incarnationID: harness.lane.binding.incarnationID, transcriptResetGeneration: 0, entityID: "run"),
            kindRaw: AgentRecoveryActionKind.reconcileOnly.rawValue,
            expectedRevision: nil,
            incarnationID: harness.lane.binding.incarnationID,
            transcriptResetGeneration: harness.lane.binding.transcriptResetGeneration,
            sourceIntentIDs: [],
            sourceRunAttemptID: runAttemptID,
            sourceInteractionID: nil,
            target: harness.viewModel.recoveryActionTarget(for: harness.session),
            text: nil,
            plannedUserItemID: nil,
            appInstanceID: UUID(),
            reservedAt: AgentRecoveryTimestamp(Date())
        )
    }

    /// Cold relaunch: reconcile creates exactly one temporary controller through the existing
    /// factory (correlated by the action ID only), observes under the explicit durable scope, joins
    /// its shutdown, and never installs it, sets a run, or starts/resumes a thread. A verified
    /// completion is kept even when its items cannot be projected; a missing turn is unconfirmed.
    func testColdCodexReconcileObservesThroughATemporaryControllerAndJoinsItsCleanup() async throws {
        struct Row {
            let name: String
            let observed: (String) -> CodexRecoveryObservation
            let expected: (UUID) -> AgentRecoveryReconcileResult
        }
        let rows: [Row] = [
            Row(
                name: "completed-unsupported-items",
                observed: { _ in self.codexObservation(turnID: "turn-c", terminal: .completed, items: nil) },
                expected: { .imported(completion: .confirmed(runAttemptID: $0), rowCount: 0) }
            ),
            Row(
                name: "missing-turn",
                observed: { _ in self.codexObservation(turnID: nil, terminal: .unconfirmed, items: nil) },
                expected: { _ in .nothingImported("Codex has no matching record of the interrupted turn.") }
            ),
            Row(
                // 9-live R2: the turn was found; its items can't be imported. Still an
                // unconfirmed observation (`nothingImported`, not `blocked`), so Continue proceeds.
                name: "interrupted-unsupported-items",
                observed: { _ in self.codexObservation(turnID: "turn-c", terminal: .interrupted, items: nil) },
                expected: { _ in .nothingImported("Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported.") }
            )
        ]
        for (index, row) in rows.enumerated() {
            let recorder = LifecycleRecorder()
            let controller = LifecycleNoopCodexController(recorder: recorder)
            controller.lifecycleLabel = "obs"
            controller.joinsRetirementBeforeSuccessor = true
            controller.recoveryObservationOutcome = .success(row.observed(row.name))
            let (harness, log) = try await makeColdCodexHarness(windowID: 4980 + index, controllers: [controller])
            let runAttemptID = UUID()
            let action = reconcileAction(harness, runAttemptID: runAttemptID)
            let itemsBefore = harness.session.items.map(\.id)
            let runIDBefore = harness.session.runID

            let result = await harness.viewModel.reconcileRecoveryHistory(action, session: harness.session, lane: harness.lane, codexTurnID: "turn-c")

            XCTAssertEqual(result, row.expected(runAttemptID), row.name)
            XCTAssertEqual(log.runIDs, [action.actionID], "\(row.name): one creation, correlated by the action ID only")
            let scope = AgentRuntimeSessionScope.session(AgentRuntimeSessionAssociation(
                lifecycle: harness.lane.binding,
                runAttemptID: runAttemptID,
                processRunID: nil
            ))
            XCTAssertEqual(controller.observationOwners, [scope], "\(row.name): explicit durable scope, no process run")
            XCTAssertEqual(recorder.events, ["codex:observe:obs", "codex:shutdown", "codex:shutdown-complete:obs"], row.name)
            XCTAssertTrue(controller.startReferences.isEmpty, "\(row.name): no thread start or resume")
            XCTAssertTrue(controller.sentTexts.isEmpty, row.name)
            XCTAssertNil(harness.session.codexController, "\(row.name): never installed on the session")
            XCTAssertEqual(harness.session.runID, runIDBefore, row.name)
            XCTAssertNil(harness.session.codexEventTask, row.name)
            // The shutdown already completed before the result; the retained retirement only
            // drops its entry on a later hop, and joining it performs nothing further.
            await harness.session.joinRuntimeRetirements()
            XCTAssertEqual(recorder.events, ["codex:observe:obs", "codex:shutdown", "codex:shutdown-complete:obs"], "\(row.name): cleanup joined")
            XCTAssertFalse(harness.session.hasPendingRuntimeRetirements, row.name)
            XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "\(row.name): zero transcript rows")
        }
    }

    /// Step 9-check through the real Reconcile (cold Codex, temporary controller): history confirms
    /// the interrupted attempt's turn finished and its rows are saved, so Check reports the card
    /// resolved from the runner's typed result. 9-live R2: the observed turn is the one recorded on
    /// the run attempt, with no span naming it and with a span naming a different turn (record wins).
    func testCheckReportsAConfirmedAndSavedCodexCompletionAsResolved() async throws {
        for (index, spanTurnID) in [nil, "turn-old"].enumerated() {
            let name = "span \(spanTurnID ?? "none")"
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            controller.joinsRetirementBeforeSuccessor = true
            controller.recoveryObservationOutcome = .success(codexObservation(
                turnID: "turn-c",
                terminal: .completed,
                items: [.init(nativeItemID: "item-1", kind: .agentMessage, text: "Done.")]
            ))
            let (harness, _) = try await makeColdCodexHarness(windowID: 5070 + index, controllers: [controller])
            let viewModel = harness.viewModel
            let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
            let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
            let turnID = UUID()
            harness.session.transcript = AgentTranscript(turns: [AgentTranscriptTurn(
                id: turnID,
                request: AgentTranscriptRequestAnchor(from: AgentChatItem.user("Do it")),
                responseSpans: [AgentTranscriptProviderResponseSpan(providerTurnID: spanTurnID, startedAt: Date(), activities: [])],
                startedAt: Date()
            )])
            let ownership = RecoveryTestSupport.ownership(sessionID: sessionID)
            _ = try await harness.lane.ensureRunAttempt(
                ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: harness.session.selectedAgent.rawValue
            ).get()
            _ = try await harness.lane.recordRunProviderTurn(ownership: ownership, providerTurnID: "turn-c").get()
            await harness.lane.recordTerminalEvidence(
                RecoveryTestSupport.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
                transcriptTurnID: turnID
            ).value
            let itemID = "turn-\(sessionID.uuidString)-\(turnID.uuidString)"
            let listed = await RecoveryTestSupport.eventually { coordinator.catalog.item(id: itemID)?.attention == .informational }
            XCTAssertTrue(listed, name)
            let itemCountBefore = harness.session.items.count
            let rows = viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: harness.session)

            let task = try XCTUnwrap(viewModel.startRecoveryCheck(rows: rows))
            let result = await task.value
            let status = try XCTUnwrap(result)
            let entry = try XCTUnwrap(status.entries.first { $0.itemID == itemID })
            XCTAssertEqual(controller.observedExpectedTurnIDs, ["turn-c"], "\(name): the recorded turn is observed")
            XCTAssertEqual(entry.outcome, .resolved("Provider history shows the turn finished."), name)
            XCTAssertGreaterThan(harness.session.items.count, itemCountBefore, "\(name): the observed rows were imported")
            XCTAssertTrue(controller.sentTexts.isEmpty, "\(name): nothing was sent")
            XCTAssertTrue(controller.startReferences.isEmpty, "\(name): no thread start or resume")
        }
    }

    /// 9-live R2 round 1: a run whose recorded turn was cleared (a non-user turn became
    /// authoritative) never falls back to a span naming an older turn: Check doesn't ask Codex for
    /// it, imports nothing and doesn't report the run resolved.
    func testCheckNeverObservesTheSpanTurnAfterTheRecordedTurnWasCleared() async throws {
        let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
        controller.joinsRetirementBeforeSuccessor = true
        controller.recoveryObservationOutcome = .success(codexObservation(
            turnID: "turn-old",
            terminal: .completed,
            items: [.init(nativeItemID: "item-1", kind: .agentMessage, text: "Done.")]
        ))
        let (harness, _) = try await makeColdCodexHarness(windowID: 5072, controllers: [controller])
        let viewModel = harness.viewModel
        let coordinator = try XCTUnwrap(viewModel.recoveryCoordinator)
        let sessionID = try XCTUnwrap(harness.session.activeAgentSessionID)
        let turnID = UUID()
        harness.session.transcript = AgentTranscript(turns: [AgentTranscriptTurn(
            id: turnID,
            request: AgentTranscriptRequestAnchor(from: AgentChatItem.user("Do it")),
            responseSpans: [AgentTranscriptProviderResponseSpan(providerTurnID: "turn-old", startedAt: Date(), activities: [])],
            startedAt: Date()
        )])
        let ownership = RecoveryTestSupport.ownership(sessionID: sessionID)
        _ = try await harness.lane.ensureRunAttempt(
            ownership: ownership, processRunID: nil, transcriptTurnID: turnID, providerKindRaw: harness.session.selectedAgent.rawValue
        ).get()
        _ = try await harness.lane.recordRunProviderTurn(ownership: ownership, providerTurnID: nil).get()
        await harness.lane.recordTerminalEvidence(
            RecoveryTestSupport.terminalCommit(ownership: ownership, state: .failed, cause: .providerProcessLost),
            transcriptTurnID: turnID
        ).value
        let itemID = "turn-\(sessionID.uuidString)-\(turnID.uuidString)"
        let listed = await RecoveryTestSupport.eventually { coordinator.catalog.item(id: itemID) != nil }
        XCTAssertTrue(listed)
        let itemCountBefore = harness.session.items.count
        let rows = viewModel.recoveryNeedsAttentionRows(includeDismissed: false, activeSession: harness.session)

        let task = try XCTUnwrap(viewModel.startRecoveryCheck(rows: rows))
        let result = await task.value
        let status = try XCTUnwrap(result)
        let entry = try XCTUnwrap(status.entries.first { $0.itemID == itemID })
        XCTAssertEqual(controller.observedExpectedTurnIDs, [], "the span's older turn is never observed")
        XCTAssertNotEqual(entry.outcome, .resolved("Provider history shows the turn finished."))
        XCTAssertEqual(harness.session.items.count, itemCountBefore, "nothing was imported")
        XCTAssertTrue(controller.sentTexts.isEmpty, "nothing was sent")
    }

    /// Review A P1-04 / B F1: live Codex output already in the conversation has no native mapping, so
    /// projected observation rows that could duplicate it are withheld entirely (zero rows, zero
    /// ledger writes), while a confirmed completion stays honest. Without canonical output after the
    /// turn's user item the same rows import.
    func testCodexOverlappingCanonicalOutputImportsZeroRowsAndKeepsCompletion() async throws {
        struct Row {
            let name: String
            let terminal: CodexRecoveryObservation.Terminal
            let liveOutput: Bool
            let expected: (UUID) -> AgentRecoveryReconcileResult
        }
        let rows: [Row] = [
            Row(
                name: "completed-overlap",
                terminal: .completed,
                liveOutput: true,
                expected: { .imported(completion: .confirmed(runAttemptID: $0), rowCount: 0) }
            ),
            Row(
                name: "interrupted-overlap",
                terminal: .interrupted,
                liveOutput: true,
                expected: { _ in .nothingImported(AgentModeViewModel.recoveryCodexOverlapText) }
            ),
            Row(
                name: "completed-no-overlap",
                terminal: .completed,
                liveOutput: false,
                expected: { .imported(completion: .confirmed(runAttemptID: $0), rowCount: -1) }
            )
        ]
        for (index, row) in rows.enumerated() {
            let controller = LifecycleNoopCodexController(recorder: LifecycleRecorder())
            controller.joinsRetirementBeforeSuccessor = true
            controller.recoveryObservationOutcome = .success(codexObservation(
                turnID: "turn-c",
                terminal: row.terminal,
                items: [.init(nativeItemID: "item-1", kind: .agentMessage, text: "Done.")]
            ))
            let (harness, _) = try await makeColdCodexHarness(windowID: 5060 + index, controllers: [controller])
            let userItem = AgentChatItem.user("Do it")
            let live = AgentChatItem.assistant("Done.")
            let turnID = UUID()
            harness.session.transcript = AgentTranscript(turns: [AgentTranscriptTurn(
                id: turnID,
                request: AgentTranscriptRequestAnchor(from: userItem),
                responseSpans: [AgentTranscriptProviderResponseSpan(
                    startedAt: Date(),
                    activities: row.liveOutput ? [AgentTranscriptActivity(from: live)] : []
                )],
                startedAt: Date()
            )])
            let itemsBefore = harness.session.items.map(\.id)
            let ledgerBefore = harness.session.providerHistoryRecovery
            let runAttemptID = UUID()

            let result = await harness.viewModel.reconcileRecoveryHistory(
                reconcileAction(harness, runAttemptID: runAttemptID),
                session: harness.session,
                lane: harness.lane,
                codexTurnID: "turn-c",
                runTurnID: turnID
            )

            if case let .imported(completion, rowCount) = row.expected(runAttemptID), rowCount < 0 {
                // Control: whatever the projection yields, it imports (and completion is kept).
                guard case let .imported(actualCompletion, actualRows) = result else {
                    XCTFail("\(row.name): expected an import, got \(result)")
                    continue
                }
                XCTAssertEqual(actualCompletion, completion, row.name)
                XCTAssertGreaterThan(actualRows, 0, row.name)
                XCTAssertEqual(harness.session.items.count, itemsBefore.count + actualRows, "\(row.name): the observed output imports")
                continue
            }
            XCTAssertEqual(result, row.expected(runAttemptID), row.name)
            if row.liveOutput {
                XCTAssertEqual(harness.session.items.map(\.id), itemsBefore, "\(row.name): zero rows appended")
                XCTAssertEqual(harness.session.providerHistoryRecovery, ledgerBefore, "\(row.name): zero ledger writes")
            }
        }
    }

    /// Ownership cuts of the coordinator transaction: pending retirement, cleanup before the result,
    /// warm borrow, incompatible warm controller, busy session, a policy change or cancellation
    /// while observing.
    func testCodexObservationTransactionOwnershipCuts() async throws {
        let completed = codexObservation(turnID: "turn-c", terminal: .completed, items: nil)
        func observe(_ harness: ProducerHarness, isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> CodexRecoveryObservation {
            try await harness.viewModel.codexCoordinator.observeRecovery(
                session: harness.session,
                actionID: UUID(),
                threadID: "thread-c",
                expectedTurnID: "turn-c",
                sourceRunAttemptID: nil,
                timeout: nil,
                isCurrent: isCurrent
            )
        }

        // A prior retirement on the tab is joined before anything is created; the result is held
        // until the temporary controller's shutdown completed.
        do {
            let recorder = LifecycleRecorder()
            let cold = LifecycleNoopCodexController(recorder: recorder)
            cold.lifecycleLabel = "cold"
            cold.joinsRetirementBeforeSuccessor = true
            cold.recoveryObservationOutcome = .success(completed)
            let shutdownGate = LifecycleAsyncGate()
            cold.shutdownGate = shutdownGate
            let (harness, log) = try await makeColdCodexHarness(windowID: 4990, controllers: [cold])
            let retirementGate = LifecycleAsyncGate()
            harness.session.retainRuntimeRetirement { await retirementGate.arriveAndWait() }
            let finished = LifecycleCompletionFlag()
            let observing = Task { @MainActor in
                defer { Task { await finished.set() } }
                return try await observe(harness)
            }
            await retirementGate.waitUntilArrived()
            XCTAssertEqual(log.runIDs.count, 0, "zero creations while a retirement is pending")
            await retirementGate.release()
            await shutdownGate.waitUntilArrived()
            XCTAssertEqual(log.runIDs.count, 1)
            let finishedDuringCleanup = await finished.isSet
            XCTAssertFalse(finishedDuringCleanup, "no result while the cleanup is unresolved")
            await shutdownGate.release()
            let observation = try await observing.value
            XCTAssertEqual(observation, completed)
            XCTAssertEqual(recorder.events, ["codex:observe:cold", "codex:shutdown", "codex:shutdown-complete:cold"])
        }

        // Warm: a compatible live controller is borrowed unchanged (zero creations, zero shutdowns);
        // an incompatible one is refused as stale and left alone.
        do {
            let probeRecorder = LifecycleRecorder()
            let probe = LifecycleNoopCodexController(recorder: probeRecorder)
            probe.recoveryObservationOutcome = .success(completed)
            let warmRecorder = LifecycleRecorder()
            let warm = LifecycleNoopCodexController(recorder: warmRecorder)
            warm.lifecycleLabel = "warm"
            warm.recoveryObservationOutcome = .success(completed)
            let (harness, log) = try await makeColdCodexHarness(windowID: 4991, controllers: [probe])
            _ = try await observe(harness)
            let inputs = try XCTUnwrap(log.calls.first)
            let session = harness.session
            session.codexController = warm
            session.codexControllerWorkspacePath = inputs.workspacePath
            session.codexControllerPermissionProfile = inputs.permissionProfile
            session.codexControllerSessionProfile = inputs.sessionProfile
            session.codexControllerTaskLabelKind = inputs.taskLabelKind

            let borrowed = try await observe(harness)
            XCTAssertEqual(borrowed, completed)
            XCTAssertEqual(log.calls.count, 1, "warm: zero creations")
            XCTAssertEqual(warmRecorder.events, ["codex:observe:warm"], "warm: never shut down")
            XCTAssertTrue(session.codexController === warm, "warm: left in place")

            session.codexControllerWorkspacePath = "/elsewhere"
            do {
                _ = try await observe(harness)
                XCTFail("an incompatible controller is never borrowed")
            } catch {
                XCTAssertEqual(error as? CodexRecoveryObservationError, .staleContext)
            }
            XCTAssertEqual(log.calls.count, 1, "incompatible: never silently replaced")
            XCTAssertEqual(warmRecorder.events, ["codex:observe:warm"], "incompatible: never invalidated")
            XCTAssertTrue(session.codexController === warm)

            session.runState = .running
            do {
                _ = try await observe(harness)
                XCTFail("a busy session acquires nothing")
            } catch {
                XCTAssertEqual(error as? CodexRecoveryObservationError, .sessionBusy)
            }
            session.runState = .idle
        }

        // A policy change or a cancellation while the cold observation awaits: nothing usable is
        // returned, and the temporary controller's cleanup is still joined.
        enum Cut: CaseIterable { case policyChanged, targetReplaced, cancelled }
        for (index, cut) in Cut.allCases.enumerated() {
            let recorder = LifecycleRecorder()
            let cold = LifecycleNoopCodexController(recorder: recorder)
            cold.lifecycleLabel = "cut"
            cold.joinsRetirementBeforeSuccessor = true
            cold.recoveryObservationOutcome = .success(completed)
            let gate = LifecycleAsyncGate()
            cold.observationGate = gate
            let (harness, _) = try await makeColdCodexHarness(windowID: 4992 + index, controllers: [cold])
            let current = CodexObservationCurrentFlag()
            let observing = Task { @MainActor in try await observe(harness, isCurrent: { current.value }) }
            await gate.waitUntilArrived()
            switch cut {
            case .policyChanged:
                harness.session.permissionProfile = harness.session.permissionProfile == .mcpSafeDefaults ? .userConfigured : .mcpSafeDefaults
            case .targetReplaced:
                current.value = false
            case .cancelled:
                observing.cancel()
            }
            await gate.release()
            do {
                _ = try await observing.value
                XCTFail("\(cut): nothing usable")
            } catch {
                switch cut {
                case .policyChanged, .targetReplaced:
                    XCTAssertEqual(error as? CodexRecoveryObservationError, .staleContext, "\(cut)")
                case .cancelled:
                    XCTAssertTrue(error is CancellationError, "\(cut): \(error)")
                }
            }
            XCTAssertEqual(recorder.events, ["codex:observe:cut", "codex:shutdown", "codex:shutdown-complete:cut"], "\(cut): cleanup joined")
            XCTAssertNil(harness.session.codexController, "\(cut)")
            await harness.session.joinRuntimeRetirements()
            XCTAssertEqual(recorder.events.count, 3, "\(cut): nothing left to clean up")
            XCTAssertFalse(harness.session.hasPendingRuntimeRetirements, "\(cut)")
        }
    }
}

/// The `isCurrent` answer a cold Codex observation test flips mid-observation.
@MainActor
private final class CodexObservationCurrentFlag {
    var value = true
}

/// Records the coordinator factory's creations for the cold Codex observation tests.
private final class CodexObservationFactoryLog {
    struct Call {
        let runID: UUID
        let workspacePath: String?
        let permissionProfile: AgentProviderPermissionProfile
        let sessionProfile: AgentSessionProfile
        let taskLabelKind: AgentModelCatalog.TaskLabelKind?
    }

    private let controllers: [LifecycleNoopCodexController]
    private(set) var calls: [Call] = []

    var runIDs: [UUID] {
        calls.map(\.runID)
    }

    init(_ controllers: [LifecycleNoopCodexController]) {
        self.controllers = controllers
    }

    func make(
        runID: UUID,
        workspacePath: String?,
        permissionProfile: AgentProviderPermissionProfile,
        sessionProfile: AgentSessionProfile,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?
    ) -> any CodexSessionControlling {
        calls.append(Call(runID: runID, workspacePath: workspacePath, permissionProfile: permissionProfile, sessionProfile: sessionProfile, taskLabelKind: taskLabelKind))
        return controllers[min(calls.count - 1, controllers.count - 1)]
    }
}

private final class ReconciliationRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ method: String) {
        lock.lock()
        recorded.append(method)
        lock.unlock()
    }
}
