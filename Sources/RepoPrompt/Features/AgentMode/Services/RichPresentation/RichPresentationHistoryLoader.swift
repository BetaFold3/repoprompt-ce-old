import CoreGraphics
import Foundation
import ImageIO
import RepoPromptAgentCore

/// Local, read-only loading of rich-presentation history for the transcript renderer
/// (docs/context/specs/2026-11-04-rich-presentation-spec.md, Step 4, A6).
///
/// Authority comes only from the exact hydrated owner of the transcript being shown (its tab,
/// bound session and captured persistence state, never the selected tab or a reference) and from
/// the owner workspace's ACTUAL current storage directory (`WorkspaceManagerViewModel`), not the
/// data service's constructor root and not the D2 creation agreement: history renders even where
/// creation and handoff are refused. No URL ever comes from a tool result or a view; nothing here
/// touches the network. A missing or invalid manifest yields `.unavailable` (labeled fallback); a
/// missing or invalid image yields only that image's placeholder.
///
/// Every displayed state belongs to one `LoadIdentity` (exact owner lifetime, persistence stamp,
/// actual storage root and its revision, artifact). Views key their manifest and image tasks by
/// it and never show a state loaded for another identity, so a storage move or an owner
/// replacement restarts loading at the current root instead of keeping a stale or wrong-session
/// result. Root mutations publish `RichPresentationPublicationService.storageGeneration`, which
/// re-evaluates mounted blocks; owner replacement publishes through `AgentModeViewModel.sessions`.
@MainActor
final class RichPresentationHistoryLoader {
    static let shared = RichPresentationHistoryLoader()

    /// The exact hydrated owner of one displayed transcript.
    struct Owner {
        weak var viewModel: AgentModeViewModel?
        weak var session: AgentTabSession?
        let tabID: UUID
        let sessionID: UUID
        let state: AgentSessionPersistenceState
        let workspaceID: UUID
        weak var workspaceManager: WorkspaceManagerViewModel?
        let dataService: AgentSessionDataService

        /// Still the same owner lifetime: same tab object, binding and captured state.
        @MainActor
        func isCurrent() -> Bool {
            guard let viewModel, let session,
                  viewModel.sessions[tabID] === session,
                  session.activeAgentSessionID == sessionID,
                  session.persistenceState(for: sessionID)?.stamp == state.stamp
            else { return false }
            return true
        }
    }

    enum ManifestState: Equatable {
        case loaded(AgentRichArtifactManifest)
        case unavailable
    }

    /// Everything one displayed manifest or image depends on.
    struct LoadIdentity: Hashable {
        let tabID: UUID
        /// The exact owner `AgentTabSession` object (a replacement with the same IDs differs).
        let session: ObjectIdentifier
        let sessionID: UUID
        let stamp: AgentSessionPersistenceStamp
        let workspaceID: UUID
        let root: URL
        let revision: UInt64
        let artifactID: UUID
    }

    /// Whether a read can start now, and for which identity.
    enum LoadContext: Hashable {
        /// No local owner (remote or never-persisted session) or the owner workspace is gone.
        case unavailable
        /// A root mutation is in progress or the owner is momentarily not current. Transient: the
        /// end of the mutation or the owner change publishes, and the view re-evaluates.
        case pending
        case ready(LoadIdentity)
    }

    /// Loaded manifest with the capability that read it (asset reads reuse it).
    private struct Loaded {
        let manifest: AgentRichArtifactManifest
        let capability: AgentSessionDataService.RichArtifactReadCapability
        let storage: RichPresentationPublicationService.Storage
        /// The chart's plotted content, parsed once per loaded manifest (nil: unplottable).
        let chartContent: RichPresentationChartView.Content?
    }

    private struct ManifestKey: Hashable {
        let sessionID: UUID
        let stamp: AgentSessionPersistenceStamp
        let directory: URL
        let revision: UInt64
        let artifactID: UUID
    }

