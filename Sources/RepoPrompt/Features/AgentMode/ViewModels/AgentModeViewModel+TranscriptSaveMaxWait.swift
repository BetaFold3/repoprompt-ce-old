import Foundation
import RepoPromptAgentCore

/// Transcript save maximum wait (lossless-restart R3, Phase 1a).
///
/// The 1 s trailing debounce in `scheduleSave` is kept, but continuous mutations can replace it
/// indefinitely. The first change not yet covered by a successful save starts a 10 s monotonic
/// deadline; when it expires, the ordinary `saveSessionDetailed` path is entered (there is no
/// second writer). A clean receipt of the current owner and projection clears it. A covering
/// write of an older snapshot (`.written`, projection not clean) rebases it to the instant captured
/// immediately before that save call: the snapshot covered every earlier change, so each change
/// still unsaved happened at or after that instant and stays within 10 s of its own time. An
/// acknowledged reset, a write that cannot be shown to cover the pre-call state, or a save deferred
/// behind an in-flight write keeps the deadline and is followed by an immediate save. A save that
/// writes nothing keeps it and retries at least 1 s later (fixed 1 s while waiting for authority).
///
/// The deadline is absolute: the timer sleeps until `first unsaved instant + 10 s`, so a timer
/// task that starts late never extends it. It bounds when a save is requested on healthy
/// storage; it cannot guarantee a write within 10 s when storage fails or another write blocks.
/// Replacing a tab's binding retires the previous owner's obligation
/// (`AgentTabSession.beginPersistentBindingTransition`); a disposed owner's wakeup is obsolete
/// because it is no longer `sessions[tabID]`.
extension AgentModeViewModel {
    enum SaveTimerKind: Equatable {
        case debounce
        case maxWait
        case retry
    }

    static let saveDebounceInterval: Duration = .seconds(1)
    static let transcriptSaveMaxWait: Duration = .seconds(10)
    static let transcriptSaveRetryFloor: Duration = .seconds(1)
    static let transcriptSaveRetryCeiling: Duration = .seconds(30)
    /// Immediate follow-on saves per wakeup before falling back to the retry spacing.
    static let transcriptSaveMaxImmediateFollowOns = 2

    private enum TranscriptSaveMaxWaitAction {
        case save
        case nothingToSave
        case waitForAuthority
    }

    /// Sleep until an absolute monotonic deadline, used by the save timers; tests replace it to
    /// control time without wall-clock waits.
    var saveTimerSleep: @MainActor (SaveTimerKind, ContinuousClock.Instant) async throws -> Void {
        #if DEBUG
            if let override = test_saveTimerSleepOverride {
                return override
            }
        #endif
        return { _, deadline in try await Task.sleep(until: deadline, clock: .continuous) }
    }

    /// Mutation observation for the maximum wait. Called from the source-items callback (which
    /// runs before the mutation's dirty mark) and from every `isDirty = true`. Only the first
    /// unsaved change arms the deadline; later changes never move it.
    func noteTranscriptPersistenceMutation(_ session: AgentTabSession) {
        guard session.transcriptSaveFirstUnsavedAt == nil,
              !AppLaunchConfiguration.current.suppressesAgentSessionPersistence,
              !hasPreparedForWindowClose,
              sessions[session.tabID] === session
        else { return }
        let firstUnsavedAt = ContinuousClock.now
        session.transcriptSaveFirstUnsavedAt = firstUnsavedAt
        session.transcriptSaveMaxWaitRetryCount = 0
        armTranscriptSaveTimer(session, kind: .maxWait, until: firstUnsavedAt + Self.transcriptSaveMaxWait)
    }

    /// Withdraws the obligation: called by a clean current save receipt, or when nothing is
    /// left that this owner may save.
    func clearTranscriptSaveMaxWait(_ session: AgentTabSession) {
        session.invalidateTranscriptSaveMaxWait()
    }

    /// Workspace-switch discard: the owner is discarded, so neither the debounce nor the maximum
    /// wait may start a save afterwards. Window close keeps its pending debounce and only clears
    /// the maximum wait (`prepareSessionForWindowClose`).
    func cancelTranscriptSaveTimers(_ session: AgentTabSession) {
        session.saveDebounceTask?.cancel()
        session.saveDebounceTask = nil
        clearTranscriptSaveMaxWait(session)
    }

    private func armTranscriptSaveTimer(
        _ session: AgentTabSession,
        kind: SaveTimerKind,
        until deadline: ContinuousClock.Instant
    ) {
        session.transcriptSaveMaxWaitTask?.cancel()
        session.transcriptSaveMaxWaitGeneration &+= 1
        let generation = session.transcriptSaveMaxWaitGeneration
        let sleep = saveTimerSleep
        session.transcriptSaveMaxWaitTask = Task { [weak self, weak session] in
            do {
                try await sleep(kind, deadline)
            } catch {
                return
            }
            guard let self, let session else { return }
            await serviceTranscriptSaveMaxWait(session, generation: generation)
        }
    }

