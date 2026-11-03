import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// `indexGeneration` is a digest of the index entries the codemap pipeline reads. A stat-only index
/// rewrite must not change it; staged content, index flags, and conflict stages must.
final class WorkspaceCodemapIndexGenerationTests: XCTestCase {
    private let namespaceSalt = Data(repeating: 0x42, count: GitBlobRepositoryNamespace.saltByteCount)
    private static let files = [
        "Sources/Feature.swift": "let value = 1\n",
        "Sources/Other.swift": "let other = 2\n",
        "Notes.txt": "notes\n"
    ]

    /// U1
    func testStatOnlyIndexRewriteKeepsIndexGenerationAndIssues() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeSettledRepository(fixture)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
        let rootRequest = request(for: root, seed: 1)
        let initial = try await capability(service.resolve(root: rootRequest))

        try fixture.rewriteIndexWithoutContentChange(path: "Sources/Feature.swift", at: root)

        let issuance = await issueSourceAuthority(service, capability: initial, path: "Sources/Feature.swift")
        XCTAssertNotNil(issuance.token, "A stat-only index rewrite must still issue: \(String(describing: issuance.failure))")
        let resolved = try await capability(service.resolve(root: rootRequest))
        XCTAssertEqual(resolved.repositoryAuthority.indexGeneration, initial.repositoryAuthority.indexGeneration)
        XCTAssertEqual(resolved.repositoryAuthority, initial.repositoryAuthority)
    }

    /// U2
    func testStagingModifiedContentReportsIndexAuthorityChange() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeSettledRepository(fixture)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
        let initial = try await capability(service.resolve(root: request(for: root, seed: 2)))

        try fixture.write("notes changed\n", to: "Notes.txt", at: root)
        try fixture.stage("Notes.txt", at: root)

        let issuance = await issueSourceAuthority(service, capability: initial, path: "Sources/Feature.swift")
        XCTAssertEqual(issuance, .unavailable(.repositoryAuthorityChanged(changed: [.index])))
    }

    /// U3
    func testAssumeUnchangedAndSkipWorktreeChangeIndexGeneration() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeSettledRepository(fixture)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
        let rootRequest = request(for: root, seed: 3)
        let path = "Sources/Feature.swift"
        let baseline = try await indexGeneration(service, rootRequest)

        try fixture.runGit(["update-index", "--assume-unchanged", "--", path], at: root)
        let assumeUnchanged = try await indexGeneration(service, rootRequest)
        XCTAssertNotEqual(assumeUnchanged, baseline, "Setting assume-unchanged must change the generation.")

        try fixture.runGit(["update-index", "--no-assume-unchanged", "--", path], at: root)
        let cleared = try await indexGeneration(service, rootRequest)
        XCTAssertEqual(cleared, baseline, "Identical entries must give the identical generation.")

        try fixture.runGit(["update-index", "--skip-worktree", "--", path], at: root)
        let skipWorktree = try await indexGeneration(service, rootRequest)
        XCTAssertNotEqual(skipWorktree, baseline, "Setting skip-worktree must change the generation.")
        XCTAssertNotEqual(skipWorktree, assumeUnchanged)
    }

    /// An index-only mode change (`--chmod=+x`) changes the generation and rejects issuance
    /// against the earlier authority with `.index`.
    func testIndexModeChangeReportsIndexAuthorityChange() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeSettledRepository(fixture)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
        let rootRequest = request(for: root, seed: 11)
        let initial = try await capability(service.resolve(root: rootRequest))

        try fixture.runGit(["update-index", "--chmod=+x", "--", "Sources/Other.swift"], at: root)

        let issuance = await issueSourceAuthority(service, capability: initial, path: "Sources/Feature.swift")
        XCTAssertEqual(issuance, .unavailable(.repositoryAuthorityChanged(changed: [.index])))
        let changed = try await indexGeneration(service, rootRequest)
        XCTAssertNotEqual(changed, initial.repositoryAuthority.indexGeneration)
    }

    /// Unmerged entries (stages 1, 2 and 3 for one path) change the generation.
    func testUnmergedStagesChangeIndexGeneration() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeSettledRepository(fixture)
        try fixture.runGit(["checkout", "-q", "-b", "side"], at: root)
        try fixture.write("notes side\n", to: "Notes.txt", at: root)
        try fixture.stage("Notes.txt", at: root)
        try fixture.commit("side", at: root)
        try fixture.runGit(["checkout", "-q", "-"], at: root)
        try fixture.write("notes main\n", to: "Notes.txt", at: root)
        try fixture.stage("Notes.txt", at: root)
        try fixture.commit("main", at: root)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
        let rootRequest = request(for: root, seed: 12)
        let merged = try await indexGeneration(service, rootRequest)

        let merge = try fixture.runGitResult(["merge", "--no-edit", "side"], at: root)
        XCTAssertNotEqual(merge.terminationStatus, 0, "The merge must stop on a conflict: \(merge.outputText)")
        let stages = try fixture.runGit(["ls-files", "--stage", "--", "Notes.txt"], at: root)
            .split(separator: "\n")
            .compactMap { line in line.split(separator: "\t").first?.split(separator: " ").last }
            .map(String.init)
        XCTAssertEqual(stages, ["1", "2", "3"], "The fixture must produce an unmerged path.")

        let conflicted = try await indexGeneration(service, rootRequest)
        XCTAssertNotEqual(conflicted, merged, "Unmerged stages must change the generation.")
    }

    #if DEBUG
        /// U4
        func testIndexEntriesAreReadOncePerIndexStat() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let root = try makeSettledRepository(fixture)
            let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
            let rootRequest = request(for: root, seed: 4)

            let initial = try await capability(service.resolve(root: rootRequest))
            let issuance = await issueSourceAuthority(service, capability: initial, path: "Sources/Feature.swift")
            XCTAssertNotNil(issuance.token)
            let readsAtOneStat = await service.indexEntriesReadCountForTesting()
            XCTAssertEqual(readsAtOneStat, 1, "Captures at one index stat must share one ls-files read.")

            try fixture.rewriteIndexWithoutContentChange(path: "Sources/Feature.swift", at: root)
            let afterRewrite = try await capability(service.resolve(root: rootRequest))
            let readsAfterRewrite = await service.indexEntriesReadCountForTesting()
            XCTAssertEqual(readsAfterRewrite, 2, "A rewritten index must be read once more.")
            XCTAssertEqual(
                afterRewrite.repositoryAuthority.indexGeneration,
                initial.repositoryAuthority.indexGeneration
            )
        }

        /// U5: an index rewrite between the two stat reads fails the capture as unstable; the next
        /// capture reads again and issues with the unchanged generation.
        func testIndexRewriteDuringEntriesReadIsUnstableAndNotMemoized() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let root = try makeSettledRepository(fixture)
            let rewrite = OneShotIndexRewrite(fixture: fixture, root: root, path: "Sources/Other.swift")
            let service = WorkspaceCodemapGitCapabilityService(
                namespaceSalt: namespaceSalt,
                hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                    afterIndexEntriesRead: { rewrite.rewriteOnceIfArmed() }
                )
            )
            let rootRequest = request(for: root, seed: 5)
            let initial = try await capability(service.resolve(root: rootRequest))
            let path = "Sources/Feature.swift"
            // Leave the memo stale so the next capture reads the entries and runs the hook.
            try fixture.rewriteIndexWithoutContentChange(path: "Sources/Other.swift", at: root)
            let readsBefore = await service.indexEntriesReadCountForTesting()

            rewrite.arm()
            let raced = await issueSourceAuthority(service, capability: initial, path: path)
            XCTAssertTrue(rewrite.didRewrite())
            XCTAssertEqual(raced, .unavailable(.unstableWindow(.repository)))
            let readsAfterRace = await service.indexEntriesReadCountForTesting()
            XCTAssertEqual(readsAfterRace, readsBefore + 1)

            let retried = await issueSourceAuthority(service, capability: initial, path: path)
            XCTAssertNotNil(retried.token, "The next capture must succeed: \(String(describing: retried.failure))")
            let readsAfterRetry = await service.indexEntriesReadCountForTesting()
            XCTAssertEqual(readsAfterRetry, readsAfterRace + 1, "The unstable read must not be memoized.")
            let resolved = try await capability(service.resolve(root: rootRequest))
            XCTAssertEqual(resolved.repositoryAuthority, initial.repositoryAuthority)
        }

        /// Resolution retries an index rewrite during an entries read once, as it does a pre/post
        /// capture mismatch, instead of reporting the root transiently unavailable.
        func testIndexRewriteDuringResolutionEntriesReadRetriesOnce() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let root = try makeSettledRepository(fixture)
            let rewrite = OneShotIndexRewrite(fixture: fixture, root: root, path: "Sources/Other.swift")
            rewrite.arm()
            let service = WorkspaceCodemapGitCapabilityService(
                namespaceSalt: namespaceSalt,
                hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                    afterIndexEntriesRead: { rewrite.rewriteOnceIfArmed() }
                )
            )

            let resolved = try await capability(service.resolve(root: request(for: root, seed: 9)))

            XCTAssertTrue(rewrite.didRewrite())
            let reads = await service.indexEntriesReadCountForTesting()
            XCTAssertEqual(reads, 2, "The unstable read and the retry's read.")
            let reference = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
            let expected = try await capability(reference.resolve(root: request(for: root, seed: 10)))
            XCTAssertEqual(resolved.repositoryAuthority.indexGeneration, expected.repositoryAuthority.indexGeneration)
        }

        /// A failing `ls-files` (corrupt index) fails issuance instead of reusing the memoized
        /// digest; after the index is restored the next capture reads again and issues.
        func testIndexEntriesReadFailureFailsClosedAndRecovers() async throws {
            let fixture = try ReviewGitRepositoryFixture(name: #function)
            let root = try makeSettledRepository(fixture)
            let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
            let initial = try await capability(service.resolve(root: request(for: root, seed: 13)))
            let path = "Sources/Feature.swift"
            let indexURL = try fixture.gitPath("index", at: root)
            let original = try Data(contentsOf: indexURL)
            let readsBefore = await service.indexEntriesReadCountForTesting()

            try Data("not an index".utf8).write(to: indexURL, options: .atomic)
            let corrupt = await issueSourceAuthority(service, capability: initial, path: path)
            XCTAssertNil(corrupt.token, "A failed entries read must not issue.")
            XCTAssertNotNil(corrupt.failure)
            let readsAfterCorrupt = await service.indexEntriesReadCountForTesting()
            XCTAssertEqual(readsAfterCorrupt, readsBefore + 1, "The corrupt index must be read, not memo-served.")

            try original.write(to: indexURL, options: .atomic)
            let restored = await issueSourceAuthority(service, capability: initial, path: path)
            XCTAssertNotNil(restored.token, "The restored index must issue: \(String(describing: restored.failure))")
            let readsAfterRestore = await service.indexEntriesReadCountForTesting()
            XCTAssertGreaterThan(readsAfterRestore, readsAfterCorrupt, "The restored index must be read again.")
        }
    #endif

    /// The structural validator accepts real and empty output and rejects malformed records.
    func testIndexEntriesOutputValidation() throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeSettledRepository(fixture)
        let real = try fixture.runGit(["ls-files", "--stage", "-v", "-z"], at: root)
        XCTAssertNoThrow(try GitService.validateIndexEntriesOutput(Data(real.utf8), objectFormat: .sha1))
        XCTAssertNoThrow(try GitService.validateIndexEntriesOutput(Data(), objectFormat: .sha1))

        let oid = String(repeating: "a", count: 40)
        let valid = "h 100644 \(oid) 0\tSources/A.swift\0"
        XCTAssertNoThrow(try GitService.validateIndexEntriesOutput(Data(valid.utf8), objectFormat: .sha1))
        let malformed: [String: String] = [
            "unterminated": "H 100644 \(oid) 0\tA.swift",
            "tag": "1 100644 \(oid) 0\tA.swift\0",
            "mode": "H 100648 \(oid) 0\tA.swift\0",
            "short object ID": "H 100644 \(oid.dropLast()) 0\tA.swift\0",
            "object ID for sha256": valid,
            "stage": "H 100644 \(oid) 4\tA.swift\0",
            "path separator": "H 100644 \(oid) 0 A.swift\0",
            "empty path": "H 100644 \(oid) 0\t\0",
            "trailing garbage": valid + "garbage\0"
        ]
        for (reason, output) in malformed {
            let format: GitObjectFormat = reason == "object ID for sha256" ? .sha256 : .sha1
            XCTAssertThrowsError(
                try GitService.validateIndexEntriesOutput(Data(output.utf8), objectFormat: format),
                "Expected rejection: \(reason)"
            )
        }
    }

    /// U6: above the output limit, the index stat digest is the generation (pre-entry semantics).
    func testOversizedIndexEntriesFallBackToStatGeneration() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeSettledRepository(fixture)
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            indexEntriesOutputByteLimit: 1
        )
        let initial = try await capability(service.resolve(root: request(for: root, seed: 6)))

        try fixture.rewriteIndexWithoutContentChange(path: "Sources/Feature.swift", at: root)

        let issuance = await issueSourceAuthority(service, capability: initial, path: "Sources/Feature.swift")
        XCTAssertEqual(issuance, .unavailable(.repositoryAuthorityChanged(changed: [.index])))
    }

    /// A stat-only rewrite inside a source-authority window, before either repository capture or
    /// between them, still issues. The candidate is untracked so the rewrite's settle, which
    /// backdates tracked files, cannot move its path fingerprint.
    func testStatOnlyIndexRewriteInsideSourceAuthorityWindowStillIssues() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try makeSettledRepository(fixture)
        let candidate = "Sources/Untracked.swift"
        try fixture.createUntrackedFile("let untracked = 1\n", at: candidate, root: root)

        let beforeOpening = OneShotIndexRewrite(fixture: fixture, root: root, path: "Sources/Other.swift")
        let openingService = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { beforeOpening.rewriteOnceIfArmed() }
            )
        )
        let openingCapability = try await capability(openingService.resolve(root: request(for: root, seed: 7)))
        beforeOpening.arm()
        let openingIssuance = await issueSourceAuthority(openingService, capability: openingCapability, path: candidate)
        XCTAssertTrue(beforeOpening.didRewrite())
        XCTAssertNotNil(
            openingIssuance.token,
            "A rewrite before the opening capture must issue: \(String(describing: openingIssuance.failure))"
        )

        let betweenCaptures = OneShotIndexRewrite(fixture: fixture, root: root, path: "Sources/Other.swift")
        let closingService = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                beforeSourceAuthorityPostRepositoryCapture: { betweenCaptures.rewriteOnceIfArmed() }
            )
        )
        let closingCapability = try await capability(closingService.resolve(root: request(for: root, seed: 8)))
        betweenCaptures.arm()
        let closingIssuance = await issueSourceAuthority(closingService, capability: closingCapability, path: candidate)
        XCTAssertTrue(betweenCaptures.didRewrite())
        XCTAssertNotNil(
            closingIssuance.token,
            "A rewrite between the captures must issue: \(String(describing: closingIssuance.failure))"
        )
    }

    private func makeSettledRepository(_ fixture: ReviewGitRepositoryFixture) throws -> URL {
        let root = try fixture.makeRepository(named: "repository", files: Self.files)
        try fixture.settleIndex(at: root)
        return root
    }

    private func indexGeneration(
        _ service: WorkspaceCodemapGitCapabilityService,
        _ rootRequest: WorkspaceCodemapGitCapabilityRequest
    ) async throws -> String {
        try await capability(service.resolve(root: rootRequest)).repositoryAuthority.indexGeneration
    }

    private func issueSourceAuthority(
        _ service: WorkspaceCodemapGitCapabilityService,
        capability: GitCodemapRootCapability,
        path: String
    ) async -> WorkspaceCodemapSourceAuthorityIssuance {
        await service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: capability.rootEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 1,
            currentPathGeneration: 1,
            observedIngressGeneration: 1,
            currentIngressGeneration: 1
        )
    }

    private func request(for root: URL, seed: UInt8) -> WorkspaceCodemapGitCapabilityRequest {
        WorkspaceCodemapGitCapabilityRequest(
            rootID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1)),
            rootLifetimeID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2)),
            loadedRootURL: root
        )
    }

    private func capability(
        _ state: WorkspaceCodemapGitCapabilityState
    ) throws -> GitCodemapRootCapability {
        guard case let .eligible(capability) = state else {
            XCTFail("Expected eligible capability, received \(state)")
            throw NSError(domain: #function, code: 1)
        }
        return capability
    }
}

/// Performs one stat-only index rewrite from a capability hook once armed.
private final class OneShotIndexRewrite: @unchecked Sendable {
    private let lock = NSLock()
    private let fixture: ReviewGitRepositoryFixture
    private let root: URL
    private let path: String
    private var armed = false
    private var rewritten = false

    init(fixture: ReviewGitRepositoryFixture, root: URL, path: String) {
        self.fixture = fixture
        self.root = root
        self.path = path
    }

    func arm() {
        lock.withLock { armed = true }
    }

    func rewriteOnceIfArmed() {
        lock.lock()
        defer { lock.unlock() }
        guard armed, !rewritten else { return }
        rewritten = true
        do {
            try fixture.rewriteIndexWithoutContentChange(path: path, at: root)
        } catch {
            XCTFail("Stat-only index rewrite failed: \(error)")
        }
    }

    func didRewrite() -> Bool {
        lock.withLock { rewritten }
    }
}
