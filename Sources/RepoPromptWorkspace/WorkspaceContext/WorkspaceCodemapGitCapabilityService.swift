import CryptoKit
import Darwin
import Foundation
import OSLog

struct WorkspaceCodemapPathFingerprintClient {
    let fingerprint: @Sendable (_ repositoryRoot: URL, _ repositoryRelativePath: String) throws
        -> GitBlobLStatFingerprint

    static let noFollow = WorkspaceCodemapPathFingerprintClient { repositoryRoot, relativePath in
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })
        else {
            throw POSIXError(.EINVAL)
        }

        let rootDescriptor = open(
            repositoryRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var directoryDescriptor = rootDescriptor
        defer { close(directoryDescriptor) }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString { name in
                openat(
                    directoryDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        var value = stat()
        let status = components.last!.withCString { name in
            fstatat(directoryDescriptor, name, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return GitBlobLStatFingerprint(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }
}

struct WorkspaceCodemapSourceAuthorityToken: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let repositoryRelativeLoadedRootPrefix: String
    let standardizedRepositoryRelativePath: String
    let acceptedPrePathFingerprint: GitBlobLStatFingerprint
    let acceptedPostPathFingerprint: GitBlobLStatFingerprint
    let candidateAttributeGeneration: String
    let pathGeneration: UInt64
    let ingressGeneration: UInt64

    var isFactoryValidated: Bool {
        acceptedPrePathFingerprint == acceptedPostPathFingerprint &&
            acceptedPostPathFingerprint.isRegularFile &&
            !candidateAttributeGeneration.isEmpty
    }

    private init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        repositoryRelativeLoadedRootPrefix: String,
        standardizedRepositoryRelativePath: String,
        acceptedPrePathFingerprint: GitBlobLStatFingerprint,
        acceptedPostPathFingerprint: GitBlobLStatFingerprint,
        candidateAttributeGeneration: String,
        pathGeneration: UInt64,
        ingressGeneration: UInt64
    ) {
        self.rootEpoch = rootEpoch
        self.repositoryAuthority = repositoryAuthority
        self.repositoryRelativeLoadedRootPrefix = repositoryRelativeLoadedRootPrefix
        self.standardizedRepositoryRelativePath = standardizedRepositoryRelativePath
        self.acceptedPrePathFingerprint = acceptedPrePathFingerprint
        self.acceptedPostPathFingerprint = acceptedPostPathFingerprint
        self.candidateAttributeGeneration = candidateAttributeGeneration
        self.pathGeneration = pathGeneration
        self.ingressGeneration = ingressGeneration
    }

    fileprivate static func issue(
        capability: GitCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRepositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        candidateRepositoryRelativePath: String,
        acceptedPrePathFingerprint: GitBlobLStatFingerprint,
        acceptedPostPathFingerprint: GitBlobLStatFingerprint,
        candidateAttributeGeneration: String,
        observedPathGeneration: UInt64,
        currentPathGeneration: UInt64,
        observedIngressGeneration: UInt64,
        currentIngressGeneration: UInt64
    ) -> WorkspaceCodemapSourceAuthorityToken? {
        guard capability.rootEpoch == observedRootEpoch,
              capability.repositoryAuthority == observedRepositoryAuthority,
              capability.repositoryNamespace == capability.repositoryAuthority.repositoryNamespace,
              capability.objectFormat == capability.repositoryAuthority.objectFormat,
              acceptedPrePathFingerprint == acceptedPostPathFingerprint,
              acceptedPostPathFingerprint.isRegularFile,
              observedPathGeneration == currentPathGeneration,
              observedIngressGeneration == currentIngressGeneration,
              !candidateAttributeGeneration.isEmpty,
              let path = standardizedSafeRelativePath(candidateRepositoryRelativePath),
              let prefix = standardizedPrefix(capability.repositoryRelativeLoadedRootPrefix),
              isCandidate(path, insideLoadedRootPrefix: prefix)
        else { return nil }

        return WorkspaceCodemapSourceAuthorityToken(
            rootEpoch: observedRootEpoch,
            repositoryAuthority: observedRepositoryAuthority,
            repositoryRelativeLoadedRootPrefix: prefix,
            standardizedRepositoryRelativePath: path,
            acceptedPrePathFingerprint: acceptedPrePathFingerprint,
            acceptedPostPathFingerprint: acceptedPostPathFingerprint,
            candidateAttributeGeneration: candidateAttributeGeneration,
            pathGeneration: observedPathGeneration,
            ingressGeneration: observedIngressGeneration
        )
    }

    private static func standardizedSafeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !StandardizedPath.containsNUL(path) else { return nil }
        let standardized = StandardizedPath.relative(path)
        guard standardized != ".", standardized != "..", !standardized.hasPrefix("../") else { return nil }
        return standardized
    }

    private static func standardizedPrefix(_ prefix: String) -> String? {
        if prefix.isEmpty { return "" }
        return standardizedSafeRelativePath(prefix)
    }

    private static func isCandidate(_ path: String, insideLoadedRootPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        return path.hasPrefix(prefix + "/")
    }
}

/// Names-only reason a source-authority token could not be issued or revalidated.
/// Never carries source or metadata contents, paths, digests, ref values, or raw error text.
enum WorkspaceCodemapSourceAuthorityFailure: Hashable {
    enum AuthorityComponent: String, CaseIterable, Hashable {
        case layout
        case index
        case checkoutConfiguration = "checkout_configuration"
        case attributes
        case sparse
        case metadata
    }

    enum UnstableWindow: String, Hashable {
        case attributes
        case repository
        case pathFingerprint = "path_fingerprint"
        case capability
    }

    enum CaptureFailure: String, Hashable {
        case permissionDenied = "permission_denied"
        case transient
    }

    case capabilityInactive
    case candidatePathRejected
    case candidateNotRegularFile
    /// The capture disagrees with the cached baseline on non-binding components.
    case repositoryAuthorityChanged(changed: [AuthorityComponent])
    /// The capture disagrees on namespace, object format, or a binding epoch.
    case repositoryBindingChanged
    /// The capture's repository layout or loaded-root prefix guard failed.
    case repositoryLayoutChanged
    case unstableWindow(UnstableWindow)
    case captureFailed(CaptureFailure)
    case tokenInvalid
    case cancelled

    var reason: String {
        switch self {
        case .capabilityInactive: "capability_inactive"
        case .candidatePathRejected: "candidate_path_rejected"
        case .candidateNotRegularFile: "candidate_not_regular_file"
        case .repositoryAuthorityChanged: "repository_authority_changed"
        case .repositoryBindingChanged: "repository_binding_changed"
        case .repositoryLayoutChanged: "repository_layout_changed"
        case let .unstableWindow(window): "unstable_window.\(window.rawValue)"
        case let .captureFailed(failure): "capture_failed.\(failure.rawValue)"
        case .tokenInvalid: "token_invalid"
        case .cancelled: "cancelled"
        }
    }

    var changedComponents: [AuthorityComponent] {
        guard case let .repositoryAuthorityChanged(changed) = self else { return [] }
        return changed
    }

    /// Root-wide failures mean the cached repository authority no longer matches the repository,
    /// so retrying any candidate against the same capability cannot succeed.
    var isRootWide: Bool {
        switch self {
        case .repositoryAuthorityChanged, .repositoryBindingChanged, .repositoryLayoutChanged:
            true
        case .capabilityInactive, .candidatePathRejected, .candidateNotRegularFile,
             .unstableWindow, .captureFailed, .tokenInvalid, .cancelled:
            false
        }
    }
}

enum WorkspaceCodemapSourceAuthorityIssuance: Hashable {
    case issued(WorkspaceCodemapSourceAuthorityToken)
    case unavailable(WorkspaceCodemapSourceAuthorityFailure)

    var token: WorkspaceCodemapSourceAuthorityToken? {
        guard case let .issued(token) = self else { return nil }
        return token
    }

    var failure: WorkspaceCodemapSourceAuthorityFailure? {
        guard case let .unavailable(failure) = self else { return nil }
        return failure
    }
}

enum WorkspaceCodemapSourceAuthorityRevalidation: Hashable {
    case valid
    case invalid(WorkspaceCodemapSourceAuthorityFailure)

    var failure: WorkspaceCodemapSourceAuthorityFailure? {
        guard case let .invalid(failure) = self else { return nil }
        return failure
    }
}

/// One candidate of a batched source-authority issuance window.
struct WorkspaceCodemapSourceAuthorityRequest: Equatable {
    let candidateRepositoryRelativePath: String
    let observedPathGeneration: UInt64
    let currentPathGeneration: UInt64
}

struct WorkspaceCodemapGitCapabilityServiceHooks {
    var beforeResolution: @Sendable () async -> Void
    var afterFirstAuthorityCapture: @Sendable () async -> Void
    var afterSourcePathFingerprintCapture: @Sendable () async -> Void
    /// Runs in each source-authority window after the per-candidate attribute captures, right
    /// before the window's closing repository capture.
    var beforeSourceAuthorityPostRepositoryCapture: @Sendable () async -> Void
    var afterAuthorityEvidenceComponentStat: @Sendable (String, Bool) -> Void
    var afterAuthorityEvidenceOpen: @Sendable (URL) -> Void
    /// Runs after a capture reads the index entries with `ls-files`, right before the closing index
    /// stat that must match the opening one.
    var afterIndexEntriesRead: @Sendable () async -> Void

    init(
        beforeResolution: @escaping @Sendable () async -> Void = {},
        afterFirstAuthorityCapture: @escaping @Sendable () async -> Void = {},
        afterSourcePathFingerprintCapture: @escaping @Sendable () async -> Void = {},
        beforeSourceAuthorityPostRepositoryCapture: @escaping @Sendable () async -> Void = {},
        afterAuthorityEvidenceComponentStat: @escaping @Sendable (String, Bool) -> Void = { _, _ in },
        afterAuthorityEvidenceOpen: @escaping @Sendable (URL) -> Void = { _ in },
        afterIndexEntriesRead: @escaping @Sendable () async -> Void = {}
    ) {
        self.beforeResolution = beforeResolution
        self.afterFirstAuthorityCapture = afterFirstAuthorityCapture
        self.afterSourcePathFingerprintCapture = afterSourcePathFingerprintCapture
        self.beforeSourceAuthorityPostRepositoryCapture = beforeSourceAuthorityPostRepositoryCapture
        self.afterAuthorityEvidenceComponentStat = afterAuthorityEvidenceComponentStat
        self.afterAuthorityEvidenceOpen = afterAuthorityEvidenceOpen
        self.afterIndexEntriesRead = afterIndexEntriesRead
    }

    static let none = WorkspaceCodemapGitCapabilityServiceHooks()
}

actor WorkspaceCodemapGitCapabilityService {
    private static let logger = Logger(
        subsystem: "com.repoprompt.workspace",
        category: "CodemapSourceAuthority"
    )

    #if DEBUG
        struct Snapshot: Equatable {
            let activeRecordCount: Int
            let historicalRecordCount: Int
            let activeFlightCount: Int
            let waiterCount: Int
            let resolutionObserverCount: Int
        }
    #endif

    private struct StableAuthority: Hashable {
        let repositoryNamespace: GitBlobRepositoryNamespace
        let objectFormat: GitObjectFormat
        let repositoryBindingEpoch: String
        let worktreeBindingEpoch: String
        let layoutGeneration: String
        /// Digest of the index entries the codemap pipeline reads (`ls-files --stage -v`), not of
        /// the index file's stat (oversized indexes fall back to the stat digest). See
        /// `indexEntriesGeneration(layout:objectFormat:)`.
        let indexGeneration: String
        let checkoutConfigurationGeneration: String
        let attributeGeneration: String
        let sparseGeneration: String
        let metadataGeneration: String
    }

    private struct AuthorityCapture: Equatable {
        let layout: GitRepositoryLayout
        let objectFormat: GitObjectFormat
        let stableAuthority: StableAuthority
    }

    private struct RootBinding: Hashable {
        let standardizedLoadedRootPath: String
        var repositoryID: String?
        var worktreeID: String?
    }

    private struct RootRecord {
        var state: WorkspaceCodemapGitCapabilityState = .unresolved
        var resolutionGeneration: UInt64 = 0
        var authorityGeneration: UInt64 = 0
        var stableAuthority: StableAuthority?
        var binding: RootBinding
        var retainedWorkTreeRoot: URL?
        var retainedGitDirectory: URL?
        #if DEBUG
            /// One bounded diagnostic entry per root; removed with the record on release.
            var lastSourceAuthorityFailure: WorkspaceCodemapSourceAuthorityFailure?
        #endif
    }

    private struct RootFlight {
        let id: UUID
        let resolutionGeneration: UInt64
        let priorState: WorkspaceCodemapGitCapabilityState
        let task: Task<Resolution, Never>
        var waiters: [UUID: CheckedContinuation<WorkspaceCodemapGitCapabilityState, Never>]
    }

    private struct HistoricalRecord {
        let binding: RootBinding
        let finalState: WorkspaceCodemapGitCapabilityState
        let releaseOrdinal: UInt64
    }

    private enum Resolution {
        case eligible(
            layout: GitRepositoryLayout,
            prefix: String,
            repositoryIdentity: GitWorktreeRepositoryIdentity,
            worktreeID: String,
            authority: StableAuthority
        )
        case terminal(WorkspaceCodemapGitTerminalUnavailableReason)
        case transient(WorkspaceCodemapGitTransientUnavailableReason)
    }

    private let gitService: GitService
    private let namespaceSalt: Data
    private let hooks: WorkspaceCodemapGitCapabilityServiceHooks
    private let pathFingerprintClient: WorkspaceCodemapPathFingerprintClient
    private let historicalRecordLimit: Int
    private let indexEntriesOutputByteLimit: Int
    private var records: [WorkspaceCodemapRootEpoch: RootRecord] = [:]
    /// Index entry generations keyed by standardized index path. Each value pairs the index stat
    /// digest with the entry digest read while that stat was the same before and after the read.
    /// In memory only; cleared when it reaches `indexGenerationMemoLimit` entries.
    private var indexGenerationMemo: [String: (statDigest: String, generation: String)] = [:]
    #if DEBUG
        private var authorityCaptureCount = 0
        private var indexEntriesReadCount = 0
    #endif
    private var flights: [WorkspaceCodemapRootEpoch: RootFlight] = [:]
    private var resolutionObservers: [UUID: Task<Void, Never>] = [:]
    private var rootEpochByWaiterID: [UUID: WorkspaceCodemapRootEpoch] = [:]
    private var historicalRecords: [WorkspaceCodemapRootEpoch: HistoricalRecord] = [:]
    private var releaseOrdinal: UInt64 = 0

    init(
        gitService: GitService = GitService(),
        namespaceSalt: Data,
        hooks: WorkspaceCodemapGitCapabilityServiceHooks = .none,
        pathFingerprintClient: WorkspaceCodemapPathFingerprintClient = .noFollow,
        historicalRecordLimit: Int = 64,
        indexEntriesOutputByteLimit: Int = WorkspaceCodemapGitCapabilityService.defaultIndexEntriesOutputByteLimit
    ) {
        precondition(historicalRecordLimit > 0)
        precondition(indexEntriesOutputByteLimit > 0)
        self.gitService = gitService
        self.namespaceSalt = namespaceSalt
        self.hooks = hooks
        self.pathFingerprintClient = pathFingerprintClient
        self.historicalRecordLimit = historicalRecordLimit
        self.indexEntriesOutputByteLimit = indexEntriesOutputByteLimit
    }

    /// Above this much `ls-files` output, `indexGeneration` falls back to the index stat digest.
    static let defaultIndexEntriesOutputByteLimit = 64 * 1024 * 1024
    private static let indexGenerationMemoLimit = 32

    nonisolated static func eligibilityPreflight(
        gitService: GitService,
        loadedRootURL: URL
    ) async -> WorkspaceCodemapGitEligibilityPreflightResult {
        let loadedRoot = loadedRootURL.standardizedFileURL
        guard loadedRoot.isFileURL, loadedRoot.path.hasPrefix("/") else {
            return .terminalUnavailable(.invalidLoadedRootContainment)
        }
        switch directoryState(at: loadedRoot) {
        case .valid:
            break
        case .missing:
            return .transientUnavailable(.repositoryChanging)
        case .permissionDenied:
            return .transientUnavailable(.permissionFailure)
        case .invalid:
            return .terminalUnavailable(.invalidLoadedRootContainment)
        }

        do {
            if try await gitService.findGitRoot(from: loadedRoot) != nil {
                return .eligible
            }
            return switch try await gitService.gitRepositoryKind(at: loadedRoot) {
            case .nonGit:
                .terminalUnavailable(.nonGit)
            case .bare:
                .terminalUnavailable(.bareRepository)
            case .worktree:
                .terminalUnavailable(.invalidLayout)
            }
        } catch {
            return .transientUnavailable(transientReason(for: error))
        }
    }

    func state(for rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapGitCapabilityState {
        if let state = records[rootEpoch]?.state { return state }
        if historicalRecords[rootEpoch] != nil { return .terminalUnavailable(.releasedRootEpoch) }
        return .unresolved
    }

    @discardableResult
    func resolve(
        root request: WorkspaceCodemapGitCapabilityRequest
    ) async -> WorkspaceCodemapGitCapabilityState {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(waiterID: waiterID, request: request, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    @discardableResult
    func reload(
        root request: WorkspaceCodemapGitCapabilityRequest
    ) async -> WorkspaceCodemapGitCapabilityState {
        guard historicalRecords[request.rootEpoch] == nil else {
            return .terminalUnavailable(.releasedRootEpoch)
        }
        if var record = records[request.rootEpoch] {
            guard record.binding.standardizedLoadedRootPath == request.loadedRootURL.path else {
                return .terminalUnavailable(.rootEpochBindingMismatch)
            }
            cancelFlight(for: request.rootEpoch, restoring: record.state)
            record = records[request.rootEpoch] ?? record
            if case .terminalUnavailable = record.state {
                record.state = .unresolved
                records[request.rootEpoch] = record
            }
        }
        return await resolve(root: request)
    }

    @discardableResult
    func retarget(
        from oldRootEpoch: WorkspaceCodemapRootEpoch,
        to request: WorkspaceCodemapGitCapabilityRequest
    ) async -> WorkspaceCodemapGitCapabilityState {
        await release(rootEpoch: oldRootEpoch)
        return await resolve(root: request)
    }

    func invalidateForAuthorityReplacement(rootEpoch: WorkspaceCodemapRootEpoch) async {
        cancelFlight(for: rootEpoch, restoring: .unresolved)
        guard let record = records.removeValue(forKey: rootEpoch) else { return }
        if let workTreeRoot = record.retainedWorkTreeRoot,
           let gitDirectory = record.retainedGitDirectory
        {
            await gitService.releaseRepositoryLayout(
                workTreeRoot: workTreeRoot,
                expectedGitDirectory: gitDirectory
            )
        }
    }

    func release(rootEpoch: WorkspaceCodemapRootEpoch) async {
        cancelFlight(for: rootEpoch, restoring: .unresolved)
        guard let record = records.removeValue(forKey: rootEpoch) else { return }
        releaseOrdinal &+= 1
        historicalRecords[rootEpoch] = HistoricalRecord(
            binding: record.binding,
            finalState: record.state,
            releaseOrdinal: releaseOrdinal
        )
        evictReleasedHistoryIfNeeded()
        if let workTreeRoot = record.retainedWorkTreeRoot,
           let gitDirectory = record.retainedGitDirectory
        {
            await gitService.releaseRepositoryLayout(
                workTreeRoot: workTreeRoot,
                expectedGitDirectory: gitDirectory
            )
        }
    }

    func drain() async {
        while !resolutionObservers.isEmpty {
            let observers = Array(resolutionObservers.values)
            for observer in observers {
                await observer.value
            }
        }
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            Snapshot(
                activeRecordCount: records.count,
                historicalRecordCount: historicalRecords.count,
                activeFlightCount: flights.count,
                waiterCount: flights.values.reduce(0) { $0 + $1.waiters.count },
                resolutionObserverCount: resolutionObservers.count
            )
        }

        func lastSourceAuthorityFailureForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> WorkspaceCodemapSourceAuthorityFailure? {
            records[rootEpoch]?.lastSourceAuthorityFailure
        }

        /// Repository authority captures started by this service (resolution, issuance, and
        /// revalidation), each about eight Git spawns.
        func authorityCaptureCountForTesting() -> Int {
            authorityCaptureCount
        }

        /// Full-index `ls-files` reads started by `indexEntriesGeneration(layout:objectFormat:)` (memo misses).
        func indexEntriesReadCountForTesting() -> Int {
            indexEntriesReadCount
        }
    #endif

    private func enqueue(
        waiterID: UUID,
        request: WorkspaceCodemapGitCapabilityRequest,
        continuation: CheckedContinuation<WorkspaceCodemapGitCapabilityState, Never>
    ) {
        if Task.isCancelled {
            continuation.resume(returning: state(for: request.rootEpoch))
            return
        }
        if historicalRecords[request.rootEpoch] != nil {
            continuation.resume(returning: .terminalUnavailable(.releasedRootEpoch))
            return
        }

        let loadedRootPath = request.loadedRootURL.path
        var record = records[request.rootEpoch] ?? RootRecord(
            binding: RootBinding(
                standardizedLoadedRootPath: loadedRootPath,
                repositoryID: nil,
                worktreeID: nil
            )
        )
        guard record.binding.standardizedLoadedRootPath == loadedRootPath else {
            continuation.resume(returning: .terminalUnavailable(.rootEpochBindingMismatch))
            return
        }
        if case .terminalUnavailable = record.state {
            continuation.resume(returning: record.state)
            return
        }
        if var flight = flights[request.rootEpoch] {
            flight.waiters[waiterID] = continuation
            flights[request.rootEpoch] = flight
            rootEpochByWaiterID[waiterID] = request.rootEpoch
            return
        }

        let priorState = Self.restorableState(record.state)
        record.resolutionGeneration &+= 1
        let generation = record.resolutionGeneration
        record.state = .resolving(generation: generation)
        records[request.rootEpoch] = record

        let flightID = UUID()
        let loadedRootURL = request.loadedRootURL
        let task = Task(priority: Task.currentPriority) { [weak self] in
            guard let self else { return Resolution.transient(.runtimeUnavailable) }
            await hooks.beforeResolution()
            if Task.isCancelled { return .transient(.runtimeUnavailable) }
            return await resolveCandidate(loadedRootURL: loadedRootURL)
        }
        flights[request.rootEpoch] = RootFlight(
            id: flightID,
            resolutionGeneration: generation,
            priorState: priorState,
            task: task,
            waiters: [waiterID: continuation]
        )
        rootEpochByWaiterID[waiterID] = request.rootEpoch
        let observer = Task { [weak self] in
            let resolution = await task.value
            guard let self else { return }
            await complete(
                rootEpoch: request.rootEpoch,
                flightID: flightID,
                resolution: resolution
            )
            await finishResolutionObserver(flightID)
        }
        resolutionObservers[flightID] = observer
    }

    private func finishResolutionObserver(_ flightID: UUID) {
        resolutionObservers.removeValue(forKey: flightID)
    }

    private func cancelWaiter(id waiterID: UUID) {
        guard let rootEpoch = rootEpochByWaiterID.removeValue(forKey: waiterID),
              var flight = flights[rootEpoch],
              let continuation = flight.waiters.removeValue(forKey: waiterID)
        else { return }
        continuation.resume(returning: flight.priorState)
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights.removeValue(forKey: rootEpoch)
            if var record = records[rootEpoch],
               case .resolving(generation: flight.resolutionGeneration) = record.state
            {
                record.state = flight.priorState
                records[rootEpoch] = record
            }
        } else {
            flights[rootEpoch] = flight
        }
    }

    private func complete(
        rootEpoch: WorkspaceCodemapRootEpoch,
        flightID: UUID,
        resolution: Resolution
    ) async {
        guard let flight = flights[rootEpoch], flight.id == flightID,
              var record = records[rootEpoch],
              case .resolving(generation: flight.resolutionGeneration) = record.state
        else { return }

        if case let .eligible(layout, _, _, _, _) = resolution,
           record.retainedWorkTreeRoot == nil
        {
            await gitService.retainRepositoryLayout(layout)
            guard let currentFlight = flights[rootEpoch], currentFlight.id == flightID,
                  let currentRecord = records[rootEpoch],
                  case .resolving(generation: flight.resolutionGeneration) = currentRecord.state
            else {
                await gitService.releaseRepositoryLayout(
                    workTreeRoot: layout.workTreeRoot,
                    expectedGitDirectory: layout.gitDir
                )
                return
            }
            record = currentRecord
            record.retainedWorkTreeRoot = layout.workTreeRoot
            record.retainedGitDirectory = layout.gitDir
        }
        flights.removeValue(forKey: rootEpoch)
        for waiterID in flight.waiters.keys {
            rootEpochByWaiterID.removeValue(forKey: waiterID)
        }

        switch resolution {
        case let .eligible(layout, prefix, repositoryIdentity, worktreeID, authority):
            if let repositoryID = record.binding.repositoryID,
               repositoryID != repositoryIdentity.repositoryID ||
               record.binding.worktreeID != worktreeID ||
               record.stableAuthority?.repositoryBindingEpoch != authority.repositoryBindingEpoch ||
               record.stableAuthority?.worktreeBindingEpoch != authority.worktreeBindingEpoch
            {
                record.state = .terminalUnavailable(.rootEpochBindingMismatch)
            } else {
                record.binding.repositoryID = repositoryIdentity.repositoryID
                record.binding.worktreeID = worktreeID
                if record.stableAuthority != authority {
                    record.authorityGeneration &+= 1
                    if record.authorityGeneration == 0 { record.authorityGeneration = 1 }
                    record.stableAuthority = authority
                }
                let token = WorkspaceCodemapRepositoryAuthorityToken(
                    authorityGeneration: record.authorityGeneration,
                    repositoryNamespace: authority.repositoryNamespace,
                    objectFormat: authority.objectFormat,
                    repositoryBindingEpoch: authority.repositoryBindingEpoch,
                    worktreeBindingEpoch: authority.worktreeBindingEpoch,
                    layoutGeneration: authority.layoutGeneration,
                    indexGeneration: authority.indexGeneration,
                    checkoutConfigurationGeneration: authority.checkoutConfigurationGeneration,
                    attributeGeneration: authority.attributeGeneration,
                    sparseGeneration: authority.sparseGeneration,
                    metadataGeneration: authority.metadataGeneration
                )
                record.state = .eligible(
                    GitCodemapRootCapability(
                        rootEpoch: rootEpoch,
                        repositoryLayout: layout,
                        repositoryIdentity: repositoryIdentity,
                        worktreeID: worktreeID,
                        repositoryNamespace: authority.repositoryNamespace,
                        objectFormat: authority.objectFormat,
                        repositoryRelativeLoadedRootPrefix: prefix,
                        repositoryAuthority: token
                    )
                )
            }
        case let .terminal(reason):
            if record.binding.repositoryID != nil,
               reason == .nonGit || reason == .invalidLayout
            {
                record.state = .transientUnavailable(
                    reason: .repositoryChanging,
                    retryGeneration: flight.resolutionGeneration &+ 1
                )
            } else {
                record.state = .terminalUnavailable(reason)
            }
        case let .transient(reason):
            record.state = .transientUnavailable(
                reason: reason,
                retryGeneration: flight.resolutionGeneration &+ 1
            )
        }
        records[rootEpoch] = record
        for continuation in flight.waiters.values {
            continuation.resume(returning: record.state)
        }
    }

    private func cancelFlight(
        for rootEpoch: WorkspaceCodemapRootEpoch,
        restoring state: WorkspaceCodemapGitCapabilityState
    ) {
        guard let flight = flights.removeValue(forKey: rootEpoch) else { return }
        flight.task.cancel()
        for (waiterID, continuation) in flight.waiters {
            rootEpochByWaiterID.removeValue(forKey: waiterID)
            continuation.resume(returning: state)
        }
    }

    private func evictReleasedHistoryIfNeeded() {
        while historicalRecords.count > historicalRecordLimit,
              let oldest = historicalRecords.min(by: { $0.value.releaseOrdinal < $1.value.releaseOrdinal })
        {
            historicalRecords.removeValue(forKey: oldest.key)
        }
    }

    private static func restorableState(
        _ state: WorkspaceCodemapGitCapabilityState
    ) -> WorkspaceCodemapGitCapabilityState {
        if case .resolving = state { return .unresolved }
        return state
    }

    /// Single-candidate issuance: a one-request window of `makeSourceAuthorities`.
    func makeSourceAuthority(
        capability: GitCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRepositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        candidateRepositoryRelativePath: String,
        observedPathGeneration: UInt64,
        currentPathGeneration: UInt64,
        observedIngressGeneration: UInt64,
        currentIngressGeneration: UInt64
    ) async -> WorkspaceCodemapSourceAuthorityIssuance {
        let issuances = await makeSourceAuthorities(
            capability: capability,
            observedRootEpoch: observedRootEpoch,
            observedRepositoryAuthority: observedRepositoryAuthority,
            observedIngressGeneration: observedIngressGeneration,
            currentIngressGeneration: currentIngressGeneration,
            requests: [WorkspaceCodemapSourceAuthorityRequest(
                candidateRepositoryRelativePath: candidateRepositoryRelativePath,
                observedPathGeneration: observedPathGeneration,
                currentPathGeneration: currentPathGeneration
            )]
        )
        return issuances.first ?? .unavailable(sourceAuthorityFailed(.tokenInvalid, rootEpoch: capability.rootEpoch))
    }

    static let maximumSourceAuthorityWindowCandidateCount = 128

    /// Issues source authority for many candidates, sharing one bracketed repository capture
    /// window per chunk of at most `maximumSourceAuthorityWindowCandidateCount` requests.
    /// Effective configuration is captured fresh at both ends of every window. Returns one
    /// issuance per request, in request order; never throws.
    func makeSourceAuthorities(
        capability: GitCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRepositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        observedIngressGeneration: UInt64,
        currentIngressGeneration: UInt64,
        requests: [WorkspaceCodemapSourceAuthorityRequest]
    ) async -> [WorkspaceCodemapSourceAuthorityIssuance] {
        var issuances: [WorkspaceCodemapSourceAuthorityIssuance] = []
        issuances.reserveCapacity(requests.count)
        var windowStart = requests.startIndex
        while windowStart < requests.endIndex {
            let windowEnd = min(windowStart + Self.maximumSourceAuthorityWindowCandidateCount, requests.endIndex)
            await issuances.append(contentsOf: makeSourceAuthorityWindow(
                capability: capability,
                observedRootEpoch: observedRootEpoch,
                observedRepositoryAuthority: observedRepositoryAuthority,
                observedIngressGeneration: observedIngressGeneration,
                currentIngressGeneration: currentIngressGeneration,
                requests: Array(requests[windowStart ..< windowEnd])
            ))
            windowStart = windowEnd
        }
        return issuances
    }

    /// One candidate still in a source-authority window.
    private struct SourceAuthorityWindowCandidate {
        let index: Int
        let request: WorkspaceCodemapSourceAuthorityRequest
        let path: String
        let prePathFingerprint: GitBlobLStatFingerprint
        var preAttributes = ""
        var postAttributes = ""
        var postPathFingerprint: GitBlobLStatFingerprint?
    }

    /// One window, in the single issuance's step order. A per-candidate failure drops only that
    /// candidate (logged once each); a root-wide or window-wide failure applies to every
    /// remaining candidate and is logged once for the window.
    private func makeSourceAuthorityWindow(
        capability: GitCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRepositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        observedIngressGeneration: UInt64,
        currentIngressGeneration: UInt64,
        requests: [WorkspaceCodemapSourceAuthorityRequest]
    ) async -> [WorkspaceCodemapSourceAuthorityIssuance] {
        let rootEpoch = capability.rootEpoch
        var results = [WorkspaceCodemapSourceAuthorityIssuance?](repeating: nil, count: requests.count)
        func finished() -> [WorkspaceCodemapSourceAuthorityIssuance] {
            results.map { $0 ?? .unavailable(.tokenInvalid) }
        }
        func fail(_ candidateIndex: Int, _ failure: WorkspaceCodemapSourceAuthorityFailure) {
            results[candidateIndex] = .unavailable(sourceAuthorityFailed(failure, rootEpoch: rootEpoch))
        }
        func failAll(
            _ candidates: [SourceAuthorityWindowCandidate],
            _ failure: WorkspaceCodemapSourceAuthorityFailure
        ) {
            guard !candidates.isEmpty else { return }
            let recorded = sourceAuthorityFailed(failure, rootEpoch: rootEpoch)
            for candidate in candidates {
                results[candidate.index] = .unavailable(recorded)
            }
        }

        // 1. The capability must still be the record's eligible, stable capability.
        guard let record = records[rootEpoch],
              case let .eligible(activeCapability) = record.state,
              activeCapability == capability,
              let stableAuthority = record.stableAuthority
        else {
            let failure = sourceAuthorityFailed(.capabilityInactive, rootEpoch: rootEpoch)
            return Array(repeating: .unavailable(failure), count: requests.count)
        }
        let loadedRoot = URL(fileURLWithPath: record.binding.standardizedLoadedRootPath)

        // 2. Per candidate: a safe path inside the loaded-root prefix, a no-follow pre path
        // fingerprint, and a regular file.
        var survivors: [SourceAuthorityWindowCandidate] = []
        survivors.reserveCapacity(requests.count)
        for (index, request) in requests.enumerated() {
            guard let candidatePath = Self.safeRepositoryRelativePath(request.candidateRepositoryRelativePath),
                  Self.isCandidate(
                      candidatePath,
                      insideLoadedRootPrefix: capability.repositoryRelativeLoadedRootPrefix
                  )
            else {
                fail(index, .candidatePathRejected)
                continue
            }
            let prePathFingerprint: GitBlobLStatFingerprint
            do {
                prePathFingerprint = try pathFingerprintClient.fingerprint(
                    capability.repositoryLayout.workTreeRoot,
                    candidatePath
                )
            } catch {
                fail(index, Self.candidatePathFailure(for: error))
                continue
            }
            guard prePathFingerprint.isRegularFile else {
                fail(index, .candidateNotRegularFile)
                continue
            }
            survivors.append(SourceAuthorityWindowCandidate(
                index: index,
                request: request,
                path: candidatePath,
                prePathFingerprint: prePathFingerprint
            ))
        }
        guard !survivors.isEmpty else { return finished() }

        // 3.
        await hooks.afterSourcePathFingerprintCapture()
        guard !Task.isCancelled else {
            failAll(survivors, .cancelled)
            return finished()
        }

        // 4. One opening repository capture. Return on the first baseline mismatch: no token can
        // be accepted, and a second capture would only spend Git calls on a rejection whose
        // root-wide cause is already known.
        let preRepository: AuthorityCapture
        do {
            preRepository = try await captureAuthorityStep(loadedRoot: loadedRoot, capability: capability)
        } catch {
            failAll(survivors, Self.captureFailure(for: error, window: .repository))
            return finished()
        }
        if let mismatch = Self.authorityMismatch(
            baseline: stableAuthority,
            observed: preRepository.stableAuthority
        ) {
            failAll(survivors, mismatch)
            return finished()
        }

        // 5.
        survivors = survivors.compactMap { candidate in
            var candidate = candidate
            do {
                candidate.preAttributes = try candidateAttributeStep(
                    layout: capability.repositoryLayout,
                    candidatePath: candidate.path
                )
                return candidate
            } catch {
                fail(candidate.index, Self.captureFailure(for: error, window: .attributes))
                return nil
            }
        }
        guard !survivors.isEmpty else { return finished() }

        // 6.
        guard !Task.isCancelled else {
            failAll(survivors, .cancelled)
            return finished()
        }

        // 7.
        survivors = survivors.compactMap { candidate in
            var candidate = candidate
            do {
                candidate.postAttributes = try candidateAttributeStep(
                    layout: capability.repositoryLayout,
                    candidatePath: candidate.path
                )
                return candidate
            } catch {
                fail(candidate.index, Self.captureFailure(for: error, window: .attributes))
                return nil
            }
        }
        guard !survivors.isEmpty else { return finished() }

        // 8. One closing repository capture.
        await hooks.beforeSourceAuthorityPostRepositoryCapture()
        let postRepository: AuthorityCapture
        do {
            postRepository = try await captureAuthorityStep(loadedRoot: loadedRoot, capability: capability)
        } catch {
            failAll(survivors, Self.captureFailure(for: error, window: .repository))
            return finished()
        }

        // 9.
        survivors = survivors.compactMap { candidate in
            var candidate = candidate
            do {
                candidate.postPathFingerprint = try pathFingerprintClient.fingerprint(
                    capability.repositoryLayout.workTreeRoot,
                    candidate.path
                )
                return candidate
            } catch {
                fail(candidate.index, Self.captureFailure(for: error, window: .pathFingerprint))
                return nil
            }
        }
        guard !survivors.isEmpty else { return finished() }

        // 10. Window checks, per candidate in the single issuance's order. The opening capture
        // matched the baseline, so any later disagreement is window instability.
        let repositoryStable = preRepository == postRepository &&
            postRepository.stableAuthority == stableAuthority
        let capabilityCurrent = if case let .eligible(currentCapability) = records[rootEpoch]?.state {
            currentCapability == capability
        } else {
            false
        }
        var repositoryUnstable: [SourceAuthorityWindowCandidate] = []
        var capabilityChanged: [SourceAuthorityWindowCandidate] = []
        var accepted: [SourceAuthorityWindowCandidate] = []
        for candidate in survivors {
            guard candidate.preAttributes == candidate.postAttributes else {
                fail(candidate.index, .unstableWindow(.attributes))
                continue
            }
            guard repositoryStable else {
                repositoryUnstable.append(candidate)
                continue
            }
            guard let postPathFingerprint = candidate.postPathFingerprint,
                  candidate.prePathFingerprint == postPathFingerprint,
                  postPathFingerprint.isRegularFile
            else {
                fail(candidate.index, .unstableWindow(.pathFingerprint))
                continue
            }
            guard capabilityCurrent else {
                capabilityChanged.append(candidate)
                continue
            }
            accepted.append(candidate)
        }
        failAll(repositoryUnstable, .unstableWindow(.repository))
        failAll(capabilityChanged, .unstableWindow(.capability))

        // 11.
        for candidate in accepted {
            guard let postPathFingerprint = candidate.postPathFingerprint,
                  let token = WorkspaceCodemapSourceAuthorityToken.issue(
                      capability: capability,
                      observedRootEpoch: observedRootEpoch,
                      observedRepositoryAuthority: observedRepositoryAuthority,
                      candidateRepositoryRelativePath: candidate.path,
                      acceptedPrePathFingerprint: candidate.prePathFingerprint,
                      acceptedPostPathFingerprint: postPathFingerprint,
                      candidateAttributeGeneration: candidate.postAttributes,
                      observedPathGeneration: candidate.request.observedPathGeneration,
                      currentPathGeneration: candidate.request.currentPathGeneration,
                      observedIngressGeneration: observedIngressGeneration,
                      currentIngressGeneration: currentIngressGeneration
                  )
            else {
                fail(candidate.index, .tokenInvalid)
                continue
            }
            results[candidate.index] = .issued(token)
        }
        return finished()
    }

    /// Revalidates previously issued source-authority tokens against one stable repository/path window.
    /// This reads Git metadata and no-follow path fingerprints only; it never reads source bytes.
    func revalidateSourceAuthorities(
        capability: GitCodemapRootCapability,
        tokens: [WorkspaceCodemapSourceAuthorityToken]
    ) async -> WorkspaceCodemapSourceAuthorityRevalidation {
        let rootEpoch = capability.rootEpoch
        guard let record = records[rootEpoch],
              case let .eligible(activeCapability) = record.state,
              activeCapability == capability,
              let stableAuthority = record.stableAuthority
        else { return .invalid(sourceAuthorityFailed(.capabilityInactive, rootEpoch: rootEpoch)) }
        if tokens.isEmpty { return .valid }

        var candidatePaths = Set<String>()
        for token in tokens {
            guard token.isFactoryValidated,
                  token.rootEpoch == rootEpoch,
                  token.repositoryAuthority == capability.repositoryAuthority,
                  token.repositoryRelativeLoadedRootPrefix == capability.repositoryRelativeLoadedRootPrefix,
                  let candidatePath = Self.safeRepositoryRelativePath(token.standardizedRepositoryRelativePath),
                  candidatePath == token.standardizedRepositoryRelativePath,
                  Self.isCandidate(
                      candidatePath,
                      insideLoadedRootPrefix: capability.repositoryRelativeLoadedRootPrefix
                  ),
                  candidatePaths.insert(candidatePath).inserted
            else { return .invalid(sourceAuthorityFailed(.tokenInvalid, rootEpoch: rootEpoch)) }
        }

        let loadedRoot = URL(fileURLWithPath: record.binding.standardizedLoadedRootPath)
        let failure: WorkspaceCodemapSourceAuthorityFailure
        do {
            var prePathFingerprints: [String: GitBlobLStatFingerprint] = [:]
            var preAttributeGenerations: [String: String] = [:]
            for token in tokens {
                let path = token.standardizedRepositoryRelativePath
                let fingerprint = try pathFingerprintStep(capability: capability, path: path)
                guard fingerprint == token.acceptedPostPathFingerprint,
                      fingerprint.isRegularFile
                else { throw SourceAuthorityStepError(.unstableWindow(.pathFingerprint)) }
                prePathFingerprints[path] = fingerprint
            }
            try Task.checkCancellation()

            let preRepository = try await captureAuthorityStep(
                loadedRoot: loadedRoot,
                capability: capability
            )
            if let mismatch = Self.authorityMismatch(
                baseline: stableAuthority,
                observed: preRepository.stableAuthority
            ) {
                throw SourceAuthorityStepError(mismatch)
            }

            for token in tokens {
                let path = token.standardizedRepositoryRelativePath
                let generation = try candidateAttributeStep(
                    layout: capability.repositoryLayout,
                    candidatePath: path
                )
                guard generation == token.candidateAttributeGeneration else {
                    throw SourceAuthorityStepError(.unstableWindow(.attributes))
                }
                preAttributeGenerations[path] = generation
            }
            try Task.checkCancellation()

            for token in tokens {
                let path = token.standardizedRepositoryRelativePath
                let generation = try candidateAttributeStep(
                    layout: capability.repositoryLayout,
                    candidatePath: path
                )
                guard generation == preAttributeGenerations[path],
                      generation == token.candidateAttributeGeneration
                else { throw SourceAuthorityStepError(.unstableWindow(.attributes)) }
            }

            let postRepository = try await captureAuthorityStep(
                loadedRoot: loadedRoot,
                capability: capability
            )
            guard preRepository == postRepository,
                  postRepository.stableAuthority == stableAuthority
            else { throw SourceAuthorityStepError(.unstableWindow(.repository)) }

            for token in tokens {
                let path = token.standardizedRepositoryRelativePath
                let fingerprint = try pathFingerprintStep(capability: capability, path: path)
                guard fingerprint == prePathFingerprints[path],
                      fingerprint == token.acceptedPostPathFingerprint,
                      fingerprint.isRegularFile
                else { throw SourceAuthorityStepError(.unstableWindow(.pathFingerprint)) }
            }
            guard case let .eligible(currentCapability) = records[rootEpoch]?.state,
                  currentCapability == capability
            else { throw SourceAuthorityStepError(.unstableWindow(.capability)) }
            return .valid
        } catch let error as SourceAuthorityStepError {
            failure = error.failure
        } catch {
            failure = Self.captureFailure(for: error, window: .repository)
        }
        return .invalid(sourceAuthorityFailed(failure, rootEpoch: rootEpoch))
    }

    /// A typed source-authority step failure; thrown only inside this service's capture windows.
    private struct SourceAuthorityStepError: Error {
        let failure: WorkspaceCodemapSourceAuthorityFailure

        init(_ failure: WorkspaceCodemapSourceAuthorityFailure) {
            self.failure = failure
        }
    }

    private func captureAuthorityStep(
        loadedRoot: URL,
        capability: GitCodemapRootCapability
    ) async throws -> AuthorityCapture {
        do {
            return try await captureAuthority(
                loadedRoot: loadedRoot,
                expectedLayout: capability.repositoryLayout,
                prefix: capability.repositoryRelativeLoadedRootPrefix
            )
        } catch {
            throw SourceAuthorityStepError(Self.captureFailure(for: error, window: .repository))
        }
    }

    private func candidateAttributeStep(
        layout: GitRepositoryLayout,
        candidatePath: String
    ) throws -> String {
        do {
            return try digestEvidence(
                urls: Self.candidateAttributeURLs(
                    layout: layout,
                    candidateRepositoryRelativePath: candidatePath
                ),
                includeBoundedContents: true
            )
        } catch {
            throw SourceAuthorityStepError(Self.captureFailure(for: error, window: .attributes))
        }
    }

    private func pathFingerprintStep(
        capability: GitCodemapRootCapability,
        path: String
    ) throws -> GitBlobLStatFingerprint {
        do {
            return try pathFingerprintClient.fingerprint(capability.repositoryLayout.workTreeRoot, path)
        } catch {
            throw SourceAuthorityStepError(Self.captureFailure(for: error, window: .pathFingerprint))
        }
    }

    /// Compares one capture against the cached baseline. Binding components (namespace, object
    /// format, binding epochs) map to a binding change; every other component is an authority change.
    private static func authorityMismatch(
        baseline: StableAuthority,
        observed: StableAuthority
    ) -> WorkspaceCodemapSourceAuthorityFailure? {
        guard baseline != observed else { return nil }
        guard baseline.repositoryNamespace == observed.repositoryNamespace,
              baseline.objectFormat == observed.objectFormat,
              baseline.repositoryBindingEpoch == observed.repositoryBindingEpoch,
              baseline.worktreeBindingEpoch == observed.worktreeBindingEpoch
        else { return .repositoryBindingChanged }
        var changed: [WorkspaceCodemapSourceAuthorityFailure.AuthorityComponent] = []
        if baseline.layoutGeneration != observed.layoutGeneration { changed.append(.layout) }
        if baseline.indexGeneration != observed.indexGeneration { changed.append(.index) }
        if baseline.checkoutConfigurationGeneration != observed.checkoutConfigurationGeneration {
            changed.append(.checkoutConfiguration)
        }
        if baseline.attributeGeneration != observed.attributeGeneration { changed.append(.attributes) }
        if baseline.sparseGeneration != observed.sparseGeneration { changed.append(.sparse) }
        if baseline.metadataGeneration != observed.metadataGeneration { changed.append(.metadata) }
        return .repositoryAuthorityChanged(changed: changed)
    }

    private static func candidatePathFailure(for error: Error) -> WorkspaceCodemapSourceAuthorityFailure {
        switch captureFailure(for: error, window: .pathFingerprint) {
        case .cancelled: .cancelled
        case .captureFailed(.permissionDenied): .captureFailed(.permissionDenied)
        default: .candidatePathRejected
        }
    }

    private static func captureFailure(
        for error: Error,
        window: WorkspaceCodemapSourceAuthorityFailure.UnstableWindow
    ) -> WorkspaceCodemapSourceAuthorityFailure {
        if let stepError = error as? SourceAuthorityStepError { return stepError.failure }
        if error is CancellationError { return .cancelled }
        if let captureError = error as? CapabilityCaptureError {
            switch captureError {
            case .layoutChanged(.repositoryLayout): return .repositoryLayoutChanged
            case .layoutChanged(.descriptorWindow), .layoutChanged(.indexEntriesWindow):
                return .unstableWindow(window)
            case .permissionDenied: return .captureFailed(.permissionDenied)
            case .authorityFileTooLarge: return .captureFailed(.transient)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        {
            return .captureFailed(.permissionDenied)
        }
        return .captureFailed(.transient)
    }

    /// Records and logs one names-only failure leaf. Never logs contents, paths, digests, or raw errors.
    private func sourceAuthorityFailed(
        _ failure: WorkspaceCodemapSourceAuthorityFailure,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapSourceAuthorityFailure {
        #if DEBUG
            records[rootEpoch]?.lastSourceAuthorityFailure = failure
        #endif
        if failure != .cancelled {
            let changed = failure.changedComponents.map(\.rawValue).joined(separator: ",")
            Self.logger.notice(
                "codemap source authority unavailable root=\(rootEpoch.rootID.uuidString, privacy: .public) reason=\(failure.reason, privacy: .public) changed=[\(changed, privacy: .public)]"
            )
        }
        return failure
    }

    private func resolveCandidate(loadedRootURL: URL) async -> Resolution {
        let loadedRoot = loadedRootURL.standardizedFileURL
        guard loadedRoot.isFileURL, loadedRoot.path.hasPrefix("/") else {
            return .terminal(.invalidLoadedRootContainment)
        }
        switch Self.directoryState(at: loadedRoot) {
        case .valid:
            break
        case .missing:
            return .transient(.repositoryChanging)
        case .permissionDenied:
            return .transient(.permissionFailure)
        case .invalid:
            return .terminal(.invalidLoadedRootContainment)
        }

        let repositoryRoot: URL
        do {
            guard let resolved = try await gitService.findGitRoot(from: loadedRoot) else {
                return switch try await gitService.gitRepositoryKind(at: loadedRoot) {
                case .nonGit: .terminal(.nonGit)
                case .bare: .terminal(.bareRepository)
                case .worktree: .terminal(.invalidLayout)
                }
            }
            repositoryRoot = resolved.standardizedFileURL
        } catch {
            return .transient(Self.transientReason(for: error))
        }

        guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repositoryRoot) else {
            return FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(".git").path)
                ? .terminal(.invalidLayout)
                : .transient(.repositoryChanging)
        }
        switch Self.layoutState(layout) {
        case .valid:
            break
        case .missing:
            return .transient(.repositoryChanging)
        case .permissionDenied:
            return .transient(.permissionFailure)
        case .invalid:
            return .terminal(.invalidLayout)
        }
        guard let prefix = Self.repositoryRelativePrefix(
            loadedRoot: loadedRoot,
            worktreeRoot: layout.workTreeRoot
        ) else {
            return .terminal(.invalidLoadedRootContainment)
        }

        do {
            for attempt in 0 ..< 2 {
                let pre: AuthorityCapture
                let post: AuthorityCapture
                do {
                    pre = try await captureAuthority(
                        loadedRoot: loadedRoot,
                        expectedLayout: layout,
                        prefix: prefix
                    )
                    await hooks.afterFirstAuthorityCapture()
                    try Task.checkCancellation()
                    post = try await captureAuthority(
                        loadedRoot: loadedRoot,
                        expectedLayout: layout,
                        prefix: prefix
                    )
                } catch CapabilityCaptureError.layoutChanged(.indexEntriesWindow) {
                    // An index rewrite during an entries read is the same race as a pre/post mismatch.
                    if attempt == 0 { continue }
                    return .transient(.repositoryChanging)
                }
                guard pre == post else {
                    if attempt == 0 { continue }
                    return .transient(.repositoryChanging)
                }

                let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                    commonGitDir: layout.commonDir,
                    mainWorktreeRoot: layout.knownMainWorktreeRoot
                )
                let worktreeID = GitWorktreeIdentity.worktreeID(
                    repositoryID: repositoryIdentity.repositoryID,
                    gitDir: layout.gitDir,
                    isMain: !layout.isLinkedWorktree,
                    path: layout.workTreeRoot
                )
                return .eligible(
                    layout: layout,
                    prefix: prefix,
                    repositoryIdentity: repositoryIdentity,
                    worktreeID: worktreeID,
                    authority: post.stableAuthority
                )
            }
            return .transient(.repositoryChanging)
        } catch let error as GitBlobIdentityError {
            switch error {
            case .invalidObjectFormat:
                return .terminal(.unsupportedObjectFormat)
            case .unsupportedGit:
                return .terminal(.unsupportedGit)
            default:
                return .transient(.runtimeUnavailable)
            }
        } catch let error as GitBlobCodeMapLocatorModelError {
            switch error {
            case .invalidNamespaceSalt, .invalidCommonDirectory, .invalidNamespace:
                return .terminal(.namespaceUnavailable)
            default:
                return .terminal(.unsupportedObjectFormat)
            }
        } catch {
            return .transient(Self.transientReason(for: error))
        }
    }

    private func captureAuthority(
        loadedRoot: URL,
        expectedLayout: GitRepositoryLayout,
        prefix: String
    ) async throws -> AuthorityCapture {
        #if DEBUG
            authorityCaptureCount += 1
        #endif
        guard let currentLayout = try await gitService.resolveGitBlobRepository(containing: loadedRoot),
              Self.repositoryRelativePrefix(
                  loadedRoot: loadedRoot,
                  worktreeRoot: currentLayout.workTreeRoot
              ) == prefix,
              Self.layoutIdentity(currentLayout) == Self.layoutIdentity(expectedLayout)
        else {
            throw CapabilityCaptureError.layoutChanged(.repositoryLayout)
        }
        switch Self.layoutState(currentLayout) {
        case .valid:
            break
        case .missing:
            throw CapabilityCaptureError.layoutChanged(.repositoryLayout)
        case .permissionDenied:
            throw CapabilityCaptureError.permissionDenied
        case .invalid:
            throw CapabilityCaptureError.layoutChanged(.repositoryLayout)
        }

        let objectFormat = try await gitService.gitBlobObjectFormat(at: currentLayout.workTreeRoot)
        let configuration = try await gitService.gitCodemapAuthorityConfiguration(
            at: currentLayout.workTreeRoot
        )
        let namespace = try GitBlobRepositoryNamespace(
            repositoryLayout: currentLayout,
            salt: namespaceSalt
        )

        let layoutGeneration = try digestEvidence(
            urls: [
                currentLayout.workTreeRoot,
                currentLayout.dotGitPath,
                currentLayout.gitDir,
                currentLayout.gitDir.appendingPathComponent("commondir"),
                currentLayout.commonDir
            ],
            includeBoundedContents: true
        )
        let indexGeneration = try await indexEntriesGeneration(
            layout: currentLayout,
            objectFormat: objectFormat
        )
        let metadataGeneration = try digestEvidence(
            urls: Self.metadataURLs(layout: currentLayout),
            includeBoundedContents: true
        )
        let checkoutConfigurationGeneration = try Self.checkoutConfigurationDigest(
            configuration,
            filesDigest: digestEvidence(
                urls: [
                    currentLayout.commonDir.appendingPathComponent("config"),
                    currentLayout.gitDir.appendingPathComponent("config"),
                    currentLayout.commonDir.appendingPathComponent("config.worktree"),
                    currentLayout.gitDir.appendingPathComponent("config.worktree")
                ],
                includeBoundedContents: true
            )
        )
        let attributeGeneration = try digestEvidence(
            urls: Self.attributeURLs(
                layout: currentLayout,
                loadedRoot: loadedRoot,
                configuredAttributesFile: configuration.attributesFilePath
            ),
            includeBoundedContents: true
        )
        let sparseGeneration = try Self.sparseDigest(
            configuration,
            filesDigest: digestEvidence(
                urls: [
                    currentLayout.gitDir.appendingPathComponent("info/sparse-checkout"),
                    currentLayout.commonDir.appendingPathComponent("info/sparse-checkout")
                ],
                includeBoundedContents: true
            )
        )
        let repositoryBindingEpoch = try Self.digestStrings([
            namespace.rawValue,
            objectFormat.rawValue,
            currentLayout.commonDir.resolvingSymlinksInPath().standardizedFileURL.path,
            bindingIdentityDigest(urls: [currentLayout.commonDir])
        ])
        let worktreeBindingEpoch = try Self.digestStrings([
            currentLayout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            currentLayout.gitDir.resolvingSymlinksInPath().standardizedFileURL.path,
            currentLayout.dotGitPath.resolvingSymlinksInPath().standardizedFileURL.path,
            bindingIdentityDigest(urls: [
                currentLayout.workTreeRoot,
                currentLayout.dotGitPath,
                currentLayout.gitDir
            ])
        ])

        return AuthorityCapture(
            layout: currentLayout,
            objectFormat: objectFormat,
            stableAuthority: StableAuthority(
                repositoryNamespace: namespace,
                objectFormat: objectFormat,
                repositoryBindingEpoch: repositoryBindingEpoch,
                worktreeBindingEpoch: worktreeBindingEpoch,
                layoutGeneration: layoutGeneration,
                indexGeneration: indexGeneration,
                checkoutConfigurationGeneration: checkoutConfigurationGeneration,
                attributeGeneration: attributeGeneration,
                sparseGeneration: sparseGeneration,
                metadataGeneration: metadataGeneration
            )
        )
    }

    /// The `indexGeneration` authority component: a digest of the index entries the codemap pipeline
    /// reads (mode, object ID, stage, path, assume-unchanged and skip-worktree per entry), so an index
    /// rewrite that changes only stat data (for example `git status` refreshing entries) is not an
    /// authority change. The index stat digest keys an in-memory memo, so `ls-files` runs once per index
    /// rewrite. The entries are read between two stat digests; if they differ, the capture fails as an
    /// unstable repository window (resolution retries it once, like a pre/post capture mismatch, then
    /// reports `.repositoryChanging`) and nothing is memoized. Above `indexEntriesOutputByteLimit` of
    /// output, the stat digest itself is the generation.
    private func indexEntriesGeneration(
        layout: GitRepositoryLayout,
        objectFormat: GitObjectFormat
    ) async throws -> String {
        let indexURL = layout.gitDir.appendingPathComponent("index")
        let memoKey = indexURL.standardizedFileURL.path
        let openingStat = try digestEvidence(urls: [indexURL], includeBoundedContents: false)
        if let memo = indexGenerationMemo[memoKey], memo.statDigest == openingStat {
            return memo.generation
        }
        #if DEBUG
            indexEntriesReadCount += 1
        #endif
        let entriesDigest = try await gitService.gitIndexEntriesDigest(
            at: layout.workTreeRoot,
            objectFormat: objectFormat,
            maximumOutputByteCount: indexEntriesOutputByteLimit
        )
        await hooks.afterIndexEntriesRead()
        try Task.checkCancellation()
        let closingStat = try digestEvidence(urls: [indexURL], includeBoundedContents: false)
        guard openingStat == closingStat else {
            throw CapabilityCaptureError.layoutChanged(.indexEntriesWindow)
        }
        let generation = entriesDigest ?? openingStat
        if indexGenerationMemo[memoKey] == nil, indexGenerationMemo.count >= Self.indexGenerationMemoLimit {
            indexGenerationMemo.removeAll()
        }
        indexGenerationMemo[memoKey] = (statDigest: openingStat, generation: generation)
        return generation
    }

    private enum CapabilityCaptureError: Error {
        /// Where a layout change was observed. Only the capture's repository layout/prefix guard is a
        /// layout change; descriptor-window races, traversal rejection, and an index rewrite while
        /// its entries are read are window instability.
        enum Origin {
            case repositoryLayout
            case descriptorWindow
            /// The index stat changed while `ls-files` read its entries.
            case indexEntriesWindow
        }

        case layoutChanged(Origin)
        case permissionDenied
        case authorityFileTooLarge
    }

    private static func transientReason(for error: Error) -> WorkspaceCodemapGitTransientUnavailableReason {
        if error is CancellationError { return .runtimeUnavailable }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        {
            return .permissionFailure
        }
        if error is GitService.GitError { return .gitProcessUnavailable }
        if let captureError = error as? CapabilityCaptureError {
            switch captureError {
            case .layoutChanged: return .repositoryChanging
            case .permissionDenied: return .permissionFailure
            case .authorityFileTooLarge: return .runtimeUnavailable
            }
        }
        return .runtimeUnavailable
    }

    private enum DirectoryState: Equatable {
        case valid
        case missing
        case permissionDenied
        case invalid
    }

    private static func directoryState(at url: URL) -> DirectoryState {
        guard url.isFileURL, url.path.hasPrefix("/") else { return .invalid }
        var statValue = stat()
        guard lstat(url.path, &statValue) == 0 else {
            return switch errno {
            case ENOENT, ENOTDIR: .missing
            case EACCES, EPERM: .permissionDenied
            default: .invalid
            }
        }
        guard (statValue.st_mode & S_IFMT) == S_IFDIR else { return .invalid }
        guard Darwin.access(url.path, R_OK | X_OK) == 0 else {
            return errno == EACCES || errno == EPERM ? .permissionDenied : .invalid
        }
        return .valid
    }

    private static func layoutState(_ layout: GitRepositoryLayout) -> DirectoryState {
        for directory in [layout.workTreeRoot, layout.gitDir, layout.commonDir] {
            let state = directoryState(at: directory)
            if state != .valid { return state }
        }
        return .valid
    }

    private static func repositoryRelativePrefix(loadedRoot: URL, worktreeRoot: URL) -> String? {
        let rootPath = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let loadedPath = loadedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard loadedPath == rootPath || StandardizedPath.isDescendant(loadedPath, of: rootPath) else {
            return nil
        }
        if loadedPath == rootPath { return "" }
        return String(loadedPath.dropFirst(rootPath.count + 1))
    }

    private static func layoutIdentity(_ layout: GitRepositoryLayout) -> [String] {
        [layout.workTreeRoot, layout.dotGitPath, layout.gitDir, layout.commonDir].map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    private static func metadataURLs(layout: GitRepositoryLayout) -> [URL] {
        var urls = [
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("HEAD"),
            layout.gitDir.appendingPathComponent("packed-refs"),
            layout.commonDir.appendingPathComponent("packed-refs")
        ]
        for headURL in [
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("HEAD")
        ] {
            if let data = try? Data(contentsOf: headURL), data.count <= 4096,
               let value = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               value.hasPrefix("ref: ")
            {
                let relativeRef = String(value.dropFirst(5))
                if !relativeRef.hasPrefix("/"), !relativeRef.contains(".."), !relativeRef.contains("\0") {
                    urls.append(layout.gitDir.appendingPathComponent(relativeRef))
                    urls.append(layout.commonDir.appendingPathComponent(relativeRef))
                }
            }
        }
        return urls
    }

    private static func attributeURLs(
        layout: GitRepositoryLayout,
        loadedRoot: URL,
        configuredAttributesFile: String?
    ) -> [URL] {
        var urls = [
            layout.gitDir.appendingPathComponent("info/attributes"),
            layout.commonDir.appendingPathComponent("info/attributes")
        ]
        var directory = layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL
        let target = loadedRoot.resolvingSymlinksInPath().standardizedFileURL
        while true {
            urls.append(directory.appendingPathComponent(".gitattributes"))
            if directory.path == target.path { break }
            let relative = String(target.path.dropFirst(directory.path.count))
                .split(separator: "/", omittingEmptySubsequences: true)
            guard let next = relative.first else { break }
            directory.appendPathComponent(String(next), isDirectory: true)
        }
        if let configuredAttributesFile {
            let configuredURL = URL(fileURLWithPath: configuredAttributesFile, relativeTo: layout.commonDir)
                .standardizedFileURL
            urls.append(configuredURL)
        }
        return urls
    }

    private static func candidateAttributeURLs(
        layout: GitRepositoryLayout,
        candidateRepositoryRelativePath: String
    ) throws -> [URL] {
        let components = candidateRepositoryRelativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, components.count <= 512 else {
            throw CapabilityCaptureError.authorityFileTooLarge
        }
        var urls: [URL] = []
        var directory = layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL
        urls.append(directory.appendingPathComponent(".gitattributes"))
        for component in components.dropLast() {
            directory.appendPathComponent(String(component), isDirectory: true)
            urls.append(directory.appendingPathComponent(".gitattributes"))
        }
        return urls
    }

    private static func safeRepositoryRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !StandardizedPath.containsNUL(path) else { return nil }
        let standardized = StandardizedPath.relative(path)
        guard standardized != ".", standardized != "..", !standardized.hasPrefix("../") else { return nil }
        return standardized
    }

    private static func isCandidate(_ path: String, insideLoadedRootPrefix rawPrefix: String) -> Bool {
        guard let prefix = rawPrefix.isEmpty ? "" : safeRepositoryRelativePath(rawPrefix) else { return false }
        return prefix.isEmpty || path.hasPrefix(prefix + "/")
    }

    private struct DescriptorEvidence {
        let statValue: stat
        let contents: Data?
    }

    private struct DescriptorLink {
        let parentDescriptor: Int32
        let name: String
        let childStat: stat
    }

    private func digestEvidence(urls: [URL], includeBoundedContents: Bool) throws -> String {
        var data = Data()
        for path in Dictionary(grouping: urls, by: { $0.standardizedFileURL.path }).keys.sorted() {
            data.append(Data(path.utf8))
            data.append(0)
            guard let evidence = try descriptorEvidence(
                at: URL(fileURLWithPath: path),
                includeContents: includeBoundedContents,
                maximumContentByteCount: 1024 * 1024,
                missingAllowed: true
            ) else {
                data.append(0)
                continue
            }
            data.append(1)
            if Self.isDirectory(evidence.statValue) {
                // Directory size and timestamps churn with every lock or temp file Git and the
                // app create; identity covers replacement, and authority files carry their own evidence.
                appendIdentityEvidence(evidence.statValue, to: &data)
            } else {
                appendStatEvidence(evidence.statValue, to: &data)
            }
            if let contents = evidence.contents {
                data.append(contents)
                data.append(0)
            }
        }
        return Self.hex(Data(SHA256.hash(data: data)))
    }

    private func bindingIdentityDigest(urls: [URL]) throws -> String {
        var data = Data()
        for path in Dictionary(grouping: urls, by: { $0.standardizedFileURL.path }).keys.sorted() {
            data.append(Data(path.utf8))
            data.append(0)
            guard let evidence = try descriptorEvidence(
                at: URL(fileURLWithPath: path),
                includeContents: true,
                maximumContentByteCount: 64 * 1024,
                missingAllowed: false
            ) else {
                throw POSIXError(.ENOENT)
            }
            data.append(Data([
                String(evidence.statValue.st_dev),
                String(evidence.statValue.st_ino),
                String(evidence.statValue.st_mode)
            ].joined(separator: ":").utf8))
            data.append(0)
            if let contents = evidence.contents {
                data.append(contents)
                data.append(0)
            }
        }
        return Self.hex(Data(SHA256.hash(data: data)))
    }

    private func descriptorEvidence(
        at url: URL,
        includeContents: Bool,
        maximumContentByteCount: Int64,
        missingAllowed: Bool
    ) throws -> DescriptorEvidence? {
        let path = Self.normalizedSystemAliasPath(url.standardizedFileURL.path)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, components.count <= 1024 else {
            throw POSIXError(.EINVAL)
        }
        let rootDescriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var descriptors = [rootDescriptor]
        var links: [DescriptorLink] = []
        defer {
            for descriptor in descriptors.reversed() {
                close(descriptor)
            }
        }

        for (index, component) in components.enumerated() {
            let parentDescriptor = descriptors[descriptors.count - 1]
            var linkStat = stat()
            let status = component.withCString { name in
                fstatat(parentDescriptor, name, &linkStat, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                if missingAllowed, errno == ENOENT || errno == ENOTDIR { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard (linkStat.st_mode & S_IFMT) != S_IFLNK else {
                throw CapabilityCaptureError.layoutChanged(.descriptorWindow)
            }
            let isLeaf = index == components.count - 1
            hooks.afterAuthorityEvidenceComponentStat(component, isLeaf)
            if !isLeaf, (linkStat.st_mode & S_IFMT) != S_IFDIR {
                if missingAllowed { return nil }
                throw POSIXError(.ENOTDIR)
            }
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK |
                (isLeaf ? 0 : O_DIRECTORY)
            let descriptor = component.withCString { name in
                openat(parentDescriptor, name, flags)
            }
            guard descriptor >= 0 else {
                if missingAllowed, errno == ENOENT || errno == ENOTDIR { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            descriptors.append(descriptor)
            var descriptorStat = stat()
            guard fstat(descriptor, &descriptorStat) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Intermediate directories are traversal capabilities, not authority
            // evidence. Sibling churn may change their size/timestamps without
            // changing the descriptor-bound path. A file leaf's complete stat is
            // authority evidence and must remain stable across lookup and open;
            // a directory leaf contributes identity only, keyed on the observed type.
            let componentRemainedStable = isLeaf
                ? sameLeafEvidence(linkStat, descriptorStat)
                : sameDescriptorIdentity(linkStat, descriptorStat)
            guard componentRemainedStable else {
                throw CapabilityCaptureError.layoutChanged(.descriptorWindow)
            }
            links.append(DescriptorLink(
                parentDescriptor: parentDescriptor,
                name: component,
                childStat: descriptorStat
            ))
        }

        let leafDescriptor = descriptors[descriptors.count - 1]
        let preStat = links[links.count - 1].childStat
        hooks.afterAuthorityEvidenceOpen(url)
        var contents: Data?
        if includeContents, (preStat.st_mode & S_IFMT) == S_IFREG {
            guard preStat.st_size >= 0, preStat.st_size <= maximumContentByteCount else {
                throw CapabilityCaptureError.authorityFileTooLarge
            }
            contents = try readBounded(
                descriptor: leafDescriptor,
                maximumByteCount: maximumContentByteCount
            )
        }
        var postStat = stat()
        guard fstat(leafDescriptor, &postStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard sameLeafEvidence(preStat, postStat) else {
            throw CapabilityCaptureError.layoutChanged(.descriptorWindow)
        }
        for link in links {
            var current = stat()
            let status = link.name.withCString { name in
                fstatat(link.parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0,
                  sameDescriptorIdentity(link.childStat, current),
                  (current.st_mode & S_IFMT) != S_IFLNK
            else {
                throw CapabilityCaptureError.layoutChanged(.descriptorWindow)
            }
        }
        return DescriptorEvidence(statValue: postStat, contents: contents)
    }

    private func readBounded(descriptor: Int32, maximumByteCount: Int64) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Int64(data.count) <= maximumByteCount - Int64(count) else {
                throw CapabilityCaptureError.authorityFileTooLarge
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func appendStatEvidence(_ value: stat, to data: inout Data) {
        let evidence = [
            String(value.st_dev),
            String(value.st_ino),
            String(value.st_mode),
            String(value.st_size),
            String(value.st_mtimespec.tv_sec),
            String(value.st_mtimespec.tv_nsec),
            String(value.st_ctimespec.tv_sec),
            String(value.st_ctimespec.tv_nsec)
        ].joined(separator: ":")
        data.append(Data(evidence.utf8))
        data.append(0)
    }

    private func appendIdentityEvidence(_ value: stat, to data: inout Data) {
        let evidence = [
            String(value.st_dev),
            String(value.st_ino),
            String(value.st_mode)
        ].joined(separator: ":")
        data.append(Data(evidence.utf8))
        data.append(0)
    }

    private static func isDirectory(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR
    }

    /// Directory leaves compare identity only; every other leaf keeps the full stable-stat window.
    private func sameLeafEvidence(_ lhs: stat, _ rhs: stat) -> Bool {
        Self.isDirectory(lhs) && Self.isDirectory(rhs)
            ? sameDescriptorIdentity(lhs, rhs)
            : sameStableStat(lhs, rhs)
    }

    private func sameDescriptorIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
    }

    private func sameStableStat(_ lhs: stat, _ rhs: stat) -> Bool {
        sameDescriptorIdentity(lhs, rhs) &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// macOS exposes these immutable system aliases at the filesystem root. Normalize only
    /// those aliases; repository-controlled symlinks remain forbidden by descriptor traversal.
    private static func normalizedSystemAliasPath(_ path: String) -> String {
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")] {
            if path == alias { return target }
            if path.hasPrefix(alias + "/") { return target + path.dropFirst(alias.count) }
        }
        return path
    }

    private static func checkoutConfigurationDigest(
        _ configuration: GitCodemapAuthorityConfiguration,
        filesDigest: String
    ) throws -> String {
        var values = [
            filesDigest,
            configuration.checkout.coreAutoCRLF ?? "<nil>",
            configuration.checkout.coreEOL ?? "<nil>",
            configuration.attributesFilePath ?? "<nil>"
        ]
        for key in configuration.checkout.filterDriverConfiguration.keys.sorted() {
            values.append(key)
            values.append(configuration.checkout.filterDriverConfiguration[key] ?? "")
        }
        return digestStrings(values)
    }

    private static func sparseDigest(
        _ configuration: GitCodemapAuthorityConfiguration,
        filesDigest: String
    ) throws -> String {
        digestStrings([
            filesDigest,
            configuration.sparseCheckoutEnabled ? "1" : "0",
            configuration.sparseCheckoutConeEnabled ? "1" : "0"
        ])
    }

    private static func digestStrings(_ values: [String]) -> String {
        hex(Data(SHA256.hash(data: Data(values.joined(separator: "\0").utf8))))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
