@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Automatic foreground root-session repair (D2): an automatic prompt-stats operation that observes
/// repository-authority drift on the current root session spends one bounded reset, so automatic
/// codemaps converge without a structure request. Background projection stays non-recovering.
extension PromptContextAccountingServiceTests {
    func testAutomaticPromptStatsRepairsSeedIssuanceDriftOnce() async throws {
        let fixture = try await makeAutomaticRepairFixture(name: #function)
        try await fixture.convergeBaseline()

        // A new seed's cold demand observes the advanced index: seed issuance drift.
        try fixture.repositories.stage("Notes.txt", at: fixture.root)
        try await fixture.assertRecoversWithOneRepair(seedPath: "Sources/Other.swift")
    }

    func testAutomaticPromptStatsRepairsProjectionDetectedDriftOnce() async throws {
        let fixture = try await makeAutomaticRepairFixture(name: #function)
        try await fixture.convergeBaseline()

        // The seed stays ready; the Swift edit reruns projection, which observes the advanced index.
        try fixture.repositories.stage("Notes.txt", at: fixture.root)
        _ = try await fixture.store.editFile(
            rootID: fixture.rootID,
            relativePath: "Sources/Extra.swift",
            newContent: "struct Extra { let edited = true }\n"
        )
        // The first call observes the latch (at acquisition or while planning waits), spends the
        // projection reset, and returns pending `graphRebuild` without restarting.
        try await fixture.assertRecoversWithOneRepair(
            seedPath: "Sources/Source.swift",
            expectFirstCallReset: true
        )
    }

    func testAutomaticPromptStatsRepairsColdCandidateDriftOnce() async throws {
        let fixture = try await makeAutomaticRepairFixture(name: #function)
        try await fixture.convergeBaseline()

        // Keep the seed warm (held, so it joins without issuing authority), and evict the idle
        // ready Target so its next demand is cold. The completed projection is not rerun.
        let sourceTicket = try await fixture.holdReadyDemand(path: "Sources/Source.swift")
        addTeardownBlock { _ = await fixture.store.cancelCodemapArtifactDemand(sourceTicket) }
        let evicted = await fixture.store.evictIdleReadyCodemapDemandsForTesting(rootEpoch: fixture.rootEpoch)
        XCTAssertGreaterThan(evicted, 0, "Target must be an idle ready record to evict")

        try fixture.repositories.stage("Notes.txt", at: fixture.root)
        try await fixture.assertRecoversWithOneRepair(seedPath: "Sources/Source.swift")
    }

    /// The background projection latched the drift before any accounting call: the first automatic
    /// call's projection acquisition already reports the failure. Seed and Target stay warm, so the
    /// round-0 projection check is the only path that can spend the reset.
    func testAutomaticPromptStatsRepairsProjectionLatchedBeforeCallOnce() async throws {
        let fixture = try await makeAutomaticRepairFixture(name: #function)
        try await fixture.convergeBaseline()

        try fixture.repositories.stage("Notes.txt", at: fixture.root)
        try await fixture.editExtraAndAwaitBackgroundAuthorityLatch()
        try await fixture.assertRecoversWithOneRepair(
            seedPath: "Sources/Source.swift",
            expectFirstCallReset: true
        )
    }

    /// A rejection that survives a reset (capability unavailable on every demand) must not reset the
    /// root on each automatic recount: automatic recovery is scoped to repository-authority drift.
    func testAutomaticPromptStatsDoNotResetForPersistentCapabilityRejection() async throws {
        let rejections = CodemapLockedCounter()
        let fixture = try await makeAutomaticRepairFixture(
            name: #function,
            demandResultHook: { _, _ in
                rejections.increment()
                return .rejected(.capabilityUnavailable)
            }
        )
        // Prime until root setup reaches the engine and the first rejection is observed.
        let clock = ContinuousClock()
        let primeDeadline = clock.now.advanced(by: .seconds(10))
        while rejections.value == 0, clock.now < primeDeadline {
            _ = try await fixture.automaticCall(seedPath: "Sources/Source.swift")
        }
        XCTAssertGreaterThan(rejections.value, 0, "No demand reached the rejecting hook.")
        for call in 1 ... 5 {
            let rejectionsBefore = rejections.value
            let result = try await fixture.automaticCall(seedPath: "Sources/Source.swift")
            XCTAssertFalse(result.included, result.diagnostics)
            XCTAssertGreaterThan(rejections.value, rejectionsBefore, "Call \(call) never observed the rejection.")
        }
        let repairs = await fixture.store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairs, 0, "Automatic recounts must not reset for a persistent capability rejection.")
    }

    func testExactPromptStatsDoNotRepairAuthorityDrift() async throws {
        let fixture = try await makeAutomaticRepairFixture(name: #function)
        try await fixture.convergeBaseline()

        try fixture.repositories.stage("Notes.txt", at: fixture.root)
        var diagnostics = ""
        for _ in 1 ... 5 {
            diagnostics = try await fixture.exactCall(seedPath: "Sources/Other.swift")
        }
        XCTAssertTrue(diagnostics.contains("repositoryAuthorityChanged"), diagnostics)
        let repairs = await fixture.store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairs, fixture.baselineRepairs, "Exact intents keep non-recovering demand.")
    }

    func testConcurrentAutomaticPromptStatsShareOneRepairForOneDrift() async throws {
        let fixture = try await makeAutomaticRepairFixture(name: #function)
        try await fixture.convergeBaseline()

        try fixture.repositories.stage("Notes.txt", at: fixture.root)
        async let first = fixture.automaticCall(seedPath: "Sources/Other.swift")
        async let second = fixture.automaticCall(seedPath: "Sources/Other.swift")
        _ = try await (first, second)
        let concurrentRepairs = await fixture.store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(
            concurrentRepairs - fixture.baselineRepairs,
            1,
            "The store fences admit one reset for one drift across concurrent operations."
        )
        try await fixture.assertRecoversWithOneRepair(seedPath: "Sources/Other.swift")
    }

    /// Stat-only index rewrites (a tracked file touched, then the index refreshed, as `git status`
    /// does) are not repository-authority drift: automatic codemaps stay, and nothing is repaired.
    /// Each round also edits a Swift file so projection reruns and captures repository authority
    /// against the rewritten index; warm recounts alone never capture.
    func testStatOnlyIndexRewritesKeepAutomaticCodemapsWithoutRepair() async throws {
        let fixture = try await makeAutomaticRepairFixture(name: #function)
        try await fixture.convergeBaseline()
        let authorityChangesBefore = await fixture.repositoryAuthorityChanges()

        for (index, path) in ["Sources/Target.swift", "Sources/Source.swift", "Sources/Target.swift"].enumerated() {
            let round = index + 1
            try fixture.repositories.rewriteIndexWithoutContentChange(path: path, at: fixture.root)
            let coveragesBefore = await fixture.projectionCoveragesCompleted()
            _ = try await fixture.store.editFile(
                rootID: fixture.rootID,
                relativePath: "Sources/Extra.swift",
                newContent: "struct Extra { let round = \(round) }\n"
            )
            var calls: [String] = []
            var included = false
            while !included, calls.count < 4 {
                if !calls.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                let call = try await fixture.automaticCall(seedPath: "Sources/Source.swift")
                included = call.included
                calls.append(call.diagnostics)
                XCTAssertFalse(call.reportsGraphRebuild, "Round \(round) reset the root: \(call.diagnostics)")
                XCTAssertFalse(
                    call.diagnostics.contains("repositoryAuthorityChanged"),
                    "Round \(round) reported authority drift: \(call.diagnostics)"
                )
            }
            XCTAssertTrue(included, "Round \(round) dropped Target:\n\(calls.joined(separator: "\n"))")
            let completed = try await fixture.awaitProjectionCoverage(beyond: coveragesBefore)
            XCTAssertTrue(completed, "Round \(round): the projection rerun never completed coverage.")
        }
        let repairs = await fixture.store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairs - fixture.baselineRepairs, 0, "Stat-only index rewrites must not reset the root.")
        let authorityChangesAfter = await fixture.repositoryAuthorityChanges()
        XCTAssertEqual(authorityChangesAfter, authorityChangesBefore, "No capture may observe an authority change.")
    }

    /// Covers store-internal projection preload only: with drift and no accounting call, the store
    /// and engine never reset the root session. App recount triggers are not modeled here.
    func testIdleStoreInternalProjectionPreloadDoesNotRepairAuthorityDrift() async throws {
        let fixture = try await makeAutomaticRepairFixture(name: #function)
        try await fixture.convergeBaseline()
        let authorityChangesBefore = await fixture.repositoryAuthorityChanges()

        try fixture.repositories.stage("Notes.txt", at: fixture.root)
        _ = try await fixture.store.editFile(
            rootID: fixture.rootID,
            relativePath: "Sources/Extra.swift",
            newContent: "struct Extra { let edited = true }\n"
        )
        let clock = ContinuousClock()
        let detectionDeadline = clock.now.advanced(by: .seconds(8))
        var detected = false
        while !detected, clock.now < detectionDeadline {
            detected = await fixture.repositoryAuthorityChanges() > authorityChangesBefore
            if !detected {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTAssertTrue(detected, "Background projection never observed the staged index change.")
        // Bounded idle wait after detection: no accounting or foreground call runs.
        try await Task.sleep(for: .seconds(2))
        let repairs = await fixture.store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairs, fixture.baselineRepairs, "Idle background projection must not reset the root session.")
    }

    private func makeAutomaticRepairFixture(
        name: String,
        demandResultHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket,
            WorkspaceCodemapBindingDemandResult
        ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result }
    ) async throws -> AutomaticRepairFixture {
        let repositories = try ReviewGitRepositoryFixture(name: name)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Other.swift": "struct Other { let target: Target }\n",
                "Sources/Target.swift": "struct Target { func repairTargetCodemapSymbol() {} }\n",
                "Sources/Extra.swift": "struct Extra {}\n",
                "Notes.txt": "notes\n"
            ]
        )
        let codemapFixture = try CodemapStoreFixture(name: name)
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        // Only the index advances after the baseline.
        try repositories.write("notes changed\n", to: "Notes.txt", at: root)
        try repositories.settleIndex(at: root)
        let store = codemapFixture.makeStore(demandResultHook: demandResultHook)
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let targetLookup = await store.lookupPath(
            root.appendingPathComponent("Sources/Target.swift").path,
            rootScope: .allLoaded
        )
        let target = try XCTUnwrap(targetLookup?.file)
        return AutomaticRepairFixture(
            repositories: repositories,
            root: root,
            store: store,
            rootID: loaded.id,
            rootEpoch: rootEpoch,
            targetID: target.id
        )
    }
}

private final class AutomaticRepairFixture: @unchecked Sendable {
    struct Call {
        let included: Bool
        let reportsGraphRebuild: Bool
        let diagnostics: String
    }

    let repositories: ReviewGitRepositoryFixture
    let root: URL
    let store: WorkspaceFileContextStore
    let rootID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let targetID: UUID
    private(set) var baselineRepairs = 0
    private let service = PromptContextAccountingService()
    private let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)

    init(
        repositories: ReviewGitRepositoryFixture,
        root: URL,
        store: WorkspaceFileContextStore,
        rootID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        targetID: UUID
    ) {
        self.repositories = repositories
        self.root = root
        self.store = store
        self.rootID = rootID
        self.rootEpoch = rootEpoch
        self.targetID = targetID
    }

    /// One automatic prompt-stats call; reports whether Target rendered and whether the call
    /// returned a pending `graphRebuild` reason (only a root-session reset produces it here).
    func automaticCall(seedPath: String) async throws -> Call {
        let presentation = try await promptStats(seedPath: seedPath, codeMapUsage: .auto)
        let included = presentation.renderedEntriesByFileID[targetID]?.text
            .contains("repairTargetCodemapSymbol") == true
        let reportsGraphRebuild = presentation.issues.contains { issue in
            guard case let .automatic(.pending(reasons)) = issue else { return false }
            return reasons.contains(.graphRebuild(rootEpoch: rootEpoch))
        }
        return Call(
            included: included,
            reportsGraphRebuild: reportsGraphRebuild,
            diagnostics: "\(presentation.coverage) \(presentation.issues)"
        )
    }

    /// One exact (selected-codemap) prompt-stats call; returns diagnostics.
    func exactCall(seedPath: String) async throws -> String {
        let presentation = try await promptStats(seedPath: seedPath, codeMapUsage: .selected)
        return "\(presentation.coverage) \(presentation.issues)"
    }

    private func promptStats(
        seedPath: String,
        codeMapUsage: CodeMapUsage
    ) async throws -> WorkspaceCodemapOperationPresentation {
        let request = PromptContextAccountingRequest(
            selection: StoredSelection(
                selectedPaths: [root.appendingPathComponent(seedPath).path],
                codemapAutoEnabled: codeMapUsage == .auto
            ),
            codeMapUsage: codeMapUsage
        )
        return try await service.withPromptStats(
            request: request,
            store: store,
            lookupContext: lookupContext
        ) { $0.codemapPresentation }
    }

    /// Holds a ready demand for the file so it stays warm (not idle) across later operations.
    func holdReadyDemand(path: String) async throws -> WorkspaceCodemapArtifactDemandTicket {
        let lookup = await store.lookupPath(root.appendingPathComponent(path).path, rootScope: .allLoaded)
        let file = try XCTUnwrap(lookup?.file)
        let owned = await store.requestCodemapArtifactWithOwnership(forFileID: file.id, priority: .demand)
        guard case let .ready(ready) = owned.result else {
            throw NSError(
                domain: "AutomaticRepairFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected a warm ready join for \(path): \(owned.result)"]
            )
        }
        return ready.ticket
    }

    /// Automatic baseline that includes Target, with graph recovery drained and no repair.
    func convergeBaseline(file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        var converged = false
        var diagnostics = ""
        while !converged, clock.now < deadline {
            let call = try await automaticCall(seedPath: "Sources/Source.swift")
            converged = call.included
            diagnostics = call.diagnostics
            if !converged {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        XCTAssertTrue(converged, "Automatic baseline never included Target: \(diagnostics)", file: file, line: line)
        let drainDeadline = clock.now.advanced(by: .seconds(10))
        var drained = false
        while !drained, clock.now < drainDeadline {
            let state = await store.codemapGraphPublicationRecoveryStateForTesting(rootEpoch: rootEpoch)
            drained = !state.flightActive && !state.observerActive
            if !drained {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTAssertTrue(drained, "Graph publication recovery did not drain after the baseline", file: file, line: line)
        baselineRepairs = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(baselineRepairs, 0, "The automatic baseline must not reset.", file: file, line: line)
    }

    /// Target returns within 4 automatic calls and 10 s with exactly one repair since the baseline;
    /// unchanged repeats stay included and do not repair again. With
    /// `expectFirstCallReset`, the first call must spend the repair and report pending
    /// `graphRebuild` (every root-reset path does; each caller's setup leaves one reachable path).
    func assertRecoversWithOneRepair(
        seedPath: String,
        expectFirstCallReset: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        var included = false
        var calls = 0
        var trail: [String] = []
        var firstRepairCall: (index: Int, call: Call)?
        var previousRepairs = await store.codemapRootSessionRepairCountForTesting()
        while !included, calls < 4, clock.now - started < .seconds(10) {
            calls += 1
            let call = try await automaticCall(seedPath: seedPath)
            included = call.included
            let repairs = await store.codemapRootSessionRepairCountForTesting()
            if repairs > previousRepairs, firstRepairCall == nil {
                firstRepairCall = (calls, call)
            }
            previousRepairs = repairs
            trail.append("call \(calls) at \(clock.now - started) repairs=\(repairs): \(call.diagnostics)")
            if !included {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let recoveryRepairs = await store.codemapRootSessionRepairCountForTesting() - baselineRepairs
        let summary = trail.joined(separator: "\n")
        XCTAssertTrue(included, "Target never returned within 4 automatic calls and 10 s:\n\(summary)", file: file, line: line)
        XCTAssertLessThan(clock.now - started, .seconds(10), summary, file: file, line: line)
        XCTAssertEqual(recoveryRepairs, 1, "One drift event spends exactly one root reset:\n\(summary)", file: file, line: line)
        if expectFirstCallReset {
            XCTAssertEqual(firstRepairCall?.index, 1, "The first call must spend the repair:\n\(summary)", file: file, line: line)
            XCTAssertEqual(
                firstRepairCall?.call.reportsGraphRebuild,
                true,
                "The repairing call must return pending graphRebuild:\n\(summary)",
                file: file,
                line: line
            )
            XCTAssertEqual(firstRepairCall?.call.included, false, summary, file: file, line: line)
        }
        guard included else { return }

        for repeatCall in 1 ... 3 {
            let repeated = try await automaticCall(seedPath: seedPath)
            XCTAssertTrue(
                repeated.included,
                "Unchanged repeat \(repeatCall) dropped Target: \(repeated.diagnostics)",
                file: file,
                line: line
            )
        }
        let repeatRepairs = await store.codemapRootSessionRepairCountForTesting() - baselineRepairs
        XCTAssertEqual(repeatRepairs, 1, "Unchanged repeats must not reset again.", file: file, line: line)
    }

    /// Edits a Swift file so the store-internal projection reruns, then waits until that background
    /// projection has observed (and latched) the staged index change. No accounting call runs.
    func editExtraAndAwaitBackgroundAuthorityLatch(file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = await repositoryAuthorityChanges()
        _ = try await store.editFile(
            rootID: rootID,
            relativePath: "Sources/Extra.swift",
            newContent: "struct Extra { let edited = true }\n"
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        var detected = false
        while !detected, clock.now < deadline {
            detected = await repositoryAuthorityChanges() > before
            if !detected {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTAssertTrue(detected, "Background projection never observed the staged index change.", file: file, line: line)
        let repairs = await store.codemapRootSessionRepairCountForTesting()
        XCTAssertEqual(repairs, baselineRepairs, "The background latch must not reset.", file: file, line: line)
    }

    func repositoryAuthorityChanges() async -> UInt64 {
        await store.codemapBindingEngineAccountingForTesting(rootID: rootID)?.counters.repositoryAuthorityChanges ?? 0
    }

    func projectionCoveragesCompleted() async -> UInt64 {
        await store.codemapBindingEngineAccountingForTesting(rootID: rootID)?.counters.projectionCoveragesCompleted ?? 0
    }

    /// Waits up to 30 s for a projection coverage completed after `baseline`.
    func awaitProjectionCoverage(beyond baseline: UInt64) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if await projectionCoveragesCompleted() > baseline { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}