    private struct ImageKey: Hashable {
        let capability: AgentSessionDataService.RichArtifactReadCapability
        let assetID: UUID
    }

    /// Decoded image with its byte cost (`bytesPerRow × height`).
    final class DecodedImage: @unchecked Sendable {
        let image: CGImage
        let cost: Int

        init(image: CGImage) {
            self.image = image
            cost = image.bytesPerRow * image.height
        }
    }

    static let maxDecodedImageBytes = 32 * 1024 * 1024
    static let maxCachedManifests = 64
    static let maxConcurrentLocalReads = 2
    static let maxConcurrentDecodes = 1

    private let publication: @MainActor () -> RichPresentationPublicationService
    private var manifests: [ManifestKey: Loaded] = [:]
    private var unavailable: Set<ManifestKey> = []
    private var manifestOrder: [ManifestKey] = []
    private var images = RichPresentationDecodedImageCache<ImageKey>(maxCost: maxDecodedImageBytes)
    private let readPermits = RichPresentationPermits(maxConcurrentLocalReads)
    private let decodePermits = RichPresentationPermits(maxConcurrentDecodes)
    #if DEBUG
        /// Local manifest/asset reads and decodes performed (test evidence for bounds and reuse).
        private(set) var test_manifestReadCount = 0
        private(set) var test_assetReadCount = 0
        private(set) var test_decodeCount = 0
        /// Runs synchronously when a manifest read starts, before its first suspension.
        var test_onManifestReadStarted: (() -> Void)?
    #endif

    init(publication: @escaping @MainActor () -> RichPresentationPublicationService = { .shared }) {
        self.publication = publication
    }

    var decodedImageCost: Int {
        images.totalCost
    }

    /// The publication service whose `storageGeneration` mounted views observe.
    var publicationService: RichPresentationPublicationService {
        publication()
    }

    // MARK: - Manifest

    /// The owner's current storage (actual workspace directory plus the App's revision).
    private enum CurrentStorage {
        case unavailable
        case pending
        case ready(RichPresentationPublicationService.Storage)
    }

    private func currentStorage(for owner: Owner?) -> CurrentStorage {
        guard let owner else { return .unavailable }
        guard owner.isCurrent() else { return .pending }
        guard let manager = owner.workspaceManager,
              let workspace = manager.workspaces.first(where: { $0.id == owner.workspaceID })
        else { return .unavailable }
        guard let storage = try? publication().capture(
            workspaceID: owner.workspaceID, root: manager.workspaceDirectory(for: workspace)
        ) else { return .pending }
        return .ready(storage)
    }

    /// The identity a read for `reference` would have now (synchronous; no I/O beyond resolving
    /// the root path).
    func loadContext(for reference: RichPresentationReference, owner: Owner?) -> LoadContext {
        switch currentStorage(for: owner) {
        case .unavailable:
            return .unavailable
        case .pending:
            return .pending
        case let .ready(storage):
            guard let owner, let session = owner.session else { return .pending }
            return .ready(identity(for: reference, owner: owner, session: session, storage: storage))
        }
    }

    private func identity(
        for reference: RichPresentationReference, owner: Owner, session: AgentTabSession,
        storage: RichPresentationPublicationService.Storage
    ) -> LoadIdentity {
        LoadIdentity(
            tabID: owner.tabID, session: ObjectIdentifier(session), sessionID: owner.sessionID,
            stamp: owner.state.stamp, workspaceID: owner.workspaceID,
            root: storage.root, revision: storage.revision, artifactID: reference.artifactID
        )
    }

    private func makeCurrentCheck(
        owner: Owner, storage: RichPresentationPublicationService.Storage
    ) -> @MainActor () throws -> Void {
        let publication = publication
        return {
            guard owner.isCurrent(),
                  let manager = owner.workspaceManager,
                  let workspace = manager.workspaces.first(where: { $0.id == owner.workspaceID })
            else { throw AgentRichArtifactError.storageMoved }
            try publication().validate(storage, currentRoot: manager.workspaceDirectory(for: workspace))
        }
    }

