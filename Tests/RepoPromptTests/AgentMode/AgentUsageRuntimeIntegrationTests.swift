import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptWorkspace
@_spi(TestSupport) @testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
import XCTest

/// Runtime integration of `providerUsage` accounting through the production ViewModel seams
/// (plan §3.2/§3.3): persisted hydration, controller install/replace/remove, the session-owned
/// usage-evidence forwarder, save, projection and handoff.
///
/// Execution identity is created by the controller's `.launched` usage event (an actual process
/// spawn) and disposed by `.launchEnded`, never by controller installation. Production verifies
/// every execution (`.productionClaude == .executionVerified`): opaque/foreign payloads stay
/// byte-for-byte untouched, owned records are continued, and captured 2.1.268 wire replays charge
/// through the production controller → forwarder → accumulator path under the shipped contract.
@MainActor
final class AgentUsageRuntimeIntegrationTests: XCTestCase {
    private let qualified = AgentUsageQualification.qualified(contractID: "test.claude.cumulative.v1")
    private let syntheticVersion = "0.0.0-test"
    private var syntheticContractID: String {
        "test.claude.stream-json.v1@\(syntheticVersion)"
    }

    override func tearDown() {
        ClaudeNativeUsageContract.test_contractsOverride = nil
        super.tearDown()
    }

    // MARK: - Hydration → controller lifecycle → save (opaque/foreign payloads stay untouched)

    func testHydrationPreservesNullOpaqueAndForeignUsageThroughControllerLifecycleAndSave() async throws {
        let foreignOrigin = UUID()
        let foreignRecord = AgentProviderUsageRecord(
            originSessionID: foreignOrigin,
            trackingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasUnmeasuredHistory: true
        )
        let foreignRawJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(foreignRecord))
        let unknownSchemaJSON: [String: Any] = [
            "schemaVersion": 2,
            "turns": "future",
            "nested": ["k": [1, 2, ["deep": NSNull()]]]
        ]
        let cases: [(label: String, seed: AgentProviderUsagePersist?, rawMember: Any?, expectedEligibility: AgentUsageEligibility)] = [
            ("explicit null", .opaque(.null), nil, .opaquePersistedValue),
            ("unknown schema object", nil, unknownSchemaJSON, .opaquePersistedValue),
            ("foreign record", .record(foreignRecord), nil, .foreignOrigin(foreignOrigin))
        ]

        for testCase in cases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let persistedBeforeHydration = try await fixture.seedPersistedSession(
                providerUsage: testCase.seed,
                rawProviderUsageMember: testCase.rawMember
            )
            let expectedRawMember: Any = testCase.rawMember
                ?? (testCase.seed == .opaque(.null) ? NSNull() : foreignRawJSON)
            XCTAssertNotNil(persistedBeforeHydration.providerUsage, testCase.label)

            // A controller arriving before hydration installs a lifecycle-only accumulator; no
            // execution exists until the runtime reports an actual process launch.
            let firstController = UsageEvidenceFakeNativeController(label: "first")
            fixture.session.claudeController = firstController
            XCTAssertNil(fixture.session.usageAccounting?.persistedRepresentation, testCase.label)
            XCTAssertNil(fixture.session.usageAccounting?.activeExecutionID, testCase.label)
            let firstLaunch = firstController.emitLaunch()
            await waitUntil("\(testCase.label): launch registered") {
                fixture.session.usageAccounting?.activeExecutionID == firstLaunch.token
            }

            let payload = try await fixture.hydrationPayload()
            let didHydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
            XCTAssertTrue(didHydrate, testCase.label)
            let hydrated = try XCTUnwrap(fixture.session.usageAccounting, testCase.label)
            XCTAssertEqual(hydrated.ownerSessionID, fixture.sessionID, testCase.label)
            XCTAssertEqual(hydrated.qualification, .executionVerified, testCase.label)
            XCTAssertEqual(hydrated.eligibility, testCase.expectedEligibility, testCase.label)
            XCTAssertEqual(hydrated.persistedRepresentation, persistedBeforeHydration.providerUsage, testCase.label)
            XCTAssertEqual(
                hydrated.activeExecutionID,
                firstLaunch.token,
                "\(testCase.label): the live launch is re-registered on the hydrated accumulator"
            )

