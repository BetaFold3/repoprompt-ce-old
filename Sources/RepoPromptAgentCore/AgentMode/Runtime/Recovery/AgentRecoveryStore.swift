import Foundation
import RepoPromptWorkspace

// Lossless-restart Phase 1b recovery store (spec R1, R2). INACTIVE: nothing in production
// constructs this store until the complete composer/send/queue/schedule cutover lands
// (composition lives in `AgentRecoveryCoordinator`; activation is the final cutover step).
//
// Lock order: a caller holds the foundation session gate (`AgentRecoveryLifecycleGate`, backed by
// `AgentSessionDataService`) and then awaits this actor. This actor never calls the gate or
// DataService, so the order is always gate → store.

// MARK: - Lifecycle gate seam

/// Foundation-owned lifecycle gate. An implementation acquires the session's existing persistence
/// gate, validates the current durable lifecycle (incarnation, reset generation) and tombstone
/// against `binding`, runs `body` while still holding the gate, and only then releases it. A
/// rejection throws before `body` runs.
///
/// Call discipline: `body` is not reentrant. It must not call another gated operation (a DataService
/// method that takes the same session gate, or a nested `performRecoveryTransaction`) for the same
/// session, which would deadlock on the gate it already holds. Store calls made outside a gate (for
/// example `importManagedImage`, which only copies files) are not lifecycle-validated, so producers
/// route every record mutation through this gate.
package protocol AgentRecoveryLifecycleGate: Sendable {
    var binding: AgentRecoveryLifecycleBinding { get }
    func performRecoveryTransaction<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T
}

// MARK: - Clean-exit gate

/// Persistence-boundary fence for this launch's clean mark (spec R4). The shutdown coordinator
/// authorizes one clean write after a successful final flush; the store writes `cleanExit` only
/// when that authorization is still current as the write begins (a newer authorization or a
/// revocation stops an unstarted write). A write that already began is atomic and cannot be
/// revoked: `revoke()` only reports that it may still land (`inProgress`).
package final class AgentRecoveryCleanExitGate: @unchecked Sendable {
    package enum Revocation: Equatable {
        /// No clean write is in progress and none is on disk: none can land from now on.
        case prevented
        /// A clean write began and is being written; it may still land.
        case inProgress
        /// The clean mark is on disk (no later unclean mark replaced it).
        case committed
    }

    private let lock = NSLock()
    private var authorized: UUID?
    private var writing: UUID?
    private var cleanOnDisk = false

    package init() {}

    /// A fresh single-use authorization; it supersedes any earlier, unstarted one.
    package func authorize() -> UUID {
        let token = UUID()
        lock.withLock { authorized = token }
        return token
    }

    /// Revokes any unstarted authorization and reports what can still land.
    package func revoke() -> Revocation {
        lock.withLock {
            authorized = nil
            if writing != nil { return .inProgress }
            return cleanOnDisk ? .committed : .prevented
        }
    }

    /// Store only: starts the clean write of `token` when it is still the authorization.
    func begin(_ token: UUID) -> Bool {
        lock.withLock {
            guard authorized == token, writing == nil else { return false }
            authorized = nil
            writing = token
            return true
        }
    }

    /// Store only: the clean write of `token` finished.
    func finish(_ token: UUID, committed: Bool) {
        lock.withLock {
            guard writing == token else { return }
            writing = nil
            if committed { cleanOnDisk = true }
        }
    }

    /// Store only: an unclean mark replaced the launch file.
    func noteUncleanCommitted() {
        lock.withLock { cleanOnDisk = false }
    }
}

/// Identity of the current app launch. `previousInstance` holds are derived by comparing an
/// intent's owning instance with this value; nothing is rewritten at relaunch.
package enum AgentRecoveryLaunchInstance {
    package static let currentID = UUID()
}

// MARK: - Errors and read results

package enum AgentRecoveryStoreError: Error, Equatable {
    package enum Category: Equatable {
        case authorityRejected
        case revisionConflict
        case unreadable
        case attachment
        case storage
        case invalidOperation
        /// An unresolved composer from another reset generation blocks implicit replacement.
        case heldInput
    }

    package enum Operation: String, Equatable {
        case submit
        case beginDispatch
        case recordOutcome
        case settleToQueue
        case markTargetStale
        case withdraw
        case attachPendingHandoff
    }

    case sessionMismatch(expected: UUID, actual: UUID)
    case staleIncarnation(expected: UUID, actual: UUID)
    case staleTranscriptResetGeneration(binding: UInt64, record: UInt64)
    case revisionConflict(expected: AgentRecoveryRecordRevision?, actual: AgentRecoveryRecordRevision?)
    case composerRevisionConflict(expected: AgentRecoveryComposerRevision?, actual: AgentRecoveryComposerRevision?)
    /// The stored composer was typed under another reset generation. Ordinary composer writes and
    /// removals refuse to replace it; it must be resolved explicitly (not implemented while inactive).
    case heldComposerUnresolved(revision: AgentRecoveryComposerRevision, transcriptResetGeneration: UInt64)
    case unreadableRecord(UUID, AgentRecoveryUnreadableReason)
    case attachmentUnavailable(imageID: UUID)
    case attachmentImportFailed(String)
    /// A storage operation failed: the raw description (logs only, never user-facing text) and its
    /// typed cause, classified at the store boundary (`AgentRecoveryStorageFailureCause`).
    case storageFailure(String, cause: AgentRecoveryStorageFailureCause)
    case intentNotFound(UUID)
    case intentConflict(UUID)
    case attemptNotFound(UUID)
    case attemptConflict(UUID)
    case runAttemptNotFound(UUID)
    case runAttemptConflict(UUID)
    case invalidTransition(intentID: UUID, from: AgentRecoveryDeliveryState, operation: Operation)
    case heldIntent(intentID: UUID, holds: Set<AgentRecoveryHoldReason>)
    /// A composer change reached the owner while an explicit held-composer restore was in flight,
    /// before its write (`AgentRecoveryResolutionFence`). Nothing was written.
    case heldResolutionSuperseded
    /// The acknowledged card's semantic state changed (or it no longer exists). Nothing was written.
    case cardChanged
    /// Phase 4: the same action ID with different parameters, or another unresolved action for the
    /// same item. Nothing was written.
    case actionConflict(UUID)
    case actionNotFound(UUID)
    /// Phase 4: the action's source no longer allows it (for example the saved input was already
    /// handed off, withdrawn, or held). Nothing was written.
    case actionIneligible(actionID: UUID, reason: String)
    /// Phase 4: a previous launch's unresolved action holds the item. It is joined and shown first;
    /// only an explicit new choice naming it (`supersedesActionID`) may replace it. Nothing was written.
    case priorLaunchAction(UUID)
    /// Phase 4: the named previous-launch action may have delivered input, and the new choice is not
    /// an explicitly confirmed continuation. Nothing was written.
    case supersedeRefused(actionID: UUID, reason: String)
    /// Phase 4: the history cursor moved since the import began (compare-and-swap on import ID).
    case historyCursorConflict
    /// Step 5b: the same MCP invocation is already linked to a different child or parent attempt.
    /// Nothing was written.
    case delegatedChildLinkConflict(invocationID: UUID)
    /// Step 5b: the parent record cannot take the link (no record, or the admitted parent run attempt
    /// is missing, finished, or from another reset generation). Nothing was written.
    case delegatedChildLinkIneligible(reason: String)
    /// Step 5a: the same review ID is already stored with a different proposal. Nothing was written.
    case editProposalConflict(reviewID: UUID)
    /// Step 5a: the proposal is not stored (already resolved, discarded, or never committed), or it
    /// cannot take the requested state change (for example another reset generation's proposal).
    /// Nothing was written.
    case editProposalIneligible(reviewID: UUID, reason: String)

    package var category: Category {
        switch self {
        case .sessionMismatch, .staleIncarnation, .staleTranscriptResetGeneration:
            .authorityRejected
        case .revisionConflict, .composerRevisionConflict:
            .revisionConflict
        case .unreadableRecord:
            .unreadable
        case .attachmentUnavailable, .attachmentImportFailed:
            .attachment
        case .storageFailure:
            .storage
        case .heldComposerUnresolved, .heldResolutionSuperseded:
            .heldInput
        case .intentNotFound, .intentConflict, .attemptNotFound, .attemptConflict, .runAttemptNotFound,
             .runAttemptConflict, .invalidTransition, .heldIntent, .cardChanged, .actionConflict, .actionNotFound,
             .actionIneligible, .priorLaunchAction, .supersedeRefused, .delegatedChildLinkConflict,
             .delegatedChildLinkIneligible, .editProposalConflict, .editProposalIneligible:
            .invalidOperation
        case .historyCursorConflict:
            .revisionConflict
        }
    }
}

package enum AgentRecoveryRecordState: Equatable {
    case absent
    case supported(AgentRecoveryRecord)
    /// Unreadable or future data. Its bytes are never modified and it is never writable.
    case preserved(AgentRecoveryUnreadableReason)

    package var record: AgentRecoveryRecord? {
        guard case let .supported(record) = self else { return nil }
        return record
    }
}

package struct AgentRecoveryDiscoveredRecord: Equatable {
    package let record: AgentRecoveryRecord
    /// Effective holds for intents that may still need delivery action.
    package let holdsByIntentID: [UUID: Set<AgentRecoveryHoldReason>]
}

package struct AgentRecoveryPreservedEntry: Equatable {
    /// `nil` when the file name is not a session UUID.
    package let sessionID: UUID?
    package let fileURL: URL
    package let reason: AgentRecoveryUnreadableReason
}

/// Raw filesystem inventory entry. Not authorization: actionable recovery requires the foundation
/// lifecycle and tombstone check (`AgentSessionDataService.discoverRecoveryRecords`).
package enum AgentRecoveryDiscoveryEntry: Equatable {
    case supported(AgentRecoveryDiscoveredRecord)
    case preserved(AgentRecoveryPreservedEntry)
}

/// Whether this session's recovery record references a managed image file. A record reference is
/// not proof of global non-use (live input and schedules can hold the same file), so nothing
/// deletes files from `notReferencedByRecord` alone.
package enum AgentRecoveryManagedImageRecordReference: Equatable {
    case referencedByRecord
    case notReferencedByRecord
    /// Unreadable record or unsafe name.
    case unknown
}

package enum AgentRecoveryDeletedSessionCleanup: Equatable {
    /// Supported record (if any) and the session's managed attachment directory were removed.
    case removed
    /// Unreadable or future record bytes and their attachments were kept (unknown-data contract).
    case preservedUnreadable(AgentRecoveryUnreadableReason)
}

// MARK: - Held-composer restore fence

/// Freeze boundary of one explicit held-composer restore (plan §2). The owner reports every composer
/// change while the restore is in flight; the store commits the restore only if none arrived first,
/// atomically with that check. A change that arrives after the commit is reported as
/// `trippedAfterCommit`, and the owner reverts the restore so the held draft stays durable.
package final class AgentRecoveryResolutionFence: @unchecked Sendable {
    package enum State: Equatable {
        case armed
        case tripped
        case committed
        case trippedAfterCommit
    }

    private let lock = NSLock()
    private var value: State = .armed

    package init() {}

    package var state: State {
        lock.withLock { value }
    }

    /// Store side, immediately before the write: commits unless a change tripped the fence.
    package func commitIfUntripped() -> Bool {
        lock.withLock {
            guard value == .armed else { return false }
            value = .committed
            return true
        }
    }

    /// Owner side: a composer change arrived while the restore was in flight.
    package func noteComposerMutation() {
        lock.withLock {
            switch value {
            case .armed: value = .tripped
            case .committed: value = .trippedAfterCommit
            case .tripped, .trippedAfterCommit: break
            }
        }
    }
}

