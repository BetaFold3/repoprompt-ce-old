@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class PromptContextAccountingServiceTests: XCTestCase {
    func testExactSelectedFilesPreserveStoredSelectionOrderAfterBatchLookupAndConcurrentReads() async throws {
        let root = try makeTemporaryRoot(name: "AccountingOrder")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        let fileC = root.appendingPathComponent("C.swift")
        try write("alpha", to: fileA)
        try write("beta", to: fileB)
        try write("gamma", to: fileC)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileC.path, fileA.path, fileB.path],

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["C.swift", "A.swift", "B.swift"])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["gamma", "alpha", "beta"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testPhysicalizedSelectionRefreshesSessionBoundBatchLookupAfterWorktreeLoad() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "AccountingLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "AccountingWorktree")
        let logicalFile = logicalRoot.appendingPathComponent("Sources/App.swift")
        let worktreeFile = worktreeRoot.appendingPathComponent("Sources/App.swift")
        try write("canonical", to: logicalFile)
        try write("worktree", to: worktreeFile)

        let store = WorkspaceFileContextStore()
        let logicalRootRecord = try await store.loadRoot(path: logicalRoot.path)
        let logicalRootRef = WorkspaceRootRef(
            id: logicalRootRecord.id,
            name: logicalRootRecord.name,
            fullPath: logicalRootRecord.standardizedFullPath
        )
        let physicalRootRef = WorkspaceRootRef(
            id: UUID(),
            name: logicalRootRecord.name,
            fullPath: worktreeRoot.path
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRootRef,
                    physicalRoot: physicalRootRef,
                    binding: AgentSessionWorktreeBinding(
                        id: "accounting-binding",
                        repositoryID: "accounting-repository",
                        repoKey: "accounting-repo",
                        logicalRootPath: logicalRoot.path,
                        logicalRootName: logicalRootRecord.name,
                        worktreeID: "accounting-worktree",
                        worktreeRootPath: worktreeRoot.path,
                        source: "test"
                    )
                )
            ],
            visibleLogicalRoots: [logicalRootRef]
        )
        let lookupContext = WorkspaceLookupContext(
            // This test intentionally exercises a dynamic path selector that begins before
            // the worktree root is loaded. Authoritative file-tool projections use the
            // identity-pinned `projection.lookupRootScope` instead.
            rootScope: .sessionBoundWorkspace(
                canonicalRootPaths: [],
                physicalRootPaths: [worktreeRoot.path]
            ),
            bindingProjection: projection
        )
        let logicalSelection = StoredSelection(
            selectedPaths: [logicalFile.path],
            codemapAutoEnabled: false
        )
        let physicalSelection = lookupContext.physicalizeSelection(logicalSelection)
        XCTAssertEqual(physicalSelection.selectedPaths, [worktreeFile.path])

        let request = WorkspacePathLookupRequest(
            userPath: worktreeFile.path,
            profile: .uiAssisted,
            rootScope: lookupContext.rootScope
        )
        let generationBeforeWorktreeLoad = await store.catalogGeneration(rootScope: lookupContext.rootScope)
        let lookupBeforeWorktreeLoad = await store.lookupPaths([request])
        XCTAssertTrue(lookupBeforeWorktreeLoad.isEmpty)

        let worktreeRootRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
        let generationAfterWorktreeLoad = await store.catalogGeneration(rootScope: lookupContext.rootScope)
        XCTAssertNotEqual(generationAfterWorktreeLoad, generationBeforeWorktreeLoad)
        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: physicalSelection,
            store: store,
            rootScope: lookupContext.rootScope,
            codeMapUsage: .none
        )

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertEqual(entry.file.rootID, worktreeRootRecord.id)
        XCTAssertEqual(entry.file.standardizedRelativePath, "Sources/App.swift")
        XCTAssertEqual(entry.loadedContent, "worktree")
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testDuplicateSelectedPathsPreserveExistingEntryDedupOrder() async throws {
        let root = try makeTemporaryRoot(name: "AccountingDuplicates")
        let fileA = root.appendingPathComponent("A.swift")
        let fileB = root.appendingPathComponent("B.swift")
        try write("alpha", to: fileA)
        try write("beta", to: fileB)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileA.path, fileA.path, fileB.path],

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["A.swift", "B.swift"])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["alpha", "beta"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testSelectedCodemapUsageDoesNotLoadContentWhenCodemapExists() async throws {
        let root = try makeTemporaryRoot(name: "AccountingSelectedCodemap")
        let fileURL = root.appendingPathComponent("A.swift")
        try write("struct A { func fullContent() {} }", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let fileLookup = await store.lookupPath(fileURL.path)
        let file = try XCTUnwrap(fileLookup?.file)
        let api = makeSyntaxArtifact(path: fileURL.path)
        let presentation = try makePresentation(entries: [(file, api.renderedCodeMap(displayPath: "AccountingSelectedCodemap/A.swift"))])
        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: [fileURL.path],

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(
            selection: selection,
            store: store,
            codeMapUsage: .selected,
            codemapPresentation: presentation
        )

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertTrue(entry.isCodemap)
        XCTAssertEqual(entry.mode, .codemap)
        XCTAssertNil(entry.lineRanges)
        XCTAssertNil(entry.loadedContent)
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testAutoCodemapResolutionUsesCanonicalPathsAndPreservesSlices() async throws {
        let root = try makeTemporaryRoot(name: "AccountingCanonicalAutoCodemap")
        let selectedURL = root.appendingPathComponent("Selected.swift")
        let targetURL = root.appendingPathComponent("Target.swift")
        try write("let excluded = 0\nlet selected = TargetType()\n", to: selectedURL)
        try write("struct TargetType { func targetFullContent() {} }\n", to: targetURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let targetLookup = await store.lookupPath(targetURL.path)
        let target = try XCTUnwrap(targetLookup?.file)
        let targetAPI = makeSyntaxArtifact(
            path: targetURL.path,
            symbolName: "targetCodemapSymbol",
            className: "TargetType"
        )
        let targetPresentation = try makePresentation(entries: [
            (target, targetAPI.renderedCodeMap(displayPath: "AccountingCanonicalAutoCodemap/Target.swift"))
        ])
        let service = PromptContextAccountingService()
        let slice = LineRange(start: 2, end: 2)
        let selectionWithoutCanonicalCodemap = StoredSelection(
            selectedPaths: [selectedURL.path],

            slices: [selectedURL.path: [slice]],
            codemapAutoEnabled: false
        )

        let withoutCanonicalCodemap = await service.resolveEntries(
            selection: selectionWithoutCanonicalCodemap,
            store: store,
            codeMapUsage: .auto
        )

        let selectedOnlyEntry = try XCTUnwrap(withoutCanonicalCodemap.entries.first)
        XCTAssertEqual(withoutCanonicalCodemap.entries.count, 1)
        XCTAssertEqual(selectedOnlyEntry.file.standardizedFullPath, selectedURL.standardizedFileURL.path)
        XCTAssertEqual(selectedOnlyEntry.mode, .sliced)
        XCTAssertEqual(selectedOnlyEntry.lineRanges, [slice])
        XCTAssertFalse(selectedOnlyEntry.isCodemap)

        let canonicalSelection = StoredSelection(
            selectedPaths: selectionWithoutCanonicalCodemap.selectedPaths,

            slices: selectionWithoutCanonicalCodemap.slices,
            codemapAutoEnabled: true
        )
        let canonicalResolution = await service.resolveEntries(
            selection: canonicalSelection,
            store: store,
            codeMapUsage: .auto,
            codemapPresentation: targetPresentation
        )

        XCTAssertEqual(canonicalResolution.entries.count, 2)
        let selectedEntry = try XCTUnwrap(canonicalResolution.entries.first { $0.file.standardizedFullPath == selectedURL.standardizedFileURL.path })
        XCTAssertEqual(selectedEntry.mode, .sliced)
        XCTAssertEqual(selectedEntry.lineRanges, [slice])
        let codemapEntry = try XCTUnwrap(canonicalResolution.entries.first { $0.file.standardizedFullPath == targetURL.standardizedFileURL.path })
        XCTAssertEqual(codemapEntry.mode, .codemap)
        XCTAssertTrue(codemapEntry.isCodemap)
        XCTAssertNil(codemapEntry.loadedContent)
    }

    func testMissingSelectedPathsRemainMissingAndInvalidPathsRemainEmpty() async throws {
        let root = try makeTemporaryRoot(name: "AccountingMissing")
        try write("alpha", to: root.appendingPathComponent("A.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let service = PromptContextAccountingService()
        let missingPath = root.appendingPathComponent("Missing.swift").path
        let unresolvedRelativePath = "DefinitelyMissing.swift"
        let selection = StoredSelection(
            selectedPaths: [missingPath, unresolvedRelativePath],

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries, [])
        XCTAssertEqual(resolution.missingPaths, [unresolvedRelativePath, missingPath].sorted())
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testExpandedSelectedFolderFilesRemainRelativePathOrderedWithContents() async throws {
        let root = try makeTemporaryRoot(name: "AccountingFolder")
        try write("b", to: root.appendingPathComponent("Sources/B.swift"))
        try write("a", to: root.appendingPathComponent("Sources/Nested/A.swift"))
        try write("notes", to: root.appendingPathComponent("Sources/notes.txt"))
        try write("outside", to: root.appendingPathComponent("Outside.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let expansion = await store.expandFolderInputToFiles("Sources", rootScope: .visibleWorkspace)
        XCTAssertTrue(expansion.handled)
        XCTAssertEqual(expansion.files.map(\.standardizedRelativePath), [
            "Sources/B.swift",
            "Sources/Nested/A.swift",
            "Sources/notes.txt"
        ])

        let service = PromptContextAccountingService()
        let selection = StoredSelection(
            selectedPaths: expansion.files.map(\.standardizedFullPath),

            slices: [:],
            codemapAutoEnabled: false
        )

        let resolution = await service.resolveEntries(selection: selection, store: store, codeMapUsage: .none)

        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), [
            "Sources/B.swift",
            "Sources/Nested/A.swift",
            "Sources/notes.txt"
        ])
        XCTAssertEqual(resolution.entries.map(\.loadedContent), ["b", "a", "notes"])
        XCTAssertEqual(resolution.missingPaths, [])
        XCTAssertEqual(resolution.invalidPaths, [])
    }

    func testCancelledAccountingReadBatchStopsSchedulingRemainingFiles() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "AccountingCancellation")
            let fileCount = 24
            var selectedPaths: [String] = []
            for index in 0 ..< fileCount {
                let fileURL = root.appendingPathComponent("File\(index).swift")
                try write("struct File\(index) {}", to: fileURL)
                selectedPaths.append(fileURL.path)
            }

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedService = await store.fileSystemServiceForTesting(rootID: rootRecord.id)
            let service = try XCTUnwrap(loadedService)
            let gate = AccountingReadCancellationGate()
            await service.setContentReadChunkHandlerForTesting { _ in
                await gate.markStartedAndWaitForRelease()
            }

            let accountingTask = Task {
                await PromptContextAccountingService().resolveEntries(
                    selection: StoredSelection(
                        selectedPaths: selectedPaths,
                        codemapAutoEnabled: false
                    ),
                    store: store,
                    codeMapUsage: .none
                )
            }
            await gate.waitUntilStarted()
            accountingTask.cancel()
            await gate.release()
            _ = await accountingTask.value
            try? await Task.sleep(for: .milliseconds(50))

            let startedReadCount = await gate.startedCount()
            await service.setContentReadChunkHandlerForTesting(nil)
            XCTAssertLessThanOrEqual(
                startedReadCount,
                4,
                "A cancelled accounting batch should not continue draining all selected files"
            )
        #endif
    }

    func testCodemapAccountingCountsExactRenderedHeaderAndImports() async throws {
        let root = try makeTemporaryRoot(name: "AccountingRenderedCodemapTokens")
        let fileURL = root.appendingPathComponent("Nested/Target.swift")
        try write(SwiftFixtureSource.emptyStruct("Target", trailingNewline: false), to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let api = makeSyntaxArtifact(
            path: fileURL.path,
            symbolName: "renderedTokenSentinel",
            imports: ["Foundation", "Combine"]
        )
        let fileLookup = await store.lookupPath(fileURL.path)
        let file = try XCTUnwrap(fileLookup?.file)
        let rendered = api.renderedCodeMap(displayPath: "AccountingRenderedCodemapTokens/Nested/Target.swift")
        let presentation = try makePresentation(entries: [(file, rendered)])

        let result = await PromptContextAccountingService().calculatePromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(
                    selectedPaths: [fileURL.path],
                    codemapAutoEnabled: false
                ),
                codeMapUsage: .selected,
                filePathDisplay: .relative
            ),
            store: store,
            codemapPresentation: presentation
        )

        let expectedTokens = TokenCalculationService.estimateTokens(for: rendered)
        let snapshot = try XCTUnwrap(result.promptFileEntrySnapshots.first)
        XCTAssertEqual(result.promptFileEntrySnapshots.count, 1)
        XCTAssertEqual(snapshot.codeMapContent, rendered)
        XCTAssertEqual(snapshot.availableCodeMapTokenCount, expectedTokens)
        XCTAssertEqual(result.tokenResult.codeMapTokenCount, expectedTokens)
        XCTAssertEqual(result.tokenResult.totalTokenCountFilesOnly, 0)
    }

    func testAccountingAndPackagingShareExactPresentationArtifactAndRenderedText() async throws {
        let root = try makeTemporaryRoot(name: "AccountingPackagingIdentity")
        let fileURL = root.appendingPathComponent("Target.swift")
        try write(SwiftFixtureSource.emptyStruct("Target", trailingNewline: false), to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let fileLookup = await store.lookupPath(fileURL.path)
        let file = try XCTUnwrap(fileLookup?.file)
        let rendered = makeSyntaxArtifact(path: fileURL.path, symbolName: "sharedArtifactSentinel")
            .renderedCodeMap(displayPath: "LogicalRoot/Target.swift")
        let presentation = try makePresentation(entries: [(file, rendered)])

        let result = await PromptContextAccountingService().calculatePromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(selectedPaths: [fileURL.path], codemapAutoEnabled: false),
                codeMapUsage: .selected
            ),
            store: store,
            codemapPresentation: presentation
        )
        let blocks = PromptPackagingService.generatePartitionedFileBlocks(
            result.resolvedEntries,
            filePathDisplay: .relative,
            codemapPresentation: result.codemapPresentation
        )

        let operationEntry = try XCTUnwrap(result.codemapPresentation.renderedEntriesByFileID[file.id])
        let snapshot = try XCTUnwrap(result.promptFileEntrySnapshots.first)
        XCTAssertEqual(result.codemapPresentation.id, presentation.id)
        XCTAssertEqual(operationEntry.artifactKey, presentation.renderedEntriesByFileID[file.id]?.artifactKey)
        XCTAssertEqual(blocks.codemapBlocks, [rendered])
        XCTAssertEqual(snapshot.codeMapContent, rendered)
        XCTAssertEqual(snapshot.availableCodeMapTokenCount, TokenCalculationService.estimateTokens(for: rendered))
        XCTAssertEqual(result.tokenResult.codeMapTokenCount, snapshot.availableCodeMapTokenCount)
    }

    func testNonGitSelectedCodemapIsTypedUnavailableAndFallsBackToContent() async throws {
        let root = try makeTemporaryRoot(name: "AccountingNonGitFallback")
        let fileURL = root.appendingPathComponent("A.swift")
        let content = SwiftFixtureSource.emptyStruct("NonGitFallback", trailingNewline: false)
        try write(content, to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(selectedPaths: [fileURL.path], codemapAutoEnabled: false),
            store: store,
            codeMapUsage: .selected
        )

        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertFalse(entry.isCodemap)
        XCTAssertEqual(entry.loadedContent, content)
        guard case let .unavailable(issues) = resolution.codemapPresentation.coverage else {
            return XCTFail("Expected typed unavailable presentation coverage")
        }
        XCTAssertTrue(issues.contains { issue in
            if case .unavailable(_, .gitTerminal(.nonGit)) = issue { return true }
            return false
        })
    }

    func testCompleteCodemapResolutionUsesSingleFrozenOperationPresentation() async throws {
        let root = try makeTemporaryRoot(name: "AccountingCompleteCodemapBatch")
        let fileCount = 24
        for index in 0 ..< fileCount {
            try write("struct File\(index) {}", to: root.appendingPathComponent("File\(index).swift"))
        }

        let store = WorkspaceFileContextStore()
        let loadedRoot = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loadedRoot.id)
        let presentation = try makePresentation(entries: files.map { file in
            let api = makeSyntaxArtifact(path: file.standardizedFullPath)
            return (file, api.renderedCodeMap(displayPath: "AccountingCompleteCodemapBatch/\(file.standardizedRelativePath)"))
        })

        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(codemapAutoEnabled: false),
            store: store,
            codeMapUsage: .complete,
            codemapPresentation: presentation
        )

        XCTAssertEqual(resolution.codemapPresentation.id, presentation.id)
        XCTAssertEqual(resolution.entries.count, fileCount)
        XCTAssertTrue(resolution.entries.allSatisfy { $0.mode == .codemap })
    }

    func testResolveEntriesOmitsPendingAutomaticCodemapsAfterShortBoundedWait() async throws {
        let fixture = try await makePendingCodemapFixture(name: #function)
        let clock = ContinuousClock()
        let started = clock.now

        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(selectedPaths: [fixture.sourcePath], codemapAutoEnabled: true),
            store: fixture.store,
            codeMapUsage: .auto
        )

        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, Self.pendingReadinessElapsedBound, "Accounting must not wait the full readiness deadline for pending codemaps")
        XCTAssertEqual(resolution.entries.map(\.file.standardizedRelativePath), ["Sources/Source.swift"])
        XCTAssertFalse(resolution.entries.contains { $0.isCodemap })
        assertPendingCodemapsOmitted(resolution.codemapPresentation)
    }

    func testWithPromptStatsOmitsPendingAutomaticCodemapsAfterShortBoundedWait() async throws {
        let fixture = try await makePendingCodemapFixture(name: #function)
        let clock = ContinuousClock()
        let started = clock.now

        let result = try await PromptContextAccountingService().withPromptStats(
            request: PromptContextAccountingRequest(
                selection: StoredSelection(selectedPaths: [fixture.sourcePath], codemapAutoEnabled: true),
                codeMapUsage: .auto
            ),
            store: fixture.store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        ) { $0 }

        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, Self.pendingReadinessElapsedBound, "Prompt stats must not wait the full readiness deadline for pending codemaps")
        XCTAssertEqual(result.resolvedEntries.map(\.file.standardizedRelativePath), ["Sources/Source.swift"])
        XCTAssertTrue(result.codemapFileIDsUsed.isEmpty)
        assertPendingCodemapsOmitted(result.codemapPresentation)
    }

    func testResolveEntriesIncludesAlreadyReadySelectedCodemap() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/Ready.swift": "struct ReadyAccounting { func readyAccountingSymbol() {} }\n"]
        )
        let codemapFixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        let store = codemapFixture.makeStore(codemapProjectionPreloadLaunchPolicy: .disabled)
        let loaded = try await store.loadRoot(path: root.path)
        let files = await store.files(inRoot: loaded.id)
        let file = try XCTUnwrap(files.first)
        let ready = try await readyCodemapDemand(store: store, fileID: file.id)
        addTeardownBlock {
            _ = await store.cancelCodemapArtifactDemand(ready.ticket)
        }

        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(selectedPaths: [file.standardizedFullPath], codemapAutoEnabled: false),
            store: store,
            codeMapUsage: .selected
        )

        XCTAssertEqual(resolution.codemapPresentation.orderedEntries.map(\.fileID), [file.id])
        XCTAssertTrue(
            resolution.codemapPresentation.renderedEntriesByFileID[file.id]?.text.contains("readyAccountingSymbol") == true
        )
        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertTrue(entry.isCodemap)
    }

    func testWithPromptStatsIncludesAutomaticCodemapOnRecountAfterPendingCall() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target { func convergedTargetCodemapSymbol() {} }\n"
            ]
        )
        let codemapFixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        let demandsReleased = CodemapLockedCounter()
        let store = codemapFixture.makeStore(demandResultHook: { _, result in
            demandsReleased.value == 0 ? .busy(retryAfterMilliseconds: 1000) : result
        })
        _ = try await store.loadRoot(path: root.path)
        let targetLookup = await store.lookupPath(
            root.appendingPathComponent("Sources/Target.swift").path,
            rootScope: .allLoaded
        )
        let target = try XCTUnwrap(targetLookup?.file)
        let request = PromptContextAccountingRequest(
            selection: StoredSelection(
                selectedPaths: [root.appendingPathComponent("Sources/Source.swift").path],
                codemapAutoEnabled: true
            ),
            codeMapUsage: .auto
        )
        let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        let service = PromptContextAccountingService()

        let pending = try await service.withPromptStats(
            request: request,
            store: store,
            lookupContext: lookupContext
        ) { $0 }
        assertPendingCodemapsOmitted(pending.codemapPresentation)

        demandsReleased.increment()
        // Later recounts (as UI/MCP refreshes would issue) must eventually include the target.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        var included = false
        var laterCalls = 0
        while !included, clock.now < deadline {
            laterCalls += 1
            let later = try await service.withPromptStats(
                request: request,
                store: store,
                lookupContext: lookupContext
            ) { $0 }
            included = later.codemapPresentation.renderedEntriesByFileID[target.id]?.text
                .contains("convergedTargetCodemapSymbol") == true
            if !included {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        XCTAssertTrue(included, "Automatic codemap never became ready after \(laterCalls) bounded-wait recounts")
    }

    func testRepeatedAutomaticPromptStatsAfterConvergenceScheduleNoProjectionWork() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target { func steadyTargetCodemapSymbol() {} }\n"
            ]
        )
        let codemapFixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
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
        let request = PromptContextAccountingRequest(
            selection: StoredSelection(
                selectedPaths: [root.appendingPathComponent("Sources/Source.swift").path],
                codemapAutoEnabled: true
            ),
            codeMapUsage: .auto
        )
        let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        let service = PromptContextAccountingService()
        var lastCoverage = ""
        func includesTarget() async throws -> Bool {
            let result = try await service.withPromptStats(
                request: request,
                store: store,
                lookupContext: lookupContext
            ) { $0 }
            lastCoverage = "\(result.codemapPresentation.coverage) \(result.codemapPresentation.issues)"
            return result.codemapPresentation.renderedEntriesByFileID[target.id]?.text
                .contains("steadyTargetCodemapSymbol") == true
        }

        let clock = ContinuousClock()
        let convergenceDeadline = clock.now.advanced(by: .seconds(30))
        var converged = false
        while !converged, clock.now < convergenceDeadline {
            converged = try await includesTarget()
            if !converged {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        XCTAssertTrue(converged, "Automatic codemap never converged: \(lastCoverage)")
        guard converged else { return }
        // Let any recovery started by the converging call finish before measuring steady state.
        let drainDeadline = clock.now.advanced(by: .seconds(10))
        var drained = false
        while !drained, clock.now < drainDeadline {
            let state = await store.codemapGraphPublicationRecoveryStateForTesting(rootEpoch: rootEpoch)
            drained = !state.flightActive && !state.observerActive
            if !drained {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTAssertTrue(drained, "Graph publication recovery did not drain after convergence")

        let scheduledBefore = await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)?
            .counters.projectionPreloadsScheduled
        let generationBefore = await store.codemapOverlayContributionGenerationForTesting(rootEpoch: rootEpoch)
        for call in 1 ... 5 {
            let included = try await includesTarget()
            XCTAssertTrue(included, "Steady automatic call \(call) dropped Target")
        }
        let scheduledAfter = await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)?
            .counters.projectionPreloadsScheduled
        let generationAfter = await store.codemapOverlayContributionGenerationForTesting(rootEpoch: rootEpoch)
        XCTAssertNotNil(scheduledBefore)
        XCTAssertEqual(scheduledAfter, scheduledBefore, "Steady automatic calls must not schedule projection work")
        XCTAssertNotNil(generationBefore)
        XCTAssertEqual(generationAfter, generationBefore, "Steady automatic calls must not advance the overlay")
    }

    /// A working set larger than the former 64-record idle cap must still reach steady state:
    /// releasing it at the end of each call keeps every record warm, so repeated identical calls
    /// evict nothing, advance no overlay contribution, and schedule no projection work. The files
    /// are warmed through direct demands first: a cold automatic call readies only a few sources
    /// within its bounded wait and cancels the rest, which is a separate throughput property.
    func testRepeatedAutomaticPromptStatsOverWorkingSetLargerThanFormerIdleCapScheduleNoProjectionWork() async throws {
        let sourceCount = 70
        var repositoryFiles = [
            "Sources/Target.swift": "struct Target { func wideTargetCodemapSymbol() {} }\n"
        ]
        for index in 0 ..< sourceCount {
            repositoryFiles[String(format: "Sources/Source%03d.swift", index)] =
                String(format: "struct Source%03d { let target: Target }\n", index)
        }
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(named: "repository", files: repositoryFiles)
        let codemapFixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
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
        // Warm every file through direct demands, then release each one into the idle cache.
        let warmClock = ContinuousClock()
        for file in await store.files(inRoot: loaded.id) {
            let warmDeadline = warmClock.now.advanced(by: .seconds(15))
            var result = await store.requestCodemapArtifact(forFileID: file.id)
            while case let .pending(ticket) = result, warmClock.now < warmDeadline {
                try await Task.sleep(for: .milliseconds(10))
                result = await store.codemapArtifactDemandStatus(ticket)
            }
            guard case let .ready(ready) = result else {
                return XCTFail("\(file.standardizedRelativePath) did not warm: \(result)")
            }
            _ = await store.cancelCodemapArtifactDemand(ready.ticket)
        }
        let warmedIdle = await store.codemapIdleReadyDemandFileIDsForTesting(rootEpoch: rootEpoch)
        XCTAssertEqual(warmedIdle.count, sourceCount + 1, "Every warmed record must stay idle")

        let selectedPaths = (0 ..< sourceCount).map {
            root.appendingPathComponent(String(format: "Sources/Source%03d.swift", $0)).path
        }
        let request = PromptContextAccountingRequest(
            selection: StoredSelection(selectedPaths: selectedPaths, codemapAutoEnabled: true),
            codeMapUsage: .auto
        )
        let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        let service = PromptContextAccountingService()
        var lastCoverage = ""
        func includesTarget() async throws -> Bool {
            let result = try await service.withPromptStats(
                request: request,
                store: store,
                lookupContext: lookupContext
            ) { $0 }
            lastCoverage = "\(result.codemapPresentation.coverage) \(result.codemapPresentation.issues)"
            return result.codemapPresentation.renderedEntriesByFileID[target.id]?.text
                .contains("wideTargetCodemapSymbol") == true
        }

        let clock = ContinuousClock()
        let convergenceDeadline = clock.now.advanced(by: .seconds(60))
        var converged = false
        while !converged, clock.now < convergenceDeadline {
            converged = try await includesTarget()
            if !converged {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        XCTAssertTrue(converged, "Automatic codemap never converged: \(lastCoverage)")
        guard converged else { return }
        let drainDeadline = clock.now.advanced(by: .seconds(10))
        var drained = false
        while !drained, clock.now < drainDeadline {
            let state = await store.codemapGraphPublicationRecoveryStateForTesting(rootEpoch: rootEpoch)
            drained = !state.flightActive && !state.observerActive
            if !drained {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTAssertTrue(drained, "Graph publication recovery did not drain after convergence")
        let idleAfterConvergence = await store.codemapIdleReadyDemandFileIDsForTesting(rootEpoch: rootEpoch)
        XCTAssertGreaterThan(idleAfterConvergence.count, 64, "The call's working set must exceed the former cap")

        let scheduledBefore = await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)?
            .counters.projectionPreloadsScheduled
        let generationBefore = await store.codemapOverlayContributionGenerationForTesting(rootEpoch: rootEpoch)
        let evictionsBefore = await store.codemapIdleReadyDemandEvictionCountForTesting()
        for call in 1 ... 2 {
            let included = try await includesTarget()
            XCTAssertTrue(included, "Steady automatic call \(call) dropped Target")
        }
        let scheduledAfter = await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)?
            .counters.projectionPreloadsScheduled
        let generationAfter = await store.codemapOverlayContributionGenerationForTesting(rootEpoch: rootEpoch)
        let evictionsAfter = await store.codemapIdleReadyDemandEvictionCountForTesting()
        XCTAssertNotNil(scheduledBefore)
        XCTAssertEqual(scheduledAfter, scheduledBefore, "Steady automatic calls must not schedule projection work")
        XCTAssertNotNil(generationBefore)
        XCTAssertEqual(generationAfter, generationBefore, "Steady automatic calls must not advance the overlay")
        XCTAssertEqual(evictionsAfter, evictionsBefore, "Steady automatic calls must not evict idle records")
    }

    /// Step 1b V4: cold repeated automatic calls converge when the demand work a call's engine has
    /// already admitted outlives the call. Every build is gated: none completes inside a call's
    /// bounded wait, and the gate opens only after the call has released its demands. With
    /// admission limit C, each call admits C demands and queues the rest, so all N sources are warm
    /// by call ceil(N/C). The shared target is demanded from call 2 on (once a ready source names
    /// it), but competes with the selected sources for the C slots: while it loses, it is cancelled
    /// as queued. It is admitted at the latest once the N + 1 demands have each had a slot, so the
    /// target renders by call ceil((N + 1)/C) + 1. Steady calls then change nothing. Releasing by
    /// cancelling admitted work (before Step 1b) never converges here.
    func testColdAutomaticPromptStatsConvergeWhenAdmittedDemandsOutliveEachCall() async throws {
        let sourceCount = 6
        let admissionLimit = 2
        var repositoryFiles = [
            "Sources/Target.swift": "struct Target { func gatedTargetCodemapSymbol() {} }\n",
            "Sources/Prime.swift": "struct Prime {}\n"
        ]
        for index in 0 ..< sourceCount {
            repositoryFiles[String(format: "Sources/Source%03d.swift", index)] =
                String(format: "struct Source%03d { let target: Target }\n", index)
        }
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(named: "repository", files: repositoryFiles)
        let codemapFixture = try CodemapStoreFixture(
            name: #function,
            bindingEnginePolicy: WorkspaceCodemapBindingEnginePolicy(
                maximumConcurrentMaterializationCountPerRoot: admissionLimit
            )
        )
        let gate = CodemapReopenablePublicationGate()
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        addTeardownBlock { gate.open() }
        let store = codemapFixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let targetLookup = await store.lookupPath(root.appendingPathComponent("Sources/Target.swift").path, rootScope: .allLoaded)
        let target = try XCTUnwrap(targetLookup?.file)
        // Create the engine with an unrelated file so that no measured file starts warm, and let the
        // root's projection preload finish: the graph's definition universe, which gates target
        // discovery, then no longer depends on projection batches competing for the same slots.
        let primeLookup = await store.lookupPath(root.appendingPathComponent("Sources/Prime.swift").path, rootScope: .allLoaded)
        let prime = try XCTUnwrap(primeLookup?.file)
        let primed = try await readyCodemapDemand(store: store, fileID: prime.id)
        _ = await store.cancelCodemapArtifactDemand(primed.ticket)
        try await AsyncTestWait.waitUntil("projection preload complete", timeout: 30) {
            let accounting = await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)
            return accounting?.projectionRoots.first { $0.rootEpoch == rootEpoch }?.phase == .complete
        }
        let hookInstalled = await store.setCodemapBindingEngineBeforeResolutionPublicationHookForTesting(
            rootEpoch: rootEpoch
        ) { _, path in
            await gate.pass(path)
        }
        XCTAssertTrue(hookInstalled)

        let selectedPaths = (0 ..< sourceCount).map {
            root.appendingPathComponent(String(format: "Sources/Source%03d.swift", $0)).path
        }
        let request = PromptContextAccountingRequest(
            selection: StoredSelection(selectedPaths: selectedPaths, codemapAutoEnabled: true),
            codeMapUsage: .auto
        )
        let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        let service = PromptContextAccountingService()
        func includesTarget() async throws -> Bool {
            let result = try await service.withPromptStats(
                request: request,
                store: store,
                lookupContext: lookupContext
            ) { $0 }
            return result.codemapPresentation.renderedEntriesByFileID[target.id]?.text
                .contains("gatedTargetCodemapSymbol") == true
        }
        func releasedSettled() async -> Bool {
            let flow = await store.codemapDemandFlowCountsForTesting()
            let dropped = flow.releasedDroppedBusy + flow.releasedDroppedNotCurrent +
                flow.releasedDroppedUnavailable + flow.releasedDroppedCancelled
            return flow.releasedOrphaned == flow.releasedParked + flow.releasedRejoined + dropped
        }

        let sourceCalls = (sourceCount + admissionLimit - 1) / admissionLimit
        let callBound = (sourceCount + 1 + admissionLimit - 1) / admissionLimit + 1
        var convergedCall: Int?
        var sourcesWarmAfterCall: Int?
        var callLog: [String] = []
        for call in 1 ... callBound + 3 {
            gate.close()
            let flowBefore = await store.codemapDemandFlowCountsForTesting()
            if try await includesTarget() {
                convergedCall = call
                break
            }
            // Only now, after the call released its demands, may the gated builds finish.
            gate.open()
            try await AsyncTestWait.waitUntil("call \(call) admitted work settled", timeout: 30) {
                let accounting = await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)
                guard accounting?.activeRequestCount == 0, accounting?.queuedRequestCount == 0 else { return false }
                guard await releasedSettled() else { return false }
                // Parked results reach the selection graph through publication; let it finish so
                // the next call sees every ready source.
                let state = await store.codemapGraphPublicationRecoveryStateForTesting(rootEpoch: rootEpoch)
                return !state.flightActive && !state.observerActive
            }
            let flow = await store.codemapDemandFlowCountsForTesting()
            let idle = await store.codemapIdleReadyDemandFileIDsForTesting(rootEpoch: rootEpoch)
            if sourcesWarmAfterCall == nil,
               Set(idle).subtracting([prime.id, target.id]).count == sourceCount
            {
                sourcesWarmAfterCall = call
            }
            callLog.append(
                "call \(call): fresh=\(flow.freshDemands - flowBefore.freshDemands) " +
                    "orphaned=\(flow.releasedOrphaned - flowBefore.releasedOrphaned) " +
                    "parked=\(flow.releasedParked - flowBefore.releasedParked) " +
                    "queuedCancels=\(flow.releasedDroppedCancelledQueued - flowBefore.releasedDroppedCancelledQueued) " +
                    "admittedCancels=\(flow.pendingLastHolderCancels - flowBefore.pendingLastHolderCancels) " +
                    "idle=\(idle.count)"
            )
        }
        let converged = try XCTUnwrap(
            convergedCall,
            "Cold automatic calls never converged: \(callLog.joined(separator: "; "))"
        )
        let sourcesWarm = try XCTUnwrap(sourcesWarmAfterCall, callLog.joined(separator: "; "))
        XCTAssertLessThanOrEqual(sourcesWarm, sourceCalls, callLog.joined(separator: "; "))
        XCTAssertLessThanOrEqual(converged, callBound, callLog.joined(separator: "; "))

        gate.open()
        let clock = ContinuousClock()
        let drainDeadline = clock.now.advanced(by: .seconds(10))
        var drained = false
        while !drained, clock.now < drainDeadline {
            let state = await store.codemapGraphPublicationRecoveryStateForTesting(rootEpoch: rootEpoch)
            drained = !state.flightActive && !state.observerActive
            if !drained {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        XCTAssertTrue(drained, "Graph publication recovery did not drain after convergence")
        let scheduledBefore = await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)?
            .counters.projectionPreloadsScheduled
        let generationBefore = await store.codemapOverlayContributionGenerationForTesting(rootEpoch: rootEpoch)
        let evictionsBefore = await store.codemapIdleReadyDemandEvictionCountForTesting()
        let freshBefore = await store.codemapDemandFlowCountsForTesting().freshDemands
        for call in 1 ... 2 {
            let included = try await includesTarget()
            XCTAssertTrue(included, "Steady automatic call \(call) dropped Target")
        }
        let scheduledAfter = await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)?
            .counters.projectionPreloadsScheduled
        let generationAfter = await store.codemapOverlayContributionGenerationForTesting(rootEpoch: rootEpoch)
        let evictionsAfter = await store.codemapIdleReadyDemandEvictionCountForTesting()
        let freshAfter = await store.codemapDemandFlowCountsForTesting().freshDemands
        XCTAssertNotNil(scheduledBefore)
        XCTAssertEqual(scheduledAfter, scheduledBefore, "Steady automatic calls must not schedule projection work")
        XCTAssertNotNil(generationBefore)
        XCTAssertEqual(generationAfter, generationBefore, "Steady automatic calls must not advance the overlay")
        XCTAssertEqual(evictionsAfter, evictionsBefore, "Steady automatic calls must not evict idle records")
        XCTAssertEqual(freshAfter, freshBefore, "Steady automatic calls must not start demands")
    }

    /// Step 1b: keeping admitted work is only for ordinary completion. An automatic call that is
    /// itself cancelled still cancels the demand work its engine already admitted.
    func testCancelledAutomaticPromptStatsStillCancelsAdmittedDemand() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target {}\n",
                "Sources/Prime.swift": "struct Prime {}\n"
            ]
        )
        let codemapFixture = try CodemapStoreFixture(name: #function)
        let gate = CodemapReopenablePublicationGate()
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        addTeardownBlock { gate.open() }
        let store = codemapFixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let rootEpoch = try await WorkspaceCodemapRootEpoch(
            rootID: loaded.id,
            rootLifetimeID: store.rootLifetimeIDForTesting(rootID: loaded.id)
        )
        let sourceLookup = await store.lookupPath(root.appendingPathComponent("Sources/Source.swift").path, rootScope: .allLoaded)
        let source = try XCTUnwrap(sourceLookup?.file)
        let primeLookup = await store.lookupPath(root.appendingPathComponent("Sources/Prime.swift").path, rootScope: .allLoaded)
        let prime = try XCTUnwrap(primeLookup?.file)
        let primed = try await readyCodemapDemand(store: store, fileID: prime.id)
        _ = await store.cancelCodemapArtifactDemand(primed.ticket)
        let hookInstalled = await store.setCodemapBindingEngineBeforeResolutionPublicationHookForTesting(
            rootEpoch: rootEpoch
        ) { _, path in
            await gate.pass(path)
        }
        XCTAssertTrue(hookInstalled)
        let request = PromptContextAccountingRequest(
            selection: StoredSelection(
                selectedPaths: [root.appendingPathComponent("Sources/Source.swift").path],
                codemapAutoEnabled: true
            ),
            codeMapUsage: .auto
        )
        let flowBefore = await store.codemapDemandFlowCountsForTesting()

        let call = Task {
            try await PromptContextAccountingService().withPromptStats(
                request: request,
                store: store,
                lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
            ) { $0 }
        }
        try await gate.waitUntilEntered("Sources/Source.swift")
        call.cancel()
        _ = try? await call.value
        try await AsyncTestWait.waitUntil("cancelled call's demand removed", timeout: 10) {
            await store.codemapDemandRecordTicketsForTesting(rootEpoch: rootEpoch, fileID: source.id) == nil
        }
        let flowAfter = await store.codemapDemandFlowCountsForTesting()
        XCTAssertEqual(flowAfter.releasedOrphaned, flowBefore.releasedOrphaned, "A cancelled call keeps no work")
        XCTAssertGreaterThan(flowAfter.pendingLastHolderCancels, flowBefore.pendingLastHolderCancels)

        gate.open()
        try await AsyncTestWait.waitUntil("cancelled admitted work drained", timeout: 10) {
            await store.codemapBindingEngineAccountingForTesting(rootID: loaded.id)?.activeRequestCount == 0
        }
        let idle = await store.codemapIdleReadyDemandFileIDsForTesting(rootEpoch: rootEpoch)
        XCTAssertFalse(idle.contains(source.id), "The cancelled build must not park")
        let flowDrained = await store.codemapDemandFlowCountsForTesting()
        XCTAssertEqual(flowDrained.releasedParked, flowBefore.releasedParked)
    }

    func testResolveEntriesOmitsAutomaticCodemapsWhileSelectionGraphIsUnpublishedAfterShortBoundedWait() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let unpublishedGraphSentinel: Target }\n",
                "Sources/Target.swift": "struct Target { func unpublishedGraphTargetSymbol() {} }\n"
            ]
        )
        // Artifact demands succeed, but selection-graph publication stays parked, so the
        // automatic plan keeps reporting transient graph readiness.
        let codemapFixture = try CodemapStoreFixture(name: #function)
        let graphGate = CodemapGraphPublicationGate()
        addTeardownBlock {
            graphGate.release()
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        let store = codemapFixture.makeStore(graphPublicationWaiter: { rootEpoch in
            await graphGate.enterAndWait(rootEpoch)
        })
        _ = try await store.loadRoot(path: root.path)
        let clock = ContinuousClock()
        let started = clock.now

        let resolution = await PromptContextAccountingService().resolveEntries(
            selection: StoredSelection(
                selectedPaths: [root.appendingPathComponent("Sources/Source.swift").path],
                codemapAutoEnabled: true
            ),
            store: store,
            codeMapUsage: .auto
        )

        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, Self.pendingReadinessElapsedBound, "Accounting must not wait the full readiness deadline for graph readiness")
        let entry = try XCTUnwrap(resolution.entries.first)
        XCTAssertEqual(resolution.entries.count, 1)
        XCTAssertTrue(entry.loadedContent?.contains("unpublishedGraphSentinel") == true)
        XCTAssertFalse(resolution.entries.contains { $0.isCodemap })
        assertPendingCodemapsOmitted(resolution.codemapPresentation)
    }

    private static let pendingReadinessElapsedBound: Duration = .seconds(5)

    private func makePendingCodemapFixture(
        name: String
    ) async throws -> (store: WorkspaceFileContextStore, sourcePath: String) {
        let repositories = try ReviewGitRepositoryFixture(name: name)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": "struct Source { let target: Target }\n",
                "Sources/Target.swift": "struct Target { func pendingTargetCodemapSymbol() {} }\n"
            ]
        )
        let codemapFixture = try CodemapStoreFixture(name: name)
        addTeardownBlock {
            await codemapFixture.shutdown()
            repositories.cleanup()
        }
        // Every artifact demand stays busy, so automatic readiness can never settle.
        let store = codemapFixture.makeStore(demandResultHook: { _, _ in
            .busy(retryAfterMilliseconds: 1000)
        })
        _ = try await store.loadRoot(path: root.path)
        return (store, root.appendingPathComponent("Sources/Source.swift").standardizedFileURL.path)
    }

    private func assertPendingCodemapsOmitted(
        _ presentation: WorkspaceCodemapOperationPresentation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(presentation.orderedEntries.isEmpty, file: file, line: line)
        switch presentation.coverage {
        case .pending, .unavailable:
            break
        case .complete, .partial:
            XCTFail("Pending automatic codemaps must report typed retry coverage", file: file, line: line)
        }
        XCTAssertFalse(presentation.issues.isEmpty, file: file, line: line)
    }

    private func readyCodemapDemand(
        store: WorkspaceFileContextStore,
        fileID: UUID,
        timeout: Duration = .seconds(60)
    ) async throws -> WorkspaceCodemapArtifactDemandReady {
        var result = await store.requestCodemapArtifact(forFileID: fileID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            switch result {
            case let .ready(ready):
                return ready
            case let .pending(ticket):
                try await Task.sleep(for: .milliseconds(25))
                result = await store.codemapArtifactDemandStatus(ticket)
            case let .unavailable(reason):
                XCTFail("Expected ready codemap demand, got \(reason)")
                throw NSError(domain: "PromptContextAccountingServiceTests", code: 1)
            }
        }
        XCTFail("Timed out waiting for ready codemap demand")
        throw NSError(domain: "PromptContextAccountingServiceTests", code: 1)
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try makeTestDirectory(name: name)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSyntaxArtifact(
        path: String,
        symbolName: String = "codemapOnlySymbol",
        className: String? = nil,
        imports: [String] = [],
        referencedTypes: [String] = []
    ) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: imports,
            classes: className.map { [ClassInfo(name: $0, methods: [], properties: [])] } ?? [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: referencedTypes
        )
    }

    private func makePresentation(
        entries: [(WorkspaceFileRecord, String)]
    ) throws -> WorkspaceCodemapOperationPresentation {
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let bundleID = WorkspaceCodemapFrozenPresentationBundleID()
        let rendered = try entries.enumerated().map { index, pair in
            let (file, text) = pair
            let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: "LogicalRoot",
                standardizedRelativePath: file.standardizedRelativePath
            ))
            return WorkspaceCodemapOperationRenderedEntry(
                bundleID: bundleID,
                fileID: file.id,
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: file.rootID,
                    rootLifetimeID: UUID()
                ),
                artifactKey: CodeMapArtifactKey(
                    rawSHA256: CodeMapRawSourceDigest(
                        bytes: Data(repeating: UInt8((index % 254) + 1), count: 32)
                    ),
                    rawByteCount: UInt64(text.utf8.count),
                    pipelineIdentity: pipeline
                ),
                logicalPath: logicalPath,
                text: text,
                tokenCount: TokenCalculationService.estimateTokens(for: text)
            )
        }
        return WorkspaceCodemapOperationPresentation(
            orderedEntries: rendered,
            coverage: .complete,
            issues: [],
            publicationReceipt: nil
        )
    }
}

#if DEBUG
    private actor AccountingReadCancellationGate {
        private var count = 0
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            count += 1
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard count > 0 else {
                await withCheckedContinuation { continuation in
                    startWaiters.append(continuation)
                }
                return
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func startedCount() -> Int {
            count
        }
    }
#endif
