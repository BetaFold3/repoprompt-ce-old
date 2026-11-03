import Foundation

// Lossless-restart Phase 2 pending-question persistence (plan §E). Owned by each session's recovery
// lane next to its composer controller; reuses the composer's bounded scheduling pattern.

package enum AgentRecoveryQuestionFlushOutcome: Equatable {
    case nothingPending
    case committed
    case failed(AgentRecoveryControllerFailure)
}

/// Whether an answer's latest snapshot was preserved before its reply (plan §E answer ordering).
package enum AgentRecoveryQuestionReplyPreservation: Equatable {
    case preserved
    case failed(AgentRecoveryControllerFailure)
    /// Storage did not answer within the bound; the write continues, the reply is not sent.
    case timedOut
}

/// Owns one session's live pending-question snapshots: creation and queue insertion are written
/// immediately; non-secret draft changes are coalesced per interaction ID with a 300 ms debounce and
/// a 2-second maximum delay from the first unsaved change; every write is one serialized,
/// interaction-keyed store update (`AgentRecoveryStore.QuestionSnapshotUpdate`).
///
/// An ended interaction (answered, declined, cancelled, timed out, or expired) is terminal here:
/// later edits never resurrect it. Ending without preservation cancels its coalesced upsert and owes
/// an exact removal, which is retried with every later write (never by re-sending a response) until
/// it commits. Ending with preservation (window close, app quit) keeps its latest snapshot.
///
/// Ownership: this controller persists only interactions created through it (`commitCreation`).
/// Drafts and endings of any other interaction are ignored here; a question it never created (for
/// example one a closed window preserved, or one written only by shutdown preparation) is left to
/// that owner's exact-ID bookkeeping.
///
/// Snapshots are immutable values built by `AgentRecoveryQuestionSnapshotBuilder`, so secret answers
/// are structurally absent; nothing here logs or describes snapshot content.
@MainActor
package final class AgentRecoveryQuestionPersistenceController {
    package typealias Sleep = AgentRecoveryComposerPersistenceController.Sleep
    package typealias Write = @MainActor (
        AgentRecoveryStore.QuestionSnapshotUpdate
    ) async -> Result<AgentRecoveryStore.QuestionSnapshotUpdateReceipt, AgentRecoveryControllerFailure>

    package static let debounce = AgentRecoveryComposerPersistenceController.debounce
    package static let maximumDelay = AgentRecoveryComposerPersistenceController.maximumDelay

    private let write: Write
    private let sleep: Sleep
    private let clockNow: () -> ContinuousClock.Instant

    /// Latest unsaved snapshot per interaction (creation, draft, or a preserved ending's final state).
    private var pendingUpserts: [UUID: AgentRecoveryQuestionSnapshot] = [:]
    /// Snapshot this controller last committed per interaction (unchanged drafts are not rewritten).
    private var committedSnapshots: [UUID: AgentRecoveryQuestionSnapshot] = [:]
    /// Terminal markers: an ended interaction is never written again by a draft.
    private var endedIDs: Set<UUID> = []
    /// Interactions created through this controller whose snapshot may be stored (until removed).
    private var knownIDs: Set<UUID> = []
    /// Exact removals of ended interactions not yet committed; retried with every later write.
    package private(set) var owedRemovals: Set<UUID> = []
    /// Interactions whose snapshot or removal a write in flight carries (not yet known durable).
    private var inFlightIDs: Set<UUID> = []
    /// Snapshots a write in flight carries (newer than `committedSnapshots` until it commits).
    private var inFlightUpserts: [UUID: AgentRecoveryQuestionSnapshot] = [:]
    /// Live interactions whose submitted answer was not sent because its latest snapshot could not
    /// be preserved first. The answer stays in its live card; submitting again retries.
    package private(set) var unsentAnswerIDs: Set<UUID> = [] {
        didSet {
            if oldValue != unsentAnswerIDs { stateDidChange?() }
        }
    }

    /// Automatic retries after consecutive failed writes are bounded (no hot loop); an explicit
    /// Retry, a later edit, or a flush always writes again.
    package static let automaticRetryLimit = 3
    private var consecutiveFailures = 0
    private var retryTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var maximumDelayTask: Task<Void, Never>?
    private var uncapturedSince: ContinuousClock.Instant?
    package private(set) var maximumDelayDeadline: ContinuousClock.Instant?
    private var operationTail: Task<Void, Never>?
    package private(set) var isRetired = false

    /// Last write failure; cleared by the next successful write.
    package private(set) var lastWriteFailure: AgentRecoveryControllerFailure? {
        didSet {
            if oldValue != lastWriteFailure { stateDidChange?() }
        }
    }

    /// Called after a write commits, `lastWriteFailure` changes, or an interaction ends (visible
    /// recovery state: the live set decides which saved questions are historical items).
    package var stateDidChange: (@MainActor () -> Void)?

    package init(
        write: @escaping Write,
        sleep: @escaping Sleep = { try await Task.sleep(until: $0, clock: .continuous) },
        clockNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.write = write
        self.sleep = sleep
        self.clockNow = clockNow
    }

    /// Unsaved snapshots or owed removals exist.
    package var hasPendingWork: Bool {
        !pendingUpserts.isEmpty || !owedRemovals.isEmpty
    }

    /// Whether `interactionID` has a snapshot not yet written.
    package func hasUnsavedSnapshot(_ interactionID: UUID) -> Bool {
        pendingUpserts[interactionID] != nil
    }

    /// Whether `interactionID`'s latest snapshot is not yet known to be durable (unsaved, or carried
    /// by a write still in flight).
    package func needsPreservation(_ interactionID: UUID) -> Bool {
        pendingUpserts[interactionID] != nil || inFlightIDs.contains(interactionID)
    }

    /// Interaction IDs this controller committed and has not removed (test observability).
    package var committedInteractionIDs: Set<UUID> {
        Set(committedSnapshots.keys)
    }

    /// Interactions created through this controller whose live request has not ended (their saved
    /// snapshots are presented by the live question card, never as historical recovery items).
    package var liveInteractionIDs: Set<UUID> {
        isRetired ? [] : knownIDs.subtracting(endedIDs)
    }

    /// Latest snapshot (unsaved, in flight, or committed) of every live interaction whose creation
    /// committed, for an ownership-preserving hand-over (`adoptLiveInteractions`). A creation still
    /// in flight was never published, so it is not handed over (review R2, B R2-F1); a committed
    /// question's unsaved or in-flight draft still is. Empty once retired.
    package var liveSnapshots: [AgentRecoveryQuestionSnapshot] {
        liveInteractionIDs.filter { committedSnapshots[$0] != nil }
            .compactMap { pendingUpserts[$0] ?? inFlightUpserts[$0] ?? committedSnapshots[$0] }
            .sorted { $0.interactionID.uuidString < $1.interactionID.uuidString }
    }

    // MARK: Creation

    /// Writes a newly created or queued interaction now (no debounce), together with every other
    /// unsaved snapshot and owed removal. A new interaction clears any earlier terminal marker for
    /// its ID. On failure the snapshot stays unsaved (retried by the next write or flush) unless the
    /// caller withdraws it with `forget`.
    package func commitCreation(_ snapshot: AgentRecoveryQuestionSnapshot) async -> Result<Void, AgentRecoveryControllerFailure> {
        guard !isRetired else { return .failure(.retired) }
        let id = snapshot.interactionID
        endedIDs.remove(id)
        owedRemovals.remove(id)
        knownIDs.insert(id)
        pendingUpserts[id] = snapshot
        let outcome = await serialized { await $0.writePending() }
        switch outcome {
        case let .failed(failure):
            return .failure(failure)
        case .committed, .nothingPending:
            // Committed by this write, or by an earlier one that captured the same snapshot.
            return committedSnapshots[id] != nil || endedIDs.contains(id) ? .success(()) : .failure(lastWriteFailure ?? .retired)
        }
    }

    /// Withdraws an interaction that was never published (its creation write failed): nothing more
    /// is written for it, and no removal is owed for a snapshot that was never stored.
    package func forget(_ interactionID: UUID) {
        pendingUpserts[interactionID] = nil
        unsentAnswerIDs.remove(interactionID)
        endedIDs.insert(interactionID)
        if committedSnapshots[interactionID] != nil {
            owedRemovals.insert(interactionID)
            scheduleImmediateWrite()
        } else {
            knownIDs.remove(interactionID)
        }
        stateDidChange?()
    }

    // MARK: Drafts

    /// Records the latest sanitized snapshot of a live interaction after a non-secret edit and
    /// schedules the bounded write. Ignored for an ended interaction or an unchanged snapshot.
    package func draftDidChange(_ snapshot: AgentRecoveryQuestionSnapshot) {
        guard !isRetired else { return }
        let id = snapshot.interactionID
        guard knownIDs.contains(id), !endedIDs.contains(id) else { return }
        if pendingUpserts[id] == nil, committedSnapshots[id] == snapshot { return }
        pendingUpserts[id] = snapshot
        let mutationInstant = clockNow()
        let firstUnsaved = uncapturedSince.map { min($0, mutationInstant) } ?? mutationInstant
        uncapturedSince = firstUnsaved
        let deadline = firstUnsaved + Self.maximumDelay
        guard deadline > mutationInstant else {
            scheduleImmediateWrite()
            return
        }
        debounceTask?.cancel()
        debounceTask = makeTimer(until: mutationInstant + Self.debounce)
        if maximumDelayTask == nil || maximumDelayDeadline.map({ deadline < $0 }) == true {
            maximumDelayTask?.cancel()
            maximumDelayDeadline = deadline
            maximumDelayTask = makeTimer(until: deadline)
        }
    }

    // MARK: Ending

    /// Ends interactions. Without `preserving` (answered, declined, cancelled, timed out, expired)
    /// their coalesced upserts are cancelled and exact removals are enqueued now; the caller never
    /// awaits storage. With `preserving` (window close, app quit) the latest snapshot is kept and
    /// any unsaved one is written. Either way later edits are ignored.
    package func end(_ interactionIDs: Set<UUID>, preserving: Bool) {
        let owned = interactionIDs.intersection(knownIDs)
        guard !owned.isEmpty else { return }
        endedIDs.formUnion(owned)
        unsentAnswerIDs.subtract(owned)
        // The live set changed: a preserved question becomes a historical recovery item now.
        defer { stateDidChange?() }
        guard !preserving else {
            if owned.contains(where: { pendingUpserts[$0] != nil }) {
                scheduleImmediateWrite()
            }
            return
        }
        for id in owned {
            pendingUpserts[id] = nil
        }
        owedRemovals.formUnion(owned)
        scheduleImmediateWrite()
    }

    // MARK: Hand-over

    /// A same-owner, same-binding successor adopts the still-live interactions its predecessor
    /// created, so they stay live (not historical) and their drafts and endings keep being
    /// persisted. Only interactions present in `handedOver` are adopted; nothing ended, expired, or
    /// historical is revived.
    ///
    /// Review R1 (A F01-R1 / B R1-F3): the predecessor's retirement flush may still be running or
    /// may fail, so nothing handed over is assumed durable. Every adopted snapshot is pending here
    /// (so a reply waits for its preservation) and is written by this controller only after
    /// `predecessorRetirement` finishes: every later serialized write is ordered behind it, so the
    /// predecessor's last write can never overwrite a newer successor snapshot.
    package func adoptLiveInteractions(
        _ handedOver: [AgentRecoveryQuestionSnapshot],
        after predecessorRetirement: (@MainActor () async -> Void)?
    ) {
        guard !isRetired else { return }
        var adopted = false
        for snapshot in handedOver where !endedIDs.contains(snapshot.interactionID) {
            knownIDs.insert(snapshot.interactionID)
            if pendingUpserts[snapshot.interactionID] == nil {
                pendingUpserts[snapshot.interactionID] = snapshot
            }
            adopted = true
        }
        guard adopted else { return }
        let previous = operationTail
        operationTail = Task { @MainActor in
            await previous?.value
            await predecessorRetirement?()
        }
        stateDidChange?()
        scheduleImmediateWrite()
    }

    // MARK: Answer ordering

    /// Preserves `interactionID`'s latest snapshot before its reply, bounded by `limit`. The reply
    /// may be sent only on `.preserved`; otherwise the answer is marked unsent (a visible, retryable
    /// save error) and stays pending. An interaction with nothing unsaved is preserved already.
    package func preserveBeforeReply(_ interactionID: UUID, within limit: Duration) async -> AgentRecoveryQuestionReplyPreservation {
        guard !isRetired else {
            unsentAnswerIDs.insert(interactionID)
            return .failed(.retired)
        }
        let result = await replyPreservation(interactionID, within: limit)
        if result == .preserved {
            unsentAnswerIDs.remove(interactionID)
        } else if knownIDs.contains(interactionID), !endedIDs.contains(interactionID) {
            unsentAnswerIDs.insert(interactionID)
        }
        return result
    }

    /// Whether `interactionID`'s latest snapshot is durable, flushing (bounded by `limit`) when not.
    private func replyPreservation(_ interactionID: UUID, within limit: Duration) async -> AgentRecoveryQuestionReplyPreservation {
        guard needsPreservation(interactionID) else { return .preserved }
        return switch await flush(within: limit) {
        case nil:
            .timedOut
        case let .failed(failure)?:
            .failed(failure)
        case .committed?, .nothingPending?:
            needsPreservation(interactionID) || isRetired ? .failed(lastWriteFailure ?? .retired) : .preserved
        }
    }

    // MARK: Flush and drain

    /// Writes every unsaved snapshot and owed removal now. An explicit flush that finds nothing left
    /// unsaved settles an earlier failure (for example a withdrawn creation), so its save error
    /// is cleared; automatic timer retries never clear it.
    package func flush() async -> AgentRecoveryQuestionFlushOutcome {
        let outcome = await serialized { await $0.writePending() }
        if outcome == .nothingPending, !hasPendingWork, lastWriteFailure != nil {
            lastWriteFailure = nil
            consecutiveFailures = 0
        }
        return outcome
    }

    /// `flush()` bounded by `limit` on this controller's clock: `nil` when storage did not answer in
    /// time (the write continues; a later write or drain still settles it).
    package func flush(within limit: Duration) async -> AgentRecoveryQuestionFlushOutcome? {
        let deadline = clockNow() + limit
        let race = BoundedRace<AgentRecoveryQuestionFlushOutcome?>()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            let sleep = sleep
            race.timeout = Task { @MainActor in
                try? await sleep(deadline)
                race.finish(nil)
            }
            Task { @MainActor [self] in
                let outcome = await flush()
                race.finish(outcome)
            }
        }
    }

    /// Stage A: joins every serialized write, then writes what is still owed. Fails when anything
    /// remains unsaved or a removal still could not be committed.
    package func drain() async -> AgentRecoveryQuestionFlushOutcome {
        await operationTail?.value
        let outcome = await flush()
        if case .failed = outcome { return outcome }
        if hasPendingWork { return .failed(lastWriteFailure ?? .retired) }
        return outcome
    }

    // MARK: Retirement

    /// Retires before a replacement owner is installed; with `flushingPending` (same binding) the
    /// unsaved snapshots and owed removals are written first. Waits for every serialized write.
    @discardableResult
    package func retire(flushingPending: Bool) async -> AgentRecoveryQuestionFlushOutcome? {
        let outcome: AgentRecoveryQuestionFlushOutcome? = flushingPending ? await flush() : nil
        isRetired = true
        cancelTimers()
        unsentAnswerIDs = []
        await operationTail?.value
        return outcome
    }

    // MARK: Private

    private func scheduleImmediateWrite() {
        guard !isRetired else { return }
        cancelTimers()
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await serialized { await $0.writePending() }
        }
    }

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
        retryTask?.cancel()
        retryTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        maximumDelayTask?.cancel()
        maximumDelayTask = nil
        maximumDelayDeadline = nil
    }

    private func serialized<T: Sendable>(
        _ operation: @escaping @MainActor (AgentRecoveryQuestionPersistenceController) async -> T
    ) async -> T {
        let previous = operationTail
        let task = Task { @MainActor [self] in
            await previous?.value
            return await operation(self)
        }
        operationTail = Task { _ = await task.value }
        return await task.value
    }

    private func writePending() async -> AgentRecoveryQuestionFlushOutcome {
        cancelTimers()
        guard !isRetired else { return hasPendingWork ? .failed(.retired) : .nothingPending }
        let upserts = pendingUpserts
        let removals = owedRemovals
        guard !upserts.isEmpty || !removals.isEmpty else { return .nothingPending }
        let capturedSince = uncapturedSince
        uncapturedSince = nil
        pendingUpserts = [:]
        let ordered = upserts.values.sorted {
            ($0.askedAt.millisecondsSince1970, $0.interactionID.uuidString) < ($1.askedAt.millisecondsSince1970, $1.interactionID.uuidString)
        }
        let carried = Set(upserts.keys).union(removals)
        inFlightIDs.formUnion(carried)
        inFlightUpserts.merge(upserts) { _, new in new }
        let result = await write(AgentRecoveryStore.QuestionSnapshotUpdate(upserting: ordered, removing: removals))
        inFlightIDs.subtract(carried)
        for (id, snapshot) in upserts where inFlightUpserts[id] == snapshot {
            inFlightUpserts[id] = nil
        }
        switch result {
        case .success:
            consecutiveFailures = 0
            for snapshot in ordered {
                committedSnapshots[snapshot.interactionID] = snapshot
            }
            for id in removals {
                committedSnapshots[id] = nil
                // Re-created during this write: its new snapshot is still owed.
                if pendingUpserts[id] == nil {
                    knownIDs.remove(id)
                }
            }
            owedRemovals.subtract(removals)
            lastWriteFailure = nil
            stateDidChange?()
            return .committed
        case let .failure(failure):
            // Still owed, unless a newer snapshot or an ending replaced it meanwhile.
            for (id, snapshot) in upserts where pendingUpserts[id] == nil && !owedRemovals.contains(id) {
                pendingUpserts[id] = snapshot
            }
            if !pendingUpserts.isEmpty, let capturedSince, uncapturedSince.map({ capturedSince < $0 }) ?? true {
                uncapturedSince = capturedSince
            }
            lastWriteFailure = failure
            // Bounded automatic retry of what is still owed (spaced by the maximum draft delay).
            consecutiveFailures += 1
            if consecutiveFailures <= Self.automaticRetryLimit, !isRetired, hasPendingWork, retryTask == nil {
                retryTask = makeTimer(until: clockNow() + Self.maximumDelay)
            }
            return .failed(failure)
        }
    }
}

/// First-of-two completion for `flush(within:)`; MainActor-confined.
@MainActor
private final class BoundedRace<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Never>?
    var timeout: Task<Void, Never>?

    func finish(_ value: Value) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(returning: value)
    }
}
