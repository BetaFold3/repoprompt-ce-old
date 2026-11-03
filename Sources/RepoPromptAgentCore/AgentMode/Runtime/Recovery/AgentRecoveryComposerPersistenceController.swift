import Foundation

// Lossless-restart Phase 1b composer persistence (spec R2 "Composer writes"). Constructed by the
// recovery coordinator for each session lane once production recovery is composed.

package enum AgentRecoveryControllerFailure: Error, Equatable {
    case store(AgentRecoveryStoreError)
    /// The foundation lifecycle gate refused the transaction (reset, deletion, stale authority).
    case lifecycleRejected(String)
    /// This controller's ownership was retired (a replacement owner claimed the session).
    case retired
    /// Held-composer resolution was requested but no held composer is known.
    case noHeldComposer
    /// Restoring held input would replace unsaved live typing; resolve or clear it first.
    case liveComposerHasUnsavedContent
    /// The held input changed since it was displayed (another resolution, a newer write); the
    /// displayed decision no longer applies. Nothing was changed.
    case heldInputChanged
    /// The message box changed while a held draft was being restored. The held draft stays stored
    /// (the restore was not written, or was reverted) and the new text stays in the message box.
    case composerChangedDuringRestore
}

/// R02: a raced held restore whose rollback is still owed. `restoredRevision` is the previously held
/// draft now durable as this generation's composer; `held` is the held snapshot the rollback puts
/// back. In memory only (no schema): the stored restored draft itself is the durable copy, and this
/// obligation keeps every owner from replacing it until the rollback or an explicit resolution
/// commits.
package struct AgentRecoveryRestoreRollbackObligation: Equatable {
    package let restoredRevision: AgentRecoveryComposerRevision
    package let held: AgentRecoveryComposerSnapshot
}

/// Explicit user choice for a held composer; see `AgentRecoveryHeldComposerResolution`.
package enum AgentRecoveryHeldComposerChoice: Equatable {
    case discard
    case restoreToComposer
}

/// Result of a submission: a store-issued queue or dispatch receipt (never provider acceptance)
/// plus the composer revision that was submitted, so the live UI clears only if nothing newer was typed.
package struct AgentRecoverySubmissionResult<Receipt: Equatable>: Equatable {
    package let receipt: Receipt
    package let submittedRevision: AgentRecoveryComposerRevision

    package func permitsClearingLiveComposer(currentLiveRevision: AgentRecoveryComposerRevision?) -> Bool {
        currentLiveRevision == submittedRevision
    }
}

extension AgentRecoverySubmissionResult: Sendable where Receipt: Sendable {}

package enum AgentRecoveryComposerFlushOutcome: Equatable {
    case nothingPending
    case committed(AgentRecoveryLocalReceipt)
    case failed(AgentRecoveryControllerFailure)
}

package enum AgentRecoveryComposerRestoreOutcome: Equatable {
    /// The durable composer (or `nil` when none is stored) for this incarnation and reset generation.
    case restored(AgentRecoveryComposerSnapshot?)
    /// The stored composer was typed under another reset generation. It is not adopted as the live
    /// composer and is never a write baseline; the caller may present it as held input. Ordinary
    /// writes are refused (`heldComposerUnresolved`) until it is resolved explicitly. Reported even
    /// when typing happened during the read, because it never replaces live input.
    case heldForOtherGeneration(AgentRecoveryComposerSnapshot)
    /// Newer local edits exist; restoring would overwrite them. The durable baseline was still learned.
    case superseded
    case failed(AgentRecoveryControllerFailure)
}