    private func key(for identity: LoadIdentity) -> ManifestKey {
        ManifestKey(
            sessionID: identity.sessionID, stamp: identity.stamp,
            directory: identity.root, revision: identity.revision, artifactID: identity.artifactID
        )
    }

    /// The cached state for exactly `identity`.
    func cachedManifest(for identity: LoadIdentity) -> ManifestState? {
        let key = key(for: identity)
        if let loaded = manifests[key] { return .loaded(loaded.manifest) }
        return unavailable.contains(key) ? .unavailable : nil
    }

    /// The cached state for `reference`, when known for the owner's current storage.
    func cachedManifest(for reference: RichPresentationReference, owner: Owner?) -> ManifestState? {
        guard case let .ready(identity) = loadContext(for: reference, owner: owner) else { return nil }
        return cachedManifest(for: identity)
    }

    /// Forgets a cached `.unavailable` for exactly `identity`, so the next load reads the disk
    /// again (the fallback's explicit retry after the user restores the files).
    func forgetUnavailable(for identity: LoadIdentity) {
        let key = key(for: identity)
        guard unavailable.remove(key) != nil else { return }
        manifestOrder.removeAll { $0 == key }
    }

    /// The chart content of a manifest loaded for `identity`: parsed once per loaded manifest with
    /// the validator's own RFC 3339 parser, or parsed directly if the entry was evicted.
    func chartContent(for chart: RichPresentationChart, identity: LoadIdentity) -> RichPresentationChartView.Content? {
        if let loaded = manifests[key(for: identity)], case .chart = loaded.manifest.document.content {
            return loaded.chartContent
        }
        return RichPresentationChartBlock.chartContent(chart)
    }

    /// Loads the validated manifest. A `nil` owner (remote or never-persisted session), a missing
    /// owner workspace and every read failure yield `.unavailable`. Cancellation, a root mutation
    /// in progress, a momentarily non-current owner and a read that raced an owner or storage
    /// change return nil and cache nothing: the identity changes and the view loads again.
    func manifest(for reference: RichPresentationReference, owner: Owner?) async -> ManifestState? {
        let storage: RichPresentationPublicationService.Storage
        switch currentStorage(for: owner) {
        case .unavailable: return .unavailable
        case .pending: return nil
        case let .ready(ready): storage = ready
        }
        guard let owner, let session = owner.session else { return nil }
        let key = key(for: identity(for: reference, owner: owner, session: session, storage: storage))
        if let loaded = manifests[key] { return .loaded(loaded.manifest) }
        if unavailable.contains(key) { return .unavailable }
        let check = makeCurrentCheck(owner: owner, storage: storage)
        let resolved = AgentSessionDataService.ResolvedRichHistoryStorage(
            workspaceID: owner.workspaceID, directory: storage.root, revision: storage.revision
        )
        await readPermits.acquire()
        let result: Result<(AgentRichArtifactManifest, AgentSessionDataService.RichArtifactReadCapability), Error>
        do {
            try Task.checkCancellation()
            #if DEBUG
                test_manifestReadCount += 1
                test_onManifestReadStarted?()
            #endif
            let capability = try await owner.dataService.captureRichArtifactReadCapability(
                state: owner.state, resolvedStorage: resolved, checkCurrentContext: check
            )
            let manifest = try await owner.dataService.readRichArtifactManifest(
                capability: capability, reference: reference, checkCurrentStorage: check
            )
            result = .success((manifest, capability))
        } catch {
            result = .failure(error)
        }
        await readPermits.release()
        do {
            let (manifest, capability) = try result.get()
            // Reject a result that raced an owner or storage change.
            try check()
            let chartContent: RichPresentationChartView.Content? = if case let .chart(chart) = manifest.document.content {
                RichPresentationChartBlock.chartContent(chart)
            } else {
                nil
            }
            remember(key, Loaded(manifest: manifest, capability: capability, storage: storage, chartContent: chartContent))
            return .loaded(manifest)
        } catch is CancellationError {
            return nil
        } catch {
            if Task.isCancelled { return nil }
            // A storage change during the read is not evidence that the artifact is missing.
            if (try? check()) == nil { return nil }
            unavailable.insert(key)
            manifestOrder.append(key)
            trimManifests()
            return .unavailable
        }
    }