            // Controller replacement disposes the launch's execution immediately.
            let secondController = UsageEvidenceFakeNativeController(label: "second")
            fixture.session.claudeController = secondController
            XCTAssertNil(fixture.session.usageAccounting?.activeExecutionID, testCase.label)
            let secondLaunch = secondController.emitLaunch()
            await waitUntil("\(testCase.label): second launch registered") {
                fixture.session.usageAccounting?.activeExecutionID == secondLaunch.token
            }
            XCTAssertNotEqual(secondLaunch.token, firstLaunch.token, testCase.label)
            XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, persistedBeforeHydration.providerUsage, testCase.label)

            // Production-shaped evidence (dispatch, version, attributed result, completion) qualifies
            // the execution but an ineligible owner never touches the persisted payload.
            let turnID = UUID()
            secondController.emit(.dispatched(launchToken: secondLaunch.token, turnID: turnID, ordinal: 0))
            secondController.emit(.runtimeEvidence(launchToken: secondLaunch.token, runtimeVersion: "2.1.268", providerSessionID: "ps"))
            secondController.emit(.resultAttributed(Self.attribution(
                launch: secondLaunch, turnID: turnID, ordinal: 0, uuid: "res-live", cost: 1.25
            )))
            await waitUntil("\(testCase.label): evidence drained") {
                fixture.session.test_ingestedNativeUsageEventCount >= firstController.emittedCount + secondController.emittedCount
            }
            XCTAssertEqual(
                fixture.session.usageAccounting?.executionVerdict,
                .qualified(contractID: ClaudeNativeUsageContract.supported2_1_268.contractID, baseline: .verifiedZero),
                testCase.label
            )
            secondController.emit(.turnClosed(launchToken: secondLaunch.token, turnID: turnID, status: .completed))
            // Both controllers' events flow through the one session seam; the dispatch identity is
            // registered (executionVerified) and retired only once the closure has been ingested.
            await waitUntil("\(testCase.label): closure drained") {
                fixture.session.test_ingestedNativeUsageEventCount >= firstController.emittedCount + secondController.emittedCount
            }
            XCTAssertEqual(
                fixture.session.usageAccounting?.closeTurn(turnID, outcome: .completed),
                .rejected(.unregisteredTurn),
                "\(testCase.label): lifecycle closure already retired the dispatch identity"
            )
            XCTAssertEqual(fixture.session.usageAccounting?.ownedRevision, 0, testCase.label)
            XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, persistedBeforeHydration.providerUsage, testCase.label)
            XCTAssertNil(fixture.session.usageAccounting?.sessionCostEstimate, testCase.label)
            XCTAssertNil(fixture.session.usageAccounting?.cacheHitShare, testCase.label)

            // The production save projects the hydrated payload verbatim.
            fixture.session.isDirty = true
            await fixture.viewModel.flushSave(for: fixture.tabID)
            let reloaded = try await fixture.reloadPersistedSession()
            XCTAssertEqual(reloaded.providerUsage, persistedBeforeHydration.providerUsage, testCase.label)
            let rawAfterSave = try fixture.rawProviderUsageMember() as AnyObject
            XCTAssertTrue(
                rawAfterSave.isEqual(expectedRawMember),
                "\(testCase.label): raw providerUsage member must be written back unchanged, got \(rawAfterSave)"
            )

            // Removal keeps the execution alive until the process reports its end.
            fixture.session.claudeController = nil
            XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, secondLaunch.token, testCase.label)
            secondController.emit(.launchEnded(launchToken: secondLaunch.token))
            await waitUntil("\(testCase.label): launch ended") {
                fixture.session.usageAccounting?.activeExecutionID == nil
            }
            XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, persistedBeforeHydration.providerUsage, testCase.label)
        }
    }

    func testRefusedLateHydrationNeverOverwritesPersistedUsageAndResyncsSurvivingLaunch() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let persisted = try await fixture.seedPersistedSession(providerUsage: .opaque(.null), rawProviderUsageMember: nil)

        // A qualified accumulator that begins an execution before hydration owns mutations and
        // therefore refuses the late hydration. The on-disk payload must still win.
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID,
            persisted: nil,
            hasPriorHistory: false,
            qualification: qualified
        )
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        await waitUntil("launch registered") { fixture.session.usageAccounting?.activeExecutionID == launch.token }
        let owned = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertNotNil(owned.persistedRepresentation?.record, "qualified execution materializes an owned record")
        var refused = owned
        XCTAssertFalse(refused.applyHydration(persisted.providerUsage, hasPriorHistory: true))

        let payload = try await fixture.hydrationPayload()
        let didHydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
        XCTAssertTrue(didHydrate)
        let hydrated = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(hydrated.persistedRepresentation, persisted.providerUsage)
        XCTAssertNil(hydrated.persistedRepresentation?.record)
        XCTAssertEqual(hydrated.qualification, .executionVerified)
        XCTAssertEqual(hydrated.activeExecutionID, launch.token, "the surviving launch is re-registered as its execution")

        fixture.session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)
        let reloaded = try await fixture.reloadPersistedSession()
        XCTAssertEqual(reloaded.providerUsage, persisted.providerUsage)
        let rawAfterSave = try fixture.rawProviderUsageMember() as AnyObject
        XCTAssertTrue(rawAfterSave.isEqual(NSNull()), "got \(rawAfterSave)")

        // Route activation resets accounting while the launch survives; hydration must
        // re-register the execution instead of leaving later dispatches unregistered.
        fixture.session.usageAccounting = nil
        let didRehydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
        XCTAssertTrue(didRehydrate)
        let reactivated = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(reactivated.activeExecutionID, launch.token)
        XCTAssertEqual(reactivated.persistedRepresentation, persisted.providerUsage)

        fixture.session.claudeController = nil
        controller.emit(.launchEnded(launchToken: launch.token))
        await waitUntil("launch ended") { fixture.session.usageAccounting?.activeExecutionID == nil }
    }

    // MARK: - Hydration during a live launch (OracleA P0#3 / OracleB P1#1)

    /// Save → hydration replacement → next result on the **same process**: the persisted open segment
    /// is continued (its checkpoint stays the baseline), no zero-based segment is reopened, and the
    /// turn that was in flight at save time is re-registered so its result still lands.
    func testHydrationDuringALiveQualifiedLaunchContinuesItsPersistedSegmentWithoutReopeningTheBaseline() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.seedPersistedSession(providerUsage: nil, rawProviderUsageMember: nil)
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        let turn1 = UUID()
        let turn2 = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn1, ordinal: 0))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn1, ordinal: 0, uuid: "r1", cost: 1, input: 10, read: 90, creation: 0, output: 0
        )))
        // In flight at save time.
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn2, ordinal: 1))
        await drained(fixture, controller, label: "first interval drained")
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate?.amount, 1)
        fixture.session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)

        let payload = try await fixture.hydrationPayload()
        let didHydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
        XCTAssertTrue(didHydrate)
        let hydrated = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(hydrated.activeExecutionID, launch.token)
        XCTAssertEqual(hydrated.executionVerdict, .qualified(contractID: syntheticContractID, baseline: .verifiedZero))
        XCTAssertEqual(hydrated.record?.claudeSegments.count, 1, "the persisted open segment is continued, never reopened at zero")
        XCTAssertEqual(hydrated.record?.claudeSegments.first?.latestCumulative, 1)
        XCTAssertEqual(hydrated.record?.turns.map(\.outcome), [.completed, .open])

        // The cumulative $2 result on the same process adds only the additional $1.
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn2, ordinal: 1, uuid: "r2", cost: 2, input: 10, read: 90, creation: 0, output: 0
        )))
        controller.emit(.launchEnded(launchToken: launch.token))
        await waitUntil("launch ended after hydration") { fixture.session.usageAccounting?.activeExecutionID == nil }
        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.claudeSegments.count, 1)
        XCTAssertEqual(record.claudeSegments.first?.baseline, 0)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, 2)
        XCTAssertEqual(record.claudeSegments.first?.acceptedResultOrder, 2)
        XCTAssertEqual(record.claudeSegments.first?.state, .closed)
        XCTAssertEqual(record.claudeSegments.first?.coverage, .complete)
        XCTAssertEqual(record.turns.map(\.acceptedResultID), ["r1", "r2"])
        XCTAssertEqual(record.turns.map(\.outcome), [.completed, .completed])
        XCTAssertFalse(record.hasUnmeasuredHistory)
        XCTAssertEqual(accounting.sessionCostEstimate, .init(amount: 2, currency: "USD", coverage: .complete))
        XCTAssertEqual(accounting.cacheHitShare, .init(ratio: Decimal(9) / Decimal(10), coverage: .complete))
        let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $2.00")
        assertSessionAverage("90.0%", in: projection)
    }

    /// A launch blocked before the save stays blocked after hydration replaces the accumulator:
    /// the suspended segment is not reopened, and the process's later results are still rejected.
    func testHydrationDuringALiveBlockedLaunchKeepsItBlockedWithoutReopeningASegment() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.seedPersistedSession(providerUsage: nil, rawProviderUsageMember: nil)
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        let turn1 = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn1, ordinal: 0))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn1, ordinal: 0, uuid: "r1", cost: 1, input: 10, read: 90, creation: 0, output: 0
        )))
        // The synthetic contract does not qualify compaction: the execution blocks after $1.
        controller.emit(.counterBoundaryObserved(launchToken: launch.token, kind: "compact_boundary"))
        await drained(fixture, controller, label: "blocked drained")
        XCTAssertEqual(fixture.session.usageAccounting?.executionVerdict, .blocked(.unsupportedCounterBoundary("compact_boundary")))
        fixture.session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)

        let payload = try await fixture.hydrationPayload()
        let didHydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
        XCTAssertTrue(didHydrate)
        let hydrated = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(hydrated.activeExecutionID, launch.token)
        XCTAssertEqual(hydrated.executionVerdict, .blocked(.unsupportedCounterBoundary("compact_boundary")), "the block survives replacement")
        XCTAssertEqual(hydrated.record?.claudeSegments.count, 1)
        XCTAssertEqual(hydrated.record?.claudeSegments.first?.state, .suspended)

        let turn2 = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn2, ordinal: 1))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn2, ordinal: 1, uuid: "r2", cost: 2, input: 10, read: 90, creation: 0, output: 0
        )))
        controller.emit(.launchEnded(launchToken: launch.token))
        await waitUntil("blocked launch ended") { fixture.session.usageAccounting?.activeExecutionID == nil }
        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.claudeSegments.count, 1)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, 1)
        XCTAssertEqual(record.turns.compactMap(\.acceptedResultID), ["r1"])
        XCTAssertTrue(record.hasUnmeasuredHistory, "the dispatch on the blocked execution is uncounted work")
        XCTAssertEqual(accounting.sessionCostEstimate, .init(amount: 1, currency: "USD", coverage: .partial))
    }

    // MARK: - Same controller detached and re-attached while its launch drains (OracleB P1#3)

    func testReattachingTheSameControllerWhileItsLaunchDrainsKeepsTheForwarderAndExecution() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.seedPersistedSession(providerUsage: nil, rawProviderUsageMember: nil)
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        let turn = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
        await drained(fixture, controller, label: "dispatch drained")

        // Detach with the launch alive: the forwarder keeps draining. Re-attaching the very same
        // instance must neither cancel that forwarder (the stream would end for good) nor dispose
        // the execution.
        fixture.session.claudeController = nil
        XCTAssertTrue(fixture.session.test_isUsageAccountingForwardingActive)
        XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, launch.token)
        fixture.session.claudeController = controller
        XCTAssertTrue(fixture.session.test_isUsageAccountingForwardingActive)
        XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, launch.token)
        XCTAssertEqual(fixture.session.usageAccounting?.executionVerdict, .qualified(contractID: syntheticContractID, baseline: .verifiedZero))

        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn, ordinal: 0, uuid: "r1", cost: 1, input: 10, read: 90, creation: 0, output: 0
        )))
        await drained(fixture, controller, label: "result drained after reattach")
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate, .init(amount: 1, currency: "USD", coverage: .complete))
        controller.emit(.launchEnded(launchToken: launch.token))
        await waitUntil("launch ended after reattach") { fixture.session.usageAccounting?.activeExecutionID == nil }
        XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation?.record?.claudeSegments.first?.state, .closed)
    }

    // MARK: - Re-delivered launch evidence keeps continuity (review R2, OracleA P1#3)

    /// A controller resubscription bootstraps the new subscriber with the current launch's
    /// already-emitted evidence. For a launch this session already holds, the re-delivered
    /// `launched` is ignored (never a second zero baseline) and the rest is idempotent, so the
    /// next cumulative result still yields one $2 contribution in one segment.
    func testRedeliveredEvidenceForTheHeldLaunchKeepsContinuityWithoutASecondBaseline() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.seedPersistedSession(providerUsage: nil, rawProviderUsageMember: nil)
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        let turn0 = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn0, ordinal: 0))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn0, ordinal: 0, uuid: "r1", cost: 1, input: 10, read: 90, creation: 0, output: 0
        )))
        await drained(fixture, controller, label: "first result drained")
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate, .init(amount: 1, currency: "USD", coverage: .complete))
        let revisionBeforeRedelivery = fixture.session.usageAccounting?.ownedRevision

        // The bootstrap of a later subscription: the held launch's evidence delivered again.
        controller.emit(.launched(launch))
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn0, ordinal: 0))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn0, ordinal: 0, uuid: "r1", cost: 1, input: 10, read: 90, creation: 0, output: 0
        )))
        await drained(fixture, controller, label: "re-delivered evidence drained")
        XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, launch.token, "the execution is neither ended nor reopened")
        XCTAssertEqual(fixture.session.usageAccounting?.executionVerdict, .qualified(contractID: syntheticContractID, baseline: .verifiedZero))
        XCTAssertEqual(fixture.session.usageAccounting?.ownedRevision, revisionBeforeRedelivery, "re-delivered evidence mutates nothing")
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate, .init(amount: 1, currency: "USD", coverage: .complete))

        let turn1 = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn1, ordinal: 1))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn1, ordinal: 1, uuid: "r2", cost: 2, input: 10, read: 90, creation: 0, output: 0
        )))
        await drained(fixture, controller, label: "second result drained")
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate, .init(amount: 2, currency: "USD", coverage: .complete), "one contribution from the continued checkpoint, not $1 + $2")
        controller.emit(.launchEnded(launchToken: launch.token))
        await waitUntil("launch ended") { fixture.session.usageAccounting?.activeExecutionID == nil }
        let record = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.claudeSegments.count, 1)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, 2)
        XCTAssertEqual(record.turns.compactMap(\.acceptedResultID), ["r1", "r2"])
        XCTAssertFalse(record.hasUnmeasuredHistory)
    }

    // MARK: - Production policy continues an owned, valid restored record

    func testProductionPolicyContinuesEligibleRestoredRecordThroughDispatchAndSave() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let oldExecution = UUID()
        var restored = AgentProviderUsageRecord(
            originSessionID: fixture.sessionID,
            trackingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasUnmeasuredHistory: false
        )
        restored.turns = [
            .init(
                executionID: oldExecution,
                segmentIndex: 0,
                turnID: UUID(),
                acceptedResultID: "old-1",
                inputTokens: 10,
                outputTokens: 1,
                cacheReadInputTokens: 90,
                cacheCreationInputTokens: 0,
                outcome: .completed,
                coverage: .complete
            )
        ]
        restored.claudeSegments = [
            .init(
                contractID: "old",
                provider: "claude",
                providerSessionID: nil,
                executionID: oldExecution,
                resetGeneration: 0,
                baseline: 0,
                latestCumulative: Decimal(string: "0.4"),
                currency: "USD",
                acceptedResultID: "old-1",
                acceptedResultOrder: 1,
                state: .closed,
                coverage: .complete
            )
        ]
        let seeded = try await fixture.seedPersistedSession(providerUsage: .record(restored), rawProviderUsageMember: nil)
        let rawBefore = try XCTUnwrap(fixture.rawProviderUsageMember() as AnyObject)
        let payload = try await fixture.hydrationPayload()
        let didHydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
        XCTAssertTrue(didHydrate)
        let hydrated = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(hydrated.qualification, .executionVerified)
        XCTAssertEqual(hydrated.eligibility, .eligible)
        XCTAssertEqual(hydrated.persistedRepresentation, seeded.providerUsage)

        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        let turn = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: "2.1.268", providerSessionID: "ps"))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn, ordinal: 0, uuid: "live", cost: 9, input: 1, read: 1, creation: 0, output: 0
        )))
        controller.emit(.turnClosed(launchToken: launch.token, turnID: turn, status: .completed))
        controller.emit(.launchEnded(launchToken: launch.token))
        await drained(fixture, controller)
        let after = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertGreaterThan(after.ownedRevision, 0, "the continuation is owned and charged")
        let record = try XCTUnwrap(after.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.hasUnmeasuredHistory, false)
        XCTAssertEqual(record.turns.count, 2)
        XCTAssertEqual(record.turns.last?.acceptedResultID, "live")
        XCTAssertEqual(record.turns.last?.segmentIndex, 1)
        XCTAssertEqual(record.claudeSegments.count, 2)
        XCTAssertEqual(record.claudeSegments[0], restored.claudeSegments[0], "the restored segment is never rewritten")
        XCTAssertEqual(record.claudeSegments[1].contractID, ClaudeNativeUsageContract.supported2_1_268.contractID)
        XCTAssertEqual(record.claudeSegments[1].baseline, 0)
        XCTAssertEqual(record.claudeSegments[1].latestCumulative, 9)
        XCTAssertEqual(record.claudeSegments[1].state, .closed)
        XCTAssertEqual(record.claudeSegments[1].coverage, .complete)
        XCTAssertNil(after.activeExecutionID)
        let expectedCombinedCost = try XCTUnwrap(Decimal(string: "9.4"))
        XCTAssertEqual(after.sessionCostEstimate, .init(amount: expectedCombinedCost, currency: "USD", coverage: .complete))

        // Restored and live figures combine as complete coverage (91 cached of 102 input tokens).
        let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $9.40")
        assertSessionAverage("89.2%", in: projection)
        XCTAssertNil(projection.unavailableReason)
        XCTAssertNil(projection.coverageDetail)

        fixture.session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)
        let rawAfter = try XCTUnwrap(fixture.rawProviderUsageMember() as AnyObject)
        XCTAssertFalse(rawAfter.isEqual(rawBefore), "the owned typed record replaces the restored bytes")
        let reloaded = try await fixture.reloadPersistedSession()
        XCTAssertEqual(reloaded.providerUsage?.record, record)
    }

    // MARK: - Qualified launch through the session-owned seam

    func testQualifiedFreshLaunchChargesThroughForwarderProjectionSaveAndReload() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.seedPersistedSession(providerUsage: nil, rawProviderUsageMember: nil)
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID,
            persisted: nil,
            hasPriorHistory: false,
            qualification: .executionVerified
        )
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        let turn0 = UUID()
        let turn1 = UUID()
        // Dispatch before version evidence is retained in order; nothing materializes yet.
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn0, ordinal: 0))
        await waitUntil("dispatch registered while awaiting") {
            fixture.session.usageAccounting?.hasUnchargedDispatchedWork == true
        }
        XCTAssertNil(fixture.session.usageAccounting?.persistedRepresentation)
        var projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: —")
        XCTAssertEqual(
            projection.unavailableReason,
            "No live figures: the runtime has not reported its version yet. This session's turns are not counted."
        )

        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps-1"))
        await waitUntil("execution qualified") {
            fixture.session.usageAccounting?.executionVerdict?.isQualified == true
        }
        let backfilled = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
        XCTAssertEqual(backfilled.turns.map(\.turnID), [turn0])
        XCTAssertEqual(backfilled.claudeSegments.first?.contractID, syntheticContractID)
        XCTAssertEqual(backfilled.claudeSegments.first?.baseline, 0)

        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn0, ordinal: 0, uuid: "res-0", cost: 0.5, input: 10, read: 90, creation: 0, output: 1
        )))
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn1, ordinal: 1))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn1, ordinal: 1, uuid: "res-1", cost: 0.75, input: 10, read: 90, creation: 0, output: 1,
            status: .cancelled, subtype: "error_during_execution", isError: true
        )))
        await waitUntil("both results accepted") {
            fixture.session.usageAccounting?.persistedRepresentation?.record?.turns.count == 2
                && fixture.session.usageAccounting?.persistedRepresentation?.record?.turns.last?.acceptedResultID == "res-1"
        }
        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertEqual(record.turns[0].outcome, .completed)
        XCTAssertEqual(record.turns[0].coverage, .complete)
        XCTAssertEqual(record.turns[1].outcome, .interrupted, "an original cancellation result finalizes its turn as interrupted")
        XCTAssertEqual(record.turns[1].cacheReadInputTokens, 90)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, Decimal(string: "0.75"))
        let expectedCost = try XCTUnwrap(Decimal(string: "0.75"))
        let expectedShare = try XCTUnwrap(Decimal(string: "0.9"))
        XCTAssertEqual(accounting.sessionCostEstimate, .init(amount: expectedCost, currency: "USD", coverage: .complete))
        XCTAssertEqual(accounting.cacheHitShare, .init(ratio: expectedShare, coverage: .complete))

        // UI projection readout (context pill / sidebar card) through the session cache.
        projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.75")
        assertSessionAverage("90.0%", in: projection)
        XCTAssertNil(projection.unavailableReason)
        XCTAssertNil(projection.coverageDetail)
        XCTAssertEqual(projection.accountingRevision, accounting.ownedRevision)

        // Duplicate delivery of an accepted result never charges again or republishes.
        let revisionBefore = accounting.ownedRevision
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn1, ordinal: 1, uuid: "res-1", cost: 0.75, input: 10, read: 90, creation: 0, output: 1
        )))
        await drained(fixture, controller, label: "duplicate drained")
        XCTAssertEqual(fixture.session.usageAccounting?.ownedRevision, revisionBefore)

        // Save through the production writer and reload the typed record.
        fixture.session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)
        let reloaded = try await fixture.reloadPersistedSession()
        let reloadedRecord = try XCTUnwrap(reloaded.providerUsage?.record)
        XCTAssertEqual(reloadedRecord.originSessionID, fixture.sessionID)
        XCTAssertEqual(reloadedRecord.turns.map(\.acceptedResultID), ["res-0", "res-1"])
        XCTAssertEqual(reloadedRecord.claudeSegments.first?.contractID, syntheticContractID)
        XCTAssertEqual(reloadedRecord.claudeSegments.first?.latestCumulative, Decimal(string: "0.75"))

        // Launch end closes the segment; the figures stay complete.
        controller.emit(.launchEnded(launchToken: launch.token))
        await waitUntil("launch ended") { fixture.session.usageAccounting?.activeExecutionID == nil }
        XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation?.record?.claudeSegments.first?.state, .closed)
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate?.coverage, .complete)
    }

    func testLateCancellationResultAfterControllerRemovalIsDeliveredAndDisposedLaunchRejectsLaterInput() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
        )
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        let turn = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
        await waitUntil("turn open") {
            fixture.session.usageAccounting?.persistedRepresentation?.record?.turns.first?.outcome == .open
        }

        // Cancel: the coordinator detaches the controller synchronously (run consumer gone), then
        // interrupts and shuts the process down. The trailing cancellation result arrives after
        // detach and must still be attributed by the session-owned forwarder.
        fixture.session.claudeController = nil
        XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, launch.token)
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn, ordinal: 0, uuid: "abort", cost: 0.2, input: 5, read: 95, creation: 0, output: 0,
            status: .cancelled, subtype: "error_during_execution", isError: true
        )))
        await waitUntil("late cancellation accepted") {
            fixture.session.usageAccounting?.persistedRepresentation?.record?.turns.first?.acceptedResultID == "abort"
        }
        XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation?.record?.turns.first?.outcome, .interrupted)
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate?.amount, Decimal(string: "0.2"))

        controller.emit(.launchEnded(launchToken: launch.token))
        await waitUntil("launch ended") { fixture.session.usageAccounting?.activeExecutionID == nil }
        XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation?.record?.claudeSegments.first?.state, .closed)

        // Anything after the launch ended is late input for a disposed execution.
        XCTAssertEqual(
            fixture.session.usageAccounting?.registerTurn(UUID(), executionID: launch.token),
            .rejected(.disposedExecution)
        )
        let revision = fixture.session.usageAccounting?.ownedRevision
        fixture.session.ingestNativeUsageAccountingEvent(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn, ordinal: 0, uuid: "late", cost: 9, input: 1, read: 1, creation: 0, output: 0
        )))
        XCTAssertEqual(fixture.session.usageAccounting?.ownedRevision, revision, "a disposed execution never charges")
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate?.amount, Decimal(string: "0.2"))
    }

    func testControllerReplacementDisposesTheOldLaunchAndItsLateResultCannotReachTheNewExecution() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
        )
        let old = UsageEvidenceFakeNativeController(label: "old")
        fixture.session.claudeController = old
        let oldLaunch = old.emitLaunch()
        old.emit(.runtimeEvidence(launchToken: oldLaunch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        let oldTurn = UUID()
        old.emit(.dispatched(launchToken: oldLaunch.token, turnID: oldTurn, ordinal: 0))
        await waitUntil("old turn open") {
            fixture.session.usageAccounting?.persistedRepresentation?.record?.turns.first?.outcome == .open
        }

        let replacement = UsageEvidenceFakeNativeController(label: "replacement")
        fixture.session.claudeController = replacement
        let disposed = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
        XCTAssertNil(fixture.session.usageAccounting?.activeExecutionID)
        XCTAssertEqual(disposed.turns.first?.outcome, .interrupted)
        XCTAssertEqual(disposed.turns.first?.coverage, .partial)
        XCTAssertEqual(disposed.claudeSegments.first?.state, .closed)
        XCTAssertEqual(disposed.claudeSegments.first?.coverage, .partial)

        let newLaunch = replacement.emitLaunch()
        replacement.emit(.runtimeEvidence(launchToken: newLaunch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps-2"))
        await waitUntil("new execution qualified") {
            fixture.session.usageAccounting?.activeExecutionID == newLaunch.token
                && fixture.session.usageAccounting?.executionVerdict?.isQualified == true
        }
        // The old controller's late result (already cancelled forwarder, and a disposed token).
        old.emit(.resultAttributed(Self.attribution(
            launch: oldLaunch, turnID: oldTurn, ordinal: 0, uuid: "old-late", cost: 3, input: 1, read: 1, creation: 0, output: 0
        )))
        fixture.session.ingestNativeUsageAccountingEvent(.resultAttributed(Self.attribution(
            launch: oldLaunch, turnID: oldTurn, ordinal: 0, uuid: "old-late", cost: 3, input: 1, read: 1, creation: 0, output: 0
        )))
        let record = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
        XCTAssertEqual(record.claudeSegments.count, 2)
        XCTAssertNil(record.claudeSegments.last?.latestCumulative)
        XCTAssertEqual(record.turns.first?.acceptedResultID, nil)
        XCTAssertNil(fixture.session.usageAccounting?.sessionCostEstimate, "no accepted checkpoint on either segment")
    }

    func testUnknownRuntimeCountsTokensOnlyWhileResumedLaunchQueueDepthAndCompactionStayBlockedWithVisibleReasons() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        // Unknown version (no recorded contract): token observations count, cumulative cost is
        // unavailable for this execution, and the readout names that scope visibly.
        do {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            fixture.session.usageAccounting = AgentUsageAccumulator(
                ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
            )
            let controller = UsageEvidenceFakeNativeController()
            fixture.session.claudeController = controller
            let launch = controller.emitLaunch()
            let turn = UUID()
            controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
            controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: "2.1.268", providerSessionID: "ps"))
            controller.emit(.resultAttributed(Self.attribution(
                launch: launch, turnID: turn, ordinal: 0, uuid: "r", cost: 1, input: 1, read: 1, creation: 0, output: 0
            )))
            await drained(fixture, controller, label: "unknown version drained")
            XCTAssertEqual(
                fixture.session.usageAccounting?.executionVerdict,
                .qualified(contractID: "claude-native.tokens-only.v1@2.1.268", baseline: .unsupported)
            )
            let record = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
            XCTAssertNil(record.semanticViolation)
            XCTAssertEqual(record.turns.first?.acceptedResultID, "r")
            XCTAssertEqual(record.turns.first?.coverage, .complete)
            XCTAssertEqual(record.claudeSegments.first?.contractID, "claude-native.tokens-only.v1@2.1.268")
            XCTAssertNil(record.claudeSegments.first?.baseline)
            XCTAssertNil(record.claudeSegments.first?.latestCumulative, "a reported cost is never checkpointed without an established cadence")
            XCTAssertEqual(record.claudeSegments.first?.acceptedResultOrder, 0)
            XCTAssertEqual(record.claudeSegments.first?.coverage, .unavailable)
            XCTAssertFalse(record.hasUnmeasuredHistory, "tokens are fully measured; only the cost scope is unavailable")
            XCTAssertNil(fixture.session.usageAccounting?.sessionCostEstimate)
            XCTAssertEqual(fixture.session.usageAccounting?.cacheHitShare, .init(ratio: Decimal(1) / Decimal(2), coverage: .complete))
            let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
            XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: —")
            assertSessionAverage("50.0%", in: projection)
            XCTAssertNil(projection.unavailableReason)
            XCTAssertEqual(
                projection.coverageDetail,
                "The current continuation counts tokens only: provider-reported cost is not established for claude_code_version 2.1.268; only token usage is counted."
            )
            XCTAssertNil(projection.presentation.noteText)
            let metricParagraphs = try XCTUnwrap(projection.presentation.expandedDetailText)
                .components(separatedBy: "\n\n")
            let cacheParagraph = try XCTUnwrap(metricParagraphs.first { $0.hasPrefix("Session-average CH:") })
            let costParagraph = try XCTUnwrap(metricParagraphs.first { $0.hasPrefix("Accumulated session cost:") })
            XCTAssertFalse(cacheParagraph.contains("counts tokens only"), "a cost-only limitation must not contaminate CH coverage")
            XCTAssertTrue(costParagraph.contains("counts tokens only"), "the cost metric retains its actual limitation")
        }

        // Resumed launch on the qualified version: launch mode not qualified.
        do {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            fixture.session.usageAccounting = AgentUsageAccumulator(
                ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
            )
            let controller = UsageEvidenceFakeNativeController()
            fixture.session.claudeController = controller
            let launch = controller.emitLaunch(mode: .resumedSession("ps-resumed"))
            controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps-resumed"))
            await waitUntil("resumed blocked") {
                fixture.session.usageAccounting?.executionVerdict == .blocked(.unsupportedLaunchMode("resumedSession"))
            }
            XCTAssertNil(fixture.session.usageAccounting?.persistedRepresentation)
        }

        // Queue depth beyond the qualified bound blocks before the affected result is charged;
        // an already-qualified segment is suspended with its amounts intact.
        do {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            fixture.session.usageAccounting = AgentUsageAccumulator(
                ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
            )
            let controller = UsageEvidenceFakeNativeController()
            fixture.session.claudeController = controller
            let launch = controller.emitLaunch()
            controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
            let turn0 = UUID()
            let turn1 = UUID()
            controller.emit(.dispatched(launchToken: launch.token, turnID: turn0, ordinal: 0))
            controller.emit(.resultAttributed(Self.attribution(
                launch: launch, turnID: turn0, ordinal: 0, uuid: "ok", cost: 0.4, input: 1, read: 9, creation: 0, output: 0
            )))
            controller.emit(.dispatched(launchToken: launch.token, turnID: turn1, ordinal: 1))
            controller.emit(.resultAttributed(Self.attribution(
                launch: launch, turnID: turn1, ordinal: 1, uuid: "queued", cost: 0.9, input: 1, read: 9, creation: 0, output: 0, queued: 1
            )))
            await waitUntil("queue blocked") {
                fixture.session.usageAccounting?.executionVerdict
                    == .blocked(.unsupportedQueueSemantics("queued_turn_count 1 exceeds qualified bound 0"))
            }
            let record = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
            XCTAssertEqual(record.claudeSegments.first?.state, .suspended)
            XCTAssertEqual(record.claudeSegments.first?.latestCumulative, Decimal(string: "0.4"))
            XCTAssertEqual(record.turns.last?.acceptedResultID, nil)
            let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
            XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.40")
            XCTAssertEqual(projection.costEstimate?.coverage, .partial)
            assertSessionAverage("90.0%", in: projection)
            XCTAssertEqual(
                projection.coverageDetail,
                "The current continuation is not counted: queue semantics are not qualified (queued_turn_count 1 exceeds qualified bound 0)."
            )
            let blockedLatest = try XCTUnwrap(
                fixture.session.usageAccounting?.latestRequestCacheHit(for: .claudeAssistant)
            )
            XCTAssertNil(blockedLatest.share)
            XCTAssertTrue(blockedLatest.detail.contains("not shown because queue semantics are not qualified"))
            XCTAssertFalse(blockedLatest.detail.contains("yet"), "blocked request usage is terminal, not awaiting")

            // Ordinary completion after the block, then launch end, save and reload: no summary
            // stays open, the accepted amount survives, and omitted work keeps coverage partial.
            controller.emit(.turnClosed(launchToken: launch.token, turnID: turn1, status: .completed))
            controller.emit(.launchEnded(launchToken: launch.token))
            await drained(fixture, controller, label: "blocked closure drained")
            let closed = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
            XCTAssertNil(closed.semanticViolation)
            XCTAssertFalse(closed.turns.contains { $0.outcome == .open })
            XCTAssertEqual(closed.turns.last?.coverage, .partial)
            XCTAssertEqual(closed.claudeSegments.first?.latestCumulative, Decimal(string: "0.4"))
            fixture.session.isDirty = true
            await fixture.viewModel.flushSave(for: fixture.tabID)
            let reloaded = try await fixture.reloadPersistedSession()
            let reloadedRecord = try XCTUnwrap(reloaded.providerUsage?.record, "a stranded open summary would make the record opaque")
            XCTAssertFalse(reloadedRecord.turns.contains { $0.outcome == .open })
            XCTAssertEqual(reloadedRecord.claudeSegments.first?.latestCumulative, Decimal(string: "0.4"))
            XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate?.coverage, .partial)
            let afterEnd = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
            XCTAssertEqual(afterEnd.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.40")
            XCTAssertEqual(afterEnd.costEstimate?.coverage, .partial)
            assertSessionAverage("90.0%", in: afterEnd)
        }

        // A compaction boundary blocks before any affected result.
        do {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            fixture.session.usageAccounting = AgentUsageAccumulator(
                ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
            )
            let controller = UsageEvidenceFakeNativeController()
            fixture.session.claudeController = controller
            let launch = controller.emitLaunch()
            controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
            let turn = UUID()
            controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
            controller.emit(.counterBoundaryObserved(launchToken: launch.token, kind: "compact_boundary"))
            controller.emit(.resultAttributed(Self.attribution(
                launch: launch, turnID: turn, ordinal: 0, uuid: "after-compaction", cost: 2, input: 1, read: 9, creation: 0, output: 0
            )))
            await drained(fixture, controller, label: "compaction drained")
            XCTAssertEqual(
                fixture.session.usageAccounting?.executionVerdict,
                .blocked(.unsupportedCounterBoundary("compact_boundary"))
            )
            let record = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
            XCTAssertNil(record.claudeSegments.first?.latestCumulative, "the affected result was never charged")
            XCTAssertEqual(record.claudeSegments.first?.state, .suspended)
            XCTAssertNil(fixture.session.usageAccounting?.sessionCostEstimate)
        }
    }

    // MARK: - Tokens-only continuity across compaction (2026-10-01 compaction continuity plan §3.3)

    /// Saved-session-shaped regression ("P2 follow-up", `claude_code_version` 2.1.281): a resolved
    /// tokens-only execution observes `status:compacting` and `compact_boundary` between two
    /// results. The boundary is observational: the verdict, open `.unavailable` segment, latest
    /// request CH, revisions and record are untouched by it; the next dispatch/result lands in order
    /// and adds its triple exactly once; reported costs are never checkpointed; save/reload
    /// round-trips the owned record.
    func testTokensOnlyExecutionKeepsObservingTokensAcrossCompactionBoundaries() async throws {
        XCTAssertNil(ClaudeNativeUsageContract.test_contractsOverride)
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.seedPersistedSession(providerUsage: nil, rawProviderUsageMember: nil)
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
        )
        let tokensOnly = "claude-native.tokens-only.v1@2.1.281"
        let tokensOnlyVerdict = AgentUsageExecutionVerdict.qualified(contractID: tokensOnly, baseline: .unsupported)
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: "2.1.281", providerSessionID: "ps"))
        let turn1 = UUID()
        let turn2 = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn1, ordinal: 0))
        controller.emit(Self.mainRequest(launch: launch, turnID: turn1, requestID: "msg-1", input: 10, read: 90))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn1, ordinal: 0, uuid: "r1", cost: 0.5, input: 10, read: 90, creation: 0, output: 1
        )))
        controller.emit(.turnClosed(launchToken: launch.token, turnID: turn1, status: .completed))
        await drained(fixture, controller, label: "pre-compaction drained")
        XCTAssertEqual(fixture.session.usageAccounting?.executionVerdict, tokensOnlyVerdict)
        let latestBefore = try XCTUnwrap(fixture.session.usageAccounting?.latestRequestCacheHit(for: .claudeAssistant))
        XCTAssertEqual(latestBefore.requestID, "msg-1")
        XCTAssertEqual(latestBefore.share?.ratio, Decimal(90) / Decimal(100))
        let ownedRevisionBefore = try XCTUnwrap(fixture.session.usageAccounting?.ownedRevision)
        let presentationRevisionBefore = try XCTUnwrap(fixture.session.usageAccounting?.presentationRevision)
        let recordBefore = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)

        controller.emit(.counterBoundaryObserved(launchToken: launch.token, kind: "status:compacting"))
        controller.emit(.counterBoundaryObserved(launchToken: launch.token, kind: "compact_boundary"))
        await drained(fixture, controller, label: "boundaries drained")
        let afterBoundaries = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(afterBoundaries.executionVerdict, tokensOnlyVerdict, "an allowed boundary never blocks a tokens-only execution")
        XCTAssertEqual(afterBoundaries.activeExecutionID, launch.token)
        XCTAssertEqual(afterBoundaries.ownedRevision, ownedRevisionBefore, "a boundary alone causes no owned revision or save")
        XCTAssertEqual(afterBoundaries.presentationRevision, presentationRevisionBefore)
        XCTAssertEqual(afterBoundaries.persistedRepresentation?.record, recordBefore)
        let latestAfterBoundaries = try XCTUnwrap(afterBoundaries.latestRequestCacheHit(for: .claudeAssistant))
        XCTAssertEqual(latestAfterBoundaries, latestBefore, "latest-request CH is not nulled by an allowed boundary")
        XCTAssertFalse(latestAfterBoundaries.detail.hasPrefix("Unavailable"), latestAfterBoundaries.detail)

        controller.emit(.dispatched(launchToken: launch.token, turnID: turn2, ordinal: 1))
        controller.emit(Self.mainRequest(launch: launch, turnID: turn2, requestID: "msg-2", input: 30, read: 70))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn2, ordinal: 1, uuid: "r2", cost: 0.9, input: 30, read: 70, creation: 0, output: 1
        )))
        controller.emit(.turnClosed(launchToken: launch.token, turnID: turn2, status: .completed))
        await drained(fixture, controller, label: "post-compaction drained")
        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(accounting.executionVerdict, tokensOnlyVerdict)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertFalse(record.hasUnmeasuredHistory)
        XCTAssertEqual(record.turns.map(\.turnID), [turn1, turn2])
        XCTAssertEqual(record.turns.map(\.acceptedResultID), ["r1", "r2"])
        XCTAssertEqual(record.turns.map(\.outcome), [.completed, .completed])
        XCTAssertEqual(record.turns.map(\.coverage), [.complete, .complete])
        XCTAssertEqual(record.claudeSegments.count, 1, "the segment is never suspended or reopened")
        let segment = try XCTUnwrap(record.claudeSegments.first)
        XCTAssertEqual(segment.contractID, tokensOnly)
        XCTAssertEqual(segment.executionID, launch.token)
        XCTAssertEqual(segment.state, .open)
        XCTAssertEqual(segment.coverage, .unavailable)
        XCTAssertNil(segment.baseline)
        XCTAssertNil(segment.latestCumulative, "nonzero reported costs are never checkpointed for tokens-only executions")
        XCTAssertEqual(segment.acceptedResultOrder, 0)
        XCTAssertNil(accounting.sessionCostEstimate)
        XCTAssertEqual(accounting.cacheHitShare, .init(ratio: Decimal(160) / Decimal(200), coverage: .complete), "both triples, each exactly once")
        let latestAfter = try XCTUnwrap(accounting.latestRequestCacheHit(for: .claudeAssistant))
        XCTAssertEqual(latestAfter.requestID, "msg-2")
        XCTAssertEqual(latestAfter.share?.ratio, Decimal(70) / Decimal(100))

        fixture.session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)
        let reloaded = try await fixture.reloadPersistedSession()
        XCTAssertEqual(reloaded.providerUsage?.record, record)
    }

    /// A session saved while the pre-amendment rule suspended its tokens-only execution at
    /// compaction is neither migrated nor repaired: the suspended `.unavailable` segment, its
    /// turns and `hasUnmeasuredHistory` survive verbatim. Recovery happens only through a new
    /// launch, which opens its own tokens-only segment and keeps observing tokens across its own
    /// compaction boundary.
    func testHydratedSuspendedTokensOnlyHistoryRecoversOnlyThroughANewLaunchThatObservesTokens() async throws {
        XCTAssertNil(ClaudeNativeUsageContract.test_contractsOverride)
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tokensOnly = ClaudeNativeUsageContract.tokensOnlyContractID(runtimeVersion: "2.1.281")
        let oldExecution = UUID()
        var restored = AgentProviderUsageRecord(
            originSessionID: fixture.sessionID,
            trackingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasUnmeasuredHistory: true
        )
        restored.turns = [
            .init(
                executionID: oldExecution,
                segmentIndex: 0,
                turnID: UUID(),
                acceptedResultID: "old-r1",
                inputTokens: 10,
                outputTokens: 1,
                cacheReadInputTokens: 90,
                cacheCreationInputTokens: 0,
                outcome: .completed,
                coverage: .complete
            ),
            .init(executionID: oldExecution, segmentIndex: 0, turnID: UUID(), outcome: .interrupted, coverage: .partial)
        ]
        restored.claudeSegments = [
            .init(
                contractID: tokensOnly,
                provider: "claude",
                providerSessionID: "ps-old",
                executionID: oldExecution,
                resetGeneration: 0,
                baseline: nil,
                latestCumulative: nil,
                currency: "USD",
                acceptedResultID: nil,
                acceptedResultOrder: 0,
                state: .suspended,
                coverage: .unavailable
            )
        ]
        XCTAssertNil(restored.semanticViolation)
        _ = try await fixture.seedPersistedSession(providerUsage: .record(restored), rawProviderUsageMember: nil)
        let payload = try await fixture.hydrationPayload()
        let didHydrate = await fixture.viewModel.test_applyPersistedHydration(payload, to: fixture.session)
        XCTAssertTrue(didHydrate)
        let hydrated = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(hydrated.eligibility, .eligible)
        XCTAssertEqual(hydrated.record, restored, "hydration never migrates or repairs suspended history")

        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: "2.1.281", providerSessionID: "ps"))
        let turn1 = UUID()
        let turn2 = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn1, ordinal: 0))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn1, ordinal: 0, uuid: "n1", cost: 0.5, input: 10, read: 90, creation: 0, output: 1
        )))
        controller.emit(.counterBoundaryObserved(launchToken: launch.token, kind: "status:compacting"))
        controller.emit(.counterBoundaryObserved(launchToken: launch.token, kind: "compact_boundary"))
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn2, ordinal: 1))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn2, ordinal: 1, uuid: "n2", cost: 0.9, input: 30, read: 70, creation: 0, output: 1
        )))
        await drained(fixture, controller, label: "recovery launch drained")

        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(accounting.executionVerdict, .qualified(contractID: tokensOnly, baseline: .unsupported))
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertTrue(record.hasUnmeasuredHistory, "existing flags are preserved, never cleared by a new launch")
        XCTAssertEqual(record.claudeSegments.count, 2)
        XCTAssertEqual(record.claudeSegments[0], restored.claudeSegments[0], "the suspended segment is never reopened or rewritten")
        XCTAssertEqual(Array(record.turns.prefix(2)), restored.turns)
        let live = record.claudeSegments[1]
        XCTAssertEqual(live.contractID, tokensOnly)
        XCTAssertEqual(live.executionID, launch.token)
        XCTAssertEqual(live.state, .open)
        XCTAssertEqual(live.coverage, .unavailable)
        XCTAssertNil(live.baseline)
        XCTAssertNil(live.latestCumulative)
        let liveTurns = Array(record.turns.dropFirst(2))
        XCTAssertEqual(liveTurns.map(\.turnID), [turn1, turn2])
        XCTAssertEqual(liveTurns.map(\.acceptedResultID), ["n1", "n2"])
        XCTAssertEqual(liveTurns.map(\.segmentIndex), [1, 1])
        XCTAssertNil(accounting.sessionCostEstimate)
        // Restored 90/100 plus live 90/100 and 70/100; restored gaps keep the share partial.
        XCTAssertEqual(accounting.cacheHitShare, .init(ratio: Decimal(250) / Decimal(300), coverage: .partial))
    }

    /// Mid-turn compaction: a dispatched, unfinished turn with live main-request usage receives
    /// `status:compacting` and `compact_boundary` before its own result. The boundaries leave the
    /// open turn, record, revisions and latest-request CH untouched; the turn stays registered (a
    /// later main request for it is still accepted), and its result and closure are accepted
    /// exactly once (a re-delivered result and a second closure change nothing).
    func testTokensOnlyInFlightTurnKeepsItsOwnershipAcrossCompactionAndAcceptsItsResultExactlyOnce() async throws {
        XCTAssertNil(ClaudeNativeUsageContract.test_contractsOverride)
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
        )
        let tokensOnlyVerdict = AgentUsageExecutionVerdict.qualified(
            contractID: "claude-native.tokens-only.v1@2.1.281",
            baseline: .unsupported
        )
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: "2.1.281", providerSessionID: "ps"))
        let turn = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
        controller.emit(Self.mainRequest(launch: launch, turnID: turn, requestID: "msg-1", input: 10, read: 90))
        await drained(fixture, controller, label: "in-flight turn drained")
        let before = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(before.executionVerdict, tokensOnlyVerdict)
        let openRecord = try XCTUnwrap(before.persistedRepresentation?.record)
        XCTAssertEqual(openRecord.turns.map(\.turnID), [turn])
        XCTAssertEqual(openRecord.turns.map(\.outcome), [.open])
        let latestBefore = try XCTUnwrap(before.latestRequestCacheHit(for: .claudeAssistant))
        XCTAssertEqual(latestBefore.requestID, "msg-1")
        XCTAssertEqual(latestBefore.share?.ratio, Decimal(90) / Decimal(100))

        controller.emit(.counterBoundaryObserved(launchToken: launch.token, kind: "status:compacting"))
        controller.emit(.counterBoundaryObserved(launchToken: launch.token, kind: "compact_boundary"))
        await drained(fixture, controller, label: "mid-turn boundaries drained")
        let during = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(during.executionVerdict, tokensOnlyVerdict, "a mid-turn boundary never blocks a tokens-only execution")
        XCTAssertEqual(during.activeExecutionID, launch.token)
        XCTAssertEqual(during.ownedRevision, before.ownedRevision, "the boundary neither closes nor suspends anything")
        XCTAssertEqual(during.presentationRevision, before.presentationRevision)
        XCTAssertEqual(during.persistedRepresentation?.record, openRecord, "the open turn and open segment are unchanged")
        XCTAssertEqual(during.latestRequestCacheHit(for: .claudeAssistant), latestBefore)

        // The open turn is still owned: a post-compaction main request for it is accepted.
        controller.emit(Self.mainRequest(launch: launch, turnID: turn, requestID: "msg-2", input: 30, read: 70))
        await drained(fixture, controller, label: "post-compaction request drained")
        let latestAfterCompaction = try XCTUnwrap(fixture.session.usageAccounting?.latestRequestCacheHit(for: .claudeAssistant))
        XCTAssertEqual(latestAfterCompaction.requestID, "msg-2")
        XCTAssertEqual(latestAfterCompaction.share?.ratio, Decimal(70) / Decimal(100))

        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn, ordinal: 0, uuid: "r1", cost: 0.5, input: 10, read: 90, creation: 0, output: 1
        )))
        controller.emit(.turnClosed(launchToken: launch.token, turnID: turn, status: .completed))
        await drained(fixture, controller, label: "same-turn result and closure drained")
        let after = try XCTUnwrap(fixture.session.usageAccounting)
        XCTAssertEqual(after.executionVerdict, tokensOnlyVerdict)
        let record = try XCTUnwrap(after.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertFalse(record.hasUnmeasuredHistory)
        XCTAssertEqual(record.turns.map(\.turnID), [turn])
        XCTAssertEqual(record.turns.map(\.acceptedResultID), ["r1"])
        XCTAssertEqual(record.turns.map(\.outcome), [.completed])
        XCTAssertEqual(record.turns.map(\.coverage), [.complete])
        XCTAssertEqual(record.claudeSegments.count, 1)
        XCTAssertEqual(record.claudeSegments.first?.state, .open)
        XCTAssertEqual(record.claudeSegments.first?.coverage, .unavailable)
        XCTAssertNil(record.claudeSegments.first?.latestCumulative)
        XCTAssertNil(after.sessionCostEstimate)
        XCTAssertEqual(after.cacheHitShare, .init(ratio: Decimal(90) / Decimal(100), coverage: .complete))

        // Exactly once: a re-delivered result and a second closure change nothing.
        let revisionAfterAcceptance = after.ownedRevision
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn, ordinal: 0, uuid: "r1", cost: 0.5, input: 10, read: 90, creation: 0, output: 1
        )))
        controller.emit(.turnClosed(launchToken: launch.token, turnID: turn, status: .completed))
        await drained(fixture, controller, label: "re-delivery drained")
        XCTAssertEqual(fixture.session.usageAccounting?.ownedRevision, revisionAfterAcceptance)
        XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation?.record, record)
        XCTAssertEqual(
            fixture.session.usageAccounting?.closeTurn(turn, outcome: .completed),
            .rejected(.unregisteredTurn),
            "the closure already retired the turn"
        )
    }

    // MARK: - Single-stream closure and forwarder lifecycle

    func testClosureOnTheUsageStreamCannotRaceAnAttributedResultAndRetiresUnattributedTurns() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
        )
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        let attributed = UUID()
        let unattributed = UUID()
        // The controller emits attribution before closure on one ordered stream; the transcript
        // runner performs no accounting mutation, so completion order cannot drop the result.
        controller.emit(.dispatched(launchToken: launch.token, turnID: attributed, ordinal: 0))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: attributed, ordinal: 0, uuid: "r0", cost: 0.3, input: 10, read: 90, creation: 0, output: 1
        )))
        controller.emit(.turnClosed(launchToken: launch.token, turnID: attributed, status: .completed))
        controller.emit(.dispatched(launchToken: launch.token, turnID: unattributed, ordinal: 1))
        controller.emit(.turnClosed(launchToken: launch.token, turnID: unattributed, status: .failed))
        await drained(fixture, controller)
        let record = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
        XCTAssertEqual(record.turns.count, 2)
        XCTAssertEqual(record.turns[0].acceptedResultID, "r0")
        XCTAssertEqual(record.turns[0].outcome, .completed)
        XCTAssertEqual(record.turns[0].coverage, .complete)
        XCTAssertEqual(record.turns[1].outcome, .interrupted)
        XCTAssertEqual(record.turns[1].coverage, .partial)
        XCTAssertNil(record.turns[1].acceptedResultID)
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate?.amount, Decimal(string: "0.3"))
        // Exactly once: the closure for the attributed turn was a no-op.
        XCTAssertEqual(record.claudeSegments.first?.acceptedResultOrder, 1)
        XCTAssertEqual(
            fixture.session.usageAccounting?.closeTurn(attributed, outcome: .interrupted),
            .rejected(.unregisteredTurn)
        )
    }

    func testForwarderLifecycleTerminatesOnDetachStartupFailureStreamEndAndSessionDisposalWhilePreservingAttachedReuse() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        // Attached reuse: one controller, two launches on the same stream keep one forwarder.
        do {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            fixture.session.usageAccounting = AgentUsageAccumulator(
                ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
            )
            let controller = UsageEvidenceFakeNativeController()
            fixture.session.claudeController = controller
            XCTAssertTrue(fixture.session.test_isUsageAccountingForwardingActive)
            let first = controller.emitLaunch()
            controller.emit(.launchEnded(launchToken: first.token))
            await drained(fixture, controller)
            XCTAssertTrue(fixture.session.test_isUsageAccountingForwardingActive, "an attached controller may relaunch on the same stream")
            let second = controller.emitLaunch()
            await drained(fixture, controller)
            XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, second.token)

            // Detach while the launch is live: draining continues until the process reports its end,
            // then the forwarder terminates itself.
            fixture.session.claudeController = nil
            XCTAssertTrue(fixture.session.test_isUsageAccountingForwardingActive)
            XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, second.token)
            controller.emit(.launchEnded(launchToken: second.token))
            await waitUntil("forwarder terminated after detach + launchEnded") {
                !fixture.session.test_isUsageAccountingForwardingActive
            }
            XCTAssertNil(fixture.session.usageAccounting?.activeExecutionID)
            // Late events on the old stream are never ingested.
            let ingested = fixture.session.test_ingestedNativeUsageEventCount
            controller.emitLaunch()
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(fixture.session.test_ingestedNativeUsageEventCount, ingested)
            XCTAssertNil(fixture.session.usageAccounting?.activeExecutionID)
        }

        // Startup failure: installed, never launched, removed -> forwarder ends immediately.
        do {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let controller = UsageEvidenceFakeNativeController()
            fixture.session.claudeController = controller
            XCTAssertTrue(fixture.session.test_isUsageAccountingForwardingActive)
            fixture.session.claudeController = nil
            XCTAssertFalse(fixture.session.test_isUsageAccountingForwardingActive)
        }

        // Stream end while a launch is active (controller deallocated without shutdown) disposes it.
        do {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            fixture.session.usageAccounting = AgentUsageAccumulator(
                ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
            )
            let controller = UsageEvidenceFakeNativeController()
            fixture.session.claudeController = controller
            let launch = controller.emitLaunch()
            controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
            let turn = UUID()
            controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
            await drained(fixture, controller)
            fixture.session.claudeController = nil
            controller.finish()
            await waitUntil("stream end disposed the launch") {
                fixture.session.usageAccounting?.activeExecutionID == nil
                    && !fixture.session.test_isUsageAccountingForwardingActive
            }
            let record = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
            XCTAssertEqual(record.turns.first?.outcome, .interrupted)
            XCTAssertEqual(record.claudeSegments.first?.state, .closed)
        }

        // Session disposal: the forwarder holds neither the session nor the controller strongly,
        // and ephemeral teardown of run-scoped tasks leaves an attached controller's forwarder alone
        // (the session's `deinit` is what ends it once the session itself goes away).
        do {
            let controller = UsageEvidenceFakeNativeController()
            weak var weakSession: AgentTabSession?
            do {
                let session = AgentTabSession(tabID: UUID())
                session.selectedAgent = .claudeCode
                session.claudeController = controller
                XCTAssertTrue(session.test_isUsageAccountingForwardingActive)
                controller.emitLaunch()
                weakSession = session
                session.cancelEphemeralRuntimeState()
                XCTAssertTrue(session.test_isUsageAccountingForwardingActive, "the controller is still attached")
                XCTAssertNotNil(session.claudeController)
            }
            await Task.yield()
            XCTAssertNil(weakSession, "a disposed session must deallocate; the forwarder captured it weakly")
        }
    }

    /// `cancelEphemeralRuntimeState()` (window close, workspace switch, tab close, session delete)
    /// keeps `claudeController` attached for the coordinator shutdown that follows. It must not
    /// cancel the forwarder: cancelling the consumer finishes that controller's evidence stream for
    /// good, so every later launch/dispatch/result of a still-attached controller would be dropped
    /// silently. The forwarder ends only when the controller is dropped/replaced, the stream ends,
    /// or the session deinitializes.
    func testCancelEphemeralRuntimeStateKeepsAnAttachedControllerAccountingAlive() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
        )
        let controller = UsageEvidenceFakeNativeController()
        fixture.session.claudeController = controller
        let launch = controller.emitLaunch()
        controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
        await drained(fixture, controller)
        XCTAssertEqual(fixture.session.usageAccounting?.executionVerdict?.isQualified, true)

        fixture.session.cancelEphemeralRuntimeState()
        XCTAssertNotNil(fixture.session.claudeController, "ephemeral teardown keeps the controller attached")
        XCTAssertTrue(fixture.session.test_isUsageAccountingForwardingActive)
        XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, launch.token)

        // The attached controller keeps running turns; every one of them is still accounted.
        let turn = UUID()
        controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
        controller.emit(.resultAttributed(Self.attribution(
            launch: launch, turnID: turn, ordinal: 0, uuid: "after-cancel", cost: 0.25, input: 10, read: 90, creation: 0, output: 1
        )))
        controller.emit(.turnClosed(launchToken: launch.token, turnID: turn, status: .completed))
        await drained(fixture, controller)
        let record = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation?.record)
        XCTAssertEqual(record.turns.map(\.acceptedResultID), ["after-cancel"])
        XCTAssertEqual(record.turns.first?.outcome, .completed)
        XCTAssertEqual(fixture.session.usageAccounting?.sessionCostEstimate?.amount, Decimal(string: "0.25"))

        // A second launch on the same attached controller is still observed after the teardown call.
        controller.emit(.launchEnded(launchToken: launch.token))
        let relaunch = controller.emitLaunch()
        await drained(fixture, controller)
        XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, relaunch.token)

        // Disposal still ends the forwarder: the teardown paths drop the controller through the
        // coordinator shutdown (detach → `claudeController = nil`) and the process reports its end.
        fixture.session.claudeController = nil
        controller.emit(.launchEnded(launchToken: relaunch.token))
        await waitUntil("forwarder terminated after controller drop + launch end") {
            !fixture.session.test_isUsageAccountingForwardingActive
        }
        XCTAssertNil(fixture.session.usageAccounting?.activeExecutionID)
    }

    /// Controller-to-accumulator regression for duplicate result delivery: the production
    /// `handleStreamPayload` path receives result 0, its exact duplicate, then result 1. The
    /// duplicate is neither an attribution nor a turn boundary, so turn 1 is closed only by its own
    /// result and both results are accepted exactly once.
    func testDuplicateResultPayloadThroughTheProductionControllerLeavesBothResultsAcceptedExactlyOnce() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .executionVerified
        )
        let controller = try ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared
        )
        fixture.session.claudeController = controller
        let launch = await controller.test_beginSyntheticUsageLaunch()
        let turn0 = await controller.test_registerSyntheticDispatch()
        let turn1 = await controller.test_registerSyntheticDispatch()
        await controller.test_handleStreamPayload([
            "type": "system", "subtype": "init", "session_id": "sess-1", "claude_code_version": syntheticVersion,
            "tools": [], "uuid": UUID().uuidString
        ] as [String: Any])
        await waitUntil("execution qualified from real controller evidence") {
            fixture.session.usageAccounting?.executionVerdict?.isQualified == true
        }
        XCTAssertEqual(fixture.session.usageAccounting?.activeExecutionID, launch.token)

        await controller.test_handleStreamPayload(Self.rawResultPayload(index: 0, uuid: "r0", cost: 0.5))
        await controller.test_handleStreamPayload(Self.rawResultPayload(index: 0, uuid: "r0", cost: 0.5)) // exact duplicate
        await controller.test_handleStreamPayload(Self.rawResultPayload(index: 1, uuid: "r1", cost: 0.9))
        await controller.test_endSyntheticUsageLaunch()
        await waitUntil("launch ended through the forwarder") { fixture.session.usageAccounting?.activeExecutionID == nil }

        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertEqual(record.turns.map(\.turnID), [turn0, turn1])
        XCTAssertEqual(record.turns.map(\.acceptedResultID), ["r0", "r1"])
        XCTAssertEqual(record.turns.map(\.outcome), [.completed, .completed])
        XCTAssertEqual(record.turns.map(\.coverage), [.complete, .complete])
        XCTAssertEqual(record.turns.map(\.diagnostic), [nil, nil])
        XCTAssertEqual(record.claudeSegments.count, 1)
        XCTAssertEqual(record.claudeSegments.first?.acceptedResultOrder, 2, "exactly once: two accepted results, no duplicate charge")
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, Decimal(string: "0.9"))
        XCTAssertEqual(record.claudeSegments.first?.state, .closed)
        XCTAssertEqual(record.claudeSegments.first?.coverage, .complete)
        let expectedCost = try XCTUnwrap(Decimal(string: "0.9"))
        XCTAssertEqual(accounting.sessionCostEstimate, .init(amount: expectedCost, currency: "USD", coverage: .complete))
        XCTAssertFalse(accounting.hasUnchargedDispatchedWork)
    }

    /// Real production-controller request usage must traverse the transient event stream and the
    /// session's production UI callback. It must not be inferred from result aggregates or saved.
    func testProductionControllerAssistantUsageReachesUIWithoutMutatingLedgerOrSave() async throws {
        XCTAssertNil(ClaudeNativeUsageContract.test_contractsOverride)
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        // Replace the fixture's manually installed session with the production-created session so
        // this test exercises makeSession's real onUsageAccountingChanged callback.
        fixture.viewModel.test_removeLiveSession(tabID: fixture.tabID)
        let session = try XCTUnwrap(fixture.viewModel.session(for: fixture.tabID, createIfNeeded: true))
        XCTAssertEqual(session.activeAgentSessionID, fixture.sessionID)
        XCTAssertNotNil(session.onUsageAccountingChanged)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.setItemsSilently([.user("latest request", sequenceIndex: 0)], reason: .testOverride)
        session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID,
            persisted: nil,
            hasPriorHistory: false,
            qualification: .productionClaude
        )

        let controller = try ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: fixture.tabID, windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared
        )
        await controller.test_setInitializeResponse([
            "account": ["apiProvider": "firstParty", "subscriptionType": "Claude Max"]
        ])
        session.claudeController = controller
        let launch = await controller.test_beginSyntheticUsageLaunch(
            configuredEnvironmentOverrideKeys: ["MAX_MCP_OUTPUT_TOKENS", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT"]
        )
        _ = await controller.test_registerSyntheticDispatch()
        await controller.test_handleStreamPayload(Self.rawSystemInit())
        await waitUntil("production request test qualified") {
            session.usageAccounting?.executionVerdict?.isQualified == true
        }

        // Establish a 50% result/session aggregate and $2 cumulative cost without any assistant
        // request usage. That aggregate must remain separate from the compact latest-request CH.
        await controller.test_handleStreamPayload(Self.rawResultPayload(
            index: 0,
            uuid: "aggregate-result",
            cost: 2,
            input: 10,
            read: 10,
            creation: 0,
            output: 1
        ))
        await waitUntil("aggregate result accepted") {
            session.usageAccounting?.record?.turns.first?.acceptedResultID == "aggregate-result"
        }
        XCTAssertEqual(
            session.usageAccounting?.cacheHitShare,
            .init(ratio: Decimal(1) / Decimal(2), coverage: .complete)
        )
        XCTAssertEqual(
            session.usageAccounting?.sessionCostEstimate,
            .init(amount: 2, currency: "USD", coverage: .complete)
        )
        let aggregateOnlyProjection = session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertNil(aggregateOnlyProjection.latestRequestCacheHit?.requestID)
        XCTAssertNil(aggregateOnlyProjection.latestRequestCacheHit?.share)
        XCTAssertEqual(aggregateOnlyProjection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $2.00")
        assertSessionAverage("50.0%", in: aggregateOnlyProjection)

        let liveTurn = await controller.test_registerSyntheticDispatch()
        await waitUntil("live request dispatch registered") {
            session.usageAccounting?.record?.turns.contains {
                $0.turnID == liveTurn && $0.outcome == .open
            } == true
        }

        // Drain all durable mutations to disk before observing the transient request.
        session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)
        XCTAssertFalse(session.isDirty)
        fixture.viewModel.syncRuntimeMetricsUIState()
        let persistedBeforeLatest = try Data(contentsOf: fixture.sessionFileURL())
        let ownedRevisionBeforeLatest = try XCTUnwrap(session.usageAccounting?.ownedRevision)
        let presentationRevisionBeforeLatest = try XCTUnwrap(session.usageAccounting?.presentationRevision)
        let syncCountBeforeLatest = fixture.viewModel.test_syncRuntimeMetricsCallCount

        await controller.test_handleStreamPayload([
            "type": "assistant",
            "session_id": "sess-1",
            "uuid": "assistant-envelope-latest",
            "parent_tool_use_id": NSNull(),
            "message": [
                "id": "assistant-request-latest",
                "role": "assistant",
                "content": [["type": "text", "text": "working"]],
                "usage": [
                    "input_tokens": 10,
                    "output_tokens": 1,
                    "cache_read_input_tokens": 90,
                    "cache_creation_input_tokens": 0
                ]
            ] as [String: Any]
        ] as [String: Any])
        await waitUntil("assistant latest request ingested") {
            session.usageAccounting?.latestRequestCacheHit(for: .claudeAssistant)?.requestID
                == "assistant-request-latest"
        }
        await waitUntil("assistant latest request reached UI callback") {
            fixture.viewModel.test_syncRuntimeMetricsCallCount > syncCountBeforeLatest
                && fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.providerUsage.presentation.readoutText
                == "Cache Hit Ratio: 90.0% · API Cost Estimates: $2.00"
        }

        var projection = fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.providerUsage
        XCTAssertEqual(projection.latestRequestCacheHit?.share?.ratio, Decimal(string: "0.9"))
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: 90.0% · API Cost Estimates: $2.00")
        assertSessionAverage("50.0%", in: projection)
        XCTAssertEqual(session.usageAccounting?.ownedRevision, ownedRevisionBeforeLatest)
        XCTAssertGreaterThan(
            try XCTUnwrap(session.usageAccounting?.presentationRevision),
            presentationRevisionBeforeLatest
        )
        XCTAssertFalse(session.isDirty, "transient presentation must not schedule a session save")
        XCTAssertEqual(try Data(contentsOf: fixture.sessionFileURL()), persistedBeforeLatest)

        // A newer real assistant event without usage clears the latest value, republishes the UI,
        // and still leaves the aggregate, accumulated cost, owned revision, and saved bytes intact.
        let syncCountBeforeMissing = fixture.viewModel.test_syncRuntimeMetricsCallCount
        await controller.test_handleStreamPayload([
            "type": "assistant",
            "session_id": "sess-1",
            "uuid": "assistant-envelope-missing",
            "parent_tool_use_id": NSNull(),
            "message": [
                "id": "assistant-request-missing",
                "role": "assistant",
                "content": [["type": "text", "text": "continuing"]]
            ] as [String: Any]
        ] as [String: Any])
        await waitUntil("missing assistant usage ingested") {
            let latest = session.usageAccounting?.latestRequestCacheHit(for: .claudeAssistant)
            return latest?.requestID == "assistant-request-missing" && latest?.share == nil
        }
        await waitUntil("missing assistant usage reached UI callback") {
            fixture.viewModel.test_syncRuntimeMetricsCallCount > syncCountBeforeMissing
                && fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.providerUsage.presentation.readoutText
                == "Cache Hit Ratio: — · API Cost Estimates: $2.00"
        }

        projection = fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.providerUsage
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $2.00")
        XCTAssertTrue(projection.presentation.expandedDetailText?.contains("did not include a usage object") == true)
        assertSessionAverage("50.0%", in: projection)
        XCTAssertEqual(
            session.usageAccounting?.cacheHitShare,
            .init(ratio: Decimal(1) / Decimal(2), coverage: .complete)
        )
        XCTAssertEqual(
            session.usageAccounting?.sessionCostEstimate,
            .init(amount: 2, currency: "USD", coverage: .complete)
        )
        XCTAssertEqual(session.usageAccounting?.ownedRevision, ownedRevisionBeforeLatest)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.sessionFileURL()), persistedBeforeLatest)

        await controller.test_endSyntheticUsageLaunch()
        await waitUntil("production request test launch ended") {
            session.usageAccounting?.activeExecutionID == nil
        }
    }

    func testProductionCodexLastOnlyRefreshDoesNotPersistIdenticalTotal() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        fixture.viewModel.test_removeLiveSession(tabID: fixture.tabID)
        let session = try XCTUnwrap(fixture.viewModel.session(for: fixture.tabID, createIfNeeded: true))
        XCTAssertNotNil(session.onUsageAccountingChanged)
        session.selectedAgent = .codexExec
        session.hasLoadedPersistedState = true
        session.setItemsSilently([.user("Codex latest request", sequenceIndex: 0)], reason: .testOverride)

        session.beginCodexUsageExecutionIfNeeded()
        XCTAssertNotNil(session.registerCodexUsageDispatch(requestedModel: "gpt-5.3-codex"))
        session.acceptCurrentCodexUsageDispatch()
        session.bindCodexUsageTurn("codex-turn")

        let total = CodexUsageObservation.Counters(
            inputTokens: 1000,
            cachedInputTokens: 200,
            cacheWriteInputTokens: 0,
            outputTokens: 10,
            reasoningOutputTokens: 0,
            totalTokens: 1010
        )
        session.ingestCodexUsageObservation(.init(
            threadID: "codex-thread",
            turnID: "codex-turn",
            turnAttribution: .notified,
            ordinal: 1,
            last: .init(
                inputTokens: 100,
                cachedInputTokens: 20,
                cacheWriteInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0,
                totalTokens: 101
            ),
            total: total,
            modelContextWindow: 258_400
        ))
        await waitUntil("first Codex request reached production UI callback") {
            fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.providerUsage
                .latestRequestCacheHit?.share?.ratio == Decimal(string: "0.2")
        }

        session.isDirty = true
        await fixture.viewModel.flushSave(for: fixture.tabID)
        XCTAssertFalse(session.isDirty)
        fixture.viewModel.syncRuntimeMetricsUIState()
        let savedBeforeLastOnly = try Data(contentsOf: fixture.sessionFileURL())
        let recordBeforeLastOnly = session.usageAccounting?.record
        let costBeforeLastOnly = session.usageAccounting?.codexSessionCostEstimate
        let ownedRevisionBeforeLastOnly = try XCTUnwrap(session.usageAccounting?.ownedRevision)
        let presentationRevisionBeforeLastOnly = try XCTUnwrap(session.usageAccounting?.presentationRevision)
        let syncCountBeforeLastOnly = fixture.viewModel.test_syncRuntimeMetricsCallCount

        // Only request-level last changes. The identical cumulative total is an accounting no-op,
        // but presentationRevision must still drive the production UI callback.
        session.ingestCodexUsageObservation(.init(
            threadID: "codex-thread",
            turnID: "codex-turn",
            turnAttribution: .notified,
            ordinal: 2,
            last: .init(
                inputTokens: 100,
                cachedInputTokens: 80,
                cacheWriteInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0,
                totalTokens: 101
            ),
            total: total,
            modelContextWindow: 258_400
        ))
        await waitUntil("last-only Codex update reached production UI callback") {
            fixture.viewModel.test_syncRuntimeMetricsCallCount > syncCountBeforeLastOnly
                && fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.providerUsage
                .latestRequestCacheHit?.share?.ratio == Decimal(string: "0.8")
        }

        let projection = fixture.viewModel.ui.runtimeMetrics.runtimeVM.snapshot.providerUsage
        XCTAssertTrue(projection.presentation.readoutText.hasPrefix("Cache Hit Ratio: 80.0% · API Cost Estimates: "))
        assertSessionAverage("20.0%", in: projection)
        XCTAssertEqual(session.usageAccounting?.record, recordBeforeLastOnly)
        XCTAssertEqual(session.usageAccounting?.codexSessionCostEstimate, costBeforeLastOnly)
        XCTAssertEqual(session.usageAccounting?.ownedRevision, ownedRevisionBeforeLastOnly)
        XCTAssertGreaterThan(
            try XCTUnwrap(session.usageAccounting?.presentationRevision),
            presentationRevisionBeforeLastOnly
        )
        XCTAssertFalse(session.isDirty, "last-only presentation must not schedule persistence")
        XCTAssertEqual(try Data(contentsOf: fixture.sessionFileURL()), savedBeforeLastOnly)
    }

    func testAbandonedHydratedOpenStateProjectsPartialUnderExecutionVerifiedBeforeAnyLaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let oldExecution = UUID()
        var hydrated = AgentProviderUsageRecord(
            originSessionID: fixture.sessionID,
            trackingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasUnmeasuredHistory: false
        )
        hydrated.turns = [
            .init(
                executionID: oldExecution,
                segmentIndex: 0,
                turnID: UUID(),
                acceptedResultID: "a",
                inputTokens: 10,
                outputTokens: 1,
                cacheReadInputTokens: 90,
                cacheCreationInputTokens: 0,
                outcome: .completed,
                coverage: .complete
            ),
            .init(executionID: oldExecution, segmentIndex: 0, turnID: UUID(), outcome: .open, coverage: .unavailable)
        ]
        hydrated.claudeSegments = [
            .init(
                contractID: "old",
                provider: "claude",
                providerSessionID: nil,
                executionID: oldExecution,
                resetGeneration: 0,
                baseline: 0,
                latestCumulative: Decimal(string: "0.5"),
                currency: "USD",
                acceptedResultID: "a",
                acceptedResultOrder: 1,
                state: .open,
                coverage: .complete
            )
        ]
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: .record(hydrated), hasPriorHistory: false, qualification: .executionVerified
        )
        XCTAssertTrue(try XCTUnwrap(fixture.session.usageAccounting).hasAbandonedHydratedLifecycleState)
        let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.50")
        XCTAssertEqual(projection.costEstimate?.coverage, .partial)
        assertSessionAverage("90.0%", in: projection)
        XCTAssertEqual(projection.coverageDetail, "The restored state includes unfinished work.")
        XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, .record(hydrated), "no owned mutation happened")
    }

    func testExecutionVerifiedPolicyPreservesForeignAndOpaqueRecordsUnderAQualifiedLaunch() async throws {
        ClaudeNativeUsageContract.test_contractsOverride = [
            .init(contractID: syntheticContractID, runtimeVersion: syntheticVersion, launchModes: [.freshSession])
        ]
        let foreign = AgentProviderUsageRecord(
            originSessionID: UUID(), trackingStartedAt: Date(timeIntervalSince1970: 1_700_000_000), hasUnmeasuredHistory: false
        )
        let opaqueRaw = try AgentProviderUsageRawValue(validating: #"{"schemaVersion":7,"x":1e999}"#)
        let seeds: [(label: String, persisted: AgentProviderUsagePersist, eligibility: AgentUsageEligibility)] = [
            ("foreign", .record(foreign), .foreignOrigin(foreign.originSessionID)),
            ("opaque", .opaque(opaqueRaw), .opaquePersistedValue)
        ]
        for seed in seeds {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            // The production writer reloads a typed record as raw bytes with a lossless view.
            let seeded = try await fixture.seedPersistedSession(providerUsage: seed.persisted, rawProviderUsageMember: nil)
            let persisted = try XCTUnwrap(seeded.providerUsage, seed.label)
            fixture.session.usageAccounting = AgentUsageAccumulator(
                ownerSessionID: fixture.sessionID, persisted: persisted, hasPriorHistory: false, qualification: .executionVerified
            )
            XCTAssertEqual(fixture.session.usageAccounting?.eligibility, seed.eligibility, seed.label)
            let controller = UsageEvidenceFakeNativeController()
            fixture.session.claudeController = controller
            let launch = controller.emitLaunch()
            controller.emit(.runtimeEvidence(launchToken: launch.token, runtimeVersion: syntheticVersion, providerSessionID: "ps"))
            let turn = UUID()
            controller.emit(.dispatched(launchToken: launch.token, turnID: turn, ordinal: 0))
            controller.emit(.resultAttributed(Self.attribution(
                launch: launch, turnID: turn, ordinal: 0, uuid: "r", cost: 1, input: 1, read: 1, creation: 0, output: 0
            )))
            await drained(fixture, controller, label: "\(seed.label): drained")
            XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, persisted, seed.label)
            XCTAssertEqual(fixture.session.usageAccounting?.ownedRevision, 0, seed.label)
            XCTAssertNil(fixture.session.usageAccounting?.sessionCostEstimate, seed.label)
            fixture.session.isDirty = true
            await fixture.viewModel.flushSave(for: fixture.tabID)
            let reloaded = try await fixture.reloadPersistedSession()
            XCTAssertEqual(reloaded.providerUsage, persisted, seed.label)
            let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
            XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: —", seed.label)
        }
    }

    // MARK: - Handoff

    func testHandoffDestinationStartsWithoutInheritedAccounting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.hasLoadedPersistedState = true
        fixture.session.setItemsSilently(
            [.user("source question", sequenceIndex: 0), .assistant("source answer", sequenceIndex: 1)],
            reason: .testOverride
        )
        fixture.viewModel.refreshDerivedTranscriptState(for: fixture.session)
        var sourceAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID,
            persisted: nil,
            hasPriorHistory: true,
            qualification: qualified
        )
        let sourceExecution = UUID()
        sourceAccounting.beginExecution(
            executionID: sourceExecution,
            providerSessionID: "ps-source",
            baseline: .verifiedZero,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        fixture.session.usageAccounting = sourceAccounting
        let sourceRepresentation = try XCTUnwrap(fixture.session.usageAccounting?.persistedRepresentation)
        XCTAssertNotNil(sourceRepresentation.record)

        let destinationTabID = try await fixture.viewModel.prepareHandoffHeadless(
            sourceTabID: fixture.tabID,
            upToItemID: nil,
            destinationAgent: .claudeCode,
            destinationModelRaw: fixture.session.selectedModelRaw,
            destinationReasoningEffortRaw: nil
        )
        let destination = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
        let destinationSessionID = try XCTUnwrap(destination.activeAgentSessionID)
        XCTAssertNotEqual(destinationSessionID, fixture.sessionID)
        XCTAssertNil(destination.usageAccounting, "a branch never inherits source accounting")

        // The destination's first controller keys accounting to its own identity with no payload.
        destination.claudeController = UsageEvidenceFakeNativeController(label: "destination")
        let destinationAccounting = try XCTUnwrap(destination.usageAccounting)
        XCTAssertEqual(destinationAccounting.ownerSessionID, destinationSessionID)
        XCTAssertEqual(destinationAccounting.qualification, .executionVerified)
        XCTAssertNil(destinationAccounting.persistedRepresentation)
        XCTAssertNil(destinationAccounting.activeExecutionID)
        XCTAssertEqual(fixture.session.usageAccounting?.persistedRepresentation, sourceRepresentation)

        destination.isDirty = true
        await fixture.viewModel.flushSave(for: destinationTabID)
        let loadedDestination = try await AgentSessionDataService.shared.loadAgentSession(
            id: destinationSessionID,
            for: fixture.workspace
        )
        let persistedDestination = try XCTUnwrap(loadedDestination)
        XCTAssertEqual(persistedDestination.id, destinationSessionID)
        XCTAssertNil(persistedDestination.providerUsage, "absent stays absent: no measured-zero record is manufactured")
    }

    // MARK: - Helpers

    /// Raw SDK `result` payload as the controller receives it from the framed stdout line (captured
    /// 2.1.268 shape: cumulative cost equal to the summed per-model aggregate, no-child statistics).
    private static func rawResultPayload(
        index: Int, uuid: String, cost: Double, session: String = "sess-1",
        input: Int = 10, read: Int = 90, creation: Int = 0, output: Int = 1, haiku: Double = 0
    ) -> [String: Any] {
        [
            "type": "result", "subtype": "success", "is_error": false, "uuid": uuid, "session_id": session,
            "total_cost_usd": cost, "num_turns": 1, "result_index": index, "queued_turn_count": 0,
            "usage": ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read, "cache_creation_input_tokens": creation],
            "modelUsage": ["claude-sonnet-5": ["costUSD": cost - haiku], "claude-haiku-4-5-20251001": ["costUSD": haiku]],
            "subagent_stats": noChildStats
        ]
    }

    private static let noChildStats: [String: Any] = [
        "by_type": [:] as [String: Any], "completed": 0, "failed": 0, "max_depth": 0, "spawned": 0, "spawned_by_subagents": 0, "started_in_background": 0,
        "killed": ["parent": 0, "system": 0, "user": 0], "refused": ["budget": 0, "concurrency_limit": 0, "depth_limit": 0],
        "requested": ["background": 0, "foreground": 0, "unset": 0]
    ]

    private static func rawSystemInit(session: String = "sess-1") -> [String: Any] {
        [
            "type": "system", "subtype": "init", "session_id": session, "claude_code_version": "2.1.268", "apiKeySource": "none",
            "model": "claude-sonnet-5", "permissionMode": "auto", "tools": [] as [String], "uuid": UUID().uuidString
        ]
    }

    // MARK: - Shipped contract: captured-wire replay through controller → forwarder → accumulator

    /// Sanitized captured wire lines (raw text, so numeric fields keep their exact wire representation).
    private func candidateFixtureLines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ClaudeNativeUsage/\(name).jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    /// A raw `result` line with exact decimal text (the production path parses wire bytes, never a
    /// re-serialised dictionary, so cumulative decimals stay exact).
    private static func rawResultLine(index: Int, uuid: String, total: String, sonnet: String, haiku: String, input: Int, read: Int, creation: Int, output: Int) -> String {
        """
        {"type":"result","subtype":"success","is_error":false,"uuid":"\(uuid)","session_id":"sess-1","result_index":\(index),"queued_turn_count":0,"num_turns":1,"total_cost_usd":\(total),"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(read),"cache_creation_input_tokens":\(creation)},"modelUsage":{"claude-sonnet-5":{"costUSD":\(sonnet)},"claude-haiku-4-5-20251001":{"costUSD":\(haiku)}},"subagent_stats":{"by_type":{},"completed":0,"failed":0,"max_depth":0,"spawned":0,"spawned_by_subagents":0,"started_in_background":0,"killed":{"parent":0,"system":0,"user":0},"refused":{"budget":0,"concurrency_limit":0,"depth_limit":0},"requested":{"background":0,"foreground":0,"unset":0}}}
        """
    }

    private static let rawInitLine = """
    {"type":"system","subtype":"init","session_id":"sess-1","claude_code_version":"2.1.268","apiKeySource":"none","model":"claude-sonnet-5","permissionMode":"auto","tools":[],"mcp_servers":[],"uuid":"init"}
    """

    /// A real controller on the session under the shipped production policy and contract list
    /// (no override): a synthetic standard first-party fresh launch with the Agent Mode configured
    /// shape and the captured initialize account category.
    private func installProductionController(on fixture: Fixture) async throws -> (ClaudeNativeProcessSessionController, NativeProcessLaunchIdentity) {
        XCTAssertNil(ClaudeNativeUsageContract.test_contractsOverride)
        fixture.session.usageAccounting = AgentUsageAccumulator(
            ownerSessionID: fixture.sessionID, persisted: nil, hasPriorHistory: false, qualification: .productionClaude
        )
        let controller = try ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            mcpHost: ServerNetworkManager.shared
        )
        await controller.test_setInitializeResponse(["account": ["apiProvider": "firstParty", "subscriptionType": "Claude Max"]])
        fixture.session.claudeController = controller
        let launch = await controller.test_beginSyntheticUsageLaunch(
            configuredEnvironmentOverrideKeys: ["MAX_MCP_OUTPUT_TOKENS", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT"]
        )
        return (controller, launch)
    }

    /// Replays captured wire lines as raw stdout bytes through the production framing, codec and
    /// `handleStreamPayload` path, registering one dispatch per `system/init` (on the wire the user
    /// message precedes each per-turn init).
    private func replay(_ rawLines: [String], through controller: ClaudeNativeProcessSessionController, launch: NativeProcessLaunchIdentity) async {
        for line in rawLines {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               (object["type"] as? String) == "system", (object["subtype"] as? String) == "init"
            {
                _ = await controller.test_registerSyntheticDispatch()
            }
            await controller.test_handleStdoutChunk(Data((line + "\n").utf8), launchToken: launch.token)
        }
    }

    func testCapturedFreshSerialWireChargesThreeIntervalsUnderTheShippedContract() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (controller, launch) = try await installProductionController(on: fixture)
        let lines = try candidateFixtureLines("2.1.268-fresh")
        await replay(lines, through: controller, launch: launch)
        await controller.test_endSyntheticUsageLaunch()
        await waitUntil("fresh replay ended") { fixture.session.usageAccounting?.activeExecutionID == nil }

        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertEqual(record.turns.count, 3)
        XCTAssertEqual(record.turns.map(\.outcome), [.completed, .completed, .completed])
        XCTAssertEqual(record.turns.map(\.coverage), [.complete, .complete, .complete])
        XCTAssertEqual(record.turns.map(\.cacheReadInputTokens), [3289, 5259, 5362])
        XCTAssertEqual(record.turns.map(\.cacheCreationInputTokens), [1970, 103, 103])
        XCTAssertEqual(record.turns.compactMap(\.acceptedResultID).count, 3)
        XCTAssertEqual(record.claudeSegments.count, 1)
        XCTAssertEqual(record.claudeSegments.first?.contractID, "claude-native.provider-reported.v1@2.1.268")
        XCTAssertEqual(record.claudeSegments.first?.baseline, 0)
        XCTAssertEqual(record.claudeSegments.first?.acceptedResultOrder, 3)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, Decimal(string: "0.012558"))
        XCTAssertEqual(record.claudeSegments.first?.state, .closed)
        XCTAssertEqual(record.claudeSegments.first?.coverage, .complete)
        let expectedFreshCost = try XCTUnwrap(Decimal(string: "0.012558"))
        XCTAssertEqual(accounting.sessionCostEstimate, .init(amount: expectedFreshCost, currency: "USD", coverage: .complete))
        XCTAssertEqual(accounting.cacheHitShare?.coverage, .complete)
        let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.01")
        assertSessionAverage("86.4%", in: projection)
        XCTAssertNil(projection.unavailableReason)
        XCTAssertNil(projection.coverageDetail)
    }

    /// Captured child stage (`run-yzza00mc`): a main-line `Agent` tool use, a sidechain user turn,
    /// then one result with `subagent_stats.spawned == 1` and cumulative `total_cost_usd` that
    /// already includes the child. The parent-inclusive cost is accepted exactly once; the result's
    /// token triple is excluded from CH because its main-loop scope is not separable.
    func testCapturedChildInvocationAcceptsParentInclusiveCostOnceAndExcludesItsTokensFromCacheShare() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (controller, launch) = try await installProductionController(on: fixture)
        let lines = try candidateFixtureLines("2.1.268-child")
        await replay(lines, through: controller, launch: launch)
        await controller.test_endSyntheticUsageLaunch()
        await waitUntil("child replay ended") { fixture.session.usageAccounting?.activeExecutionID == nil }
        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.turns.count, 1)
        XCTAssertEqual(record.turns.first?.acceptedResultID, "908fc84e-6dd9-4533-b093-8ee57eb6251b")
        XCTAssertEqual(record.turns.first?.outcome, .completed)
        XCTAssertEqual(record.turns.first?.coverage, .partial)
        XCTAssertNil(record.turns.first?.cacheReadInputTokens, "child-affected usage is excluded, not presented as main-loop scope")
        XCTAssertEqual(record.turns.first?.diagnostic, AgentUsageAccumulator.childActivityDiagnostic)
        XCTAssertEqual(record.claudeSegments.first?.acceptedResultOrder, 1)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, Decimal(string: "0.0478345"))
        XCTAssertEqual(record.claudeSegments.first?.state, .closed)
        XCTAssertEqual(record.claudeSegments.first?.coverage, .complete)
        let expectedChildInclusiveCost = try XCTUnwrap(Decimal(string: "0.0478345"))
        XCTAssertEqual(accounting.sessionCostEstimate, .init(amount: expectedChildInclusiveCost, currency: "USD", coverage: .complete))
        XCTAssertNil(accounting.cacheHitShare, "no main-loop triple contributes")
        XCTAssertEqual(accounting.childActivityTurnCount, 1)
        XCTAssertFalse(accounting.hasUnchargedDispatchedWork)
        let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.05")
        XCTAssertNil(projection.unavailableReason)
        XCTAssertTrue(try XCTUnwrap(projection.coverageDetail).contains("Native child (subagent) activity occurred in 1 turn"), projection.coverageDetail ?? "")
    }

    /// Captured compact stage (`run-yzza00mc`): `system/status compacting`, `compact_error`, a
    /// `local_command` result with a zero triple and unchanged cumulative, then an ordinary turn.
    /// Under the shipped 2.1.268 contract compaction is not a reset: money continues on the same
    /// baseline, the zero triple adds no denominator, and nothing is assumed free.
    func testCapturedCompactionStatusContinuesCumulativeMoneyAndKeepsCoverageComplete() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (controller, launch) = try await installProductionController(on: fixture)
        let lines = try candidateFixtureLines("2.1.268-compact")
        await replay(lines, through: controller, launch: launch)
        await controller.test_endSyntheticUsageLaunch()
        await waitUntil("compact replay ended") { fixture.session.usageAccounting?.activeExecutionID == nil }
        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.turns.count, 3)
        XCTAssertEqual(record.turns.compactMap(\.acceptedResultID).count, 3)
        XCTAssertEqual(record.turns.map(\.coverage), [.complete, .complete, .complete])
        XCTAssertEqual(record.turns.map(\.cacheReadInputTokens), [4439, 0, 5259])
        XCTAssertEqual(record.claudeSegments.count, 1)
        XCTAssertEqual(record.claudeSegments.first?.acceptedResultOrder, 3)
        XCTAssertEqual(record.claudeSegments.first?.baseline, 0)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, Decimal(string: "0.007236599999999999"), "wire precision, never normalized")
        XCTAssertEqual(record.claudeSegments.first?.state, .closed)
        XCTAssertEqual(record.claudeSegments.first?.coverage, .complete)
        let expectedCompactCost = try XCTUnwrap(Decimal(string: "0.007236599999999999"))
        XCTAssertEqual(accounting.sessionCostEstimate, .init(amount: expectedCompactCost, currency: "USD", coverage: .complete))
        XCTAssertEqual(accounting.cacheHitShare?.coverage, .complete)
        // 9698 cached of 10768 input-side tokens; the compaction result's zero triple adds nothing.
        let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.01")
        assertSessionAverage("90.1%", in: projection)
    }

    /// Compaction follow-up (paid run `run-wk7k1b7v`, engineer-verified ordering): three strict
    /// successes, then `system/status compacting` → `compact_boundary` → result index 3 whose usage
    /// is all zero although the cumulative cost increased, then an ordinary result. Under the
    /// shipped contract the boundary is not a reset: all five results are accepted on the same
    /// baseline, the compaction command's cost increase is counted, and its zero triple adds no
    /// denominator (it does not establish a zero cache-hit rate).
    func testCompactionBoundaryContinuesCumulativeMoneyOnTheSameBaselineAcrossAllFiveResults() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let (controller, launch) = try await installProductionController(on: fixture)
        // Haiku helper cost is constant at 0.000955 on every captured result; sonnet = total - haiku.
        let lines: [String] = [
            Self.rawInitLine,
            Self.rawResultLine(index: 0, uuid: "f0", total: "0.0051908", sonnet: "0.0042358", haiku: "0.000955", input: 2, read: 4000, creation: 100, output: 4),
            Self.rawInitLine,
            Self.rawResultLine(index: 1, uuid: "f1", total: "0.0067118", sonnet: "0.0057568", haiku: "0.000955", input: 2, read: 4001, creation: 100, output: 4),
            Self.rawInitLine,
            Self.rawResultLine(index: 2, uuid: "f2", total: "0.008242", sonnet: "0.007287", haiku: "0.000955", input: 2, read: 4002, creation: 100, output: 4),
            Self.rawInitLine,
            "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"compacting\",\"session_id\":\"sess-1\",\"uuid\":\"st1\"}",
            "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"session_id\":\"sess-1\",\"uuid\":\"cb1\",\"compact_metadata\":{\"trigger\":\"manual\"}}",
            Self.rawResultLine(index: 3, uuid: "f3", total: "0.0178742", sonnet: "0.0169192", haiku: "0.000955", input: 0, read: 0, creation: 0, output: 0),
            Self.rawInitLine,
            Self.rawResultLine(index: 4, uuid: "f4", total: "0.02381", sonnet: "0.022855", haiku: "0.000955", input: 2, read: 5000, creation: 100, output: 4)
        ]
        await replay(lines, through: controller, launch: launch)
        await controller.test_endSyntheticUsageLaunch()
        await waitUntil("follow-up replay ended") { fixture.session.usageAccounting?.activeExecutionID == nil }

        let accounting = try XCTUnwrap(fixture.session.usageAccounting)
        let record = try XCTUnwrap(accounting.persistedRepresentation?.record)
        XCTAssertNil(record.semanticViolation)
        XCTAssertEqual(record.turns.count, 5)
        XCTAssertEqual(record.turns.map(\.acceptedResultID), ["f0", "f1", "f2", "f3", "f4"])
        XCTAssertEqual(record.turns.map(\.outcome), [.completed, .completed, .completed, .completed, .completed])
        XCTAssertEqual(record.turns.map(\.coverage), [.complete, .complete, .complete, .complete, .complete])
        XCTAssertFalse(record.hasUnmeasuredHistory)
        XCTAssertEqual(record.claudeSegments.count, 1, "compaction is not a reset generation")
        XCTAssertEqual(record.claudeSegments.first?.acceptedResultOrder, 5)
        XCTAssertEqual(record.claudeSegments.first?.baseline, 0)
        XCTAssertEqual(record.claudeSegments.first?.latestCumulative, Decimal(string: "0.02381"))
        XCTAssertEqual(record.claudeSegments.first?.state, .closed)
        XCTAssertEqual(record.claudeSegments.first?.coverage, .complete)
        let expectedCost = try XCTUnwrap(Decimal(string: "0.02381"))
        XCTAssertEqual(accounting.sessionCostEstimate, .init(amount: expectedCost, currency: "USD", coverage: .complete))
        XCTAssertEqual(accounting.executionVerdict, nil, "execution ended")
        // 17003 cached of 17411 input-side tokens across the four non-empty triples.
        let projection = fixture.session.cachedProviderUsageProjection(selectedAgent: .claudeCode)
        XCTAssertEqual(projection.presentation.readoutText, "Cache Hit Ratio: — · API Cost Estimates: $0.02")
        assertSessionAverage("97.7%", in: projection)
    }

    private func assertSessionAverage(
        _ expectedPercentage: String,
        in projection: AgentProviderUsageSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let detail = projection.presentation.expandedDetailText ?? ""
        XCTAssertTrue(
            detail.contains("Session-average CH: \(expectedPercentage)"),
            "expected session-average CH \(expectedPercentage) in expanded detail: \(detail)",
            file: file,
            line: line
        )
    }

    private static func attribution(
        launch: NativeProcessLaunchIdentity,
        turnID: UUID,
        ordinal: Int,
        uuid: String,
        cost: Double,
        input: Int = 1,
        read: Int = 1,
        creation: Int = 0,
        output: Int = 0,
        queued: Int = 0,
        status: ClaudeNativeProcessSessionController.TurnStatus = .completed,
        subtype: String = "success",
        isError: Bool = false
    ) -> NativeUsageResultAttribution {
        .init(
            launchToken: launch.token,
            turnID: turnID,
            dispatchOrdinal: ordinal,
            resultIndex: ordinal,
            queuedTurnCount: queued,
            runtimeVersion: "test",
            providerSessionID: "ps",
            observation: .init(
                source: .result,
                inputTokens: input,
                outputTokens: output,
                cacheReadInputTokens: read,
                cacheCreationInputTokens: creation,
                envelopeID: uuid,
                resultSubtype: subtype,
                resultIsError: isError,
                resultIndex: ordinal,
                queuedTurnCount: queued
            ),
            reportedCost: cost,
            turnStatus: status
        )
    }

    /// One live main-line assistant request with a complete input triple (cache creation zero).
    private static func mainRequest(
        launch: NativeProcessLaunchIdentity,
        turnID: UUID,
        requestID: String,
        input: Int,
        read: Int
    ) -> NativeUsageAccountingEvent {
        .mainRequestUsageAttributed(.init(
            launchToken: launch.token,
            turnID: turnID,
            requestID: requestID,
            observation: .init(
                source: .assistant,
                inputTokens: input,
                outputTokens: 1,
                cacheReadInputTokens: read,
                cacheCreationInputTokens: 0
            )
        ))
    }

    /// Waits until every event the fake emitted has been ingested through the session seam.
    private func drained(
        _ fixture: Fixture,
        _ controller: UsageEvidenceFakeNativeController,
        label: String = "forwarder drained",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitUntil(label, file: file, line: line) {
            fixture.session.test_ingestedNativeUsageEventCount >= controller.emittedCount
        }
    }

    /// The session-owned forwarder runs as a main-actor task; yield until it has drained.
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(label)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentTabSession
        let prompt: PromptViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
        let storage: URL
        let tabID: UUID
        let sessionID: UUID

        /// Resolved by scanning the writer's folder so the fixture never assumes a file-name
        /// scheme or a symlink-free temporary path.
        func sessionFileURL() throws -> URL {
            let folder = storage.appendingPathComponent("AgentSessions", isDirectory: true)
            let needle = sessionID.uuidString.lowercased()
            let matches = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.lowercased().contains(needle) }
            return try XCTUnwrap(matches.first, "expected exactly one persisted file for \(sessionID), found \(matches)")
        }

        /// Writes the persisted session through the production writer, optionally replacing the
        /// raw `providerUsage` member so the fixture is independent of the in-memory codec.
        @MainActor
        func seedPersistedSession(
            providerUsage: AgentProviderUsagePersist?,
            rawProviderUsageMember: Any?
        ) async throws -> AgentSession {
            let service = AgentSessionDataService.shared
            let persisted = AgentSession(
                id: sessionID,
                workspaceID: workspace.id,
                composeTabID: tabID,
                name: "Usage Runtime",
                items: [AgentChatItemPersist(from: .user("hello", sequenceIndex: 0))],
                itemCount: 1,
                agentKind: AgentProviderKind.claudeCode.rawValue,
                lastRunState: AgentSessionRunState.idle.rawValue,
                providerUsage: providerUsage
            )
            let fileURL = try await service.saveAgentSession(
                persisted,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 1
            )
            if let rawProviderUsageMember {
                var members = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
                )
                members["providerUsage"] = rawProviderUsageMember
                try JSONSerialization.data(withJSONObject: members, options: [.sortedKeys]).write(to: fileURL)
            }
            // The tab becomes the owner of the seeded incarnation through one gate-held paired
            // load (transcript, schedule projection, and persistence state together), which is what
            // authorizes this tab's later saves over the seeded file. Runtime usage accounting is
            // deliberately left untouched: these tests exercise controller-before-hydration paths and
            // apply the usage hydration explicitly through `test_applyPersistedHydration`.
            let adopted = await viewModel.test_adoptPersistedIncarnation(tabID: tabID)
            XCTAssertTrue(adopted, "paired adoption establishes ownership of the seeded incarnation")
            XCTAssertNotNil(session.persistenceState(for: sessionID))
            XCTAssertNil(session.usageAccounting, "ownership adoption never installs usage accounting")
            return try await reloadPersistedSession()
        }

        func reloadPersistedSession() async throws -> AgentSession {
            let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace)
            return try XCTUnwrap(loaded)
        }

        func rawProviderUsageMember() throws -> Any? {
            let members = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: sessionFileURL())) as? [String: Any]
            )
            return members["providerUsage"]
        }

        @MainActor
        func hydrationPayload() async throws -> AgentSessionHydrationPayload {
            let request = AgentSessionHydrationRequest(
                workspace: workspace,
                tabID: tabID,
                sessionID: sessionID,
                resolvedDisplayName: "Usage Runtime",
                hasPendingQuestionUI: false,
                transcriptViewportState: .liveBottom,
                isCompressedHistoryRevealed: false,
                initialPerformanceSnapshot: .empty
            )
            let prepared = try await AgentSessionDataService.shared.preparePersistedHydration(request)
            return try XCTUnwrap(prepared)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: storage)
        }
    }

    private func makeFixture() throws -> Fixture {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentUsageRuntimeIntegrationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let tabID = UUID()
        let sessionID = UUID()
        let workspace = WorkspaceModel(
            name: "Agent Usage Runtime",
            repoPaths: [],
            customStoragePath: storage,
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Source", activeAgentSessionID: sessionID)],
            activeComposeTabID: tabID
        )

        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager, mcpHost: ServerNetworkManager.shared, routingWaiter: .shared, codexAuthRecovery: CodexManagedAuthRecoveryService.shared, modelOverrides: AppModelOverrideReader(), ohMyPiConnectionState: { OhMyPiConnectionAvailability.isEffectivelyConnected() }),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        prompt.attachWorkspaceManager(workspaceManager)
        workspaceManager.workspaces = [workspace]
        workspaceManager.activeWorkspace = workspace
        prompt.loadComposeTabsFromWorkspace(workspace)

        let recorder = LifecycleRecorder()
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: recorder) }
        )
        viewModel.test_setSidebarAutoArchiveDependencies(promptManager: prompt, workspaceManager: workspaceManager)
        viewModel.test_establishPersistenceWorkspace(workspace)
        viewModel.test_setCurrentTabIDOverride(tabID)

        let session = AgentTabSession(tabID: tabID)
        session.selectedAgent = .claudeCode
        viewModel.test_installLiveSession(session)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        XCTAssertEqual(session.activeAgentSessionID, sessionID)

        return Fixture(
            viewModel: viewModel,
            session: session,
            prompt: prompt,
            workspaceManager: workspaceManager,
            workspace: workspace,
            storage: storage,
            tabID: tabID,
            sessionID: sessionID
        )
    }
}

