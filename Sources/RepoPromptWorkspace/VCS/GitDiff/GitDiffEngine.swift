import CryptoKit
import Foundation

package actor GitDiffEngine {
    struct DiffTextResult {
        let fingerprint: GitDiffFingerprint
        let text: String
        let perFile: [String: String]?
    }

    package struct GitDiffSnapshotBuildResult {
        package let fingerprint: GitDiffFingerprint
        let compare: GitDiffCompareSpec
        let scope: GitDiffScope
        let requestedPaths: [String]?
        package let diffText: String?
        package let perFile: [String: String]?
        package let rawPerFile: [String: Data]?
        package let changedFiles: [VCSUncommittedFile]
        let summary: (files: Int, insertions: Int, deletions: Int)
    }

    package static let shared = GitDiffEngine()

    private let vcsService: VCSService
    private let gitService: GitService // Kept for diff text generation (specific formats)
    private var cache: [CacheKey: DiffTextResult] = [:]

    private struct CacheKey: Hashable {
        let repoPath: String
        let targetKey: String
        let scope: GitDiffScope
        let selectedPathsKey: String
        let statusHash: String
        let backendKind: VCSBackendKind
    }

    package init(vcsService: VCSService = .shared, gitService: GitService = GitService()) {
        self.vcsService = vcsService
        self.gitService = gitService
    }

    func statusFingerprint(baseRef: String, repoURL: URL) async throws -> GitDiffFingerprint {
        try await vcsService.getStatusFingerprint(at: repoURL, baseRef: baseRef)
    }

    package func fingerprint(for compare: GitDiffCompareSpec, repoURL: URL) async throws -> GitDiffFingerprint {
        let backend = await vcsService.backend(forRepoRoot: repoURL)
        let normalizedCompare = backend.normalizeCompareSpec(compare)

        switch normalizedCompare {
        case let .uncommitted(base):
            return try await backend.getStatusFingerprint(at: repoURL, baseRef: base)
        case let .uncommittedMergeBase(base):
            return try await backend.getStatusFingerprint(at: repoURL, baseRef: base)
        case let .staged(base):
            return try await backend.getStatusFingerprint(at: repoURL, baseRef: base)
        case let .stagedMergeBase(base):
            return try await backend.getStatusFingerprint(at: repoURL, baseRef: base)
        case .unstaged:
            // For git, compute fingerprint from porcelain status (jj normalizes this to .uncommitted)
            let headID = try await backend.getHeadID(at: repoURL)
            let statusData = try await gitService.getStatusPorcelainZ(at: repoURL)
            let statusHash = sha256Hex(statusData)
            return GitDiffFingerprint(
                headSHA: headID,
                baseRef: "INDEX",
                statusHash: "index:\(statusHash)",
                generatedAt: Date()
            )
        case let .revspec(revspec):
            let headID = try await backend.getHeadID(at: repoURL)
            return GitDiffFingerprint(
                headSHA: headID,
                baseRef: revspec,
                statusHash: "revspec:\(revspec)",
                generatedAt: Date()
            )
        }
    }

    /// Build snapshot inputs with explicit pathspecs (Git-relative or absolute paths under the checkout).
    /// Pathspecs override scope - if provided, only files matching the pathspecs are included.
    /// Directory pathspecs (ending with `/`) match all files under that directory.
    package func buildSnapshotInputs(
        compare: GitDiffCompareSpec,
        pathspecs: [String]?,
        repoURL: URL,
        contextLines: Int,
        detectRenames: Bool,
        generateDiffText: Bool
    ) async throws -> GitDiffSnapshotBuildResult {
        let hasPathspecs = !(pathspecs?.isEmpty ?? true)
        let normalizedPathspecs = pathspecs.map {
            GitDiffPathNormalization.gitPathspecs(from: $0, repoRootPath: repoURL.path)
        }
        let scope: GitDiffScope = hasPathspecs ? .selected : .all
        let requestedPaths = hasPathspecs ? normalizedPathspecs : nil

        let fingerprint = try await fingerprint(for: compare, repoURL: repoURL)

        let includeUntracked = switch compare {
        case .uncommitted, .uncommittedMergeBase, .unstaged:
            true
        case .staged, .stagedMergeBase, .revspec:
            false
        }

        let backend = await vcsService.backend(forRepoRoot: repoURL)
        let normalizedCompare = backend.normalizeCompareSpec(compare)
        let changedFiles = try await backend.getChangedFilesStats(
            compare: normalizedCompare,
            includeUntrackedWhenApplicable: includeUntracked,
            detectRenames: detectRenames,
            at: repoURL
        )

        // Filter by pathspecs if provided
        let filtered: [VCSUncommittedFile] = if let normalizedPathspecs, !normalizedPathspecs.isEmpty {
            filterByPathspecs(changedFiles, pathspecs: normalizedPathspecs)
        } else {
            changedFiles
        }

        let summaryFiles = filtered.count
        let summaryInsertions = filtered.reduce(0) { $0 + ($1.additions ?? 0) }
        let summaryDeletions = filtered.reduce(0) { $0 + ($1.deletions ?? 0) }

        var diffText: String?
        var perFile: [String: String]?
        var rawPerFile: [String: Data]?
        if generateDiffText, !filtered.isEmpty {
            let pathFilter = normalizedPathspecs
            let tracked = try await diffOutput(
                backend: backend,
                compare: normalizedCompare,
                paths: pathFilter,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )

            // Untracked patches require path normalization after `--no-index`; partial staging never
            // accepts them, but retaining their rendered bytes keeps the combined splitter aligned.
            let untrackedPaths = filtered.filter { $0.status == "??" }.map(\.path)
            let untrackedText: String = if !untrackedPaths.isEmpty {
                try await backend.getUntrackedDiff(for: untrackedPaths, contextLines: contextLines, at: repoURL)
            } else {
                ""
            }
            let parts = [
                (text: tracked.text, data: tracked.data),
                (text: untrackedText, data: Data(untrackedText.utf8))
            ].filter { !$0.text.isEmpty }
            let combined = parts.map(\.text).joined(separator: "\n")

            if !combined.isEmpty {
                diffText = combined
                let rendered = GitService.splitUnifiedDiffByFile(combined)
                perFile = rendered
                rawPerFile = GitRawDiffFileSplitter.split(
                    Self.joinDiffData(parts.map(\.data)),
                    matching: rendered
                )
            }
        }

        return GitDiffSnapshotBuildResult(
            fingerprint: fingerprint,
            compare: compare,
            scope: scope,
            requestedPaths: requestedPaths,
            diffText: diffText,
            perFile: perFile,
            rawPerFile: rawPerFile,
            changedFiles: filtered,
            summary: (files: summaryFiles, insertions: summaryInsertions, deletions: summaryDeletions)
        )
    }

    /// Filter changed files by pathspecs.
    /// Pathspecs ending with `/` are treated as directory prefixes.
    private func filterByPathspecs(
        _ files: [VCSUncommittedFile],
        pathspecs: [String]
    ) -> [VCSUncommittedFile] {
        guard !pathspecs.isEmpty else { return files }

        return files.filter { Self.pathMatchesAnyPathspec($0.path, pathspecs) }
    }

    /// Literal pathspec match: exact path, a directory containing the path, or a `/`-suffixed
    /// directory prefix. `.` is the repository root.
    private nonisolated static func pathMatchesAnyPathspec(_ path: String, _ pathspecs: [String]) -> Bool {
        for spec in pathspecs {
            if spec == "." {
                return true
            }
            if spec.hasSuffix("/") {
                // Directory prefix match
                if path.hasPrefix(spec) || path == String(spec.dropLast()) {
                    return true
                }
            } else {
                // Exact match or the spec is a directory containing the file
                if path == spec || path.hasPrefix(spec + "/") {
                    return true
                }
            }
        }
        return false
    }

    /// `pathspecs` (caller `path`/`paths` filters) intersect `scope`: with `.all` they restrict
    /// the snapshot to matching changes, with `.selected` they narrow the selected paths. A
    /// non-nil list that has no entry inside this repository publishes no changes; absolute
    /// paths in other repositories never widen this one.
    func buildSnapshotInputs(
        compare: GitDiffCompareSpec,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        pathspecs: [String]? = nil,
        repoURL: URL,
        contextLines: Int,
        detectRenames: Bool,
        includeUntrackedInUnstaged: Bool = true,
        generateDiffText: Bool
    ) async throws -> GitDiffSnapshotBuildResult {
        let normalizedSelected = normalizedAbsolutePaths(selectedAbsolutePaths)
        let repoPathspecs: [String]? = pathspecs.map { specs in
            GitDiffPathNormalization.gitPathspecs(from: specs, repoRootPath: repoURL.path)
                .filter { !$0.hasPrefix("/") }
        }
        let selectedRequestedPaths: [String]? = if scope == .selected {
            Array(Set(gitRelativePaths(from: normalizedSelected, repoRootPath: repoURL.path))).sorted()
        } else {
            nil
        }
        // nil = whole repository; otherwise the only paths this snapshot may contain.
        let pathFilter: [String]? = switch (selectedRequestedPaths, repoPathspecs) {
        case (nil, nil):
            nil
        case let (selected?, nil):
            selected
        case let (nil, specs?):
            specs.contains(".") ? nil : Array(Set(specs)).sorted()
        case let (selected?, specs?):
            // Both directions: a selected file inside a filter directory, or a filter file inside a
            // selected directory. Every kept entry lies within both the selection and the filter.
            Array(Set(
                selected.filter { Self.pathMatchesAnyPathspec($0, specs) }
                    + specs.filter { Self.pathMatchesAnyPathspec($0, selected) }
            )).sorted()
        }
        let requestedPaths: [String]? = pathFilter?.isEmpty == false ? pathFilter : nil

        let fingerprint = try await fingerprint(for: compare, repoURL: repoURL)

        let includeUntracked = switch compare {
        case .uncommitted, .uncommittedMergeBase:
            true
        case .unstaged:
            includeUntrackedInUnstaged
        case .staged, .stagedMergeBase, .revspec:
            false
        }

        let backend = await vcsService.backend(forRepoRoot: repoURL)
        let normalizedCompare = backend.normalizeCompareSpec(compare)
        let changedFiles = try await backend.getChangedFilesStats(
            compare: normalizedCompare,
            includeUntrackedWhenApplicable: includeUntracked,
            detectRenames: detectRenames,
            at: repoURL
        )
        let scopeFiltered = filterChangedFiles(
            changedFiles,
            scope: scope,
            selectedAbsolutePaths: normalizedSelected,
            repoRootPath: repoURL.path
        )
        // With caller filters, the changed-file list follows the same effective filter as the diff.
        let filtered: [VCSUncommittedFile] = if repoPathspecs != nil {
            pathFilter.map { filter in changedFiles.filter { Self.pathMatchesAnyPathspec($0.path, filter) } }
                ?? changedFiles
        } else {
            scopeFiltered
        }

        let summaryFiles = filtered.count
        let summaryInsertions = filtered.reduce(0) { $0 + ($1.additions ?? 0) }
        let summaryDeletions = filtered.reduce(0) { $0 + ($1.deletions ?? 0) }

        var diffText: String?
        var perFile: [String: String]?
        var rawPerFile: [String: Data]?
        if generateDiffText {
            if pathFilter?.isEmpty != true, !filtered.isEmpty {
                let tracked = try await diffOutput(
                    backend: backend,
                    compare: normalizedCompare,
                    paths: pathFilter,
                    contextLines: contextLines,
                    detectRenames: detectRenames,
                    at: repoURL
                )

                let untrackedPaths = filtered.filter { $0.status == "??" }.map(\.path)
                let untrackedText: String = if !untrackedPaths.isEmpty, includeUntrackedInUnstaged {
                    try await backend.getUntrackedDiff(for: untrackedPaths, contextLines: contextLines, at: repoURL)
                } else {
                    ""
                }
                let parts = [
                    (text: tracked.text, data: tracked.data),
                    (text: untrackedText, data: Data(untrackedText.utf8))
                ].filter { !$0.text.isEmpty }
                let combined = parts.map(\.text).joined(separator: "\n")

                if !combined.isEmpty {
                    diffText = combined
                    let rendered = GitService.splitUnifiedDiffByFile(combined)
                    perFile = rendered
                    rawPerFile = GitRawDiffFileSplitter.split(
                        Self.joinDiffData(parts.map(\.data)),
                        matching: rendered
                    )
                }
            }
        }

        return GitDiffSnapshotBuildResult(
            fingerprint: fingerprint,
            compare: compare,
            scope: scope,
            requestedPaths: requestedPaths,
            diffText: diffText,
            perFile: perFile,
            rawPerFile: rawPerFile,
            changedFiles: filtered,
            summary: (files: summaryFiles, insertions: summaryInsertions, deletions: summaryDeletions)
        )
    }

    /// Uses Git's raw process path when possible; other backends remain text-only and therefore
    /// naturally fail the later raw/text provenance check for index mutation.
    private func diffOutput(
        backend: any VCSBackend,
        compare: GitDiffCompareSpec,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> (text: String, data: Data) {
        if backend.kind == .git {
            let data = try await gitService.getDiffData(
                compare: compare,
                paths: paths,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )
            return (String(decoding: data, as: UTF8.self), data)
        }
        let text = try await backend.getDiffText(
            compare: compare,
            paths: paths,
            contextLines: contextLines,
            detectRenames: detectRenames,
            at: repoURL
        )
        return (text, Data(text.utf8))
    }

    private nonisolated static func joinDiffData(_ parts: [Data]) -> Data {
        var combined = Data()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                combined.append(0x0A)
            }
            combined.append(part)
        }
        return combined
    }

    func diffText(
        target: GitDiffTarget,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        repoURL: URL,
        useCache: Bool = true
    ) async throws -> DiffTextResult {
        let normalizedSelected = normalizedAbsolutePaths(selectedAbsolutePaths)
        let selectedPathsKey = normalizedSelected.sorted().joined(separator: "|")

        switch target {
        case let .uncommitted(base):
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            let normalizedBase = backend.normalizeBaseRef(base)
            if await isRemoteBranch(normalizedBase, repoURL: repoURL) {
                try? await backend.fetch(at: repoURL)
            }
            let fingerprint = try await backend.getStatusFingerprint(at: repoURL, baseRef: normalizedBase)
            let cacheKey = CacheKey(
                repoPath: repoURL.path,
                targetKey: target.keyString,
                scope: scope,
                selectedPathsKey: selectedPathsKey,
                statusHash: fingerprint.statusHash,
                backendKind: backend.kind
            )
            if useCache, let cached = cache[cacheKey] {
                return cached
            }

            let compareSpec = GitDiffCompareSpec.uncommitted(base: normalizedBase)
            let changedFiles = try await backend.getChangedFilesStats(
                compare: compareSpec,
                includeUntrackedWhenApplicable: true,
                detectRenames: false,
                at: repoURL
            )
            let filtered = filterChangedFiles(
                changedFiles,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoRootPath: repoURL.path
            )
            guard !filtered.isEmpty else {
                let result = DiffTextResult(fingerprint: fingerprint, text: "", perFile: nil)
                cache[cacheKey] = result
                return result
            }

            let tracked = filtered.filter { $0.status != "??" }.map(\.path)
            let untracked = filtered.filter { $0.status == "??" }.map(\.path)

            // Use backend for diff text (respects jj normalization)
            let trackedDiff: String = if !tracked.isEmpty {
                try await backend.getDiffText(
                    compare: compareSpec,
                    paths: tracked,
                    contextLines: 3,
                    detectRenames: false,
                    at: repoURL
                )
            } else {
                ""
            }

            let untrackedDiff: String = if !untracked.isEmpty {
                try await backend.getUntrackedDiff(for: untracked, contextLines: 3, at: repoURL)
            } else {
                ""
            }

            let combined = [trackedDiff, untrackedDiff]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let perFile = combined.isEmpty ? nil : GitService.splitUnifiedDiffByFile(combined)
            let result = DiffTextResult(fingerprint: fingerprint, text: combined, perFile: perFile)
            cache[cacheKey] = result
            return result

        case let .uncommittedMergeBase(base):
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            let normalizedBase = backend.normalizeBaseRef(base)
            if await isRemoteBranch(normalizedBase, repoURL: repoURL) {
                try? await backend.fetch(at: repoURL)
            }
            let fingerprint = try await backend.getStatusFingerprint(at: repoURL, baseRef: normalizedBase)
            let cacheKey = CacheKey(
                repoPath: repoURL.path,
                targetKey: target.keyString,
                scope: scope,
                selectedPathsKey: selectedPathsKey,
                statusHash: fingerprint.statusHash,
                backendKind: backend.kind
            )
            if useCache, let cached = cache[cacheKey] {
                return cached
            }

            let compareSpec = GitDiffCompareSpec.uncommittedMergeBase(base: normalizedBase)
            let changedFiles = try await backend.getChangedFilesStats(
                compare: compareSpec,
                includeUntrackedWhenApplicable: true,
                detectRenames: false,
                at: repoURL
            )
            let filtered = filterChangedFiles(
                changedFiles,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoRootPath: repoURL.path
            )
            guard !filtered.isEmpty else {
                let result = DiffTextResult(fingerprint: fingerprint, text: "", perFile: nil)
                cache[cacheKey] = result
                return result
            }

            let tracked = filtered.filter { $0.status != "??" }.map(\.path)
            let untracked = filtered.filter { $0.status == "??" }.map(\.path)

            let trackedDiff: String = if !tracked.isEmpty {
                try await backend.getDiffText(
                    compare: compareSpec,
                    paths: tracked,
                    contextLines: 3,
                    detectRenames: false,
                    at: repoURL
                )
            } else {
                ""
            }

            let untrackedDiff: String = if !untracked.isEmpty {
                try await backend.getUntrackedDiff(for: untracked, contextLines: 3, at: repoURL)
            } else {
                ""
            }

            let combined = [trackedDiff, untrackedDiff]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let perFile = combined.isEmpty ? nil : GitService.splitUnifiedDiffByFile(combined)
            let result = DiffTextResult(fingerprint: fingerprint, text: combined, perFile: perFile)
            cache[cacheKey] = result
            return result

        case let .commit(sha):
            return try await diffTextForImmutableTarget(
                ref: "\(sha)^!",
                fingerprintBaseRef: sha,
                target: target,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoURL: repoURL,
                useCache: useCache
            )

        case let .range(from, to):
            let backend = await vcsService.backend(forRepoRoot: repoURL)
            let resolvedFrom = await from.isEmpty ? from : ((try? backend.getRefID(ref: from, at: repoURL)) ?? from)
            let resolvedTo = await to.isEmpty ? to : ((try? backend.getRefID(ref: to, at: repoURL)) ?? to)
            let resolvedRange = "\(resolvedFrom)..\(resolvedTo)"
            let statusHashOverride = "range:\(resolvedRange)"
            return try await diffTextForImmutableTarget(
                ref: resolvedRange,
                fingerprintBaseRef: resolvedRange,
                target: target,
                scope: scope,
                selectedAbsolutePaths: normalizedSelected,
                repoURL: repoURL,
                statusHashOverride: statusHashOverride,
                useCache: useCache
            )
        }
    }

    private func diffTextForImmutableTarget(
        ref: String,
        fingerprintBaseRef: String,
        target: GitDiffTarget,
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        repoURL: URL,
        statusHashOverride: String? = nil,
        useCache: Bool
    ) async throws -> DiffTextResult {
        let statusHash = statusHashOverride ?? target.keyString
        let backend = await vcsService.backend(forRepoRoot: repoURL)
        let headSHA = try await backend.getHeadID(at: repoURL)
        let fingerprint = GitDiffFingerprint(
            headSHA: headSHA,
            baseRef: fingerprintBaseRef,
            statusHash: statusHash,
            generatedAt: Date()
        )
        let cacheKey = CacheKey(
            repoPath: repoURL.path,
            targetKey: target.keyString,
            scope: scope,
            selectedPathsKey: selectedAbsolutePaths.sorted().joined(separator: "|"),
            statusHash: statusHash,
            backendKind: backend.kind
        )
        if useCache, let cached = cache[cacheKey] {
            return cached
        }

        let diffText: String
        switch scope {
        case .all:
            diffText = try await backend.getDiffText(
                compare: .revspec(ref),
                paths: nil,
                contextLines: 3,
                detectRenames: false,
                at: repoURL
            )
        case .selected:
            let gitPaths = gitRelativePaths(from: selectedAbsolutePaths, repoRootPath: repoURL.path)
            guard !gitPaths.isEmpty else {
                let result = DiffTextResult(fingerprint: fingerprint, text: "", perFile: nil)
                cache[cacheKey] = result
                return result
            }
            diffText = try await backend.getDiffText(
                compare: .revspec(ref),
                paths: gitPaths,
                contextLines: 3,
                detectRenames: false,
                at: repoURL
            )
        }

        let perFile = diffText.isEmpty ? nil : GitService.splitUnifiedDiffByFile(diffText)
        let result = DiffTextResult(fingerprint: fingerprint, text: diffText, perFile: perFile)
        cache[cacheKey] = result
        return result
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedAbsolutePaths(_ paths: [String]) -> [String] {
        GitDiffPathNormalization.normalizedAbsolutePaths(paths)
    }

    private func filterChangedFiles(
        _ files: [VCSUncommittedFile],
        scope: GitDiffScope,
        selectedAbsolutePaths: [String],
        repoRootPath: String
    ) -> [VCSUncommittedFile] {
        switch scope {
        case .all:
            return files
        case .selected:
            let selectedSet = Set(gitRelativePaths(from: selectedAbsolutePaths, repoRootPath: repoRootPath))
            guard !selectedSet.isEmpty else { return [] }
            return files.filter { selectedSet.contains($0.path) }
        }
    }

    private func gitRelativePaths(from absolutePaths: [String], repoRootPath: String) -> [String] {
        GitDiffPathNormalization.gitRelativePaths(from: absolutePaths, repoRootPath: repoRootPath)
    }

    private func isRemoteBranch(_ branchName: String, repoURL: URL) async -> Bool {
        guard branchName != "HEAD", !branchName.isEmpty else { return false }
        let backend = await vcsService.backend(forRepoRoot: repoURL)
        return await backend.hasRemoteTrackingRef(named: branchName, at: repoURL)
    }
}
