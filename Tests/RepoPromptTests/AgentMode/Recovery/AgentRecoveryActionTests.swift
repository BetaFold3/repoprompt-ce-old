import Foundation
@testable import RepoPromptAgentCore
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Lossless restart Phase 4 durable recovery actions, the history cursor CAS, and the action
/// runner (gate → reservation → fence → one normal dispatch → outcome), over a real recovery lane
/// (temporary store behind the real session data service gate). Performers are injected; nothing
/// reaches a provider.
@MainActor
final class AgentRecoveryActionTests: XCTestCase {
    private var fixture: RecoveryLaneFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await RecoveryLaneFixture.make("AgentRecoveryActionTests")
    }

    override func tearDown() async throws {
        fixture?.tearDown()
        fixture = nil
        try await super.tearDown()
    }

    private var lane: AgentRecoverySessionLane {
        fixture.lane
    }

    private func runKey(_ entity: UUID = UUID()) -> AgentRecoveryCardKey {
        AgentRecoveryCardKey(
            kind: .run,
            incarnationID: lane.binding.incarnationID,
            transcriptResetGeneration: lane.binding.transcriptResetGeneration,
            entityID: entity.uuidString
        )
    }

    private struct UnexpectedPreservedRecord: Error {}

    /// An unreadable (preserved) record is a fixture failure, never a skip.
    private func record() async throws -> AgentRecoveryRecord? {
        switch try await lane.readRecord().get() {
        case let .supported(record):
            return record
        case .absent:
            return nil
        case .preserved:
            XCTFail("unexpected preserved record")
            throw UnexpectedPreservedRecord()
        }
    }

    private func revision() async throws -> AgentRecoveryRecordRevision? {
        try await record()?.revision
    }

    private let target = AgentRecoveryActionTarget(providerKindRaw: "claudeCode", providerConversationID: "conv-1")

    private func continuation(
        key: AgentRecoveryCardKey,
        actionID: UUID = UUID(),
        text: String = AgentRecoveryActionRequest.defaultContinuationText,
        expectedRevision: AgentRecoveryRecordRevision?,
        plannedUserItemID: UUID = UUID(),
        sourceRunAttemptID: UUID? = nil,
        supersedes: UUID? = nil,
        confirmsUncertainPrior: Bool = false
    ) -> AgentRecoveryActionRequest {
        AgentRecoveryActionRequest(
            actionID: actionID,
            itemKey: key,
            kind: .continueWithText,
            expectedRevision: expectedRevision,
            sourceRunAttemptID: sourceRunAttemptID,
            target: target,
            text: text,
            plannedUserItemID: plannedUserItemID,
            supersedesActionID: supersedes,
            confirmsUncertainPriorDelivery: confirmsUncertainPrior
        )
    }

    /// The same recovery root opened by a previous app launch (a different app instance ID).
    private func previousLaunchStore() -> AgentRecoveryStore {
        AgentRecoveryStore(
            rootURL: fixture.root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            appInstanceID: UUID()
        )
    }

    private func storeError(
        _ result: Result<AgentRecoveryActionReceipt, AgentRecoveryControllerFailure>
    ) -> AgentRecoveryStoreError? {
        if case let .failure(.store(error)) = result { return error }
        return nil
    }

    // MARK: Store

    func testReservationIsIdempotentAndConflictsWriteNothing() async throws {
        let key = runKey()
        let request = try await continuation(key: key, expectedRevision: revision())
        let first = try await lane.reserveRecoveryAction(request).get()
        XCTAssertEqual(first.disposition, .committed)
        XCTAssertNil(first.action.outcome)

        let repeated = try await lane.reserveRecoveryAction(request).get()
        XCTAssertEqual(repeated.disposition, .unchanged, "a repeated click joins its reservation")
        XCTAssertEqual(repeated.action, first.action)

        let changed = continuation(key: key, actionID: request.actionID, text: "other", expectedRevision: first.recordRevision)
        let changedResult = await lane.reserveRecoveryAction(changed)
        XCTAssertEqual(storeError(changedResult), .actionConflict(request.actionID))
        let second = continuation(key: key, expectedRevision: first.recordRevision)
        let secondResult = await lane.reserveRecoveryAction(second)
        XCTAssertEqual(storeError(secondResult), .actionConflict(request.actionID))
        let stale = continuation(key: runKey(), expectedRevision: nil)
        let staleResult = await lane.reserveRecoveryAction(stale)
        XCTAssertNotNil(storeError(staleResult), "a choice made against an older revision is refused")
        let actions = try await record()?.actions ?? []
        XCTAssertEqual(actions.map(\.actionID), [request.actionID])
    }

    func testOutcomeIsRecordedOnceAndOnlyANotDispatchedItemAcceptsANewChoice() async throws {
        let key = runKey()
        let request = try await continuation(key: key, expectedRevision: revision())
        _ = try await lane.reserveRecoveryAction(request).get()
        let completed = try await lane.completeRecoveryAction(actionID: request.actionID, outcome: .dispatched, reason: nil).get()
        XCTAssertEqual(completed.disposition, .committed)
        XCTAssertEqual(completed.action.outcome?.kind, .dispatched)
        let again = try await lane.completeRecoveryAction(actionID: request.actionID, outcome: .dispatched, reason: nil).get()
        XCTAssertEqual(again.disposition, .unchanged)
        let rewrite = await lane.completeRecoveryAction(actionID: request.actionID, outcome: .notDispatched, reason: "x")
        XCTAssertEqual(storeError(rewrite), .actionConflict(request.actionID), "outcomes are never rewritten")
        let missing = await lane.completeRecoveryAction(actionID: UUID(), outcome: .dispatched, reason: nil)
        XCTAssertNotNil(storeError(missing), "an unknown action is never completed")

        // Review B F3b: an item resolved by a send never takes a duplicate send (Reconcile stays).
        let duplicate = continuation(key: key, expectedRevision: completed.recordRevision)
        let duplicateResult = await lane.reserveRecoveryAction(duplicate)
        guard case .actionIneligible? = storeError(duplicateResult) else {
            return XCTFail("a dispatched item must refuse another send, got \(duplicateResult)")
        }
        let reconcile = try await AgentRecoveryActionRequest(
            actionID: UUID(),
            itemKey: key,
            kind: .reconcileOnly,
            expectedRevision: revision(),
            target: target
        )
        let reconcileReceipt = try await lane.reserveRecoveryAction(reconcile).get()
        XCTAssertEqual(reconcileReceipt.disposition, .committed, "Reconcile stays available on a resolved item")

        // An item whose choice sent nothing accepts a new explicit choice.
        let otherKey = runKey()
        let declined = try await continuation(key: otherKey, expectedRevision: revision())
        _ = try await lane.reserveRecoveryAction(declined).get()
        let notSent = try await lane.completeRecoveryAction(actionID: declined.actionID, outcome: .notDispatched, reason: "x").get()
        let next = continuation(key: otherKey, expectedRevision: notSent.recordRevision)
        let nextReceipt = try await lane.reserveRecoveryAction(next).get()
        XCTAssertEqual(nextReceipt.disposition, .committed)
    }

    func testParametersAreValidatedBeforeAnyWrite() async throws {
        let rev = try await revision()
        func ineligible(_ request: AgentRecoveryActionRequest) async -> Bool {
            let result = await lane.reserveRecoveryAction(request)
            if case .actionIneligible = storeError(result) { return true }
            return false
        }
        let blank = await ineligible(continuation(key: runKey(), text: "   ", expectedRevision: rev))
        XCTAssertTrue(blank)
        let reconcileWithText = await ineligible(AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: rev, target: target, text: "x"
        ))
        XCTAssertTrue(reconcileWithText, "reconciliation never sends input")
        let answerWithoutQuestion = await ineligible(AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .questionAnswerAsInput, expectedRevision: rev, target: target,
            text: "answer", plannedUserItemID: UUID()
        ))
        XCTAssertTrue(answerWithoutQuestion)
        let twoSaved = await ineligible(AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .sendSaved, expectedRevision: rev,
            sourceIntentIDs: [UUID(), UUID()], target: target
        ))
        XCTAssertTrue(twoSaved, "one saved message at a time")
        let vanished = await ineligible(AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .sendSaved, expectedRevision: rev,
            sourceIntentIDs: [UUID()], target: target
        ))
        XCTAssertTrue(vanished)
        let actionCount = try await record()?.actions.count ?? 0
        XCTAssertEqual(actionCount, 0)
    }

    func testSendSavedClaimsTheQueuedIntentAndJoinsAsNotHandedOff() async throws {
        let identity = try await fixture.queuedIdentity("saved message")
        let intentID = try XCTUnwrap(identity.intentID)
        let key = AgentRecoveryCardKey(
            kind: .savedInput,
            incarnationID: lane.binding.incarnationID,
            transcriptResetGeneration: lane.binding.transcriptResetGeneration,
            entityID: intentID.uuidString
        )
        let request = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: key, kind: .sendSaved, expectedRevision: revision(),
            sourceIntentIDs: [intentID], target: target
        )
        let receipt = try await lane.reserveRecoveryAction(request).get()
        XCTAssertEqual(receipt.disposition, .committed)
        let loaded = try await record()
        let current = try XCTUnwrap(loaded)
        XCTAssertEqual(current.join(receipt.action), .notHandedOff(intentID: intentID))
        XCTAssertEqual(current.intent(id: intentID)?.deliveryState, .queued, "a reservation never dispatches")
    }

    func testHistoryCursorAdvancesOnlyByCompareAndSwap() async throws {
        func cursor(_ importID: UUID, offset: UInt64) -> AgentRecoveryHistoryCursor {
            AgentRecoveryHistoryCursor(
                providerRaw: "claude",
                conversationID: "conv-1",
                importID: importID,
                file: AgentRecoveryHistoryFileIdentity(device: 1, inode: 2, birthSeconds: nil, birthNanoseconds: nil),
                completeLineOffset: offset,
                committedAt: AgentRecoveryTimestamp(Date(timeIntervalSince1970: 10))
            )
        }
        let first = UUID()
        let committed = try await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor(first, offset: 10)).get()
        XCTAssertEqual(committed.disposition, .committed)
        let repeated = try await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor(first, offset: 10)).get()
        XCTAssertEqual(repeated.disposition, .unchanged)
        let conflictingRepeat = await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor(first, offset: 11))
        XCTAssertEqual(conflictingRepeat.failureValue, .store(.historyCursorConflict))
        let wrongExpectation = await lane.commitHistoryCursor(expectedPreviousImportID: UUID(), cursor: cursor(UUID(), offset: 20))
        XCTAssertEqual(wrongExpectation.failureValue, .store(.historyCursorConflict), "a stale importer never moves the cursor")
        let second = UUID()
        let advanced = try await lane.commitHistoryCursor(expectedPreviousImportID: first, cursor: cursor(second, offset: 20)).get()
        XCTAssertEqual(advanced.disposition, .committed)
        let loaded = try await record()
        let stored = try XCTUnwrap(loaded?.historyCursor(providerRaw: "claude", conversationID: "conv-1"))
        XCTAssertEqual(stored.importID, second)
        XCTAssertEqual(stored.completeLineOffset, 20)
    }

    /// Step 4d2: the byte-prefix proof is part of a cursor's exact repeat (same import ID with a
    /// different proof, or none, conflicts), and the codec keeps a malformed stored proof verbatim
    /// as an unknown member (`nil`, never a proof) while a typed proof replaces it.
    func testHistoryCursorPrefixProofIsPartOfTheExactRepeatAndDecodesTolerantly() async throws {
        let proof = AgentSessionProviderHistoryRecovery.sha256Hex(Data("prefix".utf8))
        let file = AgentRecoveryHistoryFileIdentity(device: 1, inode: 2, birthSeconds: nil, birthNanoseconds: nil)
        func cursor(
            _ importID: UUID,
            conversationID: String = "conv-1",
            proof: String?,
            extras: AgentRecoveryExtras = [:]
        ) -> AgentRecoveryHistoryCursor {
            AgentRecoveryHistoryCursor(
                providerRaw: "claude", conversationID: conversationID, importID: importID, file: file, completeLineOffset: 10,
                prefixSHA256: proof, committedAt: AgentRecoveryTimestamp(Date(timeIntervalSince1970: 10)), extras: extras
            )
        }
        let importID = UUID()
        let committed = try await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor(importID, proof: proof)).get()
        XCTAssertEqual(committed.disposition, .committed)
        let repeated = try await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor(importID, proof: proof)).get()
        XCTAssertEqual(repeated.disposition, .unchanged)
        let altered = AgentSessionProviderHistoryRecovery.sha256Hex(Data("other".utf8))
        for different in [altered, nil] {
            let conflict = await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor(importID, proof: different))
            XCTAssertEqual(conflict.failureValue, .store(.historyCursorConflict), "same import ID, different proof")
        }
        let loaded = try await record()
        XCTAssertEqual(loaded?.historyCursor(providerRaw: "claude", conversationID: "conv-1")?.prefixSHA256, proof)

        // Malformed stored proofs survive a fresh store verbatim; a typed proof replaces a raw one.
        let malformed: [AgentRecoveryJSONValue] = [.string(proof.uppercased()), .string("short"), .number(5), .null, .object([:])]
        for (index, raw) in malformed.enumerated() {
            _ = try await lane.commitHistoryCursor(
                expectedPreviousImportID: nil,
                cursor: cursor(UUID(), conversationID: "raw-\(index)", proof: nil, extras: ["prefixSHA256": raw])
            ).get()
        }
        _ = try await lane.commitHistoryCursor(
            expectedPreviousImportID: nil,
            cursor: cursor(UUID(), conversationID: "typed", proof: proof, extras: ["prefixSHA256": .string("stale raw")])
        ).get()
        let reopened = AgentRecoveryStore(rootURL: fixture.root.appendingPathComponent("AgentRecovery/v1", isDirectory: true))
        let state = await reopened.read(sessionID: fixture.sessionID)
        let decoded = try XCTUnwrap(state.record)
        for (index, raw) in malformed.enumerated() {
            let stored = try XCTUnwrap(decoded.historyCursor(providerRaw: "claude", conversationID: "raw-\(index)"))
            XCTAssertNil(stored.prefixSHA256, "\(raw)")
            XCTAssertEqual(stored.extras["prefixSHA256"], raw, "\(raw) kept verbatim")
        }
        let typed = try XCTUnwrap(decoded.historyCursor(providerRaw: "claude", conversationID: "typed"))
        XCTAssertEqual(typed.prefixSHA256, proof)
        XCTAssertNil(typed.extras["prefixSHA256"])
        XCTAssertEqual(decoded.historyCursor(providerRaw: "claude", conversationID: "conv-1")?.prefixSHA256, proof)
    }

    func testActionsAndCursorsRoundTripThroughAFreshStore() async throws {
        let key = runKey()
        let request = try await continuation(key: key, expectedRevision: revision())
        _ = try await lane.reserveRecoveryAction(request).get()
        _ = try await lane.completeRecoveryAction(actionID: request.actionID, outcome: .notDispatched, reason: "kept").get()
        let cursor = AgentRecoveryHistoryCursor(
            providerRaw: "codex", conversationID: "thread-1", importID: UUID(), file: nil,
            completeLineOffset: 0, committedAt: AgentRecoveryTimestamp(Date(timeIntervalSince1970: 5))
        )
        _ = try await lane.commitHistoryCursor(expectedPreviousImportID: nil, cursor: cursor).get()
        let reopened = AgentRecoveryStore(rootURL: fixture.root.appendingPathComponent("AgentRecovery/v1", isDirectory: true))
        let state = await reopened.read(sessionID: fixture.sessionID)
        let decoded = try XCTUnwrap(state.record)
        XCTAssertEqual(decoded.action(id: request.actionID)?.outcome?.reason, "kept")
        XCTAssertEqual(decoded.action(id: request.actionID)?.plannedUserItemID, request.plannedUserItemID)
        XCTAssertEqual(decoded.historyCursor(providerRaw: "codex", conversationID: "thread-1"), cursor)
    }

    // MARK: Runner

    private final class Calls {
        var dispatch = 0
        var reconcile = 0
        var dispatchedTexts: [String?] = []
    }

    private func performers(
        _ calls: Calls,
        dispatch: AgentRecoveryDispatchResult = .dispatched,
        reconcile: AgentRecoveryReconcileResult? = nil
    ) -> AgentRecoveryActionPerformers {
        var reconcilePerformer: (@MainActor (AgentRecoveryAction) async -> AgentRecoveryReconcileResult)?
        if let reconcile {
            reconcilePerformer = { _ in
                calls.reconcile += 1
                return reconcile
            }
        }
        return AgentRecoveryActionPerformers(reconcile: reconcilePerformer) { [self] action, authorization in
            calls.dispatch += 1
            calls.dispatchedTexts.append(action.text)
            await Task.yield()
            guard case .dispatched = dispatch else { return dispatch }
            return await handOff(action, authorization)
        }
    }

    private struct HandOffFailed: Error {}

    /// The normal dispatch seams an explicit action's payload passes (review A P1-01): the planned
    /// item is admitted once under the action's coordinator-issued authorization (Send saved
    /// dispatches its source intent instead), its one delivery attempt is committed under that
    /// authorization, and it enters the provider boundary. `.notDispatched` when any seam refuses.
    private func handOff(
        _ action: AgentRecoveryAction,
        _ authorization: AgentRecoveryActionAuthorization
    ) async -> AgentRecoveryDispatchResult {
        do {
            let intentID: UUID
            if let sourceIntentID = authorization.sourceIntentID {
                intentID = sourceIntentID
            } else {
                let itemID = try XCTUnwrap(action.plannedUserItemID)
                let admitted = try await lane.admitQueued(AgentRecoveryAdmission(
                    binding: lane.binding,
                    userItemID: itemID,
                    origin: .followUp,
                    target: .session,
                    original: RecoveryTestSupport.content(action.text ?? "continue"),
                    actionAuthorization: authorization
                )).get()
                intentID = try XCTUnwrap(AgentQueuedInputIdentity(receipt: admitted.receipt).intentID)
            }
            let ownership = RecoveryTestSupport.ownership(sessionID: fixture.sessionID)
            _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: UUID(), providerKindRaw: nil).get()
            let attemptID = UUID()
            _ = try await lane.beginDispatch(
                intentID: intentID,
                attempt: AgentRecoveryAttemptStart(attemptID: attemptID, runAttemptID: ownership.attemptID),
                authorization: .liveQueue,
                action: authorization
            ).get()
            guard lane.permitsHandoff(attemptIDs: [attemptID], action: authorization) else { throw HandOffFailed() }
            fixture.coordinator.noteRecoveryActionHandoffBegan(authorization, attemptIDs: [attemptID])
            return .dispatched
        } catch {
            return .notDispatched("handoff refused: \(error)")
        }
    }

    private let qualified = AgentRecoveryActionQualification(
        sameConversationResume: true,
        historyReconciliation: true,
        freshClaudeConversation: true,
        safeRestart: true
    )

    func testProductionQualificationAndInactiveRegistrationReserveNothing() async throws {
        // Step 9-activation-a: production stays `.off` until the live checks (9-flip).
        XCTAssertEqual(AgentRecoveryActivation.production, .off)
        XCTAssertEqual(AgentRecoveryActivation.production.actions, AgentRecoveryActionQualification())
        for kind in AgentRecoveryActionKind.allCases {
            XCTAssertFalse(AgentRecoveryActivation.production.actions.allows(kind), "\(kind) must stay OFF in production")
        }
        XCTAssertFalse(AgentRecoveryActivation.production.actions.safeRestart)
        let calls = Calls()
        let production = AgentRecoveryActionRunner(activation: .production, registrationActive: { true })
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        let disabled = await production.perform(request, lane: lane, performers: performers(calls))
        XCTAssertEqual(disabled, .disabled(AgentRecoveryActionRunner.disabledText))
        let inactive = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { false })
        XCTAssertFalse(inactive.isAvailable(.continueWithText))
        let refused = await inactive.perform(request, lane: lane, performers: performers(calls))
        XCTAssertEqual(refused, .disabled(AgentRecoveryActionRunner.registrationInactiveText))
        XCTAssertEqual(calls.dispatch, 0)
        let actionCount = try await record()?.actions.count ?? 0
        XCTAssertEqual(actionCount, 0)
    }

    /// O32 provider gate (Step 9-activation-a): under `.claudeAndCodex`, every recovery choice for a
    /// provider whose ownership and history aren't qualified refuses before the coordinator hold and
    /// any reservation (zero writes, nothing reconciled or sent), with the named reason, even when a
    /// history performer is supplied. Check reports that refusal as could not check.
    func testUnqualifiedProvidersRefuseEveryChoiceBeforeAnyReservation() async throws {
        let runner = AgentRecoveryActionRunner(activation: .claudeAndCodex, registrationActive: { true })
        let calls = Calls()
        let unqualified: [AgentProviderKind] = [.openCode, .cursor, .ohMyPi, .claudeCodeGLM, .kimiCode, .customClaudeCompatible]
        XCTAssertEqual(
            Set(unqualified),
            Set(AgentProviderKind.allCases).subtracting([.claudeCode, .codexExec]),
            "every Agent Mode provider other than Claude Code and Codex"
        )
        let revisionBefore = try await revision()
        for kind in unqualified {
            let target = AgentRecoveryActionTarget(providerKindRaw: kind.rawValue, providerConversationID: "conv-\(kind.rawValue)")
            for actionKind in AgentRecoveryActionKind.allCases {
                let request = AgentRecoveryActionRequest(
                    actionID: UUID(),
                    itemKey: runKey(),
                    kind: actionKind,
                    expectedRevision: revisionBefore,
                    sourceIntentIDs: actionKind == .sendSaved ? [UUID()] : [],
                    sourceRunAttemptID: UUID(),
                    target: target,
                    text: actionKind.dispatches && actionKind != .sendSaved ? "continue" : nil,
                    plannedUserItemID: actionKind.dispatches && actionKind != .sendSaved ? UUID() : nil
                )
                let result = await runner.perform(
                    request,
                    lane: lane,
                    performers: performers(calls, reconcile: .imported(completion: .unconfirmed, rowCount: 1))
                )
                let expected = AgentRecoveryActionRunner.unqualifiedProviderText(kind.displayName)
                if actionKind == .continueInNewConversation {
                    // Not part of this activation at all: refused by the capability gate first.
                    XCTAssertEqual(result, .disabled(AgentRecoveryActionRunner.disabledText))
                } else {
                    XCTAssertEqual(result, .disabled(expected), "\(kind) \(actionKind)")
                    XCTAssertEqual(
                        AgentRecoveryCheckReconcile.performed(result, observed: nil).outcome,
                        .couldNotCheck(expected),
                        "Check reports the refusal as could not check"
                    )
                }
            }
        }
        XCTAssertEqual(calls.reconcile, 0, "nothing reconciled")
        XCTAssertEqual(calls.dispatch, 0, "nothing sent")
        let revisionAfter = try await revision()
        XCTAssertEqual(revisionAfter, revisionBefore, "zero writes")
        let actions = try await record()?.actions ?? []
        XCTAssertTrue(actions.isEmpty, "nothing reserved")
        XCTAssertEqual(
            AgentRecoveryActionRunner.unqualifiedProviderText("OpenCode"),
            "Recovery for OpenCode isn't qualified yet: RepoPrompt can't verify its process ownership and provider history. Nothing was sent."
        )
        // A target naming no known provider refuses too.
        let unnamed = AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revisionBefore,
            target: AgentRecoveryActionTarget(providerKindRaw: nil, providerConversationID: "conv-x")
        )
        let unnamedResult = await runner.perform(unnamed, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(unnamedResult, .disabled(AgentRecoveryActionRunner.unqualifiedProviderText("this provider")))
    }

    /// 9-flip gate (launch-authority review B L1): every Agent Mode provider kind is pinned to the
    /// launch pairs its managed launchers build, and under `.claudeAndCodex` only Claude Code
    /// (standard) and Codex register; every other kind launches unregistered, carries no run-start
    /// registration mark, and its recovery choices refuse with the named reason. The pair table
    /// mirrors the launch sites (`ClaudeNativeProcessSessionController` runtimeFamily: native for
    /// standard, compatible otherwise; `ClaudeCodeAgentProvider`, `ClaudeCodeProvider` and
    /// `ClaudeCLIModelDiscoveryProbe`: headless; `CodexExecAgentProvider` and `CodexAppServerClient`;
    /// `ACPAgentSessionController`); it must equal `supportedPairs` for the kind's actual provider, so
    /// no launcher can spawn a covered provider through a family the run-start mark doesn't check.
    func testEveryProviderKindLaunchPairIsPinnedAndOnlyClaudeStandardAndCodexRegister() async throws {
        func key(_ family: AgentRuntimeFamily, _ provider: AgentRuntimeProvider) -> String {
            family.rawValue + "|" + provider.rawValue
        }
        let launchPairs: [AgentProviderKind: [(AgentRuntimeFamily, AgentRuntimeProvider)]] = [
            .claudeCode: [(.claudeNative, .claude(.standard)), (.claudeHeadless, .claude(.standard))],
            .claudeCodeGLM: [(.claudeCompatible, .claude(.glm)), (.claudeHeadless, .claude(.glm))],
            .kimiCode: [(.claudeCompatible, .claude(.kimi)), (.claudeHeadless, .claude(.kimi))],
            .customClaudeCompatible: [
                (.claudeCompatible, .claude(.customCompatible)), (.claudeHeadless, .claude(.customCompatible))
            ],
            .codexExec: [(.codexAppServer, .codex), (.codexExec, .codex)],
            .openCode: [(.acp, .acp(.openCode))],
            .cursor: [(.acp, .acp(.cursor))],
            .ohMyPi: [(.acp, .acp(.ohMyPi))]
        ]
        XCTAssertEqual(Set(launchPairs.keys), Set(AgentProviderKind.allCases), "every provider kind is pinned")
        let supported = Set(AgentRuntimeQualification.supportedPairs.map { key($0.family, $0.provider) })
        XCTAssertEqual(
            Set(launchPairs.values.flatMap(\.self).map { key($0.0, $0.1) }),
            supported,
            "the pinned launch pairs are exactly the supported pairs"
        )

        let activation = AgentRecoveryActivation.claudeAndCodex
        let registry = AgentProcessRegistry(store: previousLaunchStore(), qualification: activation.runtime, system: .live)
        XCTAssertTrue(registry.isAnyPairRegistered)
        let authority = AgentRuntimeLaunchAuthority.registry(registry)
        let registered: Set<AgentProviderKind> = [.claudeCode, .codexExec]
        let runner = AgentRecoveryActionRunner(activation: activation, registrationActive: { true })
        let calls = Calls()
        for kind in AgentProviderKind.allCases {
            let provider = try XCTUnwrap(AgentRuntimeProvider(agentKind: kind), "\(kind)")
            let pairs = try XCTUnwrap(launchPairs[kind])
            let servingSupported = Set(
                AgentRuntimeQualification.supportedPairs.filter { $0.provider == provider }.map { key($0.family, $0.provider) }
            )
            XCTAssertEqual(Set(pairs.map { key($0.0, $0.1) }), servingSupported, "\(kind): launchers build only supported pairs")
            let registers = registered.contains(kind)
            for (family, pairProvider) in pairs {
                XCTAssertEqual(pairProvider, provider, "\(kind): a launch's provider is the kind's actual provider")
                XCTAssertEqual(authority.isRegistrationActive(family: family, provider: pairProvider), registers, "\(kind) \(family)")
                let context = AgentRuntimeLaunchContext(
                    family: family, provider: pairProvider, session: .sessionless, worktreePath: nil, permission: .unavailable
                )
                XCTAssertEqual(authority.makeLaunch(context) != nil, registers, "\(kind) \(family): launch owner iff registered")
                XCTAssertNil(AgentRuntimeLaunchAuthority.activationOff.makeLaunch(context), "\(kind) \(family): off never registers")
            }
            XCTAssertEqual(activation.coversProvider(provider), registers, "\(kind)")
            XCTAssertEqual(
                authority.runStartRegistrationMark(providerKindRaw: kind.rawValue),
                registers ? AgentRecoveryRunAttempt.registeredRuntimeRegistration : nil,
                "\(kind): run-start mark only for a registered provider"
            )
            XCTAssertNil(AgentRuntimeLaunchAuthority.activationOff.runStartRegistrationMark(providerKindRaw: kind.rawValue))

            let request = try await AgentRecoveryActionRequest(
                actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revision(),
                target: AgentRecoveryActionTarget(providerKindRaw: kind.rawValue, providerConversationID: "conv-\(kind.rawValue)")
            )
            let result = await runner.perform(request, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
            if registers {
                XCTAssertEqual(result, .completed(.notDispatched, reason: "none"), "\(kind): a registered provider's choice runs")
            } else {
                XCTAssertEqual(
                    result,
                    .disabled(AgentRecoveryActionRunner.unqualifiedProviderText(kind.displayName)),
                    "\(kind): refused with the named reason"
                )
            }
        }
        XCTAssertEqual(calls.reconcile, registered.count, "only the registered providers reconciled")
        XCTAssertEqual(calls.dispatch, 0)
    }

    /// A qualified provider whose choice reconciles still needs a history performer: without one it
    /// refuses before reserving with the history-unavailable reason (never a silent continuation or
    /// a "nothing imported" outcome). Send saved reads no history, so it needs none: a real saved
    /// message is dispatched exactly once.
    func testQualifiedProviderWithoutAHistoryPerformerRefusesOnlyChoicesThatReconcile() async throws {
        let runner = AgentRecoveryActionRunner(activation: .claudeAndCodex, registrationActive: { true })
        let calls = Calls()
        let revisionBefore = try await revision()
        for providerKind in [AgentProviderKind.claudeCode, .codexExec] {
            let target = AgentRecoveryActionTarget(providerKindRaw: providerKind.rawValue, providerConversationID: "conv-1")
            let reconcile = AgentRecoveryActionRequest(
                actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revisionBefore, target: target
            )
            let reconciled = await runner.perform(reconcile, lane: lane, performers: performers(calls))
            XCTAssertEqual(reconciled, .disabled(AgentRecoveryActionRunner.historyUnavailableText), "\(providerKind)")
            let continuation = AgentRecoveryActionRequest(
                actionID: UUID(), itemKey: runKey(), kind: .continueWithText, expectedRevision: revisionBefore,
                target: target, text: "continue", plannedUserItemID: UUID()
            )
            let continued = await runner.perform(continuation, lane: lane, performers: performers(calls))
            XCTAssertEqual(continued, .disabled(AgentRecoveryActionRunner.historyUnavailableText), "\(providerKind)")
        }
        XCTAssertEqual(
            AgentRecoveryActionRunner.historyUnavailableText,
            "Provider history isn't available for this session. Nothing was sent."
        )
        let revisionAfterRefusals = try await revision()
        XCTAssertEqual(revisionAfterRefusals, revisionBefore, "the refusals wrote nothing")
        XCTAssertEqual(calls.dispatch, 0)

        let identity = try await fixture.queuedIdentity("saved message")
        let intentID = try XCTUnwrap(identity.intentID)
        let key = AgentRecoveryCardKey(
            kind: .savedInput,
            incarnationID: lane.binding.incarnationID,
            transcriptResetGeneration: lane.binding.transcriptResetGeneration,
            entityID: intentID.uuidString
        )
        let sendSaved = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: key, kind: .sendSaved, expectedRevision: revision(),
            sourceIntentIDs: [intentID],
            target: AgentRecoveryActionTarget(providerKindRaw: AgentProviderKind.claudeCode.rawValue, providerConversationID: "conv-1")
        )
        let sent = await runner.perform(sendSaved, lane: lane, performers: performers(calls))
        XCTAssertEqual(sent, .completed(.dispatched, reason: nil), "Send saved needs no history performer")
        XCTAssertEqual(calls.dispatch, 1)
        XCTAssertEqual(calls.reconcile, 0)
    }

    /// Round-0 review P2-3: a provider is covered only when every supported family that serves it is
    /// covered. A hypothetical activation qualifying Codex exec alone (app-server runs would launch
    /// unregistered) or headless GLM alone doesn't cover that provider, and the runner refuses it.
    func testProviderIsCoveredOnlyWhenEveryFamilyServingItIsCovered() async throws {
        let full = AgentRecoveryActivation.claudeAndCodex
        func only(_ families: Set<AgentRuntimeFamily>) -> AgentRecoveryActivation {
            AgentRecoveryActivation(
                runtime: AgentRuntimeQualification(families: full.runtime.families.filter { families.contains($0.key) }),
                actions: full.actions
            )
        }
        XCTAssertTrue(full.coversProvider(.codex))
        XCTAssertTrue(full.coversProvider(.claude(.standard)))
        let execOnly = only([.codexExec])
        XCTAssertTrue(execOnly.runtime.covers(family: .codexExec, provider: .codex))
        XCTAssertFalse(execOnly.coversProvider(.codex), "app-server runs would launch unregistered")
        XCTAssertFalse(only([.claudeHeadless]).coversProvider(.claude(.standard)), "native runs would launch unregistered")
        let headlessGLM = AgentRecoveryActivation(
            runtime: AgentRuntimeQualification(families: [.claudeHeadless: AgentRuntimeFamilyQualification(
                providers: [.claude(.glm)], markerPropagation: true, completeDiscovery: true,
                writerExecutableBasenames: ["claude"]
            )]),
            actions: full.actions
        )
        XCTAssertFalse(headlessGLM.coversProvider(.claude(.glm)), "compatible native runs would launch unregistered")
        XCTAssertFalse(full.coversProvider(nil))

        let runner = AgentRecoveryActionRunner(activation: execOnly, registrationActive: { true })
        let calls = Calls()
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        let codexRequest = AgentRecoveryActionRequest(
            actionID: request.actionID, itemKey: request.itemKey, kind: request.kind, expectedRevision: request.expectedRevision,
            target: AgentRecoveryActionTarget(providerKindRaw: AgentProviderKind.codexExec.rawValue, providerConversationID: "thread-1"),
            text: request.text, plannedUserItemID: request.plannedUserItemID
        )
        let result = await runner.perform(codexRequest, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(result, .disabled(AgentRecoveryActionRunner.unqualifiedProviderText(AgentProviderKind.codexExec.displayName)))
        XCTAssertEqual(calls.reconcile + calls.dispatch, 0)
    }

    func testQualifiedChoiceDispatchesOnceAndARepeatJoins() async throws {
        let calls = Calls()
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        async let first = runner.perform(request, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        async let concurrent = runner.perform(request, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        let (one, two) = await (first, concurrent)
        XCTAssertEqual(one, .completed(.dispatched, reason: nil))
        XCTAssertEqual(two, one, "a concurrent repeat joins the in-flight performance")
        XCTAssertEqual(calls.dispatch, 1)
        let repeated = await runner.perform(request, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        guard case let .joined(.resolved(outcome)) = repeated else { return XCTFail("expected a resolved join, got \(repeated)") }
        XCTAssertEqual(outcome.kind, .dispatched)
        XCTAssertEqual(calls.dispatch, 1, "a recorded choice is never performed again")
    }

    func testCrashUncertaintyNeverAutoSends() async throws {
        // An earlier performance reserved the action and stopped before recording any outcome.
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        _ = try await lane.reserveRecoveryAction(request).get()
        let calls = Calls()
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let result = await runner.perform(request, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(result, .joined(.notDispatched), "the planned message never became an intent")
        XCTAssertEqual(calls.dispatch, 0)
        let outcome = try await record()?.action(id: request.actionID)?.outcome
        XCTAssertNil(outcome, "joining records nothing")
    }

    func testNotDispatchedAndReconcileOutcomesAreRecorded() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let refusedRequest = try await continuation(key: runKey(), expectedRevision: revision())
        let refused = await runner.perform(refusedRequest, lane: lane, performers: performers(calls, dispatch: .notDispatched("busy"), reconcile: .nothingImported("none")))
        XCTAssertEqual(refused, .completed(.notDispatched, reason: "busy"))
        let reason = try await record()?.action(id: refusedRequest.actionID)?.outcome?.reason
        XCTAssertEqual(reason, "busy")
        XCTAssertEqual(calls.reconcile, 1, "a qualified continuation reconciles history before it dispatches")

        let reconcileRequest = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revision(), target: target
        )
        let imported = await runner.perform(
            reconcileRequest,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .unconfirmed, rowCount: 3))
        )
        XCTAssertEqual(imported, .completed(.importedUnconfirmed, reason: nil))
        XCTAssertEqual(calls.reconcile, 2)
        XCTAssertEqual(calls.dispatch, 1, "reconciliation never dispatches")

        let nothingRequest = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revision(), target: target
        )
        let nothing = await runner.perform(nothingRequest, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(nothing, .completed(.notDispatched, reason: "none"))
    }

    func testAssociationUnavailableIsNeitherCompletionNorImport() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        XCTAssertTrue(runner.capturesDispatchBaselines(for: .claudeCode))
        XCTAssertFalse(AgentRecoveryActionRunner(activation: .production, registrationActive: { true }).capturesDispatchBaselines(for: .claudeCode))
        let claudeAndCodex = AgentRecoveryActionRunner(activation: .claudeAndCodex, registrationActive: { true })
        XCTAssertTrue(
            claudeAndCodex.capturesDispatchBaselines(for: .claudeCode),
            "the qualified activation captures Claude baselines (coupled, ungated)"
        )
        for compatible in [AgentProviderKind.claudeCodeGLM, .kimiCode, .customClaudeCompatible] {
            XCTAssertFalse(claudeAndCodex.capturesDispatchBaselines(for: compatible), "never a compatible backend: \(compatible)")
        }
        // Round-0 review P1-2: Claude baselines need Claude's own pairs covered, not just any pair.
        let codexOnly = AgentRecoveryActionRunner(
            activation: AgentRecoveryActivation(
                runtime: AgentRuntimeQualification(families: AgentRecoveryActivation.claudeAndCodex.runtime.families.filter {
                    $0.key == .codexAppServer || $0.key == .codexExec
                }),
                actions: AgentRecoveryActivation.claudeAndCodex.actions
            ),
            registrationActive: { true }
        )
        XCTAssertFalse(codexOnly.capturesDispatchBaselines(for: .claudeCode))
        XCTAssertFalse(AgentRecoveryActionRunner(qualification: qualified, registrationActive: { false }).capturesDispatchBaselines(for: .claudeCode))
        let calls = Calls()
        let refusal = AgentRecoveryReconcileResult.associationUnavailable(.nativeUserAssociationUnavailable, "cannot match")
        let reconcileRequest = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revision(),
            sourceRunAttemptID: UUID(), target: target
        )
        let reconciled = await runner.perform(reconcileRequest, lane: lane, performers: performers(calls, reconcile: refusal))
        XCTAssertEqual(reconciled, .completed(.notDispatched, reason: "cannot match"), "nothing imported, nothing completed")
        let attempt = try XCTUnwrap(reconcileRequest.sourceRunAttemptID)
        let verified = try await record()?.hasVerifiedCompletion(ofRunAttempt: attempt) ?? true
        XCTAssertFalse(verified)

        // Missing association evidence blocks a continuation too (review A P1-02/P1-05): it is not
        // completion, but a continuation never falls through a reconciliation it couldn't trust.
        let continuation = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: attempt)
        let continued = await runner.perform(continuation, lane: lane, performers: performers(calls, reconcile: refusal))
        XCTAssertEqual(continued, .completed(.notDispatched, reason: "cannot match"))
        XCTAssertEqual(calls.reconcile, 2)
        XCTAssertEqual(calls.dispatch, 0)
    }

    // MARK: Review fixes: failure is never fallthrough, record evidence, shared hold

    func testBlockedReconciliationStopsAndKeepsConfirmedCompletion() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let attempt = UUID()
        let blocked = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: attempt)
        let stopped = await runner.perform(blocked, lane: lane, performers: performers(calls, reconcile: .blocked("read failed")))
        XCTAssertEqual(stopped, .completed(.notDispatched, reason: "read failed"), "a failed reconciliation never falls through")

        let saveFailed = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: attempt)
        let completed = await runner.perform(
            saveFailed,
            lane: lane,
            performers: performers(calls, reconcile: .blocked("not saved", completion: .confirmed(runAttemptID: attempt)))
        )
        XCTAssertEqual(completed, .completed(.importedCompleted, reason: "not saved"), "confirmed completion survives a row save failure")
        let verified = try await record()?.hasVerifiedCompletion(ofRunAttempt: attempt) ?? false
        XCTAssertTrue(verified)

        let otherAttempt = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: UUID())
        let unbound = await runner.perform(
            otherAttempt,
            lane: lane,
            performers: performers(calls, reconcile: .blocked("not saved", completion: .confirmed(runAttemptID: attempt)))
        )
        XCTAssertEqual(unbound, .completed(.notDispatched, reason: "not saved"))

        let reconcileOnly = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revision(),
            sourceRunAttemptID: attempt, target: target
        )
        let reconciled = await runner.perform(
            reconcileOnly,
            lane: lane,
            performers: performers(calls, reconcile: .blocked("not saved", completion: .confirmed(runAttemptID: attempt)))
        )
        XCTAssertEqual(reconciled, .completed(.importedCompleted, reason: "not saved"))
        XCTAssertEqual(calls.dispatch, 0)
        XCTAssertEqual(calls.reconcile, 4)
    }

    /// Step 4d7: the three action-scoped Claude history refusals (changed, unproven, unsupported) say
    /// nothing was imported or sent, and each, as the blocked reconciliation the view model returns
    /// for it, stops the continuation before any dispatch.
    func testClaudeHistoryChangedUnprovenAndUnsupportedRefusalsNeverDispatch() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let messages = [
            AgentModeViewModel.recoveryHistoryChangedText,
            AgentModeViewModel.recoveryHistoryUnprovenText,
            AgentModeViewModel.recoveryHistoryUnsupportedText
        ]
        for message in messages {
            XCTAssertTrue(message.hasSuffix("Nothing was imported or sent."), message)
            let request = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: UUID())
            let result = await runner.perform(request, lane: lane, performers: performers(calls, reconcile: .blocked(message)))
            XCTAssertEqual(result, .completed(.notDispatched, reason: message))
        }
        XCTAssertEqual(calls.reconcile, messages.count)
        XCTAssertEqual(calls.dispatch, 0, "no refusal ever dispatches")
    }

    func testSourceRunEvidenceInTheRecordDecidesWhetherAContinuationDispatches() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let sessionID = fixture.sessionID

        func run(state: AgentSessionRunState?, cause: AgentRunTerminalCause = .ordinary) async throws -> UUID {
            let ownership = RecoveryTestSupport.ownership(sessionID: sessionID)
            _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: UUID(), providerKindRaw: nil).get()
            if let state {
                _ = try await lane.recordRunTerminal(
                    RecoveryTestSupport.terminalCommit(ownership: ownership, state: state, cause: cause)
                ).get()
            }
            return ownership.attemptID
        }
        func perform(_ attempt: UUID) async throws -> AgentRecoveryActionResult {
            let request = try await continuation(key: runKey(attempt), expectedRevision: revision(), sourceRunAttemptID: attempt)
            return await runner.perform(request, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        }

        let completed = try await perform(run(state: .completed))
        XCTAssertEqual(completed, .completed(.importedCompleted, reason: AgentRecoveryActionRunner.verifiedCompletionText))
        let failed = try await perform(run(state: .failed))
        XCTAssertEqual(failed, .completed(.notDispatched, reason: AgentRecoveryActionRunner.notInterruptedText))
        let userCancelled = try await perform(run(state: .cancelled, cause: .userCancel))
        XCTAssertEqual(userCancelled, .completed(.notDispatched, reason: AgentRecoveryActionRunner.notInterruptedText))
        XCTAssertEqual(calls.dispatch, 0, "completed or non-interrupted source runs send nothing")

        let open = try await perform(run(state: nil))
        XCTAssertEqual(open, .completed(.dispatched, reason: nil), "a run with no terminal is an interruption")
        let quit = try await perform(run(state: .cancelled, cause: .appQuit))
        XCTAssertEqual(quit, .completed(.dispatched, reason: nil))
        XCTAssertEqual(calls.dispatch, 2)
    }

    func testNeverHandedOffRunIsRoutedToItsSavedMessage() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let ownership = RecoveryTestSupport.ownership(sessionID: fixture.sessionID)
        _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: UUID(), providerKindRaw: nil).get()
        let identity = try await fixture.queuedIdentity("never delivered")
        let intentID = try XCTUnwrap(identity.intentID)
        let deliveryID = UUID()
        _ = try await lane.beginDispatch(
            intentID: intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: deliveryID, runAttemptID: ownership.attemptID),
            authorization: .liveQueue
        ).get()
        _ = try await lane.settleToQueue(intentID: intentID, attemptID: deliveryID, evidence: .preHandoff, message: nil).get()
        let neverHandedOff = try await record()?.isVerifiedNeverHandedOff(runAttemptID: ownership.attemptID) ?? false
        XCTAssertTrue(neverHandedOff)

        let request = try await continuation(
            key: runKey(ownership.attemptID), expectedRevision: revision(), sourceRunAttemptID: ownership.attemptID
        )
        let result = await runner.perform(request, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(result, .completed(.notDispatched, reason: AgentRecoveryActionRunner.neverHandedOffText))
        XCTAssertEqual(calls.dispatch, 0, "Continue never replaces the saved message")
    }

    func testResolvedItemIsNeverOfferedADuplicateSendThroughTheRunner() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let key = runKey()
        let first = try await continuation(key: key, expectedRevision: revision())
        let sent = await runner.perform(first, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(sent, .completed(.dispatched, reason: nil))
        let again = try await continuation(key: key, expectedRevision: revision())
        let refused = await runner.perform(again, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        guard case .refused = refused else { return XCTFail("a resolved item refuses a new send, got \(refused)") }
        XCTAssertEqual(calls.dispatch, 1)
    }

    @MainActor
    private final class Gate {
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

    func testInFlightActionHoldsTheSessionAndRefusesOtherChoices() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let gate = Gate()
        let gated = AgentRecoveryActionPerformers(reconcile: { _ in
            calls.reconcile += 1
            await gate.wait()
            return .nothingImported("none")
        }) { [self] action, authorization in
            calls.dispatch += 1
            return await handOff(action, authorization)
        }
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        XCTAssertFalse(fixture.coordinator.isCoveredByRecoveryAction(sessionID: lane.sessionID))
        let running = Task { await runner.perform(request, lane: self.lane, performers: gated) }
        var polls = 0
        while !gate.isWaiting, polls < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        XCTAssertTrue(gate.isWaiting, "the reconciliation is in flight")
        XCTAssertTrue(
            fixture.coordinator.isCoveredByRecoveryAction(sessionID: lane.sessionID),
            "the session is held (app-shared coordinator) through reconciliation"
        )
        XCTAssertEqual(fixture.coordinator.recoveryActionHoldCount, 1)
        XCTAssertTrue(
            fixture.coordinator.isCoveredByRecoveryAction(sessionID: UUID()),
            "a session whose workspace is unknown is covered (fail closed)"
        )

        let other = try await continuation(key: runKey(), expectedRevision: revision())
        let otherResult = await runner.perform(other, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(otherResult, .refused(AgentRecoveryActionRunner.sessionActionInFlightText))
        let changed = try await continuation(
            key: request.itemKey,
            actionID: request.actionID,
            text: "changed",
            expectedRevision: revision(),
            plannedUserItemID: XCTUnwrap(request.plannedUserItemID)
        )
        let changedResult = await runner.perform(changed, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(changedResult, .refused(AgentRecoveryActionRunner.sessionActionInFlightText), "only an exact repeat joins")
        XCTAssertEqual(calls.dispatch, 0)

        gate.open()
        let result = await running.value
        XCTAssertEqual(result, .completed(.dispatched, reason: nil))
        XCTAssertFalse(fixture.coordinator.isCoveredByRecoveryAction(sessionID: lane.sessionID), "the hold ends with the recorded outcome")
        XCTAssertEqual(fixture.coordinator.recoveryActionHoldCount, 0)
        XCTAssertEqual(calls.dispatch, 1)
        XCTAssertEqual(calls.reconcile, 1)
    }

    // MARK: Review A P1-01: shared coordinator hold and exact action authorization

    private func acquire(_ request: AgentRecoveryActionRequest, on lane: AgentRecoverySessionLane? = nil) throws -> AgentRecoveryActionAuthorization {
        guard case let .acquired(authorization) = fixture.coordinator.beginRecoveryAction(request, lane: lane ?? self.lane) else {
            XCTFail("expected the hold to be acquired")
            throw HandOffFailed()
        }
        return authorization
    }

    private func admission(
        _ lane: AgentRecoverySessionLane,
        itemID: UUID = UUID(),
        origin: AgentRecoveryIntentOrigin,
        text: String = "ordinary input",
        authorization: AgentRecoveryActionAuthorization? = nil
    ) -> AgentRecoveryAdmission {
        AgentRecoveryAdmission(
            binding: lane.binding,
            userItemID: itemID,
            origin: origin,
            target: .session,
            original: RecoveryTestSupport.content(text),
            actionAuthorization: authorization
        )
    }

    private func refusal(_ result: Result<some Any, AgentRecoveryAdmissionFailure>) -> AgentRecoveryAdmissionRefusal? {
        if case let .failure(.refused(refusal)) = result { return refusal }
        return nil
    }

    private func ensureRun(on lane: AgentRecoverySessionLane) async throws -> UUID {
        let ownership = RecoveryTestSupport.ownership(sessionID: lane.sessionID)
        _ = try await lane.ensureRunAttempt(ownership: ownership, processRunID: nil, transcriptTurnID: UUID(), providerKindRaw: nil).get()
        return ownership.attemptID
    }

    /// Review R1 B N1 (R9 scope): the app-shared hold HARD-excludes only the action's own durable
    /// session (manual, MCP, steering, queued drain, untracked input, handoff), in any window or
    /// lane that owns it. Workspace siblings in another window keep their manual, MCP, steering, and
    /// queued-drain work; only AUTOMATIC work sees the workspace busy projection (scheduler,
    /// automatic new session, the gate `runAlongsideOtherSessions` consults), and a second explicit
    /// action in the workspace is refused. Another workspace is unaffected.
    func testRecoveryActionHoldExcludesItsOwnSessionAndProjectsWorkspaceBusyOnlyForAutomaticWork() async throws {
        let sibling = try await fixture.claimSiblingLane()
        let otherWorkspace = try await fixture.claimSiblingLane(workspaceID: UUID())
        let workspaceID = try XCTUnwrap(fixture.coordinator.knownWorkspaceID(for: lane.sessionID))
        XCTAssertEqual(fixture.coordinator.knownWorkspaceID(for: sibling.sessionID), workspaceID)
        let siblingQueued = try await sibling.admitQueued(admission(sibling, origin: .mcp)).get()
        let siblingIntentID = try XCTUnwrap(AgentQueuedInputIdentity(receipt: siblingQueued.receipt).intentID)
        let siblingRun = try await ensureRun(on: sibling)
        let ownQueued = try await fixture.queuedIdentity("queued in the held session before the action")
        let ownQueuedIntentID = try XCTUnwrap(ownQueued.intentID)
        let ownRun = try await ensureRun(on: lane)

        let request = try await continuation(key: runKey(), expectedRevision: revision())
        let authorization = try acquire(request)
        XCTAssertEqual(fixture.coordinator.recoveryActionHoldCount, 1)

        // The held durable session: every ordinary route is refused.
        let ownManual = await lane.admitQueued(admission(lane, origin: .composer))
        XCTAssertEqual(refusal(ownManual), .recoveryActionInProgress, "manual input of the held session")
        let ownMCP = await lane.admitQueued(admission(lane, origin: .mcp))
        XCTAssertEqual(refusal(ownMCP), .recoveryActionInProgress, "MCP input of the held session")
        let ownSteer = await lane.admitQueued(admission(lane, origin: .steering))
        XCTAssertEqual(refusal(ownSteer), .recoveryActionInProgress, "steering of the held session")
        let ownDrain = await lane.beginDispatch(
            intentID: ownQueuedIntentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: ownRun),
            authorization: .liveQueue
        )
        XCTAssertEqual(refusal(ownDrain), .recoveryActionInProgress, "the held session's queue never drains meanwhile")
        XCTAssertFalse(lane.permitsHandoff(attemptIDs: [UUID()], action: nil), "no unauthorized handoff in the held session")
        XCTAssertTrue(fixture.coordinator.recoveryActionBlocksUntrackedInput(sessionID: lane.sessionID), "untracked input of the held session")

        // A workspace sibling in another window: manual, MCP, steering, and queued drain proceed.
        let siblingManual = await sibling.admitQueued(admission(sibling, origin: .composer))
        XCTAssertNil(refusal(siblingManual), "manual input in another window, same workspace, is not hard-refused")
        let siblingMCP = await sibling.admitQueued(admission(sibling, origin: .mcp))
        XCTAssertNil(refusal(siblingMCP), "sibling MCP input")
        let siblingSteer = await sibling.admitQueued(admission(sibling, origin: .steering))
        XCTAssertNil(refusal(siblingSteer), "sibling steering")
        let siblingAttemptID = UUID()
        let siblingDrain = await sibling.beginDispatch(
            intentID: siblingIntentID,
            attempt: AgentRecoveryAttemptStart(attemptID: siblingAttemptID, runAttemptID: siblingRun),
            authorization: .liveQueue
        )
        XCTAssertNil(refusal(siblingDrain), "a sibling's queued intent drains")
        if case let .failure(failure) = siblingDrain { XCTFail("sibling drain committed, got \(failure)") }
        XCTAssertTrue(sibling.permitsHandoff(attemptIDs: [siblingAttemptID], action: nil), "and is handed off")
        XCTAssertFalse(fixture.coordinator.recoveryActionBlocksUntrackedInput(sessionID: sibling.sessionID), "sibling untracked input")
        XCTAssertFalse(fixture.coordinator.recoveryActionBlocksUntrackedInput(sessionID: nil), "a new session is never the held one")
        let borrowed = await sibling.admitQueued(admission(sibling, origin: .followUp, authorization: authorization))
        XCTAssertEqual(refusal(borrowed), .recoveryActionInProgress, "another session can't use the action's authority")

        // Automatic work keeps the workspace busy projection; a second explicit action is refused.
        XCTAssertTrue(fixture.coordinator.isCoveredByRecoveryAction(sessionID: sibling.sessionID), "scheduler busy projection")
        XCTAssertTrue(
            fixture.coordinator.hasRecoveryAction(inWorkspace: workspaceID, excluding: sibling.sessionID),
            "the automatic new-session gate runAlongsideOtherSessions consults"
        )
        let otherAction = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revision(), target: target
        )
        guard case .refused = fixture.coordinator.beginRecoveryAction(otherAction, lane: sibling) else {
            return XCTFail("one action per workspace")
        }
        XCTAssertFalse(fixture.coordinator.isCoveredByRecoveryAction(sessionID: otherWorkspace.sessionID))
        XCTAssertFalse(fixture.coordinator.recoveryActionBlocksUntrackedInput(sessionID: otherWorkspace.sessionID))
        let unrelated = await otherWorkspace.admitQueued(admission(otherWorkspace, origin: .composer))
        XCTAssertNil(refusal(unrelated), "another workspace is never held")

        // Another lane of the same durable session (a successor claim) stays hard-excluded until the
        // hold ends; revocation alone never releases it.
        let state = try await fixture.relocatedPersistenceState()
        let successor = try fixture.claimSuccessor(persistenceState: state)
        XCTAssertEqual(successor.sessionID, lane.sessionID)
        XCTAssertEqual(fixture.coordinator.recoveryActionHoldCount, 1, "revocation alone never releases the hold")
        let successorManual = await successor.admitQueued(admission(successor, origin: .composer))
        XCTAssertEqual(refusal(successorManual), .recoveryActionInProgress, "the same durable session in another lane")
        let successorMCP = await successor.admitQueued(admission(successor, origin: .mcp))
        XCTAssertEqual(refusal(successorMCP), .recoveryActionInProgress)
        fixture.coordinator.endRecoveryAction(authorization)
        XCTAssertFalse(fixture.coordinator.isCoveredByRecoveryAction(sessionID: sibling.sessionID))
        let released = await successor.admitQueued(admission(successor, origin: .composer))
        XCTAssertNil(refusal(released), "the held session is admitted again once the hold ends")
    }

    /// The authorization admits exactly its planned item, once, and commits exactly that intent's
    /// one delivery attempt; the final handoff check accepts only that attempt.
    func testActionAuthorizationAdmitsAndDispatchesOnlyItsExactPayloadOnce() async throws {
        let unrelated = try await fixture.queuedIdentity("queued before the action")
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        let authorization = try acquire(request)
        let plannedItemID = try XCTUnwrap(authorization.plannedUserItemID)

        let wrongItem = await lane.admitQueued(admission(lane, origin: .followUp, authorization: authorization))
        XCTAssertEqual(refusal(wrongItem), .recoveryActionInProgress, "only the planned item")
        let admitted = try await lane.admitQueued(admission(lane, itemID: plannedItemID, origin: .followUp, authorization: authorization)).get()
        let intentID = try XCTUnwrap(AgentQueuedInputIdentity(receipt: admitted.receipt).intentID)
        let twice = await lane.admitQueued(admission(lane, itemID: plannedItemID, origin: .followUp, authorization: authorization))
        XCTAssertEqual(refusal(twice), .recoveryActionInProgress, "admitted once")

        let run = try await ensureRun(on: lane)
        let unrelatedIntentID = try XCTUnwrap(unrelated.intentID)
        let coalesced = await lane.beginDispatch(
            intentID: unrelatedIntentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: run),
            authorization: .liveQueue,
            action: authorization
        )
        XCTAssertEqual(refusal(coalesced), .recoveryActionInProgress, "another intent never rides on the authorization")
        let attemptID = UUID()
        _ = try await lane.beginDispatch(
            intentID: intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID, runAttemptID: run),
            authorization: .liveQueue,
            action: authorization
        ).get()
        let again = await lane.beginDispatch(
            intentID: intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: run),
            authorization: .liveQueue,
            action: authorization
        )
        XCTAssertEqual(refusal(again), .recoveryActionInProgress, "one delivery attempt")
        XCTAssertFalse(lane.permitsHandoff(attemptIDs: [UUID()], action: authorization))
        XCTAssertFalse(lane.permitsHandoff(attemptIDs: [attemptID], action: nil), "unauthorized handoff is held")
        XCTAssertTrue(lane.permitsHandoff(attemptIDs: [attemptID], action: authorization))

        fixture.coordinator.noteRecoveryActionEvidence(authorization, attemptIDs: [attemptID], observation: .accepted, writeFailed: false)
        let settled = await fixture.coordinator.awaitRecoveryActionSettlement(authorization)
        XCTAssertEqual(settled, .handedOff)
        fixture.coordinator.endRecoveryAction(authorization)
    }

    /// Revocation (cancel, a refused submission, or the lane's replacement) blocks every late use
    /// of the token. With nothing committed it settles not handed off; a committed attempt keeps
    /// the hold until its evidence settles it.
    func testRevokedAuthorizationBlocksLateWorkAndSettlesExactly() async throws {
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        let authorization = try acquire(request)
        let plannedItemID = try XCTUnwrap(authorization.plannedUserItemID)
        let admitted = try await lane.admitQueued(admission(lane, itemID: plannedItemID, origin: .followUp, authorization: authorization)).get()
        let intentID = try XCTUnwrap(AgentQueuedInputIdentity(receipt: admitted.receipt).intentID)
        fixture.coordinator.revokeRecoveryAction(authorization, reason: "cancelled")
        let run = try await ensureRun(on: lane)
        let late = await lane.beginDispatch(
            intentID: intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: run),
            authorization: .liveQueue,
            action: authorization
        )
        XCTAssertEqual(refusal(late), .recoveryActionInProgress, "a revoked token blocks the late task")
        let settled = await fixture.coordinator.awaitRecoveryActionSettlement(authorization)
        XCTAssertEqual(settled, .notHandedOff("cancelled"))
        fixture.coordinator.endRecoveryAction(authorization)

        // Delayed hydration (or any later refusal) ends the submission the same way.
        let hydrating = try await continuation(key: runKey(), expectedRevision: revision())
        let hydratingAuthorization = try acquire(hydrating)
        fixture.coordinator.noteRecoveryActionSubmissionEnded(hydratingAuthorization, reason: "hydration refused")
        let hydrated = await fixture.coordinator.awaitRecoveryActionSettlement(hydratingAuthorization)
        XCTAssertEqual(hydrated, .notHandedOff("hydration refused"))
        fixture.coordinator.endRecoveryAction(hydratingAuthorization)

        // A committed attempt owes its evidence: revocation alone does not settle it, and an
        // evidence write failure is uncertain (never claimed as not sent).
        let committed = try await continuation(key: runKey(), expectedRevision: revision())
        let committedAuthorization = try acquire(committed)
        let committedItem = try XCTUnwrap(committedAuthorization.plannedUserItemID)
        let committedIntent = try await lane.admitQueued(
            admission(lane, itemID: committedItem, origin: .followUp, authorization: committedAuthorization)
        ).get()
        let attemptID = UUID()
        let committedIntentID = try XCTUnwrap(AgentQueuedInputIdentity(receipt: committedIntent.receipt).intentID)
        _ = try await lane.beginDispatch(
            intentID: committedIntentID,
            attempt: AgentRecoveryAttemptStart(attemptID: attemptID, runAttemptID: run),
            authorization: .liveQueue,
            action: committedAuthorization
        ).get()
        fixture.coordinator.revokeRecoveryAction(committedAuthorization)
        XCTAssertFalse(lane.permitsHandoff(attemptIDs: [attemptID], action: committedAuthorization), "revoked before handoff")
        let waiter = Task { await self.fixture.coordinator.awaitRecoveryActionSettlement(committedAuthorization) }
        await Task.yield()
        fixture.coordinator.noteRecoveryActionEvidence(
            committedAuthorization, attemptIDs: [attemptID], observation: .deliveryUnknown, writeFailed: true
        )
        let uncertain = await waiter.value
        XCTAssertEqual(uncertain, .uncertain(AgentRecoveryCoordinator.recoveryActionEvidenceUnrecordedText))
        fixture.coordinator.endRecoveryAction(committedAuthorization)
    }

    func testLaneReplacementRevokesItsActionHold() async throws {
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        let authorization = try acquire(request)
        let state = try await fixture.relocatedPersistenceState()
        let successor = try fixture.claimSuccessor(persistenceState: state)
        let settled = await fixture.coordinator.awaitRecoveryActionSettlement(authorization)
        XCTAssertEqual(settled, .notHandedOff(AgentRecoverySessionLane.sessionChangedHoldReason))
        let plannedItemID = try XCTUnwrap(authorization.plannedUserItemID)
        let late = await successor.admitQueued(admission(successor, itemID: plannedItemID, origin: .followUp, authorization: authorization))
        XCTAssertEqual(refusal(late), .recoveryActionInProgress, "the predecessor's token never admits on the successor")
        fixture.coordinator.endRecoveryAction(authorization)
    }

    /// The runner records the settlement, not the submission: an evidence write failure after the
    /// handoff began is recorded as dispatched with the uncertainty reason (never not-sent).
    func testRunnerRecordsUncertainSettlementAsDispatchedWithItsReason() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        let performers = AgentRecoveryActionPerformers(reconcile: { _ in .nothingImported("none") }) { [self] action, authorization in
            do {
                let plannedItemID = try XCTUnwrap(action.plannedUserItemID)
                let admitted = try await lane.admitQueued(admission(
                    lane, itemID: plannedItemID, origin: .followUp, authorization: authorization
                )).get()
                let run = try await ensureRun(on: lane)
                let attemptID = UUID()
                let intentID = try XCTUnwrap(AgentQueuedInputIdentity(receipt: admitted.receipt).intentID)
                _ = try await lane.beginDispatch(
                    intentID: intentID,
                    attempt: AgentRecoveryAttemptStart(attemptID: attemptID, runAttemptID: run),
                    authorization: .liveQueue,
                    action: authorization
                ).get()
                // `.submitted` returns before the deferred evidence lands.
                Task { @MainActor in
                    self.fixture.coordinator.noteRecoveryActionEvidence(
                        authorization, attemptIDs: [attemptID], observation: .accepted, writeFailed: true
                    )
                }
                return .dispatched
            } catch {
                return .notDispatched("\(error)")
            }
        }
        let result = await runner.perform(request, lane: lane, performers: performers)
        XCTAssertEqual(result, .completed(.dispatched, reason: AgentRecoveryCoordinator.recoveryActionEvidenceUnrecordedText))
        XCTAssertEqual(fixture.coordinator.recoveryActionHoldCount, 0, "released only after the outcome write")
    }

    // MARK: Review R1 A P1-01: a freeze landing during the action's dispatch commit

    /// Holds the lane's transaction gate so a dispatch commit suspends after its checks passed.
    private final class CommitGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var isWaiting = false

        func waitOnce() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class CommitCapture {
        var authorization: AgentRecoveryActionAuthorization?
        var identity: AgentQueuedInputIdentity?
        var holder: Task<Void, Never>?
        var settlement: AgentRecoveryActionSettlement?
    }

    /// A shutdown freeze that begins while the action's one dispatch commit is in flight (after the
    /// action check passed, before the write landed) attaches the committed attempt and then refuses
    /// its handoff. The stale settlement is bound to that exact attempt: the submission settles not
    /// handed off, the intent is back in the queue (never sent), Stage A cancel ends the freeze, and
    /// the runner records its outcome and releases the hold. Elapsed time is never the proof.
    func testShutdownFreezeDuringTheActionCommitSettlesItsAttachedAttemptAndReleasesTheRunner() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let request = try await continuation(key: runKey(), expectedRevision: revision())
        let plannedItemID = try XCTUnwrap(request.plannedUserItemID)
        let gate = CommitGate()
        let capture = CommitCapture()
        let performers = AgentRecoveryActionPerformers(reconcile: { _ in .nothingImported("none") }) { [self] _, authorization in
            capture.authorization = authorization
            do {
                let admitted = try await lane.admitQueued(admission(
                    lane, itemID: plannedItemID, origin: .followUp, authorization: authorization
                )).get()
                let identity = AgentQueuedInputIdentity(receipt: admitted.receipt)
                capture.identity = identity
                let intentID = try XCTUnwrap(identity.intentID)
                let run = try await ensureRun(on: lane)
                let lane = lane
                capture.holder = Task { _ = await lane.transaction { _, _ in await gate.waitOnce() } }
                guard await RecoveryTestSupport.eventually({ gate.isWaiting }) else { return .notDispatched("gate not held") }
                _ = try await lane.beginDispatch(
                    intentID: intentID,
                    attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: run),
                    authorization: .liveQueue,
                    action: authorization
                ).get()
                return .dispatched
            } catch {
                return .notDispatched("handoff refused: \(error)")
            }
        }
        let running = Task { await runner.perform(request, lane: self.lane, performers: performers) }
        let committing = await RecoveryTestSupport.eventually {
            guard let authorization = capture.authorization else { return false }
            return fixture.coordinator.recoveryActionCommitIsInFlight(authorization)
        }
        XCTAssertTrue(committing, "the action's dispatch commit is in flight (its action check passed)")
        let authorization = try XCTUnwrap(capture.authorization)

        let freeze = fixture.coordinator.beginShutdownFreeze(scope: .application)
        XCTAssertTrue(lane.isShutdownFrozen, "Stage A froze the lane during the commit")
        let observer = Task { @MainActor in
            capture.settlement = await self.fixture.coordinator.awaitRecoveryActionSettlement(authorization)
        }
        gate.release()
        _ = await capture.holder?.value

        // Bounded polling only detects a regression (a stuck hold); the exact settlement, the
        // durable intent, and the recorded outcome below are the proof.
        let settled = await RecoveryTestSupport.eventually { capture.settlement != nil }
        XCTAssertTrue(settled, "the stale commit settles the action's attached attempt")
        guard settled else {
            fixture.coordinator.endShutdownFreeze(freeze)
            return
        }
        _ = await observer.value
        XCTAssertEqual(capture.settlement, .notHandedOff(nil))
        let identity = try XCTUnwrap(capture.identity)
        let intent = await fixture.intent(identity)
        XCTAssertEqual(intent?.deliveryState, .queued, "the committed intent is settled back, never handed off")
        let attempts = await fixture.attempts(for: identity)
        XCTAssertEqual(attempts.count, 1, "its one attempt is kept as pre-handoff evidence")
        XCTAssertFalse(lane.permitsHandoff(attemptIDs: attempts.map(\.attemptID), action: authorization), "the token is spent")

        fixture.coordinator.endShutdownFreeze(freeze) // Stage A cancelled
        XCTAssertFalse(lane.isShutdownFrozen)
        let result = await running.value
        guard case let .completed(outcome, reason) = result else {
            return XCTFail("the runner records an outcome, got \(result)")
        }
        XCTAssertEqual(outcome, .notDispatched, "a provably unsent attempt is recorded not dispatched")
        XCTAssertNotNil(reason)
        XCTAssertEqual(fixture.coordinator.recoveryActionHoldCount, 0, "the hold is released")
        let after = await lane.admitQueued(admission(lane, origin: .composer))
        XCTAssertNil(refusal(after), "ordinary input is admitted again")
    }

    // MARK: R7 reconcile before Continue

    func testContinuationStopsWithoutDispatchWhenReconcileVerifiesItsSourceAttempt() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let attempt = UUID()
        let finished = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: attempt)
        let stopped = await runner.perform(
            finished,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .confirmed(runAttemptID: attempt), rowCount: 2))
        )
        XCTAssertEqual(stopped, .completed(.importedCompleted, reason: AgentRecoveryActionRunner.verifiedCompletionText))
        XCTAssertEqual(calls.reconcile, 1, "a continuation reconciles first")
        XCTAssertEqual(calls.dispatch, 0, "verified completion of the source attempt sends nothing")

        let zeroRows = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: UUID())
        let zeroRowAttempt = try XCTUnwrap(zeroRows.sourceRunAttemptID)
        let alsoStopped = await runner.perform(
            zeroRows,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .confirmed(runAttemptID: zeroRowAttempt), rowCount: 0))
        )
        XCTAssertEqual(alsoStopped, .completed(.importedCompleted, reason: AgentRecoveryActionRunner.verifiedCompletionText))
        XCTAssertEqual(calls.dispatch, 0)

        let otherAttempt = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: UUID())
        let unbound = await runner.perform(
            otherAttempt,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .confirmed(runAttemptID: attempt), rowCount: 1))
        )
        XCTAssertEqual(unbound, .completed(.dispatched, reason: nil), "another attempt's completion is not evidence")
        let unconfirmed = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: UUID())
        let continued = await runner.perform(
            unconfirmed,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .unconfirmed, rowCount: 1))
        )
        XCTAssertEqual(continued, .completed(.dispatched, reason: nil))
        let noSource = try await continuation(key: runKey(), expectedRevision: revision())
        let sourceless = await runner.perform(
            noSource,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .confirmed(runAttemptID: attempt), rowCount: 1))
        )
        XCTAssertEqual(sourceless, .completed(.dispatched, reason: nil), "completion needs a bound source attempt")
        XCTAssertEqual(calls.dispatch, 3)
        XCTAssertEqual(calls.reconcile, 5)
    }

    func testRecordedVerifiedCompletionStopsALaterContinuation() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let attempt = UUID()
        let reconcile = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revision(),
            sourceRunAttemptID: attempt, target: target
        )
        let reconciled = await runner.perform(
            reconcile,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .confirmed(runAttemptID: attempt), rowCount: 1))
        )
        XCTAssertEqual(reconciled, .completed(.importedCompleted, reason: nil))
        let later = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: attempt)
        let stopped = await runner.perform(later, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(stopped, .completed(.importedCompleted, reason: AgentRecoveryActionRunner.verifiedCompletionText))
        XCTAssertEqual(calls.dispatch, 0, "durable verified completion of the source attempt sends nothing")

        let misbound = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: runKey(), kind: .reconcileOnly, expectedRevision: revision(),
            sourceRunAttemptID: UUID(), target: target
        )
        let unconfirmed = await runner.perform(
            misbound,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .confirmed(runAttemptID: attempt), rowCount: 1))
        )
        XCTAssertEqual(unconfirmed, .completed(.importedUnconfirmed, reason: nil), "another attempt's evidence is not completion")
    }

    func testContinuationDoesNotReconcileWhenHistoryReconciliationIsNotQualified() async throws {
        let runner = AgentRecoveryActionRunner(
            qualification: AgentRecoveryActionQualification(sameConversationResume: true),
            registrationActive: { true }
        )
        let calls = Calls()
        let attempt = UUID()
        let request = try await continuation(key: runKey(), expectedRevision: revision(), sourceRunAttemptID: attempt)
        let result = await runner.perform(
            request,
            lane: lane,
            performers: performers(calls, reconcile: .imported(completion: .confirmed(runAttemptID: attempt), rowCount: 1))
        )
        XCTAssertEqual(result, .completed(.dispatched, reason: nil))
        XCTAssertEqual(calls.reconcile, 0, "an unqualified history import never runs")
        XCTAssertEqual(calls.dispatch, 1)
    }

    // MARK: R7 editable continuation text

    func testDefaultAndEditedContinuationTextAreReservedAndSentExactly() async throws {
        XCTAssertEqual(
            AgentRecoveryActionRequest.defaultContinuationText,
            "RepoPrompt restarted during the previous turn. Check the current state before repeating any action, then continue."
        )
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let edited = "  Check the build first,\nthen continue. "
        let request = try await continuation(key: runKey(), text: edited, expectedRevision: revision())
        let result = await runner.perform(request, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(result, .completed(.dispatched, reason: nil))
        XCTAssertEqual(calls.dispatchedTexts, [edited], "the exact edited text is sent")
        let stored = try await record()?.action(id: request.actionID)?.text
        XCTAssertEqual(stored, edited, "the exact edited text is frozen into the reservation")
        let changed = try await continuation(
            key: request.itemKey,
            actionID: request.actionID,
            text: "different",
            expectedRevision: revision(),
            plannedUserItemID: XCTUnwrap(request.plannedUserItemID)
        )
        let refused = await runner.perform(changed, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        guard case .refused = refused else { return XCTFail("changed text must not join, got \(refused)") }
        XCTAssertEqual(calls.dispatch, 1)
    }

    // MARK: Previous launch's open actions

    func testPreviousLaunchActionIsShownFirstThenReplacedOnlyByAnExplicitChoice() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let key = runKey()
        let old = try await continuation(key: key, expectedRevision: revision())
        _ = try await previousLaunchStore().reserveRecoveryAction(binding: lane.binding, request: old)
        let oldLoaded = try await record()?.action(id: old.actionID)
        let oldStored = try XCTUnwrap(oldLoaded)

        let fresh = try await continuation(key: key, expectedRevision: revision())
        let first = await runner.perform(fresh, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(first, .priorAction(actionID: old.actionID, join: .notDispatched), "the old action is joined first")
        XCTAssertEqual(calls.dispatch, 0)
        let afterJoin = try await record()?.actions.count
        XCTAssertEqual(afterJoin, 1, "joining writes nothing")

        let replacement = try await continuation(key: key, expectedRevision: revision(), supersedes: old.actionID)
        let replaced = await runner.perform(replacement, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(replaced, .completed(.dispatched, reason: nil))
        XCTAssertEqual(calls.dispatch, 1)
        let finalLoaded = try await record()
        let final = try XCTUnwrap(finalLoaded)
        XCTAssertEqual(final.action(id: old.actionID), oldStored, "the old evidence is kept unchanged")
        XCTAssertNil(final.action(id: old.actionID)?.outcome, "no outcome is fabricated for it")
        XCTAssertTrue(final.isSuperseded(oldStored))
        XCTAssertEqual(final.action(id: replacement.actionID)?.supersedesActionID, old.actionID)

        let stale = try await continuation(key: key, expectedRevision: revision(), supersedes: old.actionID)
        let staleResult = await runner.perform(stale, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        guard case .refused = staleResult else { return XCTFail("a closed old action can't be replaced again, got \(staleResult)") }

        let sameLaunchKey = runKey()
        let open = try await continuation(key: sameLaunchKey, expectedRevision: revision())
        _ = try await lane.reserveRecoveryAction(open).get()
        let overSameLaunch = try await continuation(key: sameLaunchKey, expectedRevision: revision(), supersedes: open.actionID)
        let sameLaunchResult = await lane.reserveRecoveryAction(overSameLaunch)
        XCTAssertEqual(storeError(sameLaunchResult), .actionConflict(open.actionID), "this launch's open action is never replaced")
        XCTAssertEqual(calls.dispatch, 1)
    }

    func testUncertainPriorDeliveryNeedsAConfirmedNewContinuation() async throws {
        let runner = AgentRecoveryActionRunner(qualification: qualified, registrationActive: { true })
        let calls = Calls()
        let identity = try await fixture.queuedIdentity("saved message")
        let intentID = try XCTUnwrap(identity.intentID)
        let key = AgentRecoveryCardKey(
            kind: .savedInput,
            incarnationID: lane.binding.incarnationID,
            transcriptResetGeneration: lane.binding.transcriptResetGeneration,
            entityID: intentID.uuidString
        )
        let previous = previousLaunchStore()
        let old = try await AgentRecoveryActionRequest(
            actionID: UUID(), itemKey: key, kind: .sendSaved, expectedRevision: revision(),
            sourceIntentIDs: [intentID], target: target
        )
        _ = try await previous.reserveRecoveryAction(binding: lane.binding, request: old)
        _ = try await previous.beginDispatch(
            binding: lane.binding,
            expectedRevision: revision(),
            intentID: intentID,
            attempt: AgentRecoveryAttemptStart(attemptID: UUID(), runAttemptID: nil),
            authorization: .explicitUserAction
        )
        let beforeLoaded = try await record()
        let before = try XCTUnwrap(beforeLoaded)
        let oldStored = try XCTUnwrap(before.action(id: old.actionID))
        guard case .dispatchEvidence = before.join(oldStored) else { return XCTFail("expected dispatch evidence") }

        let first = try await runner.perform(continuation(key: key, expectedRevision: revision()), lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        guard case let .priorAction(priorID, .dispatchEvidence(evidenceIntent, _)) = first else {
            return XCTFail("expected the uncertain prior action, got \(first)")
        }
        XCTAssertEqual(priorID, old.actionID)
        XCTAssertEqual(evidenceIntent, intentID)

        let unconfirmed = try await runner.perform(
            continuation(key: key, expectedRevision: revision(), supersedes: old.actionID),
            lane: lane,
            performers: performers(calls, reconcile: .nothingImported("none"))
        )
        guard case .refused = unconfirmed else { return XCTFail("an unconfirmed replacement is refused, got \(unconfirmed)") }
        let resend = try await runner.perform(
            AgentRecoveryActionRequest(
                actionID: UUID(), itemKey: key, kind: .sendSaved, expectedRevision: revision(),
                sourceIntentIDs: [intentID], target: target, supersedesActionID: old.actionID,
                confirmsUncertainPriorDelivery: true
            ),
            lane: lane,
            performers: performers(calls, reconcile: .nothingImported("none"))
        )
        guard case .refused = resend else { return XCTFail("the old input is never retried, got \(resend)") }
        XCTAssertEqual(calls.dispatch, 0)

        let confirmed = try await continuation(
            key: key, expectedRevision: revision(), supersedes: old.actionID, confirmsUncertainPrior: true
        )
        let sent = await runner.perform(confirmed, lane: lane, performers: performers(calls, reconcile: .nothingImported("none")))
        XCTAssertEqual(sent, .completed(.dispatched, reason: nil))
        XCTAssertEqual(calls.dispatch, 1)
        let afterLoaded = try await record()
        let after = try XCTUnwrap(afterLoaded)
        XCTAssertEqual(after.action(id: old.actionID), oldStored, "the old action is kept unchanged")
        XCTAssertEqual(after.intent(id: intentID), before.intent(id: intentID), "the old intent is kept unchanged")
        XCTAssertEqual(
            after.attempts(forIntent: intentID).map(\.attemptID),
            before.attempts(forIntent: intentID).map(\.attemptID),
            "the old input is never retried"
        )
        XCTAssertEqual(after.attempts.count, before.attempts.count + 1, "only the new continuation's own delivery attempt")

        let reopened = AgentRecoveryStore(rootURL: fixture.root.appendingPathComponent("AgentRecovery/v1", isDirectory: true))
        let reopenedState = await reopened.read(sessionID: fixture.sessionID)
        let decoded = try XCTUnwrap(reopenedState.record?.action(id: confirmed.actionID))
        XCTAssertEqual(decoded.supersedesActionID, old.actionID)
        XCTAssertTrue(decoded.confirmedUncertainPriorDelivery)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}