    private func transcriptSaveMaxWaitIsCurrent(_ session: AgentTabSession, generation: UInt64) -> Bool {
        sessions[session.tabID] === session
            && session.transcriptSaveMaxWaitGeneration == generation
            && session.transcriptSaveFirstUnsavedAt != nil
    }

    private func transcriptSaveMaxWaitAction(for session: AgentTabSession) -> TranscriptSaveMaxWaitAction {
        if AppLaunchConfiguration.current.suppressesAgentSessionPersistence {
            return .nothingToSave
        }
        // A retained stale-reset view has no save authority until an explicit reload.
        if session.staleResetRecovery != nil {
            return .nothingToSave
        }
        // A removal operation reserving this owner owns its final save. The obligation is parked,
        // not cleared: a committed removal makes the owner obsolete, an aborted one saves next.
        if session.staleResetRemovalAdmission?.blocksScheduledSaves == true {
            return .waitForAuthority
        }
        guard session.isDirty || !session.pendingAssistantDelta.isEmpty else {
            return .nothingToSave
        }
        if session.activeAgentSessionID == nil,
           session.pendingAssistantDelta.isEmpty,
           !hasPersistableConversationContent(session)
        {
            return .nothingToSave
        }
        // Never start a save for a bound owner without paired hydration authority.
        if session.activeAgentSessionID != nil, !hasTranscriptSaveHydrationAuthority(session) {
            return .waitForAuthority
        }
        return .save
    }

    /// Paired hydration authority for a bound owner, stricter than `hasLoadedPersistedState`:
    /// no load in flight, no binding transition underway, and the last published paired-load
    /// outcome adopted this binding (`.applied`), found nothing to adopt (`.noPayload`,
    /// `.unbound`), or no load ever ran (a fresh creator). `.unresolved`, `.failed`, and
    /// `.suppressed` never qualify. The save path's commit-token and persistence-state checks
    /// stay authoritative after every suspension.
    func hasTranscriptSaveHydrationAuthority(_ session: AgentTabSession) -> Bool {
        guard session.hasLoadedPersistedState,
              session.persistedLoadTask == nil,
              !session.bindingTransitionInProgress
        else { return false }
        switch session.persistedLoadDisposition {
        case nil, .applied, .noPayload, .unbound:
            return true
        case .unresolved, .failed, .suppressed:
            return false
        }
    }

    private func serviceTranscriptSaveMaxWait(_ session: AgentTabSession, generation: UInt64) async {
        guard transcriptSaveMaxWaitIsCurrent(session, generation: generation) else { return }
        session.transcriptSaveMaxWaitTask = nil
        var immediateFollowOns = 0
        while true {
            switch transcriptSaveMaxWaitAction(for: session) {
            case .nothingToSave:
                clearTranscriptSaveMaxWait(session)
                return
            case .waitForAuthority:
                // The check is synchronous and does no I/O, so waiting never escalates.
                scheduleTranscriptSaveRetry(session, escalates: false)
                return
            case .save:
                break
            }
            #if DEBUG
                AgentModePerfDiagnostics.increment("save.maxWait.save", tabID: session.tabID)
            #endif
            // Captured with no suspension before the call; the save's synchronous prefix builds
            // its payload and commit token from session state at or after this instant.
            let capture = captureTranscriptSaveState(session)
            let outcome = await saveSessionDetailed(for: session.tabID)
            // A clean current receipt cleared the deadline (a later change may have armed a new
            // one); an obsolete or replaced owner never continues.
            guard transcriptSaveMaxWaitIsCurrent(session, generation: generation) else { return }
            switch outcome {
            case .suppressed:
                clearTranscriptSaveMaxWait(session)
                return
            case let .written(receipt):
                session.transcriptSaveMaxWaitRetryCount = 0
                // A covering stale write rebases; with unverified coverage the deadline stays and
                // an immediate save follows.
                if !receipt.projectionClean, staleWriteCoversCapture(receipt, capture, session: session) {
                    rebaseTranscriptSaveMaxWait(session, to: capture.instant)
                    return
                }
            case .resetAcknowledged:
                // The reset barrier is durable, not the newer edits; the deadline has passed.
                session.transcriptSaveMaxWaitRetryCount = 0
            case .deferredBehindInFlightSave:
                if let sessionID = session.activeAgentSessionID {
                    await awaitInFlightSave(sessionID: sessionID)
                }
                guard transcriptSaveMaxWaitIsCurrent(session, generation: generation) else { return }
            case .notWritten:
                scheduleTranscriptSaveRetry(session)
                return
            }
            immediateFollowOns += 1
            guard immediateFollowOns <= Self.transcriptSaveMaxImmediateFollowOns else {
                scheduleTranscriptSaveRetry(session)
                return
            }
        }
    }