/// Native-controller fake that owns a driveable usage-evidence stream. It never runs a process;
/// tests emit the exact ordered events the real controller would produce. Emission is
/// nonisolated so tests drive it synchronously from the main actor.
actor UsageEvidenceFakeNativeController: NativeAgentRuntimeControlling {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }

    private let label: String
    private nonisolated let usageStream: AsyncStream<NativeUsageAccountingEvent>
    private nonisolated let usageContinuation: AsyncStream<NativeUsageAccountingEvent>.Continuation
    private nonisolated let transcriptStream: AsyncStream<NativeAgentRuntimeEvent>
    private nonisolated let counter = Counter()
    nonisolated var emittedCount: Int {
        counter.value
    }

    init(label: String = "usage-fake") {
        self.label = label
        var captured: AsyncStream<NativeUsageAccountingEvent>.Continuation?
        usageStream = AsyncStream { captured = $0 }
        usageContinuation = captured!
        transcriptStream = AsyncStream { _ in }
    }

    @discardableResult
    nonisolated func emitLaunch(
        mode: NativeProcessLaunchIdentity.LaunchMode = .freshSession,
        provenance: ClaudeNativeProcessSessionController.CommandProvenance = .automaticResolved,
        variant: ClaudeCodeRuntimeVariant = .standard
    ) -> NativeProcessLaunchIdentity {
        let identity = NativeProcessLaunchIdentity(
            token: UUID(),
            pid: 4242,
            launchMode: mode,
            commandProvenance: provenance,
            runtimeVariant: variant,
            executablePath: "/synthetic/bin/claude",
            executableRealPath: "/synthetic/claude",
            backend: .defaultClaude,
            environmentOverrideKeys: [],
            configuredEnvironmentOverrideKeys: [],
            spawnedAt: Date()
        )
        emit(.launched(identity))
        return identity
    }

    nonisolated func emit(_ event: NativeUsageAccountingEvent) {
        counter.increment()
        usageContinuation.yield(event)
    }

    /// Mirrors controller deallocation: the evidence stream ends without a launch end.
    nonisolated func finish() {
        usageContinuation.finish()
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        transcriptStream
    }

    var usageAccountingEvents: AsyncStream<NativeUsageAccountingEvent> {
        usageStream
    }

    func ensureEventsStreamReady() async {}
    func resetEventsStreamForNewRun() async {}
    func startOrResume(
        existingSessionID: String?,
        model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride _: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: existingSessionID ?? "usage-fake-session")
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "usage-fake-session")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {}

    func sendUserMessage(_: String) async throws -> UUID {
        UUID()
    }

    func interruptTurn(reason _: String) async -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() async {}
    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}
}
