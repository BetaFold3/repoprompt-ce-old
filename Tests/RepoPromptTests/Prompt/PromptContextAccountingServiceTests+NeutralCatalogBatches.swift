@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// Projection-neutral catalog batches: an applied-index batch with no file-level change (only
/// folders modified, added, or removed, such as FSEvents for a tracked directory whose changed entry
/// is ignored or transient, or an empty directory appearing or disappearing) changes no projection
/// candidate, because the candidate set is files. It must leave the projection catalog token
/// current, including its topology and applied-index stamps, so a completed automatic projection
/// keeps its coverage and automatic codemaps keep rendering without a projection restart.
/// File-level batches still move the token. Each neutral test proves the batch landed (the raw
/// applied-index generation advances), was classified neutral (the neutral count advances by one),
/// and left the ordered projection view unchanged.
extension PromptContextAccountingServiceTests {
    func testFolderOnlyCatalogBatchKeepsCompletedAutomaticCodemaps() async throws {
        let fixture = try await makeNeutralBatchFixture(name: #function)
        try await fixture.convergeBaseline()
        try await assertNeutralBatchKeepsCompletedAutomaticCodemaps(
            fixture: fixture,
            delta: .folderModified("Sources", Date()),
            label: "folder-only",
            expectsTopologyBump: false
        ) {}
    }

    /// Control: a file-level batch on the same root still moves the token (the projection stamp
    /// follows projection-relevant batches), and automatic codemaps converge again afterwards. A
    /// later neutral batch then keeps the nonzero-stamp token.
    func testFileLevelCatalogBatchStillMovesProjectionCatalogToken() async throws {
        let fixture = try await makeNeutralBatchFixture(name: #function)
        try await fixture.convergeBaseline()
        let observedTokenBefore = await fixture.catalogToken()
        let tokenBefore = try XCTUnwrap(observedTokenBefore, "Baseline must expose a projection catalog token.")

        await fixture.store.replayObservedFileSystemDeltas(
            rootID: fixture.rootID,
            deltas: [.fileModified("Sources/Extra.swift", Date())]
        )

        let observedTokenAfter = await fixture.catalogToken()
        let tokenAfter = try XCTUnwrap(observedTokenAfter, "The file-level batch removed the catalog token.")
        XCTAssertNotEqual(tokenAfter, tokenBefore, "A file-level batch must move the projection catalog token.")
        XCTAssertNotEqual(
            tokenAfter.appliedIndexGeneration,
            tokenBefore.appliedIndexGeneration,
            "A file-level batch must advance the projection applied-index stamp."
        )
        try await fixture.convergeBaseline()

        // Neutral after relevant: the stamp is now nonzero and a folder-only batch must keep it.
        let observedRelevantToken = await fixture.catalogToken()
        let relevantToken = try XCTUnwrap(observedRelevantToken, "The reconverged root must expose a token.")
        XCTAssertNotEqual(
            relevantToken.appliedIndexGeneration,
            0,
            "The file-level batch must leave a nonzero projection applied-index stamp."
        )
        let observedRawBefore = await fixture.rawAppliedIndexGeneration()
        let rawBefore = try XCTUnwrap(observedRawBefore, "The root must expose a raw applied-index generation.")
        let neutralBefore = await fixture.neutralBatchCount()

        await fixture.store.replayObservedFileSystemDeltas(
            rootID: fixture.rootID,
            deltas: [.folderModified("Sources", Date())]
        )

        let observedRawAfter = await fixture.rawAppliedIndexGeneration()
        let rawAfter = try XCTUnwrap(observedRawAfter, "The root lost its raw applied-index generation.")
        XCTAssertGreaterThan(rawAfter, rawBefore, "The folder-only batch after a file-level batch must land.")
        let neutralAfter = await fixture.neutralBatchCount()
        XCTAssertEqual(
            neutralAfter,
            neutralBefore + 1,
            "The folder-only batch after a file-level batch must be classified neutral."
        )
        let observedNeutralToken = await fixture.catalogToken()
        let neutralToken = try XCTUnwrap(observedNeutralToken, "The folder-only batch removed the catalog token.")
        XCTAssertEqual(
            neutralToken,
            relevantToken,
            "A folder-only batch after a file-level batch must keep the nonzero-stamp token " +
                "(raw applied-index \(rawBefore)->\(rawAfter))."
        )
    }

    func testFolderAddedBatchKeepsCompletedAutomaticCodemaps() async throws {
        let fixture = try await makeNeutralBatchFixture(name: #function)
        try await fixture.convergeBaseline()
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Sources/Empty"),
            withIntermediateDirectories: true
        )
        try await assertNeutralBatchKeepsCompletedAutomaticCodemaps(
            fixture: fixture,
            delta: .folderAdded("Sources/Empty"),
            label: "folder-added",
            expectsTopologyBump: true
        ) {
            let present = await fixture.folderRecordPresent("Sources/Empty")
            XCTAssertTrue(present, "The folder-added batch must index Sources/Empty.")
        }
    }

    func testEmptyFolderRemovedBatchKeepsCompletedAutomaticCodemaps() async throws {
        let fixture = try await makeNeutralBatchFixture(name: #function, preloadDirectories: ["Sources/Empty"])
        let presentAfterLoad = await fixture.folderRecordPresent("Sources/Empty")
        XCTAssertTrue(presentAfterLoad, "The preloaded empty folder must be indexed at load.")
        try await fixture.convergeBaseline()
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Sources/Empty"))
        try await assertNeutralBatchKeepsCompletedAutomaticCodemaps(
            fixture: fixture,
            delta: .folderRemoved("Sources/Empty"),
            label: "empty-folder-removed",
            expectsTopologyBump: true
        ) {
            let present = await fixture.folderRecordPresent("Sources/Empty")
            XCTAssertFalse(present, "The empty-folder-removed batch must remove the Sources/Empty record.")
        }
    }

    /// Control: a file-added batch moves the projection topology stamp as well as the applied-index
    /// stamp, and automatic codemaps converge again afterwards (file-level batches fence and relaunch).
    func testFileAddedBatchMovesProjectionTopologyStamp() async throws {
        let fixture = try await makeNeutralBatchFixture(name: #function)
        try await fixture.convergeBaseline()
        let observedTokenBefore = await fixture.catalogToken()
        let tokenBefore = try XCTUnwrap(observedTokenBefore, "Baseline must expose a projection catalog token.")

        try "struct Added {}\n".write(
            to: fixture.root.appendingPathComponent("Sources/Added.swift"),
            atomically: true,
            encoding: .utf8
        )
        await fixture.store.replayObservedFileSystemDeltas(
            rootID: fixture.rootID,
            deltas: [.fileAdded("Sources/Added.swift")]
        )

        let observedTokenAfter = await fixture.catalogToken()
        let tokenAfter = try XCTUnwrap(observedTokenAfter, "The file-added batch removed the catalog token.")
        XCTAssertNotEqual(tokenAfter, tokenBefore, "A file-added batch must move the projection catalog token.")
        XCTAssertNotEqual(
            tokenAfter.topologyGeneration,
            tokenBefore.topologyGeneration,
            "A file-added batch must advance the projection topology stamp."
        )
        XCTAssertNotEqual(
            tokenAfter.appliedIndexGeneration,
            tokenBefore.appliedIndexGeneration,
            "A file-added batch must advance the projection applied-index stamp."
        )
        try await fixture.convergeBaseline()
    }

    /// Shared assertions for a projection-neutral batch on a converged fixture. The batch must land
    /// (raw applied-index generation advances) and be classified neutral (neutral count +1), leave the
    /// ordered projection view and the token unchanged, and, when `expectsTopologyBump`, still advance
    /// the shard's raw topology generation, so the stamp decoupling (not a missing bump) keeps the
    /// token equal. The phase and projection counters stay unchanged through three automatic calls.
    private func assertNeutralBatchKeepsCompletedAutomaticCodemaps(
        fixture: NeutralBatchFixture,
        delta: FileSystemDelta,
        label: String,
        expectsTopologyBump: Bool,
        verifyDeltaApplied: () async -> Void
    ) async throws {
        let observedTokenBefore = await fixture.catalogToken()
        let tokenBefore = try XCTUnwrap(observedTokenBefore, "Baseline must expose a projection catalog token.")
        let observedRawBefore = await fixture.rawAppliedIndexGeneration()
        let rawBefore = try XCTUnwrap(observedRawBefore, "Baseline must expose a raw applied-index generation.")
        let observedTopologyBefore = await fixture.shardTopologyGeneration()
        let topologyBefore = try XCTUnwrap(observedTopologyBefore, "Baseline must publish a catalog shard.")
        let neutralBefore = await fixture.neutralBatchCount()
        let observedProjectionIDsBefore = await fixture.projectionFileIDs()
        let projectionIDsBefore = try XCTUnwrap(observedProjectionIDsBefore, "Baseline must publish projection files.")
        XCTAssertFalse(projectionIDsBefore.isEmpty, "Baseline projection files must not be empty.")
        let scheduledBefore = try await fixture.projectionPreloadsScheduled()
        let coveragesBefore = try await fixture.projectionCoveragesCompleted()

        await fixture.store.replayObservedFileSystemDeltas(rootID: fixture.rootID, deltas: [delta])
        await verifyDeltaApplied()

        let observedRawAfter = await fixture.rawAppliedIndexGeneration()
        let rawAfter = try XCTUnwrap(observedRawAfter, "The \(label) batch removed the raw applied-index generation.")
        let observedTopologyAfter = await fixture.shardTopologyGeneration()
        let topologyAfter = try XCTUnwrap(observedTopologyAfter, "The \(label) batch removed the catalog shard.")
        let neutralAfter = await fixture.neutralBatchCount()
        let observed = "raw applied-index \(rawBefore)->\(rawAfter), shard topology \(topologyBefore)->\(topologyAfter), " +
            "neutral count \(neutralBefore)->\(neutralAfter)"
        XCTAssertGreaterThan(rawAfter, rawBefore, "The \(label) batch must land (\(observed)).")
        XCTAssertEqual(neutralAfter, neutralBefore + 1, "The \(label) batch must be classified neutral (\(observed)).")
        if expectsTopologyBump {
            XCTAssertGreaterThan(
                topologyAfter,
                topologyBefore,
                "The \(label) batch must still advance the raw shard topology (\(observed))."
            )
        } else {
            XCTAssertEqual(topologyAfter, topologyBefore, "The \(label) batch must not move the raw shard topology (\(observed)).")
        }
        let projectionIDsAfter = await fixture.projectionFileIDs()
        XCTAssertEqual(
            projectionIDsAfter,
            projectionIDsBefore,
            "A \(label) batch must not change the ordered projection files (\(observed))."
        )
        let observedTokenAfter = await fixture.catalogToken()
        let tokenAfter = try XCTUnwrap(observedTokenAfter, "The \(label) batch removed the catalog token.")
        XCTAssertEqual(
            tokenAfter,
            tokenBefore,
            "A \(label) batch must not move the projection catalog token (\(observed))."
        )
        try await assertProjectionUnchanged(
            fixture: fixture,
            label: label,
            stage: "the batch",
            scheduledBefore: scheduledBefore,
            coveragesBefore: coveragesBefore
        )

        for repeatCall in 1 ... 3 {
            let call = try await fixture.automaticCall()
            XCTAssertTrue(
                call.included,
                "Automatic call \(repeatCall) after the \(label) batch dropped Target: \(call.diagnostics)"
            )
            XCTAssertFalse(
                call.reportsPublicationStale,
                "Automatic call \(repeatCall) after the \(label) batch reported publicationStale: \(call.diagnostics)"
            )
        }
        try await assertProjectionUnchanged(
            fixture: fixture,
            label: label,
            stage: "the automatic calls",
            scheduledBefore: scheduledBefore,
            coveragesBefore: coveragesBefore
        )
    }

    private func assertProjectionUnchanged(
        fixture: NeutralBatchFixture,
        label: String,
        stage: String,
        scheduledBefore: UInt64,
        coveragesBefore: UInt64
    ) async throws {
        let phase = await fixture.projectionPhase()
        XCTAssertEqual(phase, .complete, "The completed projection must stay complete after \(stage) (\(label)).")
        let scheduled = try await fixture.projectionPreloadsScheduled()
        XCTAssertEqual(scheduled, scheduledBefore, "No projection restart may be scheduled after \(stage) (\(label)).")
        let coverages = try await fixture.projectionCoveragesCompleted()
        XCTAssertEqual(coverages, coveragesBefore, "No projection coverage may rerun after \(stage) (\(label)).")
    }

    private func makeNeutralBatchFixture(
        name: String,
        preloadDirectories: [String] = []
    ) async throws -> NeutralBatchFixture {
        let repositories = try ReviewGitRepositoryFixture(name: name)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target { func neutralTargetCodemapSymbol() {} }\n",
                "Sources/Extra.swift": "struct Extra {}\n"
            ]
        )
        for directory in preloadDirectories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        let codemapFixture = try CodemapStoreFixture(name: name)
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        // Production preload policy: the store-owned projection must complete on its own.
        let store = codemapFixture.makeStore()
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
        return NeutralBatchFixture(
            root: root,
            store: store,
            rootID: loaded.id,
            rootEpoch: rootEpoch,
            targetID: target.id
        )
    }
}

private struct NeutralBatchFixture {
    struct Call {
        let included: Bool
        let reportsPublicationStale: Bool
        let diagnostics: String
    }

    let root: URL
    let store: WorkspaceFileContextStore
    let rootID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let targetID: UUID
    private let service = PromptContextAccountingService()
    private let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)

    /// Whether the store holds a folder record at the root-relative path.
    func folderRecordPresent(_ relativePath: String) async -> Bool {
        await store.lookupPath(rootID: rootID, relativePath: relativePath)?.folder != nil
    }

    /// One automatic prompt-stats call for the seed; reports whether Target rendered and whether
    /// the call ended on a `publicationStale` issue.
    func automaticCall() async throws -> Call {
        let presentation = try await service.withPromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(
                    selectedPaths: [root.appendingPathComponent("Sources/Source.swift").path],
                    codemapAutoEnabled: true
                ),
                codeMapUsage: .auto
            ),
            store: store,
            lookupContext: lookupContext
        ) { $0.codemapPresentation }
        let included = presentation.renderedEntriesByFileID[targetID]?.text
            .contains("neutralTargetCodemapSymbol") == true
        let reportsPublicationStale = presentation.issues.contains { issue in
            if case .publicationStale = issue { return true }
            return false
        }
        return Call(
            included: included,
            reportsPublicationStale: reportsPublicationStale,
            diagnostics: "\(presentation.coverage) \(presentation.issues)"
        )
    }

    /// Automatic baseline that includes Target without `publicationStale`, with the store-owned
    /// projection complete and graph recovery drained, so a later catalog batch meets a settled
    /// completed projection.
    func convergeBaseline(file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        var converged = false
        var diagnostics = ""
        while !converged, clock.now < deadline {
            let call = try await automaticCall()
            converged = call.included && !call.reportsPublicationStale
            diagnostics = call.diagnostics
            if !converged {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        XCTAssertTrue(converged, "Automatic baseline never included Target: \(diagnostics)", file: file, line: line)
        let settleDeadline = clock.now.advanced(by: .seconds(15))
        var settled = false
        var lastPhase: WorkspaceCodemapProjectionPreloadPhase?
        while !settled, clock.now < settleDeadline {
            let state = await store.codemapGraphPublicationRecoveryStateForTesting(rootEpoch: rootEpoch)
            lastPhase = await projectionPhase()
            settled = !state.flightActive && !state.observerActive && lastPhase == .complete
            if !settled {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTAssertTrue(
            settled,
            "Projection never settled complete after the baseline (phase \(String(describing: lastPhase))).",
            file: file,
            line: line
        )
        let settledCall = try await automaticCall()
        XCTAssertTrue(
            settledCall.included,
            "The settled baseline dropped Target: \(settledCall.diagnostics)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            settledCall.reportsPublicationStale,
            "The settled baseline reported publicationStale: \(settledCall.diagnostics)",
            file: file,
            line: line
        )
    }

    func catalogToken() async -> WorkspaceCodemapProjectionCatalogToken? {
        await store.codemapProjectionCatalogTokenForTesting(rootID: rootID)
    }

    func rawAppliedIndexGeneration() async -> UInt64? {
        await store.appliedIndexGenerationForTesting(rootID: rootID)
    }

    func shardTopologyGeneration() async -> UInt64? {
        await store.publishedRootCatalogShardTopologyGenerationForTesting(rootID: rootID)
    }

    func neutralBatchCount() async -> UInt64 {
        await store.codemapProjectionNeutralBatchCountForTesting(rootID: rootID)
    }

    func projectionFileIDs() async -> [UUID]? {
        await store.publishedRootCatalogShardProjectionFileIDsForTesting(rootID: rootID)
    }

    func projectionPhase() async -> WorkspaceCodemapProjectionPreloadPhase? {
        await store.codemapBindingEngineAccountingForTesting(rootID: rootID)?.projectionRoots.first?.phase
    }

    func projectionPreloadsScheduled() async throws -> UInt64 {
        let accounting = await store.codemapBindingEngineAccountingForTesting(rootID: rootID)
        return try XCTUnwrap(accounting, "The root must expose engine accounting.").counters.projectionPreloadsScheduled
    }

    func projectionCoveragesCompleted() async throws -> UInt64 {
        let accounting = await store.codemapBindingEngineAccountingForTesting(rootID: rootID)
        return try XCTUnwrap(accounting, "The root must expose engine accounting.").counters.projectionCoveragesCompleted
    }
}
