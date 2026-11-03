@testable import RepoPromptApp
@testable import RepoPromptWorkspace
import XCTest

/// A retained superseded projection with no worker is refused by ordinary scheduling, so its
/// automatic coverage is terminal for the root session. Automatic accounting must report it as
/// typed unavailable (not pending forever), keep selected content, and recover only on reload.
extension PromptContextAccountingServiceTests {
    func testAutomaticPromptStatsReportRetainedSupersededProjectionAsTerminal() async throws {
        let fixture = try await makeTerminalProjectionFixture(name: #function)
        let jobID = try await fixture.installRetainedSupersededProjection()

        let result = try await fixture.settledAutomaticStats()

        XCTAssertEqual(result.resolvedEntries.map(\.file.standardizedRelativePath), ["Sources/Source.swift"])
        XCTAssertFalse(result.resolvedEntries.contains { $0.isCodemap })
        XCTAssertTrue(result.codemapPresentation.orderedEntries.isEmpty)
        let terminal = WorkspaceCodemapOperationIssue.automatic(.unavailable(.graph(.definitionUniverse(
            rootEpoch: fixture.rootEpoch,
            reason: .projectionSuperseded
        ))))
        guard case let .unavailable(coverageIssues) = result.codemapPresentation.coverage else {
            return XCTFail("Expected terminal unavailable coverage, got \(result.codemapPresentation.coverage)")
        }
        XCTAssertTrue(
            (coverageIssues + result.codemapPresentation.issues).contains(terminal),
            "\(coverageIssues) \(result.codemapPresentation.issues)"
        )
        XCTAssertFalse(result.codemapPresentation.issues.contains { issue in
            if case .automatic(.incomplete) = issue { return true }
            if case .automatic(.pending) = issue { return true }
            return false
        }, "\(result.codemapPresentation.issues)")

        // Reporting never restarts the refused projection.
        let accounting = await fixture.store.codemapBindingEngineAccountingForTesting(rootID: fixture.rootID)
        XCTAssertEqual(accounting?.counters.projectionPreloadsScheduled, 0)
        XCTAssertEqual(accounting?.projectionRoots.first?.phase, .superseded)
        let retained = await fixture.store.retainedSupersededCodemapProjectionIDForTesting(rootID: fixture.rootID)
        XCTAssertEqual(retained, jobID)
    }

    func testReloadingRootReplacesRetainedSupersededProjectionWithFreshJob() async throws {
        let fixture = try await makeTerminalProjectionFixture(name: #function)
        _ = try await fixture.installRetainedSupersededProjection()
        let terminalResult = try await fixture.settledAutomaticStats()
        XCTAssertTrue(fixture.reportsTerminal(terminalResult.codemapPresentation, rootEpoch: fixture.rootEpoch))

        await fixture.store.unloadRoot(id: fixture.rootID)
        let reloaded = try await fixture.store.loadRoot(path: fixture.root.path)
        let reloadedEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: reloaded.id,
            rootLifetimeID: fixture.store.rootLifetimeIDForTesting(rootID: reloaded.id)
        )
        XCTAssertNotEqual(reloadedEpoch, fixture.rootEpoch)

        // The next automatic call activates projection demand on the replacement session, which
        // schedules a fresh job instead of inheriting the retained superseded one.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var scheduled: UInt64 = 0
        var last = ""
        while scheduled == 0, clock.now < deadline {
            let result = try await fixture.automaticStats()
            XCTAssertFalse(fixture.reportsTerminal(result.codemapPresentation, rootEpoch: reloadedEpoch))
            last = "\(result.codemapPresentation.coverage)"
            scheduled = await fixture.store.codemapBindingEngineAccountingForTesting(rootID: reloaded.id)?
                .counters.projectionPreloadsScheduled ?? 0
            if scheduled == 0 { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertGreaterThan(scheduled, 0, "Reload never scheduled a fresh projection: \(last)")
        let retained = await fixture.store.retainedSupersededCodemapProjectionIDForTesting(rootID: reloaded.id)
        XCTAssertNil(retained)
    }

    private func makeTerminalProjectionFixture(name: String) async throws -> TerminalProjectionFixture {
        let repositories = try ReviewGitRepositoryFixture(name: name)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target { func terminalTargetCodemapSymbol() {} }\n"
            ]
        )
        let codemapFixture = try CodemapStoreFixture(name: name)
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        // Preload stays off so the only projection job is the injected retained superseded one.
        let store = codemapFixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        return TerminalProjectionFixture(root: root, store: store, rootID: loaded.id, rootEpoch: rootEpoch)
    }
}

private struct TerminalProjectionFixture {
    let root: URL
    let store: WorkspaceFileContextStore
    let rootID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch

    func installRetainedSupersededProjection() async throws -> UUID {
        // Codemap root setup is lazy; one plain source demand registers the engine session
        // without activating projection demand (preload is disabled).
        let lookup = await store.lookupPath(
            root.appendingPathComponent("Sources/Source.swift").path,
            rootScope: .allLoaded
        )
        let source = try XCTUnwrap(lookup?.file)
        _ = await store.requestCodemapArtifact(forFileID: source.id)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if let jobID = await store.installRetainedSupersededCodemapProjectionForTesting(rootID: rootID) {
                return jobID
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(
            domain: "TerminalProjectionFixture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Root session never accepted a retained superseded projection."]
        )
    }

    func automaticStats() async throws -> PromptContextAccountingResult {
        try await PromptContextAccountingService().withPromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(
                    selectedPaths: [root.appendingPathComponent("Sources/Source.swift").path],
                    codemapAutoEnabled: true
                ),
                codeMapUsage: .auto
            ),
            store: store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        ) { $0 }
    }

    /// Retries past transient `publicationStale` results while the freshly loaded root settles.
    func settledAutomaticStats() async throws -> PromptContextAccountingResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var result = try await automaticStats()
        while clock.now < deadline, result.codemapPresentation.issues.contains(where: { issue in
            if case .publicationStale = issue { return true }
            return false
        }) {
            try await Task.sleep(for: .milliseconds(100))
            result = try await automaticStats()
        }
        return result
    }

    func reportsTerminal(
        _ presentation: WorkspaceCodemapOperationPresentation,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        let terminal = WorkspaceCodemapOperationIssue.automatic(.unavailable(.graph(.definitionUniverse(
            rootEpoch: rootEpoch,
            reason: .projectionSuperseded
        ))))
        var issues = presentation.issues
        if case let .unavailable(coverageIssues) = presentation.coverage {
            issues += coverageIssues
        }
        return issues.contains(terminal)
    }
}