/// Owns one session's composer persistence: immutable snapshots under opaque revisions, a 300 ms
/// debounce with a 2-second maximum delay from the first unsaved change, explicit flush, and
/// guarded composer consumption on submission. All store writes are serialized here and run
/// inside the foundation lifecycle gate.
///
/// Producer contract (restore before edits): call `loadRestorableComposer()` before forwarding any
/// edit or submission, or pass the discovered baseline to `init(durableComposerRevision:)`. A write
/// serialized ahead of the first restore runs without a baseline, fails with
/// `composerRevisionConflict` when a composer is stored, and is retried only on the next edit or
/// flush (no automatic retry). A submission queued behind the restore is covered by
/// `effectiveConsumption`. A held draft is never carried forward or discarded implicitly; only
/// `resolveHeldComposer` (an explicit user action) discards or restores it.
@MainActor
package final class AgentRecoveryComposerPersistenceController {
    /// Sleeps until an absolute monotonic deadline (the Phase 1a transcript max-wait pattern);
    /// tests replace it to fire deadlines deterministically.
    package typealias Sleep = @Sendable (_ deadline: ContinuousClock.Instant) async throws -> Void

    package static let debounce: Duration = .milliseconds(300)
    package static let maximumDelay: Duration = .seconds(2)
    private static let maximumConflictRetries = 3

    private let store: AgentRecoveryStore
    private let gate: any AgentRecoveryLifecycleGate
    private let sleep: Sleep
    private let clockNow: () -> ContinuousClock.Instant
    private let now: () -> Date

    /// Latest revision issued for the live composer.
    package private(set) var liveRevision: AgentRecoveryComposerRevision?
    /// Current-generation composer revision this controller believes is stored (`nil` = none). The
    /// CAS baseline for composer writes.
    package private(set) var durableComposerRevision: AgentRecoveryComposerRevision?
    /// Stored composer from another reset generation, if known. Never a write or consumption baseline.
    package private(set) var heldComposerRevision: AgentRecoveryComposerRevision? {
        didSet {
            if oldValue != heldComposerRevision { stateDidChange?() }
        }
    }

    /// Same-generation stored revision learned by a restore read that this controller did not issue.
    /// Under the single-writer contract it was stored before this controller issued any revision, so
    /// it predates every submitted edit. Cleared when the stored composer changes.
    private var restoredBaselineRevision: AgentRecoveryComposerRevision?
    /// Operations ever enqueued on the serial chain (test observability only).
    private(set) var enqueuedOperationCount = 0
    /// Last write failure; cleared by the next successful composer write. Persistent until resolved.
    package private(set) var lastWriteFailure: AgentRecoveryControllerFailure? {
        didSet {
            if oldValue != lastWriteFailure { stateDidChange?() }
        }
    }

    /// Called when `lastWriteFailure` or `heldComposerRevision` changes (visible recovery state).
    package var stateDidChange: (@MainActor () -> Void)?

    /// Freeze boundary of the explicit held-composer restore in flight, if any (plan §2). Every
    /// composer change reported meanwhile trips it.
    package private(set) var activeResolutionFence: AgentRecoveryResolutionFence?
    /// Set only when a restore raced a composer change and could not be reverted; the restored
    /// draft is then kept visible with this failure. Cleared by the next resolution or a revert
    /// that later succeeds.
    package private(set) var restoreRevertFailure: AgentRecoveryControllerFailure?

    /// A raced restore whose revert failed (R02): the previously held draft is durable as this
    /// generation's composer (`restoredRevision`), and `held` is the held snapshot to put back. While
    /// set, no ordinary composer write replaces the restored draft and no submission consumes it;
    /// every write or flush first retries the revert. Cleared only when the revert succeeds (the held
    /// slot owns the draft again) or an explicit resolution's write commits. A retiring lane hands it
    /// to its same-binding successor (`adoptRestoreRollback`), so it never ends with an owner.
    private var unrevertedRestore: AgentRecoveryRestoreRollbackObligation?

    /// Whether a restored draft is protected pending its rollback (see `unrevertedRestore`).
    package var isRestoredDraftAwaitingRollback: Bool {
        unrevertedRestore != nil
    }

    /// The outstanding rollback obligation, if any (carried to a successor by lane retirement).
    package var outstandingRestoreRollback: AgentRecoveryRestoreRollbackObligation? {
        unrevertedRestore
    }

    /// A same-binding successor takes over a retired controller's outstanding rollback before its
    /// first restore, write, or submission (the lane adopts it in its predecessor settlement, which
    /// every one of those waits for). From then on its writes retry the rollback first.
    package func adoptRestoreRollback(_ obligation: AgentRecoveryRestoreRollbackObligation) {
        guard unrevertedRestore == nil, !isRetired else { return }
        unrevertedRestore = obligation
    }

    /// Called with the held snapshot once a retried rollback put it back in the held slot.
    package var restoreRollbackDidSucceed: (@MainActor (AgentRecoveryComposerSnapshot) -> Void)?

    private var pending: AgentRecoveryComposerSnapshot?
    /// Revisions issued by this controller, in local issue order, since the last consumption.
    private var issuedRevisions: [AgentRecoveryComposerRevision] = []
    private var debounceTask: Task<Void, Never>?
    private var maximumDelayTask: Task<Void, Never>?
    /// Instant of the first mutation not yet captured by a write. Captured synchronously at the
    /// mutation; later mutations never move it. Cleared when a write captures the snapshot, so
    /// edits made during an in-flight write own a fresh bound from their own first mutation.
    private var uncapturedSince: ContinuousClock.Instant?
    package private(set) var maximumDelayDeadline: ContinuousClock.Instant?
    private var operationTail: Task<Void, Never>?
    /// Set once by `retire`; every later write, submission, restore, or resolution fails `.retired`.
    package private(set) var isRetired = false

    package init(
        store: AgentRecoveryStore,
        gate: any AgentRecoveryLifecycleGate,
        durableComposerRevision: AgentRecoveryComposerRevision? = nil,
        sleep: @escaping Sleep = { try await Task.sleep(until: $0, clock: .continuous) },
        clockNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.gate = gate
        self.durableComposerRevision = durableComposerRevision
        self.sleep = sleep
        self.clockNow = clockNow
        self.now = now
    }

    package var hasPendingChanges: Bool {
        pending != nil
    }

    /// Content of the snapshot not yet written (kept after a failed write or retirement).
    package var pendingContent: AgentRecoveryInputContent? {
        pending?.content
    }

    // MARK: Edits

    /// Current instant on this controller's absolute monotonic clock seam. Producers that buffer a
    /// mutation before forwarding it (restore in flight, first-draft authority preparation) capture
    /// the first unsaved instant here so the forwarded write keeps its original deadline.
    package var currentInstant: ContinuousClock.Instant {
        clockNow()
    }

    /// Records a full immutable composer snapshot under a new revision and schedules its write.
    ///
    /// `firstUnsavedAt` is the instant of the earliest mutation this snapshot represents when the
    /// producer buffered it (default: now). The 2-second maximum delay runs from the earliest
    /// outstanding instant and is never restarted by forwarding; an already-overdue obligation is
    /// written immediately rather than waiting another debounce window.
    @discardableResult
    package func composerDidChange(
        _ content: AgentRecoveryInputContent,
        firstUnsavedAt: ContinuousClock.Instant? = nil
    ) -> AgentRecoveryComposerRevision {
        activeResolutionFence?.noteComposerMutation()
        let revision = AgentRecoveryComposerRevision.make()
        liveRevision = revision
        issuedRevisions.append(revision)
        pending = AgentRecoveryComposerSnapshot(
            revision: revision,
            capturedAt: AgentRecoveryTimestamp(now()),
            transcriptResetGeneration: gate.binding.transcriptResetGeneration,
            content: content
        )
        // A retired controller keeps no timers; its owner's replacement persists live input.
        guard !isRetired else { return revision }
        // Deadlines are absolute and computed here, not when the timer task first runs.
        let mutationInstant = clockNow()
        let candidate = min(firstUnsavedAt ?? mutationInstant, mutationInstant)
        let firstUnsaved = uncapturedSince.map { min($0, candidate) } ?? candidate
        uncapturedSince = firstUnsaved
        let deadline = firstUnsaved + Self.maximumDelay
        guard deadline > mutationInstant else {
            // Overdue (buffered past its bound): write now instead of re-debouncing.
            cancelTimers()
            maximumDelayDeadline = deadline
            maximumDelayTask = Task { [weak self] in
                guard let self else { return }
                _ = await serialized { await $0.writePending() }
            }
            return revision
        }
        debounceTask?.cancel()
        debounceTask = makeTimer(until: mutationInstant + Self.debounce)
        if maximumDelayTask == nil || maximumDelayDeadline.map({ deadline < $0 }) == true {
            maximumDelayTask?.cancel()
            maximumDelayDeadline = deadline
            maximumDelayTask = makeTimer(until: deadline)
        }
        return revision
    }

    /// A composer change that cannot be represented yet (an image awaiting promotion). It is not a
    /// snapshot, but it still trips an in-flight restore's fence.
    package func noteUnrepresentableComposerChange() {
        activeResolutionFence?.noteComposerMutation()
    }

    /// Writes any pending snapshot now (tab switch, shutdown).
    package func flush() async -> AgentRecoveryComposerFlushOutcome {
        await serialized { await $0.writePending() }
    }

    // MARK: Ownership

    /// Retires this controller before a replacement owner is installed. With `flushingPending`, the
    /// pending snapshot is written first (same binding hand-over). Waits for every operation already
    /// serialized, so no write from this controller can land after a successor starts.
    @discardableResult
    package func retire(flushingPending: Bool) async -> AgentRecoveryComposerFlushOutcome? {
        let outcome: AgentRecoveryComposerFlushOutcome? = flushingPending ? await flush() : nil
        isRetired = true
        cancelTimers()
        await operationTail?.value
        return outcome
    }

    // MARK: Held composer resolution

    /// Explicit user resolution of exactly the displayed held composer (`expectedHeldRevision`;
    /// otherwise `heldInputChanged`). `discard` removes it; pending live typing is stored in the
    /// same record replacement (never left memory-only between the two). `restoreToComposer`
    /// requires no unsaved live content and returns the content now stored as this generation's
    /// composer, adopted as the live revision.
    ///
    /// Restore freeze (plan §2): a composer change reported while the restore is in flight trips
    /// its fence. Before the store write, the write is refused; after it, the held draft is put
    /// back (conditional held-slot replacement). Either way the result is
    /// `composerChangedDuringRestore`: the held draft stays stored and the change stays pending,
    /// as with any typing while a held draft exists. Only if that revert itself fails is the
    /// restored snapshot returned unadopted (`restoreRevertFailure` set) for the caller to keep
    /// visible. Nothing is carried forward or retargeted without this call.
    package func resolveHeldComposer(
        _ choice: AgentRecoveryHeldComposerChoice,
        expectedHeldRevision: AgentRecoveryComposerRevision
    ) async -> Result<AgentRecoveryComposerSnapshot?, AgentRecoveryControllerFailure> {
        await serialized { controller in
            await controller.performHeldResolution(choice, expectedHeldRevision: expectedHeldRevision)
        }
    }

    private func performHeldResolution(
        _ choice: AgentRecoveryHeldComposerChoice,
        expectedHeldRevision: AgentRecoveryComposerRevision
    ) async -> Result<AgentRecoveryComposerSnapshot?, AgentRecoveryControllerFailure> {
        guard !isRetired else { return .failure(.retired) }
        guard let held = heldComposerRevision else { return .failure(.noHeldComposer) }
        guard held == expectedHeldRevision else { return .failure(.heldInputChanged) }
        restoreRevertFailure = nil
        let resolution: AgentRecoveryHeldComposerResolution
        let adoptedRevision: AgentRecoveryComposerRevision?
        var replacement: AgentRecoveryComposerSnapshot?
        let fence: AgentRecoveryResolutionFence?
        let liveRevisionAtResolution = liveRevision
        switch choice {
        case .discard:
            adoptedRevision = nil
            fence = nil
            if let pending, !pending.content.isEmpty {
                resolution = .discardReplacingWith(pending)
                replacement = pending
            } else {
                resolution = .discard
            }
        case .restoreToComposer:
            if let pending, !pending.content.isEmpty {
                return .failure(.liveComposerHasUnsavedContent)
            }
            let revision = AgentRecoveryComposerRevision.make()
            resolution = .restoreToComposer(revision: revision)
            adoptedRevision = revision
            fence = AgentRecoveryResolutionFence()
        }
        activeResolutionFence = fence
        defer { activeResolutionFence = nil }
        let store = store
        let binding = gate.binding
        let result = await withConflictRetry {
            // Inside the session gate: no other recovery write can land between this read and the
            // resolution, so `before` is exactly the held draft being resolved.
            let before = await store.read(sessionID: binding.sessionID).record?.composer
            let receipt = try await store.resolveHeldComposer(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                heldComposerRevision: held,
                resolution: resolution,
                fence: fence
            )
            let composer = await store.read(sessionID: binding.sessionID).record?.composer
            return (receipt, composer, before)
        }
        switch result {
        case .failure(.store(.heldResolutionSuperseded)):
            // Changed before the write: nothing was written; the held draft stays.
            return .failure(.composerChangedDuringRestore)
        case let .failure(failure):
            return .failure(failure)
        case let .success((receipt, storedComposer, heldSnapshot)):
            if let adoptedRevision,
               fence?.state == .trippedAfterCommit || liveRevision != liveRevisionAtResolution
            {
                return await revertRacedRestore(
                    restoredRevision: adoptedRevision,
                    heldSnapshot: heldSnapshot,
                    storedComposer: storedComposer,
                    receipt: receipt
                )
            }
            heldComposerRevision = nil
            durableComposerRevision = receipt.composerRevision
            restoredBaselineRevision = nil
            if let replacement {
                // The captured live snapshot is durable: a successful composer write.
                lastWriteFailure = nil
                if pending?.revision == replacement.revision {
                    pending = nil
                    uncapturedSince = nil
                    cancelTimers()
                }
                if let index = issuedRevisions.firstIndex(of: replacement.revision) {
                    issuedRevisions.removeSubrange(..<index)
                }
            } else if case .store(.heldComposerUnresolved) = lastWriteFailure {
                lastWriteFailure = nil
            }
            guard let adoptedRevision else {
                // Live typing newer than the captured replacement (or blocked by the held
                // composer) is written now.
                if pending != nil {
                    _ = await writePending()
                }
                return .success(nil)
            }
            // Any empty pending snapshot is superseded by the restored content.
            pending = nil
            uncapturedSince = nil
            cancelTimers()
            liveRevision = adoptedRevision
            issuedRevisions = [adoptedRevision]
            return .success(storedComposer?.revision == adoptedRevision ? storedComposer : nil)
        }
    }

    /// A composer change raced a committed restore: the held draft is put back in place of the
    /// restored composer, so neither copy depends on memory beyond ordinary pending typing. A
    /// failed revert keeps the restore (the restored draft is durable as this generation's
    /// composer) and returns it unadopted with `restoreRevertFailure`; the newer typing stays
    /// pending. The restored draft stays protected (`unrevertedRestore`): ordinary writes never
    /// replace it, and each later write or flush retries the revert first.
    private func revertRacedRestore(
        restoredRevision: AgentRecoveryComposerRevision,
        heldSnapshot: AgentRecoveryComposerSnapshot?,
        storedComposer: AgentRecoveryComposerSnapshot?,
        receipt: AgentRecoveryLocalReceipt
    ) async -> Result<AgentRecoveryComposerSnapshot?, AgentRecoveryControllerFailure> {
        let reverted: Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> = if let heldSnapshot, heldSnapshot.revision == heldComposerRevision {
            await attemptRestoreRollback(restoredRevision: restoredRevision, held: heldSnapshot)
        } else {
            .failure(.heldInputChanged)
        }
        switch reverted {
        case .success:
            // Held again; the pending change is refused by it until the user resolves it.
            return .failure(.composerChangedDuringRestore)
        case let .failure(failure):
            heldComposerRevision = nil
            durableComposerRevision = receipt.composerRevision
            restoredBaselineRevision = nil
            if case .store(.heldComposerUnresolved) = lastWriteFailure {
                lastWriteFailure = nil
            }
            restoreRevertFailure = failure
            if let heldSnapshot {
                unrevertedRestore = AgentRecoveryRestoreRollbackObligation(restoredRevision: restoredRevision, held: heldSnapshot)
            }
            return .success(storedComposer?.revision == restoredRevision ? storedComposer : nil)
        }
    }

    /// Explicit user resolution of exactly the protected restored copy (`obligation`), made durable
    /// before protection ends. `placing: nil` (discard) stores the current live typing in its place,
    /// or removes it when there is none; `placing: content` (restore into an empty composer) stores
    /// that content as the live composer. Only when that write commits is the obligation cleared;
    /// any failure keeps the protection (and the stored copy) and is returned for a Retry, with the
    /// live composer put back to empty when it was empty before.
    ///
    /// R02-R2 placement fence: a restore placement is written only while it is still the live
    /// revision (newer typing before the write: nothing is written, `composerChangedDuringRestore`).
    /// Newer typing during the write never yields success: the committed placement (the original
    /// content) becomes the protected restored revision and is put back in the held slot at once,
    /// exactly as for a raced held restore (a failed put-back keeps it protected). A failure clears
    /// only its own placement, and only while it is still the live revision. The placement is also
    /// fenced (`activeResolutionFence`, as for a held restore), so a change that cannot be represented
    /// yet (an image awaiting promotion) refuses the write before it, or puts the committed placement
    /// back after it, exactly like newer typing.
    package func resolveProtectedRestore(
        _ obligation: AgentRecoveryRestoreRollbackObligation,
        placing content: AgentRecoveryInputContent?
    ) async -> Result<Void, AgentRecoveryControllerFailure> {
        guard !isRetired else { return .failure(.retired) }
        guard unrevertedRestore == obligation else { return .failure(.heldInputChanged) }
        let empty = AgentRecoveryInputContent(text: "")
        var placementRevision: AgentRecoveryComposerRevision?
        if let content {
            placementRevision = composerDidChange(content)
        } else if pending == nil {
            composerDidChange(empty)
        }
        let placement = placementRevision
        // Armed after the placement itself, so only later changes trip it.
        let fence: AgentRecoveryResolutionFence? = placement == nil ? nil : AgentRecoveryResolutionFence()
        if let fence {
            activeResolutionFence = fence
        }
        defer {
            if let fence, activeResolutionFence === fence {
                activeResolutionFence = nil
            }
        }
        let result: Result<Void, AgentRecoveryControllerFailure> = await serialized { controller in
            guard !controller.isRetired else { return .failure(.retired) }
            guard controller.unrevertedRestore == obligation else { return .failure(.heldInputChanged) }
            if let placement, controller.liveRevision != placement || fence?.commitIfUntripped() == false {
                return .failure(.composerChangedDuringRestore)
            }
            controller.unrevertedRestore = nil
            switch await controller.writePending() {
            case let .committed(receipt):
                if let placement, controller.liveRevision != placement || fence?.state == .trippedAfterCommit {
                    controller.unrevertedRestore = AgentRecoveryRestoreRollbackObligation(
                        restoredRevision: receipt.composerRevision ?? placement,
                        held: obligation.held
                    )
                    if let failure = await controller.retryOutstandingRestoreRollback(),
                       controller.unrevertedRestore != nil
                    {
                        return .failure(failure)
                    }
                    return .failure(.composerChangedDuringRestore)
                }
                controller.restoreRevertFailure = nil
                return .success(())
            case .nothingPending:
                controller.unrevertedRestore = obligation
                return .failure(.heldInputChanged)
            case let .failed(failure):
                controller.unrevertedRestore = obligation
                return .failure(failure)
            }
        }
        if case .failure = result, let placement, liveRevision == placement, !isRetired {
            // The live composer was empty before the placement; the UI keeps it empty.
            composerDidChange(empty)
        }
        return result
    }

    private func attemptRestoreRollback(
        restoredRevision: AgentRecoveryComposerRevision,
        held: AgentRecoveryComposerSnapshot
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        let store = store
        let binding = gate.binding
        return await withConflictRetry {
            try await store.revertHeldComposerRestore(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                restoredRevision: restoredRevision,
                held: held
            )
        }
    }

    /// Retries a failed rollback before any composer write. On success the held slot owns the draft
    /// again: writes are refused by it (`heldComposerUnresolved`) until the user resolves it, exactly
    /// as for typing while a held draft exists. On failure nothing is written and the failure stays
    /// visible for an explicit Retry. Returns `nil` when no rollback is outstanding, or when it
    /// succeeded with nothing pending (no write was refused).
    private func retryOutstandingRestoreRollback() async -> AgentRecoveryControllerFailure? {
        guard let outstanding = unrevertedRestore else { return nil }
        switch await attemptRestoreRollback(restoredRevision: outstanding.restoredRevision, held: outstanding.held) {
        case .success:
            unrevertedRestore = nil
            restoreRevertFailure = nil
            durableComposerRevision = nil
            restoredBaselineRevision = nil
            heldComposerRevision = outstanding.held.revision
            let failure: AgentRecoveryControllerFailure? = pending == nil ? nil : .store(.heldComposerUnresolved(
                revision: outstanding.held.revision,
                transcriptResetGeneration: outstanding.held.transcriptResetGeneration
            ))
            lastWriteFailure = failure
            restoreRollbackDidSucceed?(outstanding.held)
            return failure
        case let .failure(failure):
            restoreRevertFailure = failure
            lastWriteFailure = failure
            return failure
        }
    }

    // MARK: Submission

    /// Commits `submission` as `queued` and, in the same record replacement, consumes the stored
    /// composer only if it is the submitted revision, an earlier issued revision, or a validated
    /// baseline predating the submitted edit. A newer or unfamiliar composer is preserved. Failure changes nothing (the caller
    /// restores the live composer).
    package func submitQueued(
        _ submission: AgentRecoveryIntentSubmission,
        submittedRevision: AgentRecoveryComposerRevision
    ) async -> Result<AgentRecoverySubmissionResult<AgentRecoveryQueueReceipt>, AgentRecoveryControllerFailure> {
        let callTimeConsumption = consumption(for: submittedRevision)
        let store = store
        let binding = gate.binding
        return await serialized { controller in
            let consumption = controller.effectiveConsumption(callTimeConsumption)
            return await controller.performSubmission(consumption: consumption, intentReceipt: \.intent) {
                try await store.commitQueuedIntent(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    submission: submission,
                    consumption: consumption
                )
            }
        }
    }

    /// Commits `submission` as `dispatching` with its delivery attempt, before any handoff, with the
    /// same guarded composer consumption as `submitQueued`.
    package func submitDirect(
        _ submission: AgentRecoveryIntentSubmission,
        attempt: AgentRecoveryAttemptStart,
        submittedRevision: AgentRecoveryComposerRevision
    ) async -> Result<AgentRecoverySubmissionResult<AgentRecoveryDispatchReceipt>, AgentRecoveryControllerFailure> {
        let callTimeConsumption = consumption(for: submittedRevision)
        let store = store
        let binding = gate.binding
        return await serialized { controller in
            let consumption = controller.effectiveConsumption(callTimeConsumption)
            return await controller.performSubmission(consumption: consumption, intentReceipt: \.intent) {
                try await store.commitDispatchingIntent(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    submission: submission,
                    attempt: attempt,
                    consumption: consumption
                )
            }
        }
    }

    private func consumption(for submittedRevision: AgentRecoveryComposerRevision) -> AgentRecoveryComposerConsumption {
        // Captured at call time: later typing must never become consumable by this submission.
        var superseded: Set<AgentRecoveryComposerRevision> = []
        if let index = issuedRevisions.firstIndex(of: submittedRevision) {
            superseded.formUnion(issuedRevisions[...index])
        }
        // A durable revision this controller did not issue (adopted at init/restore or left after a
        // consumption) predates every issued revision. One it issued counts only if it precedes the
        // submitted revision, which the prefix above already covers.
        // A restored draft awaiting its rollback is never consumed: no submission carries it.
        if let durableComposerRevision, !issuedRevisions.contains(durableComposerRevision),
           durableComposerRevision != unrevertedRestore?.restoredRevision
        {
            superseded.insert(durableComposerRevision)
        }
        // R02: a protected restored revision is never consumable, even when this controller issued it
        // (a raced protected placement).
        if let protected = unrevertedRestore?.restoredRevision {
            superseded.remove(protected)
        }
        return AgentRecoveryComposerConsumption(
            submittedRevision: submittedRevision,
            supersededRevisions: superseded
        )
    }

    /// Runs inside the serialized submission. Keeps the call-time cutoff (later typing is never
    /// added) and adds only a baseline learned by a preceding restore that is still the stored
    /// composer. That baseline was not issued by this controller, so it predates the submitted edit;
    /// a newer stored revision (one this controller wrote) never qualifies.
    private func effectiveConsumption(_ callTime: AgentRecoveryComposerConsumption) -> AgentRecoveryComposerConsumption {
        guard let baseline = restoredBaselineRevision,
              durableComposerRevision == baseline,
              !callTime.consumableRevisions.contains(baseline)
        else {
            return callTime
        }
        return AgentRecoveryComposerConsumption(
            submittedRevision: callTime.submittedRevision,
            supersededRevisions: callTime.consumableRevisions.union([baseline])
        )
    }

    // MARK: Restoration

    /// Reads the durable composer for restoration. The validated read sets the durable baselines
    /// inside the serialized operation, so writes queued after it compare against what is stored
    /// even when live adoption is skipped. Returns `.superseded` if the user edited while the read was
    /// in flight, so a restore never overwrites newer typing (which then replaces the stored
    /// composer on its next write). A composer from another reset generation is never adopted and
    /// never becomes a baseline.
    package func loadRestorableComposer() async -> AgentRecoveryComposerRestoreOutcome {
        let revisionAtRequest = liveRevision
        let store = store
        let sessionID = gate.binding.sessionID
        return await serialized { controller in
            guard !controller.isRetired else { return .failed(.retired) }
            let result = await controller.inGate { await store.read(sessionID: sessionID) }
            return controller.applyRestoreRead(result, revisionAtRequest: revisionAtRequest)
        }
    }

    /// Runs inside the serialized restore operation: no later operation has started, so learning the
    /// baseline here never overwrites a later write's or submission's baseline.
    private func applyRestoreRead(
        _ result: Result<AgentRecoveryRecordState, AgentRecoveryControllerFailure>,
        revisionAtRequest: AgentRecoveryComposerRevision?
    ) -> AgentRecoveryComposerRestoreOutcome {
        let binding = gate.binding
        let stored: AgentRecoveryComposerSnapshot?
        switch result {
        case let .failure(failure):
            return .failed(failure)
        case .success(.absent):
            stored = nil
        case let .success(.preserved(reason)):
            return .failed(.store(.unreadableRecord(binding.sessionID, reason)))
        case let .success(.supported(record)):
            guard record.incarnationID == binding.incarnationID else {
                return .failed(.store(.staleIncarnation(expected: binding.incarnationID, actual: record.incarnationID)))
            }
            stored = record.composer
        }
        if let stored, stored.transcriptResetGeneration != binding.transcriptResetGeneration {
            durableComposerRevision = nil
            heldComposerRevision = stored.revision
            restoredBaselineRevision = nil
            return .heldForOtherGeneration(stored)
        }
        durableComposerRevision = stored?.revision
        heldComposerRevision = nil
        restoredBaselineRevision = stored.flatMap {
            issuedRevisions.contains($0.revision) || $0.revision == unrevertedRestore?.restoredRevision ? nil : $0.revision
        }
        guard liveRevision == revisionAtRequest, pending == nil else { return .superseded }
        return .restored(stored)
    }

    // MARK: Private

    private func makeTimer(until deadline: ContinuousClock.Instant) -> Task<Void, Never> {
        let sleep = sleep
        return Task { [weak self] in
            do {
                try await sleep(deadline)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = await serialized { await $0.writePending() }
        }
    }

    private func cancelTimers() {
        debounceTask?.cancel()
        debounceTask = nil
        maximumDelayTask?.cancel()
        maximumDelayTask = nil
        maximumDelayDeadline = nil
    }

    /// Runs operations one at a time in submission order.
    private func serialized<T: Sendable>(
        _ operation: @escaping @MainActor (AgentRecoveryComposerPersistenceController) async -> T
    ) async -> T {
        let previous = operationTail
        let task = Task { @MainActor [self] in
            await previous?.value
            return await operation(self)
        }
        operationTail = Task { _ = await task.value }
        enqueuedOperationCount += 1
        return await task.value
    }

    private func writePending() async -> AgentRecoveryComposerFlushOutcome {
        // The snapshot is captured at execution time; the timers covering it are spent. Mutations
        // after this capture arm their own deadlines, which completion never resets.
        cancelTimers()
        guard !isRetired else { return pending == nil ? .nothingPending : .failed(.retired) }
        let capturedSince = uncapturedSince
        uncapturedSince = nil
        // R02: a restored draft awaiting rollback is never replaced; the rollback is retried first.
        if let failure = await retryOutstandingRestoreRollback() {
            if pending != nil, let capturedSince, uncapturedSince.map({ capturedSince < $0 }) ?? true {
                uncapturedSince = capturedSince
            }
            return .failed(failure)
        }
        guard let snapshot = pending else { return .nothingPending }
        let expectedComposerRevision = durableComposerRevision
        let store = store
        let binding = gate.binding
        let result = await withConflictRetry {
            try await store.commitComposer(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                expectedComposerRevision: expectedComposerRevision,
                snapshot: snapshot
            )
        }
        switch result {
        case let .success(receipt):
            durableComposerRevision = receipt.composerRevision
            // A composer write succeeds only when no held composer is stored.
            heldComposerRevision = nil
            restoredBaselineRevision = nil
            lastWriteFailure = nil
            if pending?.revision == snapshot.revision {
                pending = nil
            }
            // Revisions issued before the committed one can no longer be the stored composer (this
            // controller is its only writer), so dropping them never changes a consumption outcome;
            // in-flight submissions captured their consumption set at call time.
            if let index = issuedRevisions.firstIndex(of: snapshot.revision) {
                issuedRevisions.removeSubrange(..<index)
            }
            return .committed(receipt)
        case let .failure(failure):
            lastWriteFailure = failure
            if case let .store(.heldComposerUnresolved(revision, _)) = failure {
                heldComposerRevision = revision
            }
            // The snapshot is still owed from its original first mutation. No timer is re-armed
            // here (persistent storage failure must not spin); the next mutation arms the
            // already-due deadline, and flush retries immediately.
            if let capturedSince, uncapturedSince.map({ capturedSince < $0 }) ?? true {
                uncapturedSince = capturedSince
            }
            return .failed(failure)
        }
    }

    private func performSubmission<Receipt: Equatable & Sendable>(
        consumption: AgentRecoveryComposerConsumption,
        intentReceipt: (Receipt) -> AgentRecoveryIntentReceipt,
        commit: @escaping @Sendable () async throws -> Receipt
    ) async -> Result<AgentRecoverySubmissionResult<Receipt>, AgentRecoveryControllerFailure> {
        guard !isRetired else { return .failure(.retired) }
        let receipt: Receipt
        switch await withConflictRetry(commit) {
        case let .success(value):
            receipt = value
        case let .failure(failure):
            return .failure(failure)
        }
        durableComposerRevision = intentReceipt(receipt).composerRevision
        heldComposerRevision = intentReceipt(receipt).heldComposerRevision
        if durableComposerRevision != restoredBaselineRevision {
            restoredBaselineRevision = nil
        }
        // The submitted content (and anything it superseded) now lives in the intent; newer typing
        // stays pending and is written independently.
        if let pendingRevision = pending?.revision, consumption.consumableRevisions.contains(pendingRevision) {
            pending = nil
            uncapturedSince = nil
            cancelTimers()
        }
        if let index = issuedRevisions.firstIndex(of: consumption.submittedRevision) {
            issuedRevisions.removeSubrange(...index)
        }
        return .success(AgentRecoverySubmissionResult(receipt: receipt, submittedRevision: consumption.submittedRevision))
    }

    /// Runs `body` inside the lifecycle gate, retrying a record-revision conflict by rereading.
    private func withConflictRetry<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, AgentRecoveryControllerFailure> {
        var lastFailure: AgentRecoveryControllerFailure = .store(.storageFailure("no attempt", cause: .other))
        for _ in 0 ..< Self.maximumConflictRetries {
            let result = await inGate(body)
            if case let .failure(.store(error)) = result, case .revisionConflict = error {
                lastFailure = .store(error)
                continue
            }
            return result
        }
        return .failure(lastFailure)
    }

    private func inGate<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, AgentRecoveryControllerFailure> {
        do {
            return try await .success(gate.performRecoveryTransaction(body))
        } catch let error as AgentRecoveryStoreError {
            return .failure(.store(error))
        } catch {
            return .failure(.lifecycleRejected(String(describing: error)))
        }
    }
}