// MARK: - Commit publication

/// A record state the store made durable (written or removed), published after the commit returns.
/// `sequence` is monotonic per store and follows commit order, so an observer drops a publication
/// delivered after a newer one. A wake-up with the committed state; the file stays the authority.
package struct AgentRecoveryRecordCommit: @unchecked Sendable {
    package enum State {
        case supported(AgentRecoveryRecord)
        case absent
    }

    package let sessionID: UUID
    package let sequence: UInt64
    package let state: State
}

/// Post-commit observer seam of one store. The handler runs synchronously on the store's executor
/// right after each record write or deleted-session removal; it must only hand the commit off
/// (never await the store).
package final class AgentRecoveryCommitPublisher: @unchecked Sendable {
    package typealias Handler = @Sendable (AgentRecoveryRecordCommit) -> Void

    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var handler: Handler?

    package init() {}

    package func setHandler(_ handler: Handler?) {
        lock.withLock { self.handler = handler }
    }

    fileprivate func publish(sessionID: UUID, state: AgentRecoveryRecordCommit.State) {
        let (commit, handler) = lock.withLock { () -> (AgentRecoveryRecordCommit, Handler?) in
            sequence += 1
            return (AgentRecoveryRecordCommit(sessionID: sessionID, sequence: sequence, state: state), self.handler)
        }
        handler?(commit)
    }
}

// MARK: - Store