    /// Pre-call state of one maximum-wait save, for proving a stale write covered it (also Send
    /// saved's placement write, O11).
    struct TranscriptSaveCapture {
        let instant: ContinuousClock.Instant
        let sourceItemsRevision: Int
        let persistenceMutationGeneration: UInt64
        let binding: AgentPersistentSessionBindingIdentity?
        let bindingTransitionGeneration: UInt64
        let context: SessionPersistenceContext?
    }

    func captureTranscriptSaveState(_ session: AgentTabSession) -> TranscriptSaveCapture {
        TranscriptSaveCapture(
            instant: .now,
            sourceItemsRevision: session.sourceItemsRevision,
            persistenceMutationGeneration: session.persistenceMutationGeneration,
            binding: session.persistentSessionBindingIdentity,
            bindingTransitionGeneration: session.bindingTransitionGeneration,
            context: currentSessionPersistenceContext()
        )
    }

    /// Whether this call's own written receipt covers every change before the capture, for the
    /// same owner, binding, and persistence context, with paired hydration authority intact. The
    /// receipt's counters are the commit token's, captured after the payload was built in the
    /// save's synchronous prefix (the same invariant a clean receipt relies on to clear dirty).
    func staleWriteCoversCapture(
        _ receipt: SessionSaveReceipt,
        _ capture: TranscriptSaveCapture,
        session: AgentTabSession
    ) -> Bool {
        guard receipt.sourceItemsRevision >= capture.sourceItemsRevision,
              receipt.persistenceMutationGeneration >= capture.persistenceMutationGeneration,
              let binding = session.persistentSessionBindingIdentity,
              binding.sessionID == session.activeAgentSessionID,
              !session.bindingTransitionInProgress,
              let context = capture.context,
              sessionPersistenceContextIsCurrent(context),
              hasTranscriptSaveHydrationAuthority(session)
        else { return false }
        // A creator's first save binds inside the call; an existing binding must be unchanged.
        guard let capturedBinding = capture.binding else { return true }
        return capturedBinding == binding && capture.bindingTransitionGeneration == session.bindingTransitionGeneration
    }

    /// Keeps the obligation for changes after `instant`, due 10 s after it; no immediate rewrite
    /// follows.
    private func rebaseTranscriptSaveMaxWait(_ session: AgentTabSession, to instant: ContinuousClock.Instant) {
        session.transcriptSaveFirstUnsavedAt = instant
        session.transcriptSaveMaxWaitRetryCount = 0
        #if DEBUG
            AgentModePerfDiagnostics.increment("save.maxWait.rebase", tabID: session.tabID)
        #endif
        let deadline = Self.rebasedTranscriptSaveDeadline(capturedAt: instant, completedAt: .now)
        armTranscriptSaveTimer(session, kind: .maxWait, until: deadline)
    }

    /// `capturedAt + 10 s`, unchanged whenever it is still in the future (however close). Only a
    /// covering write that took 10 s or more (blocked or unhealthy storage) finds it expired; the
    /// next save then waits the 1 s retry floor instead of following back to back.
    static func rebasedTranscriptSaveDeadline(
        capturedAt: ContinuousClock.Instant,
        completedAt: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        let deadline = capturedAt + transcriptSaveMaxWait
        return deadline > completedAt ? deadline : completedAt + transcriptSaveRetryFloor
    }

    /// One coalesced retry, at least 1 s away. Failed writes double the spacing up to 30 s; waiting
    /// for authority (`escalates: false`) retries at the fixed 1 s floor.
    private func scheduleTranscriptSaveRetry(_ session: AgentTabSession, escalates: Bool = true) {
        let delay: Duration
        if escalates {
            let exponent = min(session.transcriptSaveMaxWaitRetryCount, 5)
            session.transcriptSaveMaxWaitRetryCount += 1
            delay = min(Self.transcriptSaveRetryFloor * (1 << exponent), Self.transcriptSaveRetryCeiling)
        } else {
            delay = Self.transcriptSaveRetryFloor
        }
        #if DEBUG
            AgentModePerfDiagnostics.increment("save.maxWait.retry", tabID: session.tabID)
        #endif
        armTranscriptSaveTimer(session, kind: .retry, until: ContinuousClock.now + delay)
    }
}