    private func remember(_ key: ManifestKey, _ loaded: Loaded) {
        manifests[key] = loaded
        unavailable.remove(key)
        manifestOrder.removeAll { $0 == key }
        manifestOrder.append(key)
        trimManifests()
    }

    private func trimManifests() {
        while manifestOrder.count > Self.maxCachedManifests {
            let oldest = manifestOrder.removeFirst()
            manifests.removeValue(forKey: oldest)
            unavailable.remove(oldest)
        }
    }

    // MARK: - Images

    /// The decoded image for one asset of a loaded manifest, or nil (placeholder). Local only.
    func image(assetID: UUID, reference: RichPresentationReference, owner: Owner?) async -> DecodedImage? {
        guard case let .ready(identity) = loadContext(for: reference, owner: owner), let owner,
              let loaded = manifests[key(for: identity)],
              loaded.manifest.assetIDs.contains(assetID)
        else { return nil }
        let imageKey = ImageKey(capability: loaded.capability, assetID: assetID)
        if let cached = images.value(for: imageKey) { return cached }
        let check = makeCurrentCheck(owner: owner, storage: loaded.storage)
        let bytes: Data
        await readPermits.acquire()
        do {
            try Task.checkCancellation()
            #if DEBUG
                test_assetReadCount += 1
            #endif
            bytes = try await owner.dataService.readRichArtifactAsset(
                capability: loaded.capability, manifest: loaded.manifest, assetID: assetID, checkCurrentStorage: check
            )
            await readPermits.release()
        } catch {
            await readPermits.release()
            return nil
        }
        await decodePermits.acquire()
        #if DEBUG
            test_decodeCount += 1
        #endif
        let decoded: DecodedImage? = await (try? AgentRichArtifactStore.offMain { Self.decode(bytes) }) ?? nil
        await decodePermits.release()
        guard let decoded, !Task.isCancelled, (try? check()) != nil else { return nil }
        images.insert(decoded, for: imageKey)
        return decoded
    }

    nonisolated static func decode(_ bytes: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return DecodedImage(image: image)
    }

    #if DEBUG
        func test_reset() {
            manifests.removeAll()
            unavailable.removeAll()
            manifestOrder.removeAll()
            images = RichPresentationDecodedImageCache<ImageKey>(maxCost: Self.maxDecodedImageBytes)
            test_manifestReadCount = 0
            test_assetReadCount = 0
            test_decodeCount = 0
        }
    #endif
}

/// Least-recently-used decoded-image cache bounded by total byte cost. An image costlier than the
/// whole budget is not cached.
struct RichPresentationDecodedImageCache<Key: Hashable> {
    let maxCost: Int
    private(set) var totalCost = 0
    private var entries: [Key: RichPresentationHistoryLoader.DecodedImage] = [:]
    private var order: [Key] = []

    init(maxCost: Int) {
        self.maxCost = maxCost
    }

    mutating func value(for key: Key) -> RichPresentationHistoryLoader.DecodedImage? {
        guard let value = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    mutating func insert(_ value: RichPresentationHistoryLoader.DecodedImage, for key: Key) {
        if let existing = entries.removeValue(forKey: key) {
            totalCost -= existing.cost
            order.removeAll { $0 == key }
        }
        guard value.cost <= maxCost else { return }
        entries[key] = value
        order.append(key)
        totalCost += value.cost
        while totalCost > maxCost, let oldest = order.first {
            order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) {
                totalCost -= evicted.cost
            }
        }
    }

    var count: Int {
        entries.count
    }
}

/// A small counting semaphore for bounded local reads and decodes.
actor RichPresentationPermits {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) {
        available = count
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