package actor AgentRecoveryStore {
    /// File-system seam for failure injection in tests.
    package struct FileOperations {
        package var writeAtomically: @Sendable (Data, URL) throws -> Void
        package var removeItem: @Sendable (URL) throws -> Void

        package init(
            writeAtomically: @escaping @Sendable (Data, URL) throws -> Void,
            removeItem: @escaping @Sendable (URL) throws -> Void
        ) {
            self.writeAtomically = writeAtomically
            self.removeItem = removeItem
        }

        package static let live = FileOperations(
            writeAtomically: { data, url in try data.write(to: url, options: .atomic) },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )
    }

    /// `…/AgentRecovery/v1`.
    package let rootURL: URL
    package nonisolated let appInstanceID: UUID
    /// Publishes every committed record write or deleted-session removal, in commit order.
    package nonisolated let commitPublisher = AgentRecoveryCommitPublisher()
    /// Persistence-boundary fence of this launch's clean mark (spec R4).
    package nonisolated let cleanExitGate = AgentRecoveryCleanExitGate()
    /// Nonisolated and internal so the runtime-record extension (`AgentRecoveryStore+Runtimes.swift`)
    /// shares them; both are immutable.
    nonisolated let fileOperations: FileOperations
    nonisolated let now: @Sendable () -> Date
    /// O51 (G4): when the first launch that ran the ordinary-exit settlement began. Read from the
    /// previous launch mark and written into every launch mark this launch writes, so the
    /// settlement's cohort stays "dispatched before that launch" even if its own marker was never
    /// written. `nil` until a mark is read or written.
    private(set) var ordinaryExitSettlementLaunchCutoff: AgentRecoveryTimestamp?

    package init(
        rootURL: URL,
        appInstanceID: UUID = AgentRecoveryLaunchInstance.currentID,
        fileOperations: FileOperations = .live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.appInstanceID = appInstanceID
        self.fileOperations = fileOperations
        self.now = now
    }

    /// `<Application Support>/RepoPrompt CE/AgentRecovery/v1`. XCTest processes get a temporary
    /// root (the `AgentSessionDataService` tombstone precedent), so tests never touch live data.
    package static func defaultRootURL() -> URL {
        #if DEBUG
            if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPromptCE-XCTest", isDirectory: true)
                    .appendingPathComponent("AgentRecovery-\(UUID().uuidString)", isDirectory: true)
                    .appendingPathComponent("v1", isDirectory: true)
            }
        #endif
        return MCPFilesystemConstants.identity.applicationSupportRootURL()
            .appendingPathComponent("AgentRecovery", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    /// Whether this process composes production recovery: always outside XCTest. XCTest processes
    /// (where windows are constructed by the hundreds and the real workspace index must never be
    /// read or rewritten) compose recovery explicitly with temporary stores instead.
    package static let isProductionCompositionActive: Bool = {
        #if DEBUG
            if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil {
                return false
            }
        #endif
        return true
    }()

    /// `<Application Support>/RepoPrompt CE/AgentRecovery/v1`, resolved once for the production store.
    package static let productionRootURL: URL = defaultRootURL()

    /// The app's single production recovery store (spec R8); `nil` when production composition is
    /// inactive (XCTest).
    package static let production: AgentRecoveryStore? = isProductionCompositionActive
        ? AgentRecoveryStore(rootURL: productionRootURL)
        : nil

    // MARK: Paths

    package nonisolated var sessionsDirectoryURL: URL {
        rootURL.appendingPathComponent("sessions", isDirectory: true)
    }

    package nonisolated func recordFileURL(sessionID: UUID) -> URL {
        sessionsDirectoryURL.appendingPathComponent("\(sessionID.uuidString).json")
    }

    package nonisolated func managedAttachmentDirectoryURL(sessionID: UUID) -> URL {
        rootURL
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    package nonisolated func managedImageURL(sessionID: UUID, fileName: String) -> URL? {
        guard AgentRecoveryRecordCodec.isSafeManagedFileName(fileName) else { return nil }
        return managedAttachmentDirectoryURL(sessionID: sessionID).appendingPathComponent(fileName)
    }

    // MARK: Reads

    package func read(sessionID: UUID) -> AgentRecoveryRecordState {
        let url = recordFileURL(sessionID: sessionID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .absent
        } catch {
            return .preserved(.unreadableFile(String(describing: error)))
        }
        switch AgentRecoveryRecordCodec.decode(data, expectedSessionID: sessionID) {
        case let .success(record):
            return .supported(record)
        case let .failure(reason):
            return .preserved(reason)
        }
    }

    /// Current revision for a writable record (`nil` when absent); throws for preserved data.
    package func currentRevision(sessionID: UUID) throws -> AgentRecoveryRecordRevision? {
        switch read(sessionID: sessionID) {
        case .absent:
            return nil
        case let .supported(record):
            return record.revision
        case let .preserved(reason):
            throw AgentRecoveryStoreError.unreadableRecord(sessionID, reason)
        }
    }

    /// Scans every session record, independent of open tabs or transcript content. Preserves
    /// stored delivery states and computes holds against the record's own generation; it never
    /// rewrites, re-queues, or dispatches.
    package func discoverRecords() throws -> [AgentRecoveryDiscoveryEntry] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: sessionsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw AgentRecoveryStoreError.classifiedStorageFailure(error)
        }
        var entries: [AgentRecoveryDiscoveryEntry] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let sessionID = UUID(uuidString: stem), sessionID.uuidString == stem else {
                entries.append(.preserved(AgentRecoveryPreservedEntry(
                    sessionID: nil,
                    fileURL: url,
                    reason: .malformed("file name is not a session UUID")
                )))
                continue
            }
            switch read(sessionID: sessionID) {
            case .absent:
                continue
            case let .supported(record):
                entries.append(.supported(AgentRecoveryDiscoveredRecord(
                    record: record,
                    holdsByIntentID: derivedHolds(for: record)
                )))
            case let .preserved(reason):
                entries.append(.preserved(AgentRecoveryPreservedEntry(sessionID: sessionID, fileURL: url, reason: reason)))
            }
        }
        return entries
    }

    /// Effective holds: the persisted stale-target marker, a reset-generation mismatch against
    /// `currentGeneration` (authoritative when supplied, else the record's), missing managed
    /// attachments, and a derived previous-instance hold.
    package func derivedHolds(
        for record: AgentRecoveryRecord,
        currentGeneration: UInt64? = nil
    ) -> [UUID: Set<AgentRecoveryHoldReason>] {
        let generation = currentGeneration ?? record.transcriptResetGeneration
        var holds: [UUID: Set<AgentRecoveryHoldReason>] = [:]
        for intent in record.intents where !intent.deliveryState.requiresNoFurtherDelivery {
            let reasons = holdReasons(for: intent, sessionID: record.sessionID, currentGeneration: generation)
            if !reasons.isEmpty {
                holds[intent.intentID] = reasons
            }
        }
        return holds
    }

    func holdReasons(
        for intent: AgentRecoveryIntent,
        sessionID: UUID,
        currentGeneration: UInt64
    ) -> Set<AgentRecoveryHoldReason> {
        var reasons: Set<AgentRecoveryHoldReason> = []
        if intent.appInstanceID != appInstanceID {
            reasons.insert(.previousInstance)
        }
        if intent.staleTargetMarkedAt != nil || intent.transcriptResetGeneration != currentGeneration {
            reasons.insert(.staleTarget)
        }
        if missingManagedImageID(in: intent.payload, sessionID: sessionID) != nil {
            reasons.insert(.missingAttachment)
        }
        return reasons
    }

    // MARK: Composer

    /// Replaces (or removes, for `nil`/empty content) the stored composer if its revision equals
    /// `expectedComposerRevision`. Never removes intents, attempts, or attachments. A snapshot must
    /// carry the binding's reset generation. A stored composer from another reset generation is held
    /// input: it is never replaced or removed here (`heldComposerUnresolved`). A same-generation
    /// replacement keeps unknown members of the composer, its content, and retained entities.
    package func commitComposer(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        expectedComposerRevision: AgentRecoveryComposerRevision?,
        snapshot: AgentRecoveryComposerSnapshot?
    ) throws -> AgentRecoveryLocalReceipt {
        let current = try writableRecord(binding: binding)
        try requireRevision(expectedRevision, current: current)
        if let stored = current?.composer, stored.transcriptResetGeneration != binding.transcriptResetGeneration {
            throw AgentRecoveryStoreError.heldComposerUnresolved(
                revision: stored.revision,
                transcriptResetGeneration: stored.transcriptResetGeneration
            )
        }
        let storedComposerRevision = current?.composer?.revision
        guard storedComposerRevision == expectedComposerRevision else {
            throw AgentRecoveryStoreError.composerRevisionConflict(
                expected: expectedComposerRevision,
                actual: storedComposerRevision
            )
        }
        if let snapshot, snapshot.transcriptResetGeneration != binding.transcriptResetGeneration {
            throw AgentRecoveryStoreError.staleTranscriptResetGeneration(
                binding: binding.transcriptResetGeneration,
                record: snapshot.transcriptResetGeneration
            )
        }
        let newComposer = snapshot.flatMap {
            $0.content.isEmpty ? nil : Self.preservingUnknownMembers(of: current?.composer, in: $0)
        }
        if newComposer == current?.composer {
            return AgentRecoveryLocalReceipt(
                binding: binding,
                recordRevision: current?.revision,
                disposition: .unchanged,
                composerRevision: current?.composer?.revision
            )
        }
        if let newComposer, let missing = missingManagedImageID(in: newComposer.content, sessionID: binding.sessionID) {
            throw AgentRecoveryStoreError.attachmentUnavailable(imageID: missing)
        }
        let record = try replace(
            current,
            binding: binding,
            composer: newComposer,
            intents: current?.intents ?? [],
            attempts: current?.attempts ?? [],
            runAttempts: current?.runAttempts ?? []
        )
        return AgentRecoveryLocalReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: .committed,
            composerRevision: record.composer?.revision
        )
    }

    /// Explicit user resolution of a held composer (stored under another reset generation). Requires
    /// that exact held revision to still be stored. `discard` removes it; `restoreToComposer` stores
    /// the same content as this generation's composer under the supplied revision. Never touches
    /// intents, attempts, or attachments.
    package func resolveHeldComposer(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        heldComposerRevision: AgentRecoveryComposerRevision,
        resolution: AgentRecoveryHeldComposerResolution,
        fence: AgentRecoveryResolutionFence? = nil
    ) throws -> AgentRecoveryLocalReceipt {
        let current = try writableRecord(binding: binding)
        try requireRevision(expectedRevision, current: current)
        guard let current, let stored = current.composer,
              stored.revision == heldComposerRevision,
              stored.transcriptResetGeneration != binding.transcriptResetGeneration
        else {
            throw AgentRecoveryStoreError.composerRevisionConflict(
                expected: heldComposerRevision,
                actual: current?.composer?.revision
            )
        }
        let newComposer: AgentRecoveryComposerSnapshot?
        switch resolution {
        case .discard:
            newComposer = nil
        case let .discardReplacingWith(snapshot):
            guard snapshot.transcriptResetGeneration == binding.transcriptResetGeneration else {
                throw AgentRecoveryStoreError.staleTranscriptResetGeneration(
                    binding: binding.transcriptResetGeneration,
                    record: snapshot.transcriptResetGeneration
                )
            }
            if !snapshot.content.isEmpty,
               let missing = missingManagedImageID(in: snapshot.content, sessionID: binding.sessionID)
            {
                throw AgentRecoveryStoreError.attachmentUnavailable(imageID: missing)
            }
            newComposer = snapshot.content.isEmpty ? nil : snapshot
        case let .restoreToComposer(revision):
            if let missing = missingManagedImageID(in: stored.content, sessionID: binding.sessionID) {
                throw AgentRecoveryStoreError.attachmentUnavailable(imageID: missing)
            }
            newComposer = AgentRecoveryComposerSnapshot(
                revision: revision,
                capturedAt: AgentRecoveryTimestamp(now()),
                transcriptResetGeneration: binding.transcriptResetGeneration,
                content: stored.content,
                extras: stored.extras
            )
        }
        if let fence, !fence.commitIfUntripped() {
            throw AgentRecoveryStoreError.heldResolutionSuperseded
        }
        let record = try replace(
            current,
            binding: binding,
            composer: newComposer,
            intents: current.intents,
            attempts: current.attempts,
            runAttempts: current.runAttempts
        )
        return AgentRecoveryLocalReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: .committed,
            composerRevision: record.composer?.revision
        )
    }

    /// Conditional held-slot replacement: puts `held` back in place of the composer an explicit
    /// restore just stored (`restoredRevision`, this generation), when a composer change raced that
    /// restore's commit. Refuses if anything else replaced the restored composer since.
    package func revertHeldComposerRestore(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        restoredRevision: AgentRecoveryComposerRevision,
        held: AgentRecoveryComposerSnapshot
    ) throws -> AgentRecoveryLocalReceipt {
        let current = try writableRecord(binding: binding)
        try requireRevision(expectedRevision, current: current)
        guard let current, let stored = current.composer,
              stored.revision == restoredRevision,
              stored.transcriptResetGeneration == binding.transcriptResetGeneration,
              held.transcriptResetGeneration != binding.transcriptResetGeneration
        else {
            throw AgentRecoveryStoreError.composerRevisionConflict(
                expected: restoredRevision,
                actual: current?.composer?.revision
            )
        }
        let record = try replace(
            current,
            binding: binding,
            composer: held,
            intents: current.intents,
            attempts: current.attempts,
            runAttempts: current.runAttempts
        )
        return AgentRecoveryLocalReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: .committed,
            composerRevision: record.composer?.revision
        )
    }

    // MARK: Submissions

    /// Commits a `queued` intent (no handoff has begun) and, in the same replacement, conditionally
    /// consumes the stored composer. An identical repeat revalidates that the intent is still
    /// queued and unheld before reissuing its receipt; it never consumes again.
    package func commitQueuedIntent(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        submission: AgentRecoveryIntentSubmission,
        consumption: AgentRecoveryComposerConsumption?
    ) throws -> AgentRecoveryQueueReceipt {
        let current = try writableRecord(binding: binding)
        if let current, let existing = current.intent(id: submission.intentID) {
            try requireIdenticalSubmission(existing, submission)
            return try queueReceipt(for: existing, in: current, binding: binding, disposition: .unchanged)
        }
        let (record, intent, consumed) = try insertIntent(
            current,
            binding: binding,
            expectedRevision: expectedRevision,
            submission: submission,
            start: nil,
            consumption: consumption
        )
        return AgentRecoveryQueueReceipt(
            intent: intentReceipt(intent, record: record, binding: binding, disposition: .committed, composerConsumed: consumed),
            owningAppInstanceID: intent.appInstanceID
        )
    }

    /// Commits a `dispatching` intent and its delivery attempt in one replacement, before any
    /// handoff, conditionally consuming the stored composer. An identical repeat reissues the
    /// receipt only while that exact attempt (same run/turn association) is still open.
    package func commitDispatchingIntent(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        submission: AgentRecoveryIntentSubmission,
        attempt start: AgentRecoveryAttemptStart,
        consumption: AgentRecoveryComposerConsumption?
    ) throws -> AgentRecoveryDispatchReceipt {
        let current = try writableRecord(binding: binding)
        if let current, let existing = current.intent(id: submission.intentID) {
            try requireIdenticalSubmission(existing, submission)
            guard current.attempts.contains(where: { $0.attemptID == start.attemptID }) else {
                throw AgentRecoveryStoreError.intentConflict(submission.intentID)
            }
            return try dispatchReceipt(for: existing, start: start, in: current, binding: binding, disposition: .unchanged)
        }
        let (record, intent, consumed) = try insertIntent(
            current,
            binding: binding,
            expectedRevision: expectedRevision,
            submission: submission,
            start: start,
            consumption: consumption
        )
        return AgentRecoveryDispatchReceipt(
            intent: intentReceipt(intent, record: record, binding: binding, disposition: .committed, composerConsumed: consumed),
            attemptID: start.attemptID
        )
    }

    /// Attaches the exact pending-handoff snapshot to an existing intent before its next handoff, so
    /// the dispatching attempt that follows (`beginDispatch`/`beginDispatches`) carries it. A first
    /// attachment is allowed only while the intent is `queued` and every earlier delivery attempt of
    /// it is conclusively not delivered (`hasOnlyAffirmativeNonDelivery`); zero attempts qualifies.
    /// Any open, unknown, accepted or superseded attempt evidence refuses it (`invalidTransition`),
    /// and no attempt is rewritten. An identical snapshot (unknown members ignored) is unchanged in
    /// any state and writes nothing (it does not by itself authorize a dispatch); a different
    /// snapshot never replaces the attached one (`intentConflict`). Intent identity, payload, target,
    /// delivery state, attempts, and holds are kept.
    package func attachPendingHandoff(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        intentID: UUID,
        snapshot: AgentRecoveryPendingHandoffSnapshot
    ) throws -> AgentRecoveryIntentReceipt {
        let (current, existingIntent) = try requireIntent(binding: binding, intentID: intentID)
        if let attached = existingIntent.pendingHandoff {
            guard attached.hasSameContent(as: snapshot) else {
                throw AgentRecoveryStoreError.intentConflict(intentID)
            }
            return intentReceipt(existingIntent, record: current, binding: binding, disposition: .unchanged)
        }
        guard existingIntent.deliveryState == .queued,
              Self.hasOnlyAffirmativeNonDelivery(current.attempts(forIntent: intentID))
        else {
            throw AgentRecoveryStoreError.invalidTransition(
                intentID: intentID,
                from: existingIntent.deliveryState,
                operation: .attachPendingHandoff
            )
        }
        try requireRevision(expectedRevision, current: current)
        var intent = existingIntent
        intent.pendingHandoff = snapshot
        let record = try rewrite(current, binding: binding, intents: replacing(intent, in: current))
        return intentReceipt(intent, record: record, binding: binding, disposition: .committed)
    }

    /// Whether every attempt is closed with affirmative non-delivery evidence: the handoff provably
    /// never began (`preHandoff`) or the provider verifiably rejected it (`verifiedRejection`), with
    /// no superseded evidence. An open attempt, `deliveryUnknown`, `providerAccepted`, or any
    /// `supersededOutcome` (which only accompanies a contradicting acceptance) disqualifies the whole
    /// history. Zero attempts qualifies.
    static func hasOnlyAffirmativeNonDelivery(_ attempts: [AgentRecoveryAttempt]) -> Bool {
        attempts.allSatisfy { attempt in
            guard attempt.supersededOutcome == nil, let recorded = attempt.outcome else { return false }
            switch recorded.outcome {
            case .failed(.preHandoff, _), .failed(.verifiedRejection, _):
                return true
            case .providerAccepted, .deliveryUnknown:
                return false
            }
        }
    }

    /// Reissues a queue receipt for a durable intent only if it is currently `queued` with no hold
    /// (for example after a qualified settle-to-queue). Writes nothing.
    package func issueQueueReceipt(
        binding: AgentRecoveryLifecycleBinding,
        intentID: UUID
    ) throws -> AgentRecoveryQueueReceipt {
        let (current, intent) = try requireIntent(binding: binding, intentID: intentID)
        return try queueReceipt(for: intent, in: current, binding: binding, disposition: .unchanged)
    }

    /// CAS an eligible intent to `dispatching` and persist its attempt in the same replacement.
    /// Live queues drain only their own instance's unheld `queued` intents. An explicit user action
    /// may also dispatch `failed` or `deliveryUnknown` intents and claim previous-instance ones, but
    /// never bypasses a stale target or a missing attachment.
    package func beginDispatch(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        intentID: UUID,
        attempt start: AgentRecoveryAttemptStart,
        authorization: AgentRecoveryDispatchAuthorization
    ) throws -> AgentRecoveryDispatchReceipt {
        let (current, existingIntent) = try requireIntent(binding: binding, intentID: intentID)
        if current.attempts.contains(where: { $0.attemptID == start.attemptID }) {
            return try dispatchReceipt(for: existingIntent, start: start, in: current, binding: binding, disposition: .unchanged)
        }
        try requireRevision(expectedRevision, current: current)
        let intent = try dispatchingIntent(existingIntent, in: current, binding: binding, authorization: authorization)
        var attempts = current.attempts
        attempts.append(makeAttempt(start, intentID: intentID, userItemID: intent.userItemID, at: AgentRecoveryTimestamp(now())))
        let record = try rewrite(current, binding: binding, intents: replacing(intent, in: current), attempts: attempts)
        return try dispatchReceipt(for: intent, start: start, in: record, binding: binding, disposition: .committed)
    }

    /// Atomic form of `beginDispatch` for one combined provider handoff (ACP steering coalescing).
    /// Every constituent, in the given order, moves to `dispatching` with its own attempt in a single
    /// replacement, or nothing is written. Receipts are returned in the same order. An exact repeat
    /// of the whole batch is unchanged; a partial repeat, an empty batch, or a repeated intent or
    /// attempt ID conflicts.
    package func beginDispatches(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        dispatches: [AgentRecoveryDispatchRequest],
        authorization: AgentRecoveryDispatchAuthorization
    ) throws -> [AgentRecoveryDispatchReceipt] {
        guard let first = dispatches.first else {
            throw AgentRecoveryStoreError.attemptConflict(UUID())
        }
        guard Set(dispatches.map(\.intentID)).count == dispatches.count,
              Set(dispatches.map(\.attempt.attemptID)).count == dispatches.count
        else {
            throw AgentRecoveryStoreError.attemptConflict(first.attempt.attemptID)
        }
        guard let current = try writableRecord(binding: binding) else {
            throw AgentRecoveryStoreError.intentNotFound(first.intentID)
        }
        var existing: [AgentRecoveryIntent] = []
        for dispatch in dispatches {
            guard let intent = current.intent(id: dispatch.intentID) else {
                throw AgentRecoveryStoreError.intentNotFound(dispatch.intentID)
            }
            existing.append(intent)
        }
        let repeated = dispatches.filter { dispatch in
            current.attempts.contains(where: { $0.attemptID == dispatch.attempt.attemptID })
        }
        if repeated.count == dispatches.count {
            return try zip(existing, dispatches).map { intent, dispatch in
                try dispatchReceipt(for: intent, start: dispatch.attempt, in: current, binding: binding, disposition: .unchanged)
            }
        }
        guard repeated.isEmpty else {
            throw AgentRecoveryStoreError.attemptConflict(repeated[0].attempt.attemptID)
        }
        try requireRevision(expectedRevision, current: current)
        let timestamp = AgentRecoveryTimestamp(now())
        var intents = current.intents
        var attempts = current.attempts
        var dispatching: [AgentRecoveryIntent] = []
        for (intent, dispatch) in zip(existing, dispatches) {
            let next = try dispatchingIntent(intent, in: current, binding: binding, authorization: authorization)
            intents = intents.map { $0.intentID == next.intentID ? next : $0 }
            attempts.append(makeAttempt(dispatch.attempt, intentID: next.intentID, userItemID: next.userItemID, at: timestamp))
            dispatching.append(next)
        }
        let record = try rewrite(current, binding: binding, intents: intents, attempts: attempts)
        return try zip(dispatching, dispatches).map { intent, dispatch in
            try dispatchReceipt(for: intent, start: dispatch.attempt, in: record, binding: binding, disposition: .committed)
        }
    }

    /// The `dispatching` form of an eligible intent under `authorization`, or the hold/transition error.
    private func dispatchingIntent(
        _ existingIntent: AgentRecoveryIntent,
        in current: AgentRecoveryRecord,
        binding: AgentRecoveryLifecycleBinding,
        authorization: AgentRecoveryDispatchAuthorization
    ) throws -> AgentRecoveryIntent {
        let intentID = existingIntent.intentID
        let holds = holdReasons(for: existingIntent, sessionID: current.sessionID, currentGeneration: binding.transcriptResetGeneration)
        switch (existingIntent.deliveryState, authorization) {
        case (.queued, .liveQueue):
            guard holds.isEmpty else {
                throw AgentRecoveryStoreError.heldIntent(intentID: intentID, holds: holds)
            }
        case (.queued, .explicitUserAction), (.failed, .explicitUserAction), (.deliveryUnknown, .explicitUserAction):
            let blocking = holds.subtracting([.previousInstance])
            guard blocking.isEmpty else {
                throw AgentRecoveryStoreError.heldIntent(intentID: intentID, holds: blocking)
            }
        default:
            throw AgentRecoveryStoreError.invalidTransition(
                intentID: intentID,
                from: existingIntent.deliveryState,
                operation: .beginDispatch
            )
        }
        var intent = existingIntent
        intent.deliveryState = .dispatching
        intent.appInstanceID = appInstanceID
        return intent
    }

    // MARK: Delivery evidence

    /// Records delivery evidence for one exact attempt. Rules:
    /// - an open attempt takes any outcome; a dispatching intent moves to the resulting state;
    /// - identical repeated evidence is unchanged;
    /// - affirmative acceptance refines earlier `deliveryUnknown`, or supersedes earlier `failed`
    ///   evidence (kept as `supersededOutcome`, exposing the conflict), and makes the intent
    ///   `providerAccepted` even if a later attempt has begun or the intent was settled or withdrawn;
    /// - recorded acceptance is never overwritten, and other conflicting evidence is rejected.
    package func recordDeliveryOutcome(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        intentID: UUID,
        attemptID: UUID,
        outcome: AgentRecoveryDeliveryOutcome
    ) throws -> AgentRecoveryOutcomeReceipt {
        let (current, existingIntent) = try requireIntent(binding: binding, intentID: intentID)
        let attemptIndex = try requireAttemptIndex(attemptID, intentID: intentID, in: current)
        var attempt = current.attempts[attemptIndex]
        var superseded: AgentRecoveryAttemptOutcome?
        if let recorded = attempt.outcome {
            if recorded.outcome == outcome {
                return AgentRecoveryOutcomeReceipt(
                    intent: intentReceipt(existingIntent, record: current, binding: binding, disposition: .unchanged),
                    attemptID: attemptID,
                    outcome: outcome,
                    supersededOutcome: attempt.supersededOutcome?.outcome
                )
            }
            guard outcome == .providerAccepted, recorded.outcome != .providerAccepted else {
                throw AgentRecoveryStoreError.attemptConflict(attemptID)
            }
            superseded = recorded
        }
        try requireRevision(expectedRevision, current: current)
        var intent = existingIntent
        attempt.outcome = AgentRecoveryAttemptOutcome(outcome: outcome, recordedAt: AgentRecoveryTimestamp(now()))
        if let superseded {
            attempt.supersededOutcome = superseded
        }
        if outcome == .providerAccepted {
            intent.deliveryState = .providerAccepted
        } else if intent.deliveryState == .dispatching {
            intent.deliveryState = outcome.resultingState
        }
        // Otherwise the intent was already accepted through an earlier attempt and stays accepted.
        var attempts = current.attempts
        attempts[attemptIndex] = attempt
        let record = try rewrite(current, binding: binding, intents: replacing(intent, in: current), attempts: attempts)
        return AgentRecoveryOutcomeReceipt(
            intent: intentReceipt(intent, record: record, binding: binding, disposition: .committed),
            attemptID: attemptID,
            outcome: outcome,
            supersededOutcome: superseded?.outcome
        )
    }

    /// Qualified no-handoff fallback: with affirmative non-acceptance evidence for the exact open
    /// attempt (handoff never began, or verified rejection), closes that attempt with the failure
    /// and returns the same intent (same intent and user-item IDs, payload, target, holds) to
    /// `queued` in one replacement. Never applies to accepted or delivery-unknown evidence. A
    /// latest attempt already closed with the same failure may also be settled from `failed`.
    package func settleToQueue(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        intentID: UUID,
        attemptID: UUID,
        evidence: AgentRecoveryFailureKind,
        message: String?
    ) throws -> AgentRecoveryIntentReceipt {
        let (current, existingIntent) = try requireIntent(binding: binding, intentID: intentID)
        let attemptIndex = try requireAttemptIndex(attemptID, intentID: intentID, in: current)
        var attempt = current.attempts[attemptIndex]
        let failure = AgentRecoveryDeliveryOutcome.failed(evidence, message: message)
        let invalid = AgentRecoveryStoreError.invalidTransition(
            intentID: intentID,
            from: existingIntent.deliveryState,
            operation: .settleToQueue
        )
        if let recorded = attempt.outcome {
            let isLatest = current.attempts(forIntent: intentID).last?.attemptID == attemptID
            guard recorded.outcome == failure, isLatest else { throw invalid }
            switch existingIntent.deliveryState {
            case .queued:
                return intentReceipt(existingIntent, record: current, binding: binding, disposition: .unchanged)
            case .failed:
                break
            default:
                throw invalid
            }
        } else {
            guard existingIntent.deliveryState == .dispatching else { throw invalid }
            attempt.outcome = AgentRecoveryAttemptOutcome(outcome: failure, recordedAt: AgentRecoveryTimestamp(now()))
        }
        try requireRevision(expectedRevision, current: current)
        var intent = existingIntent
        intent.deliveryState = .queued
        var attempts = current.attempts
        attempts[attemptIndex] = attempt
        let record = try rewrite(current, binding: binding, intents: replacing(intent, in: current), attempts: attempts)
        return intentReceipt(intent, record: record, binding: binding, disposition: .committed)
    }

    /// Persists the stale-target hold after the captured target was lost. Preserves payload, IDs,
    /// attempts, and delivery state; idempotent.
    package func markTargetStale(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        intentID: UUID
    ) throws -> AgentRecoveryIntentReceipt {
        let (current, existingIntent) = try requireIntent(binding: binding, intentID: intentID)
        if existingIntent.staleTargetMarkedAt != nil {
            return intentReceipt(existingIntent, record: current, binding: binding, disposition: .unchanged)
        }
        guard !existingIntent.deliveryState.requiresNoFurtherDelivery else {
            throw AgentRecoveryStoreError.invalidTransition(
                intentID: intentID,
                from: existingIntent.deliveryState,
                operation: .markTargetStale
            )
        }
        try requireRevision(expectedRevision, current: current)
        var intent = existingIntent
        intent.staleTargetMarkedAt = AgentRecoveryTimestamp(now())
        let record = try rewrite(current, binding: binding, intents: replacing(intent, in: current))
        return intentReceipt(intent, record: record, binding: binding, disposition: .committed)
    }

    /// R10: persists the explicit "Cancel pending schedule" decision on the intent linked to that
    /// exact schedule attempt (its own `.scheduled` schedule reference; any mismatch is refused).
    /// Delivery state, attempts and outcomes are unchanged. An identical decision is unchanged; a
    /// decision for another schedule attempt is never replaced.
    package func recordScheduledTransferCancellation(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        intentID: UUID,
        scheduleID: UUID,
        scheduleAttemptID: UUID
    ) throws -> AgentRecoveryIntentReceipt {
        let (current, existingIntent) = try requireIntent(binding: binding, intentID: intentID)
        guard existingIntent.origin == .scheduled,
              existingIntent.scheduleReference?.scheduleID == scheduleID,
              existingIntent.scheduleReference?.scheduleAttemptID == scheduleAttemptID
        else {
            throw AgentRecoveryStoreError.intentConflict(intentID)
        }
        if let existing = existingIntent.scheduledTransferCancellation {
            guard existing.matches(scheduleID: scheduleID, scheduleAttemptID: scheduleAttemptID) else {
                throw AgentRecoveryStoreError.intentConflict(intentID)
            }
            return intentReceipt(existingIntent, record: current, binding: binding, disposition: .unchanged)
        }
        try requireRevision(expectedRevision, current: current)
        var intent = existingIntent
        intent.scheduledTransferCancellation = AgentRecoveryScheduledTransferCancellation(
            decisionID: UUID(),
            scheduleID: scheduleID,
            scheduleAttemptID: scheduleAttemptID,
            recordedAt: AgentRecoveryTimestamp(now())
        )
        let record = try rewrite(current, binding: binding, intents: replacing(intent, in: current))
        return intentReceipt(intent, record: record, binding: binding, disposition: .committed)
    }

    /// Explicit user removal: persists `withdrawn` and keeps the payload. Allowed only before or
    /// after a handoff, never while one may be in progress or after acceptance.
    package func withdraw(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        intentID: UUID
    ) throws -> AgentRecoveryIntentReceipt {
        let (current, existingIntent) = try requireIntent(binding: binding, intentID: intentID)
        if existingIntent.deliveryState == .withdrawn {
            return intentReceipt(existingIntent, record: current, binding: binding, disposition: .unchanged)
        }
        try requireRevision(expectedRevision, current: current)
        switch existingIntent.deliveryState {
        case .queued, .failed, .deliveryUnknown:
            break
        case .dispatching, .providerAccepted, .withdrawn:
            throw AgentRecoveryStoreError.invalidTransition(
                intentID: intentID,
                from: existingIntent.deliveryState,
                operation: .withdraw
            )
        }
        var intent = existingIntent
        intent.deliveryState = .withdrawn
        intent.withdrawnAt = AgentRecoveryTimestamp(now())
        let record = try rewrite(current, binding: binding, intents: replacing(intent, in: current))
        return intentReceipt(intent, record: record, binding: binding, disposition: .committed)
    }

    // MARK: Run-attempt evidence

    /// The run-start extras of a newly recorded attempt: its provider and its registration mark.
    private static func runStartExtras(providerKindRaw: String?, runtimeRegistrationRaw: String?) -> AgentRecoveryExtras {
        var extras: AgentRecoveryExtras = [:]
        if let providerKindRaw {
            extras[AgentRecoveryRunAttempt.providerKindExtrasKey] = .string(providerKindRaw)
        }
        if let runtimeRegistrationRaw {
            extras[AgentRecoveryRunAttempt.runtimeRegistrationExtrasKey] = .string(runtimeRegistrationRaw)
        }
        return extras
    }

    /// Ensures evidence for the existing run attempt `ownership.attemptID`, capturing the binding's
    /// reset generation. A process-run or transcript-turn association may be completed later.
    /// The transcript turn is the first one recorded (the turn the run's first carried input opened);
    /// a later different turn keeps it. A conflicting process run fails, unless `processRunAssociation`
    /// is `.keepExisting` (terminal-time completion, which never fails on an existing association).
    /// `providerKindRaw` is run-start evidence written only when the attempt is first recorded
    /// (extras member `providerKind`); an existing attempt's (or a legacy attempt's absent) provider
    /// is never rewritten. `runtimeRegistrationRaw` (extras member `runtimeRegistration`) is the same
    /// kind of run-start evidence: only the creator that precedes the run's first provider write
    /// passes it, every other writer passes `nil`, and it is never added to or removed from an
    /// existing attempt.
    package func ensureRunAttempt(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        ownership: AgentRunOwnership,
        processRunID: UUID?,
        transcriptTurnID: UUID?,
        processRunAssociation: AgentRecoveryRunAssociationPolicy = .strict,
        providerKindRaw: String?,
        runtimeRegistrationRaw: String? = nil
    ) throws -> AgentRecoveryRunReceipt {
        try requireOwnership(ownership, binding: binding)
        let current = try writableRecord(binding: binding)
        let runAttemptID = ownership.attemptID
        var runAttempts = current?.runAttempts ?? []
        if let index = runAttempts.firstIndex(where: { $0.runAttemptID == runAttemptID }) {
            let existing = runAttempts[index]
            guard existing.transcriptResetGeneration == binding.transcriptResetGeneration else {
                throw AgentRecoveryStoreError.runAttemptConflict(runAttemptID)
            }
            var updated = existing
            switch processRunAssociation {
            case .strict:
                try fill(&updated.processRunID, with: processRunID, runAttemptID: runAttemptID)
            case .keepExisting:
                if updated.processRunID == nil { updated.processRunID = processRunID }
            }
            if updated.transcriptTurnID == nil { updated.transcriptTurnID = transcriptTurnID }
            if let current, updated == existing {
                return runReceipt(runAttemptID, record: current, binding: binding, disposition: .unchanged)
            }
            runAttempts[index] = updated
        } else {
            runAttempts.append(AgentRecoveryRunAttempt(
                runAttemptID: runAttemptID,
                transcriptResetGeneration: binding.transcriptResetGeneration,
                processRunID: processRunID,
                transcriptTurnID: transcriptTurnID,
                startedAt: AgentRecoveryTimestamp(now()),
                // Run-start ownership evidence; an existing attempt's (or a legacy attempt's
                // absent) instance is never rewritten.
                appInstanceID: appInstanceID,
                extras: Self.runStartExtras(providerKindRaw: providerKindRaw, runtimeRegistrationRaw: runtimeRegistrationRaw)
            ))
        }
        try requireRevision(expectedRevision, current: current)
        let record = try replace(
            current,
            binding: binding,
            composer: current?.composer,
            intents: current?.intents ?? [],
            attempts: current?.attempts ?? [],
            runAttempts: runAttempts
        )
        return runReceipt(runAttemptID, record: record, binding: binding, disposition: .committed)
    }

    /// Associates a delivery attempt with its existing run attempt once ownership is available.
    package func attachDeliveryAttempt(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        attemptID: UUID,
        ownership: AgentRunOwnership
    ) throws -> AgentRecoveryRunReceipt {
        try requireOwnership(ownership, binding: binding)
        guard let current = try writableRecord(binding: binding),
              let attemptIndex = current.attempts.firstIndex(where: { $0.attemptID == attemptID })
        else {
            throw AgentRecoveryStoreError.attemptNotFound(attemptID)
        }
        let runAttemptID = ownership.attemptID
        guard current.runAttempt(id: runAttemptID) != nil else {
            throw AgentRecoveryStoreError.runAttemptNotFound(runAttemptID)
        }
        var attempt = current.attempts[attemptIndex]
        if let existing = attempt.runAttemptID {
            guard existing == runAttemptID else {
                throw AgentRecoveryStoreError.attemptConflict(attemptID)
            }
            return runReceipt(runAttemptID, record: current, binding: binding, disposition: .unchanged)
        }
        try requireRevision(expectedRevision, current: current)
        attempt.runAttemptID = runAttemptID
        var attempts = current.attempts
        attempts[attemptIndex] = attempt
        let record = try rewrite(current, binding: binding, attempts: attempts)
        return runReceipt(runAttemptID, record: record, binding: binding, disposition: .committed)
    }

    /// Records the provider's native turn ID on the existing run attempt `ownership.attemptID`
    /// (extras member `providerTurnID`, 9-live R2). Last-wins: a different ID rewrites it and `nil`
    /// clears it to an explicit JSON `null` marker (a non-user turn became authoritative; the key
    /// stays present, so no span fallback applies), written even when no ID was recorded before.
    /// An identical value (ID or marker) is unchanged. An attempt
    /// from another transcript generation is a conflict; a missing attempt is not created here (the
    /// dispatch commit creates it before the provider write).
    package func recordRunProviderTurn(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        ownership: AgentRunOwnership,
        providerTurnID: String?
    ) throws -> AgentRecoveryRunReceipt {
        let runAttemptID = ownership.attemptID
        try requireOwnership(ownership, binding: binding)
        let (current, index) = try requireRunAttemptIndex(runAttemptID, binding: binding)
        var run = current.runAttempts[index]
        guard run.transcriptResetGeneration == binding.transcriptResetGeneration else {
            throw AgentRecoveryStoreError.runAttemptConflict(runAttemptID)
        }
        let value: AgentRecoveryJSONValue = providerTurnID.map { .string($0) } ?? .null
        if run.extras[AgentRecoveryRunAttempt.providerTurnIDExtrasKey] == value {
            return runReceipt(runAttemptID, record: current, binding: binding, disposition: .unchanged)
        }
        try requireRevision(expectedRevision, current: current)
        run.extras[AgentRecoveryRunAttempt.providerTurnIDExtrasKey] = value
        var runAttempts = current.runAttempts
        runAttempts[index] = run
        let record = try rewrite(current, binding: binding, runAttempts: runAttempts)
        return runReceipt(runAttemptID, record: record, binding: binding, disposition: .committed)
    }

    /// Records terminal evidence from the terminal commit barrier's revision (commit ID, terminal
    /// state, expected process run), with or without an MCP publication envelope. Identical repeats
    /// are unchanged; a different commit for the same run attempt fails.
    package func recordRunTerminal(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        commit: AgentRunTerminalCommitRevision
    ) throws -> AgentRecoveryRunReceipt {
        let runAttemptID = commit.ownership.attemptID
        try requireOwnership(commit.ownership, binding: binding)
        guard commit.terminalState.isTerminalForCommit else {
            throw AgentRecoveryStoreError.runAttemptConflict(runAttemptID)
        }
        let (current, index) = try requireRunAttemptIndex(runAttemptID, binding: binding)
        var run = current.runAttempts[index]
        if let terminal = run.terminal {
            guard terminal.commitID == commit.commitID,
                  terminal.terminalState == commit.terminalState,
                  terminal.expectedRunID == commit.expectedRunID,
                  terminal.cause == commit.cause
            else {
                throw AgentRecoveryStoreError.runAttemptConflict(runAttemptID)
            }
            return runReceipt(runAttemptID, record: current, binding: binding, disposition: .unchanged)
        }
        try requireRevision(expectedRevision, current: current)
        run.terminal = AgentRecoveryRunTerminalEvidence(
            commitID: commit.commitID,
            terminalState: commit.terminalState,
            expectedRunID: commit.expectedRunID,
            recordedAt: AgentRecoveryTimestamp(now()),
            cause: commit.cause
        )
        var runAttempts = current.runAttempts
        runAttempts[index] = run
        let record = try rewrite(current, binding: binding, runAttempts: runAttempts)
        return runReceipt(runAttemptID, record: record, binding: binding, disposition: .committed)
    }

    /// Records the run attempt's shutdown or close reason. The first recorded reason is kept; an
    /// identical repeat is unchanged and a different reason fails.
    package func recordRunShutdown(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        runAttemptID: UUID,
        reason: AgentRecoveryShutdownReason,
        lastConfirmedActivityAt: Date?
    ) throws -> AgentRecoveryRunReceipt {
        let (current, index) = try requireRunAttemptIndex(runAttemptID, binding: binding)
        var run = current.runAttempts[index]
        if let shutdown = run.shutdown {
            guard shutdown.reason == reason else {
                throw AgentRecoveryStoreError.runAttemptConflict(runAttemptID)
            }
            return runReceipt(runAttemptID, record: current, binding: binding, disposition: .unchanged)
        }
        try requireRevision(expectedRevision, current: current)
        run.shutdown = AgentRecoveryRunShutdownEvidence(
            reason: reason,
            observedAt: AgentRecoveryTimestamp(now()),
            lastConfirmedActivityAt: lastConfirmedActivityAt.map(AgentRecoveryTimestamp.init)
        )
        var runAttempts = current.runAttempts
        runAttempts[index] = run
        let record = try rewrite(current, binding: binding, runAttempts: runAttempts)
        return runReceipt(runAttemptID, record: record, binding: binding, disposition: .committed)
    }

    // MARK: Managed attachments

    /// Copies an image into this session's durable attachment directory using the existing import
    /// validation. The copy must complete before any record references it; nothing is committed here.
    /// A source already in this session's managed directory is referenced in place (no copy); if that
    /// managed file is missing, the import fails with `attachmentUnavailable`.
    package func importManagedImage(
        sessionID: UUID,
        sourceURL: URL,
        id: UUID = UUID(),
        title: String? = nil,
        createdAt: Date? = nil
    ) throws -> AgentRecoveryImageReference {
        if let fileName = managedFileName(of: sourceURL, sessionID: sessionID) {
            guard let url = managedImageURL(sessionID: sessionID, fileName: fileName),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                throw AgentRecoveryStoreError.attachmentUnavailable(imageID: id)
            }
            return AgentRecoveryImageReference(
                id: id,
                location: .managedFile(fileName: fileName),
                title: title ?? fileName,
                createdAt: AgentRecoveryTimestamp(createdAt ?? now())
            )
        }
        let result: AgentAttachmentStore.ImportResult
        do {
            result = try AgentAttachmentStore().importImageFile(
                sourceURL: sourceURL,
                storageRoot: managedAttachmentDirectoryURL(sessionID: sessionID)
            )
        } catch {
            throw AgentRecoveryStoreError.attachmentImportFailed(error.localizedDescription)
        }
        return AgentRecoveryImageReference(
            id: id,
            location: .managedFile(fileName: result.fileURL.lastPathComponent),
            title: title ?? result.attachment.title,
            createdAt: AgentRecoveryTimestamp(createdAt ?? result.attachment.createdAt)
        )
    }

    /// Durable reference for an existing composer attachment: local files are copied into managed
    /// recovery storage, remote URLs are kept as references.
    package func importManagedImage(sessionID: UUID, attachment: AgentImageAttachment) throws -> AgentRecoveryImageReference {
        switch attachment.source {
        case let .localFile(path):
            try importManagedImage(
                sessionID: sessionID,
                sourceURL: URL(fileURLWithPath: path),
                id: attachment.id,
                title: attachment.title,
                createdAt: attachment.createdAt
            )
        case let .url(url):
            AgentRecoveryImageReference(
                id: attachment.id,
                location: .remoteURL(url),
                title: attachment.title,
                createdAt: AgentRecoveryTimestamp(attachment.createdAt)
            )
        }
    }

    /// The managed file name when `sourceURL` is directly inside this session's attachment directory.
    private nonisolated func managedFileName(of sourceURL: URL, sessionID: UUID) -> String? {
        guard sourceURL.isFileURL else { return nil }
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = managedAttachmentDirectoryURL(sessionID: sessionID).standardizedFileURL.resolvingSymlinksInPath()
        let fileName = source.lastPathComponent
        guard source.deletingLastPathComponent().standardizedFileURL.path == directory.path,
              AgentRecoveryRecordCodec.isSafeManagedFileName(fileName)
        else {
            return nil
        }
        return fileName
    }

    /// Durable reference for a live attachment that is already managed by this session (or remote),
    /// without copying; `nil` for a local file outside managed storage (it must be imported first).
    package nonisolated func existingImageReference(
        for attachment: AgentImageAttachment,
        sessionID: UUID
    ) -> AgentRecoveryImageReference? {
        let location: AgentRecoveryImageReference.Location
        switch attachment.source {
        case let .localFile(path):
            guard let fileName = managedFileName(of: URL(fileURLWithPath: path), sessionID: sessionID) else {
                return nil
            }
            location = .managedFile(fileName: fileName)
        case let .url(url):
            location = .remoteURL(url)
        }
        return AgentRecoveryImageReference(
            id: attachment.id,
            location: location,
            title: attachment.title,
            createdAt: AgentRecoveryTimestamp(attachment.createdAt)
        )
    }

    /// Live attachment for a durable reference (managed files resolve into recovery storage).
    package nonisolated func attachment(for reference: AgentRecoveryImageReference, sessionID: UUID) -> AgentImageAttachment? {
        let source: AgentImageSource
        switch reference.location {
        case let .managedFile(fileName):
            guard let url = managedImageURL(sessionID: sessionID, fileName: fileName) else { return nil }
            source = .localFile(path: url.path)
        case let .remoteURL(url):
            source = .url(url)
        }
        return AgentImageAttachment(id: reference.id, source: source, title: reference.title, createdAt: reference.createdAt.date)
    }

    package func managedImageRecordReference(sessionID: UUID, fileName: String) -> AgentRecoveryManagedImageRecordReference {
        guard AgentRecoveryRecordCodec.isSafeManagedFileName(fileName) else { return .unknown }
        switch read(sessionID: sessionID) {
        case .absent:
            return .notReferencedByRecord
        case let .supported(record):
            return record.referencedManagedImageFileNames.contains(fileName) ? .referencedByRecord : .notReferencedByRecord
        case .preserved:
            return .unknown
        }
    }

    // MARK: Launch state

    package nonisolated var launchStateFileURL: URL {
        rootURL.appendingPathComponent("launch-state.json")
    }

    /// Reads the previous launch's mark. Call before `recordCurrentLaunchRunning()` replaces it.
    package func readLaunchMark() -> AgentRecoveryPreviousLaunch {
        let data: Data
        do {
            data = try Data(contentsOf: launchStateFileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .none
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .none
        } catch {
            return .unreadable(String(describing: error))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schemaVersion"] as? Int) == 1,
              let instanceString = object["appInstanceID"] as? String,
              let instanceID = UUID(uuidString: instanceString),
              let stateString = object["state"] as? String,
              let state = AgentRecoveryLaunchMark.State(rawValue: stateString),
              let recordedAt = (object["recordedAtMs"] as? NSNumber)?.int64Value
        else {
            return .unreadable("malformed or future launch mark")
        }
        if ordinaryExitSettlementLaunchCutoff == nil,
           let carried = (object[Self.ordinaryExitSettlementCutoffLaunchKey] as? NSNumber)?.int64Value
        {
            ordinaryExitSettlementLaunchCutoff = AgentRecoveryTimestamp(millisecondsSince1970: carried)
        }
        return .mark(AgentRecoveryLaunchMark(
            appInstanceID: instanceID,
            state: state,
            recordedAt: AgentRecoveryTimestamp(millisecondsSince1970: recordedAt)
        ))
    }

    /// Persists this instance's unclean `running` mark (atomic replace).
    package func recordCurrentLaunchRunning() throws -> AgentRecoveryLaunchMark {
        try recordCurrentLaunch(.running)
    }

    /// Persists this instance's unclean launch mark (atomic replace). `cleanExit` is written only
    /// through `recordCleanExit(authorization:)`; a committed unclean mark replaces any clean one.
    package func recordCurrentLaunch(_ state: AgentRecoveryLaunchMark.State) throws -> AgentRecoveryLaunchMark {
        guard state != .cleanExit else {
            throw AgentRecoveryStoreError.storageFailure("cleanExit requires a clean-exit authorization", cause: .other)
        }
        let mark = try writeLaunchMark(state)
        cleanExitGate.noteUncleanCommitted()
        return mark
    }

    /// Writes the clean mark only under the gate's current authorization (the app-scoped shutdown
    /// coordinator authorizes it after a successful final flush). `false` when the authorization
    /// was revoked or superseded before this write began: nothing is written.
    package func recordCleanExit(authorization: UUID) throws -> Bool {
        guard cleanExitGate.begin(authorization) else { return false }
        do {
            _ = try writeLaunchMark(.cleanExit)
        } catch {
            cleanExitGate.finish(authorization, committed: false)
            throw error
        }
        cleanExitGate.finish(authorization, committed: true)
        return true
    }

    private func writeLaunchMark(_ state: AgentRecoveryLaunchMark.State) throws -> AgentRecoveryLaunchMark {
        let mark = AgentRecoveryLaunchMark(
            appInstanceID: appInstanceID,
            state: state,
            recordedAt: AgentRecoveryTimestamp(now())
        )
        let settlementCutoff = ordinaryExitSettlementLaunchCutoff ?? mark.recordedAt
        let object: [String: Any] = [
            "schemaVersion": 1,
            "appInstanceID": mark.appInstanceID.uuidString,
            "state": mark.state.rawValue,
            "recordedAtMs": NSNumber(value: mark.recordedAt.millisecondsSince1970),
            Self.ordinaryExitSettlementCutoffLaunchKey: NSNumber(value: settlementCutoff.millisecondsSince1970)
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileOperations.writeAtomically(data, launchStateFileURL)
        } catch {
            throw AgentRecoveryStoreError.classifiedStorageFailure(error)
        }
        ordinaryExitSettlementLaunchCutoff = settlementCutoff
        return mark
    }

    /// Launch-mark member carrying `ordinaryExitSettlementLaunchCutoff` (optional; readers that
    /// do not know it ignore it).
    static let ordinaryExitSettlementCutoffLaunchKey = "ordinaryExitSettlementCutoffMs"

    // MARK: Deleted-session cleanup

    /// Cleanup after a committed tombstone. Only `AgentSessionDataService` calls this, under the
    /// session gate and after the tombstone commit; tombstone filtering never depends on it. A
    /// supported record and the session's managed attachments are removed; unreadable or future
    /// record bytes (and their attachments) are preserved.
    package func removeDataForDeletedSession(sessionID: UUID) throws -> AgentRecoveryDeletedSessionCleanup {
        switch read(sessionID: sessionID) {
        case let .preserved(reason):
            return .preservedUnreadable(reason)
        case .supported:
            try remove(recordFileURL(sessionID: sessionID))
            commitPublisher.publish(sessionID: sessionID, state: .absent)
        case .absent:
            break
        }
        let attachments = managedAttachmentDirectoryURL(sessionID: sessionID)
        if FileManager.default.fileExists(atPath: attachments.path) {
            try remove(attachments)
        }
        return .removed
    }

    // MARK: Crash-hold acknowledgement

    /// Durably records the user's explicit acknowledgement of exactly one displayed crash hold
    /// (F-2). The hold must belong to `binding` (same incarnation and reset generation) and every
    /// run attempt and intent it names must still be in the record (a stale display is refused).
    /// An identical acknowledgement with nothing left to settle is unchanged; a different one
    /// replaces it (a newer decision about a changed uncertainty set). No run is closed. Without
    /// `settlement` no delivery state or outcome is touched. With it (O43/O46), the same write
    /// settles the listed intents that qualify against `runAttemptIDs` as the exited runs
    /// (`AgentRecoveryRecord.crashHoldSettlementQualifies`, evaluated on the current record): a
    /// `dispatching` intent becomes `deliveryUnknown` and each open attempt of it gets a
    /// `.deliveryUnknown` outcome with the settlement's message; payloads stay. `.everyIntent`
    /// refuses with `.intentConflict` (nothing written) when a listed intent doesn't qualify.
    /// Creates the record when absent (a hold of legacy interrupted turns only). With
    /// `undismissedCard` (Check and resolve), refuses with `.cardChanged` when that card was
    /// dismissed in exactly that state.
    package func recordCrashHoldAcknowledgement(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        incarnationID: UUID,
        transcriptResetGeneration: UInt64,
        runAttemptIDs: Set<UUID>,
        intentIDs: Set<UUID>,
        transcriptTurnIDs: Set<UUID>,
        undismissedCard: (key: AgentRecoveryCardKey, freshness: AgentRecoveryCardFreshness)? = nil,
        settlement: AgentRecoveryCrashHoldIntentSettlement? = nil
    ) throws -> AgentRecoveryLocalReceipt {
        guard binding.incarnationID == incarnationID,
              binding.transcriptResetGeneration == transcriptResetGeneration
        else {
            throw AgentRecoveryStoreError.staleIncarnation(expected: binding.incarnationID, actual: incarnationID)
        }
        let current = try writableRecord(binding: binding)
        // Check's confirmation (Step 9-activation-b): the card it captured must still be undismissed,
        // checked atomically with the write (a Dismiss may commit after Check's last look).
        if let undismissedCard,
           current?.isCardAcknowledged(undismissedCard.key, freshness: undismissedCard.freshness) == true
        {
            throw AgentRecoveryStoreError.cardChanged
        }
        for runAttemptID in runAttemptIDs where current?.runAttempt(id: runAttemptID) == nil {
            throw AgentRecoveryStoreError.runAttemptNotFound(runAttemptID)
        }
        for intentID in intentIDs where current?.intent(id: intentID) == nil {
            throw AgentRecoveryStoreError.intentNotFound(intentID)
        }
        var intents = current?.intents ?? []
        var attempts = current?.attempts ?? []
        var settledAny = false
        if let settlement, let current {
            let outcome = AgentRecoveryAttemptOutcome(
                outcome: .deliveryUnknown,
                recordedAt: AgentRecoveryTimestamp(now()),
                extras: [AgentRecoveryAttemptOutcome.deliveryUnknownMessageExtrasKey: .string(settlement.message)]
            )
            for intentID in intentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard current.crashHoldSettlementQualifies(
                    intentID: intentID,
                    exitedRunAttemptIDs: runAttemptIDs,
                    currentInstanceID: appInstanceID
                ) else {
                    if settlement == .everyIntent { throw AgentRecoveryStoreError.intentConflict(intentID) }
                    continue
                }
                if let index = intents.firstIndex(where: { $0.intentID == intentID }),
                   intents[index].deliveryState == .dispatching
                {
                    intents[index].deliveryState = .deliveryUnknown
                    settledAny = true
                }
                for index in attempts.indices where attempts[index].intentID == intentID && attempts[index].outcome == nil {
                    attempts[index].outcome = outcome
                    settledAny = true
                }
            }
        }
        if let current, !settledAny, current.crashHoldAcknowledgement?.covers(
            incarnationID: incarnationID,
            transcriptResetGeneration: transcriptResetGeneration,
            runAttemptIDs: runAttemptIDs,
            intentIDs: intentIDs,
            transcriptTurnIDs: transcriptTurnIDs
        ) == true {
            return AgentRecoveryLocalReceipt(
                binding: binding,
                recordRevision: current.revision,
                disposition: .unchanged,
                composerRevision: current.composer?.revision
            )
        }
        try requireRevision(expectedRevision, current: current)
        let acknowledgement = AgentRecoveryCrashHoldAcknowledgement(
            decisionID: UUID(),
            incarnationID: incarnationID,
            transcriptResetGeneration: transcriptResetGeneration,
            runAttemptIDs: runAttemptIDs,
            intentIDs: intentIDs,
            transcriptTurnIDs: transcriptTurnIDs,
            recordedAt: AgentRecoveryTimestamp(now())
        )
        let record = try replace(
            current,
            binding: binding,
            composer: current?.composer,
            intents: intents,
            attempts: attempts,
            runAttempts: current?.runAttempts ?? [],
            crashHoldAcknowledgement: .some(acknowledgement)
        )
        return AgentRecoveryLocalReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: .committed,
            composerRevision: record.composer?.revision
        )
    }

    /// An exact, interaction-keyed change to the durable question snapshots. Every snapshot not
    /// named here is kept as stored, whichever launch or owner wrote it: a question a closed
    /// window (this launch or an earlier one) preserved stays until it is resolved by ID.
    package struct QuestionSnapshotUpdate: Equatable {
        /// Written in place of a stored snapshot with the same interaction ID, else appended.
        package var upserting: [AgentRecoveryQuestionSnapshot]
        /// Removed exactly (an ID also upserted is written, not removed).
        package var removing: Set<UUID>

        package init(upserting: [AgentRecoveryQuestionSnapshot] = [], removing: Set<UUID> = []) {
            self.upserting = upserting
            self.removing = removing
        }
    }

    package struct QuestionSnapshotUpdateReceipt: Equatable {
        package let receipt: AgentRecoveryLocalReceipt
        /// Upserted interaction IDs that were already stored before this write.
        package let alreadyStored: Set<UUID>
    }

    /// Applies `update` to the session's pending-question snapshots (live creation, draft, and
    /// resolution writes, shutdown preparation, Cancel, or an explicit saved-question removal).
    /// Unchanged when identical; nothing is
    /// created for an empty set on a session without a record. Secret answers are structurally absent.
    package func updateQuestionSnapshots(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        update: QuestionSnapshotUpdate
    ) throws -> QuestionSnapshotUpdateReceipt {
        let current = try writableRecord(binding: binding)
        let stored = current?.questions ?? []
        let storedIDs = Set(stored.map(\.interactionID))
        let alreadyStored = Set(update.upserting.map(\.interactionID)).intersection(storedIDs)
        var latest: [UUID: AgentRecoveryQuestionSnapshot] = [:]
        for snapshot in update.upserting {
            latest[snapshot.interactionID] = snapshot
        }
        // A snapshot written in place keeps its first stored ask time and unknown fields.
        var snapshots = stored.compactMap { snapshot in
            latest[snapshot.interactionID].map { $0.mergingStored(snapshot) }
                ?? (update.removing.contains(snapshot.interactionID) ? nil : snapshot)
        }
        var appended = Set<UUID>()
        for snapshot in update.upserting where !storedIDs.contains(snapshot.interactionID) {
            guard appended.insert(snapshot.interactionID).inserted, let written = latest[snapshot.interactionID] else { continue }
            snapshots.append(written)
        }
        if stored == snapshots {
            return QuestionSnapshotUpdateReceipt(
                receipt: AgentRecoveryLocalReceipt(
                    binding: binding,
                    recordRevision: current?.revision,
                    disposition: .unchanged,
                    composerRevision: current?.composer?.revision
                ),
                alreadyStored: alreadyStored
            )
        }
        try requireRevision(expectedRevision, current: current)
        let record = try replace(
            current,
            binding: binding,
            composer: current?.composer,
            intents: current?.intents ?? [],
            attempts: current?.attempts ?? [],
            runAttempts: current?.runAttempts ?? [],
            questions: snapshots
        )
        return QuestionSnapshotUpdateReceipt(
            receipt: AgentRecoveryLocalReceipt(
                binding: binding,
                recordRevision: record.revision,
                disposition: .committed,
                composerRevision: record.composer?.revision
            ),
            alreadyStored: alreadyStored
        )
    }

    /// Durably dismisses one recovery card in its displayed semantic state (Phase 2 §D). `isCurrent`
    /// revalidates the card against the record about to be replaced, atomically with the write;
    /// `false` (its record-backed state changed or it no longer exists) refuses with `cardChanged`
    /// and writes nothing. An identical acknowledgement is unchanged; a different one for the same
    /// key replaces it. Acknowledgements of another incarnation are dropped; no other acknowledgement
    /// is evicted, so an unchanged dismissed card never reappears because of an unrelated Dismiss
    /// (review A F07; retention is deferred). Nothing else changes: no turn is resolved, no input,
    /// draft, question, crash-hold acknowledgement, or run evidence is touched. Creates the record
    /// when absent (a card backed only by the session file).
    package func acknowledgeCard(
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        key: AgentRecoveryCardKey,
        freshness: AgentRecoveryCardFreshness,
        isCurrent: @Sendable (AgentRecoveryRecord?) -> Bool
    ) throws -> AgentRecoveryLocalReceipt {
        guard key.incarnationID == binding.incarnationID else {
            throw AgentRecoveryStoreError.staleIncarnation(expected: binding.incarnationID, actual: key.incarnationID)
        }
        let current = try writableRecord(binding: binding)
        guard isCurrent(current) else {
            throw AgentRecoveryStoreError.cardChanged
        }
        if let current, current.isCardAcknowledged(key, freshness: freshness) {
            return AgentRecoveryLocalReceipt(
                binding: binding,
                recordRevision: current.revision,
                disposition: .unchanged,
                composerRevision: current.composer?.revision
            )
        }
        try requireRevision(expectedRevision, current: current)
        var acknowledgements = (current?.cardAcknowledgements ?? []).filter {
            $0.key != key && $0.key.incarnationID == binding.incarnationID
        }
        acknowledgements.append(AgentRecoveryCardAcknowledgement(
            key: key,
            freshness: freshness,
            acknowledgedAt: AgentRecoveryTimestamp(now())
        ))
        let record = try replace(
            current,
            binding: binding,
            composer: current?.composer,
            intents: current?.intents ?? [],
            attempts: current?.attempts ?? [],
            runAttempts: current?.runAttempts ?? [],
            cardAcknowledgements: acknowledgements
        )
        return AgentRecoveryLocalReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: .committed,
            composerRevision: record.composer?.revision
        )
    }

    // MARK: Private

    /// The current record if it may be written under `binding`; `nil` when absent.
    func writableRecord(binding: AgentRecoveryLifecycleBinding) throws -> AgentRecoveryRecord? {
        switch read(sessionID: binding.sessionID) {
        case .absent:
            return nil
        case let .preserved(reason):
            throw AgentRecoveryStoreError.unreadableRecord(binding.sessionID, reason)
        case let .supported(record):
            guard record.sessionID == binding.sessionID else {
                throw AgentRecoveryStoreError.sessionMismatch(expected: binding.sessionID, actual: record.sessionID)
            }
            guard record.incarnationID == binding.incarnationID else {
                throw AgentRecoveryStoreError.staleIncarnation(expected: binding.incarnationID, actual: record.incarnationID)
            }
            // The foundation generation is an ordered counter; recovery only refuses to go back.
            guard binding.transcriptResetGeneration >= record.transcriptResetGeneration else {
                throw AgentRecoveryStoreError.staleTranscriptResetGeneration(
                    binding: binding.transcriptResetGeneration,
                    record: record.transcriptResetGeneration
                )
            }
            return record
        }
    }

    private func requireIntent(
        binding: AgentRecoveryLifecycleBinding,
        intentID: UUID
    ) throws -> (AgentRecoveryRecord, AgentRecoveryIntent) {
        guard let current = try writableRecord(binding: binding), let intent = current.intent(id: intentID) else {
            throw AgentRecoveryStoreError.intentNotFound(intentID)
        }
        return (current, intent)
    }

    private func requireAttemptIndex(_ attemptID: UUID, intentID: UUID, in record: AgentRecoveryRecord) throws -> Int {
        guard let index = record.attempts.firstIndex(where: { $0.attemptID == attemptID }),
              record.attempts[index].intentID == intentID
        else {
            throw AgentRecoveryStoreError.attemptNotFound(attemptID)
        }
        return index
    }

    private func requireRunAttemptIndex(
        _ runAttemptID: UUID,
        binding: AgentRecoveryLifecycleBinding
    ) throws -> (AgentRecoveryRecord, Int) {
        guard let current = try writableRecord(binding: binding),
              let index = current.runAttempts.firstIndex(where: { $0.runAttemptID == runAttemptID })
        else {
            throw AgentRecoveryStoreError.runAttemptNotFound(runAttemptID)
        }
        return (current, index)
    }

    /// Run evidence must come from a run owned by this binding's persistent session.
    private func requireOwnership(_ ownership: AgentRunOwnership, binding: AgentRecoveryLifecycleBinding) throws {
        guard ownership.binding.persistentSessionID == binding.sessionID else {
            throw AgentRecoveryStoreError.runAttemptConflict(ownership.attemptID)
        }
    }

    /// Same-generation composer replacement keeps unknown members a newer build stored on the
    /// composer, its content, and retained entities matched by identity (image and tagged-file ID,
    /// workflow source). Known fields and supplied members win; an entity the new snapshot omits is
    /// removed with its members. A composer from another generation is never merged.
    private static func preservingUnknownMembers(
        of stored: AgentRecoveryComposerSnapshot?,
        in snapshot: AgentRecoveryComposerSnapshot
    ) -> AgentRecoveryComposerSnapshot {
        guard let stored, stored.transcriptResetGeneration == snapshot.transcriptResetGeneration else {
            return snapshot
        }
        let old = stored.content
        let new = snapshot.content
        let images = new.images.map { image in
            var image = image
            if let previous = old.images.first(where: { $0.id == image.id }) {
                image.extras = mergedExtras(previous.extras, image.extras)
            }
            return image
        }
        let taggedFiles = new.taggedFiles.map { file in
            var file = file
            if let previous = old.taggedFiles.first(where: { $0.id == file.id }) {
                file.extras = mergedExtras(previous.extras, file.extras)
            }
            return file
        }
        var workflow = new.workflow
        if var updated = workflow, let previous = old.workflow, previous.source == updated.source {
            updated.extras = mergedExtras(previous.extras, updated.extras)
            workflow = updated
        }
        let content = AgentRecoveryInputContent(
            text: new.text,
            images: images,
            taggedFiles: taggedFiles,
            workflow: workflow,
            interviewFirst: new.interviewFirst,
            extras: mergedExtras(old.extras, new.extras)
        )
        return AgentRecoveryComposerSnapshot(
            revision: snapshot.revision,
            capturedAt: snapshot.capturedAt,
            transcriptResetGeneration: snapshot.transcriptResetGeneration,
            content: content,
            extras: mergedExtras(stored.extras, snapshot.extras)
        )
    }

    private static func mergedExtras(_ stored: AgentRecoveryExtras, _ supplied: AgentRecoveryExtras) -> AgentRecoveryExtras {
        stored.merging(supplied) { _, supplied in supplied }
    }

    func requireRevision(_ expected: AgentRecoveryRecordRevision?, current: AgentRecoveryRecord?) throws {
        guard expected == current?.revision else {
            throw AgentRecoveryStoreError.revisionConflict(expected: expected, actual: current?.revision)
        }
    }

    private func requireIdenticalSubmission(_ existing: AgentRecoveryIntent, _ submission: AgentRecoveryIntentSubmission) throws {
        guard existing.userItemID == submission.userItemID,
              existing.origin == submission.origin,
              existing.target == submission.target,
              existing.payload == submission.payload,
              existing.scheduleReference == submission.scheduleReference,
              Self.samePendingHandoff(existing.pendingHandoff, submission.pendingHandoff)
        else {
            throw AgentRecoveryStoreError.intentConflict(submission.intentID)
        }
    }

    private static func samePendingHandoff(
        _ stored: AgentRecoveryPendingHandoffSnapshot?,
        _ supplied: AgentRecoveryPendingHandoffSnapshot?
    ) -> Bool {
        switch (stored, supplied) {
        case (nil, nil): true
        case let (stored?, supplied?): stored.hasSameContent(as: supplied)
        default: false
        }
    }

    private func fill(_ slot: inout UUID?, with value: UUID?, runAttemptID: UUID) throws {
        guard let value else { return }
        if let existing = slot {
            guard existing == value else {
                throw AgentRecoveryStoreError.runAttemptConflict(runAttemptID)
            }
        } else {
            slot = value
        }
    }

    private func insertIntent(
        _ current: AgentRecoveryRecord?,
        binding: AgentRecoveryLifecycleBinding,
        expectedRevision: AgentRecoveryRecordRevision?,
        submission: AgentRecoveryIntentSubmission,
        start: AgentRecoveryAttemptStart?,
        consumption: AgentRecoveryComposerConsumption?
    ) throws -> (AgentRecoveryRecord, AgentRecoveryIntent, Bool) {
        try requireRevision(expectedRevision, current: current)
        if let current, current.intents.contains(where: { $0.userItemID == submission.userItemID }) {
            throw AgentRecoveryStoreError.intentConflict(submission.intentID)
        }
        if let missing = missingManagedImageID(in: submission.payload, sessionID: binding.sessionID) {
            throw AgentRecoveryStoreError.attachmentUnavailable(imageID: missing)
        }
        let timestamp = AgentRecoveryTimestamp(now())
        var attempts = current?.attempts ?? []
        if let start {
            guard !attempts.contains(where: { $0.attemptID == start.attemptID }) else {
                throw AgentRecoveryStoreError.attemptConflict(start.attemptID)
            }
            attempts.append(makeAttempt(start, intentID: submission.intentID, userItemID: submission.userItemID, at: timestamp))
        }
        let intent = AgentRecoveryIntent(
            intentID: submission.intentID,
            userItemID: submission.userItemID,
            origin: submission.origin,
            target: submission.target,
            createdAt: timestamp,
            appInstanceID: appInstanceID,
            transcriptResetGeneration: binding.transcriptResetGeneration,
            deliveryState: start == nil ? .queued : .dispatching,
            payload: submission.payload,
            scheduleReference: submission.scheduleReference,
            pendingHandoff: submission.pendingHandoff
        )
        var composer = current?.composer
        var consumed = false
        // A composer from another reset generation is held input: never consumed by a new intent.
        if let consumption, let stored = composer,
           stored.transcriptResetGeneration == binding.transcriptResetGeneration,
           consumption.consumableRevisions.contains(stored.revision)
        {
            composer = nil
            consumed = true
        }
        let record = try replace(
            current,
            binding: binding,
            composer: composer,
            intents: (current?.intents ?? []) + [intent],
            attempts: attempts,
            runAttempts: current?.runAttempts ?? []
        )
        return (record, intent, consumed)
    }

    private func intentReceipt(
        _ intent: AgentRecoveryIntent,
        record: AgentRecoveryRecord,
        binding: AgentRecoveryLifecycleBinding,
        disposition: AgentRecoveryCommitDisposition,
        composerConsumed: Bool = false
    ) -> AgentRecoveryIntentReceipt {
        let composer = record.composer
        let isCurrent = composer?.transcriptResetGeneration == binding.transcriptResetGeneration
        return AgentRecoveryIntentReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: disposition,
            intentID: intent.intentID,
            userItemID: intent.userItemID,
            deliveryState: intent.deliveryState,
            pendingHandoff: intent.pendingHandoff,
            composerRevision: isCurrent ? composer?.revision : nil,
            heldComposerRevision: isCurrent ? nil : composer?.revision,
            composerConsumed: composerConsumed
        )
    }

    private func queueReceipt(
        for intent: AgentRecoveryIntent,
        in record: AgentRecoveryRecord,
        binding: AgentRecoveryLifecycleBinding,
        disposition: AgentRecoveryCommitDisposition
    ) throws -> AgentRecoveryQueueReceipt {
        guard intent.deliveryState == .queued else {
            throw AgentRecoveryStoreError.invalidTransition(intentID: intent.intentID, from: intent.deliveryState, operation: .submit)
        }
        let holds = holdReasons(for: intent, sessionID: record.sessionID, currentGeneration: binding.transcriptResetGeneration)
        guard holds.isEmpty else {
            throw AgentRecoveryStoreError.heldIntent(intentID: intent.intentID, holds: holds)
        }
        return AgentRecoveryQueueReceipt(
            intent: intentReceipt(intent, record: record, binding: binding, disposition: disposition),
            owningAppInstanceID: intent.appInstanceID
        )
    }

    private func dispatchReceipt(
        for intent: AgentRecoveryIntent,
        start: AgentRecoveryAttemptStart,
        in record: AgentRecoveryRecord,
        binding: AgentRecoveryLifecycleBinding,
        disposition: AgentRecoveryCommitDisposition
    ) throws -> AgentRecoveryDispatchReceipt {
        guard let attempt = record.attempts.first(where: { $0.attemptID == start.attemptID }),
              attempt.intentID == intent.intentID,
              attempt.runAttemptID == start.runAttemptID,
              attempt.transcriptTurnID == start.transcriptTurnID
        else {
            throw AgentRecoveryStoreError.attemptConflict(start.attemptID)
        }
        guard attempt.outcome == nil, intent.deliveryState == .dispatching else {
            throw AgentRecoveryStoreError.invalidTransition(
                intentID: intent.intentID,
                from: intent.deliveryState,
                operation: .beginDispatch
            )
        }
        return AgentRecoveryDispatchReceipt(
            intent: intentReceipt(intent, record: record, binding: binding, disposition: disposition),
            attemptID: start.attemptID
        )
    }

    private func runReceipt(
        _ runAttemptID: UUID,
        record: AgentRecoveryRecord,
        binding: AgentRecoveryLifecycleBinding,
        disposition: AgentRecoveryCommitDisposition
    ) -> AgentRecoveryRunReceipt {
        AgentRecoveryRunReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: disposition,
            runAttemptID: runAttemptID
        )
    }

    private func makeAttempt(
        _ start: AgentRecoveryAttemptStart,
        intentID: UUID,
        userItemID: UUID,
        at timestamp: AgentRecoveryTimestamp
    ) -> AgentRecoveryAttempt {
        AgentRecoveryAttempt(
            attemptID: start.attemptID,
            intentID: intentID,
            userItemID: userItemID,
            runAttemptID: start.runAttemptID,
            transcriptTurnID: start.transcriptTurnID,
            appInstanceID: appInstanceID,
            dispatchedAt: timestamp
        )
    }

    private func missingManagedImageID(in content: AgentRecoveryInputContent, sessionID: UUID) -> UUID? {
        for image in content.images {
            guard let fileName = image.managedFileName else { continue }
            guard let url = managedImageURL(sessionID: sessionID, fileName: fileName),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                return image.id
            }
        }
        return nil
    }

    private func replacing(_ intent: AgentRecoveryIntent, in record: AgentRecoveryRecord) -> [AgentRecoveryIntent] {
        record.intents.map { $0.intentID == intent.intentID ? intent : $0 }
    }

    /// Rewrites an existing record, keeping its composer and any collection not supplied.
    private func rewrite(
        _ current: AgentRecoveryRecord,
        binding: AgentRecoveryLifecycleBinding,
        intents: [AgentRecoveryIntent]? = nil,
        attempts: [AgentRecoveryAttempt]? = nil,
        runAttempts: [AgentRecoveryRunAttempt]? = nil
    ) throws -> AgentRecoveryRecord {
        try replace(
            current,
            binding: binding,
            composer: current.composer,
            intents: intents ?? current.intents,
            attempts: attempts ?? current.attempts,
            runAttempts: runAttempts ?? current.runAttempts
        )
    }

    /// Atomically replaces the record (new opaque revision, binding generation, preserved extras,
    /// crash-hold acknowledgement, questions, card acknowledgements, actions, history cursors,
    /// delegated child links, and edit proposals unless supplied). Never deletes attachments: a record reference is not proof that a file is
    /// unused.
    func replace(
        _ current: AgentRecoveryRecord?,
        binding: AgentRecoveryLifecycleBinding,
        composer: AgentRecoveryComposerSnapshot?,
        intents: [AgentRecoveryIntent],
        attempts: [AgentRecoveryAttempt],
        runAttempts: [AgentRecoveryRunAttempt],
        crashHoldAcknowledgement: AgentRecoveryCrashHoldAcknowledgement?? = nil,
        questions: [AgentRecoveryQuestionSnapshot]? = nil,
        cardAcknowledgements: [AgentRecoveryCardAcknowledgement]? = nil,
        actions: [AgentRecoveryAction]? = nil,
        historyCursors: [AgentRecoveryHistoryCursor]? = nil,
        delegatedChildLinks: [AgentRecoveryDelegatedChildLink]? = nil,
        editProposals: [AgentRecoveryEditProposal]? = nil
    ) throws -> AgentRecoveryRecord {
        let record = AgentRecoveryRecord(
            sessionID: binding.sessionID,
            revision: .make(),
            incarnationID: binding.incarnationID,
            transcriptResetGeneration: binding.transcriptResetGeneration,
            updatedAt: AgentRecoveryTimestamp(now()),
            composer: composer,
            intents: intents,
            attempts: attempts,
            runAttempts: runAttempts,
            crashHoldAcknowledgement: crashHoldAcknowledgement ?? current?.crashHoldAcknowledgement,
            questions: questions ?? current?.questions ?? [],
            cardAcknowledgements: cardAcknowledgements ?? current?.cardAcknowledgements ?? [],
            actions: actions ?? current?.actions ?? [],
            historyCursors: historyCursors ?? current?.historyCursors ?? [],
            delegatedChildLinks: delegatedChildLinks ?? current?.delegatedChildLinks ?? [],
            editProposals: editProposals ?? current?.editProposals ?? [],
            extras: current?.extras ?? [:]
        )
        do {
            let data = try AgentRecoveryRecordCodec.encode(record)
            try FileManager.default.createDirectory(at: sessionsDirectoryURL, withIntermediateDirectories: true)
            try fileOperations.writeAtomically(data, recordFileURL(sessionID: binding.sessionID))
        } catch {
            throw AgentRecoveryStoreError.classifiedStorageFailure(error)
        }
        commitPublisher.publish(sessionID: binding.sessionID, state: .supported(record))
        return record
    }

    private func remove(_ url: URL) throws {
        do {
            try fileOperations.removeItem(url)
        } catch {
            throw AgentRecoveryStoreError.classifiedStorageFailure(error)
        }
    }
}
