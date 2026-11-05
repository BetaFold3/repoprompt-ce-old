import Foundation

// Automatic crash-hold confirmation (owner decision, 2026-10-31). After a restart, "Sending is
// paused" is confirmed without the user's click exactly when Check and resolve's process-record
// proof holds (`AgentRecoveryCoordinator+CrashHoldProof.swift`, conditions (a)-(f)). It uses the
// same proof, the same one write (the exact acknowledgement It stopped writes, settling every
// qualifying uncertain intent to `deliveryUnknown`, never resending) and the same publication (so
// already-authorized scheduled sends may then run, as after It stopped). Unlike Check it needs no
// card: a dismissed hold, which still pauses sending, is confirmed too.
//
// A pass over every hold runs once startup is ready, and again whenever the adopted runtime
// snapshot changes (a watched process exited, or a Refresh) or a shutdown freeze ends. A pass over
// one session's hold runs when the session is opened, a recovery action or It stopped releases it,
// a crash-hold row it skipped stops working (Check, Open, Refresh or any other row action,
// `setCatalogActionState`), or a delayed save retry covering it fires. One pass runs at a time;
// requests during it are merged into one rerun. It never refreshes the registry (that would
// trigger it again), never signals a process, and never confirms a hold the proof doesn't cover
// (no open run, a legacy turn, a run started before registration was active, a process that may
// still run): those keep asking the user. The reason a hold still needs the user is kept for the
// paused banner (`automaticCrashHoldRefusal(for:)`); transient refusals (busy, changed, closing,
// the snapshot catching up) keep the last reason. A failed save of a proven confirmation is shown,
// logged and retried after a bounded backoff (`automaticCrashHoldSaveRetryDelays`: each hold is
// charged one delay per timer that covers it; a deferred attempt schedules none, its own trigger
// runs it again), and again on any later trigger; the banner says "retrying" only while a timer
// covers the hold. While it claims a session (between its proof and its commit), Check and It
// stopped wait for it and recovery actions are refused; while It stopped confirms a session, it
// leaves that session alone.

/// Why the automatic confirmation left a hold for the user: what the paused banner explains.
package enum AgentRecoveryAutomaticCrashHoldRefusal: Equatable {
    /// The proof doesn't hold, or can't be decided, for this reason.
    case needsYou(AgentRecoveryCrashHoldNeedsYouReason)
    /// Process records proved the exit, but saving the confirmation failed; `retrying` while a
    /// delayed retry covers the hold.
    case saveFailed(retrying: Bool)
}

/// One automatic attempt at one hold.
private enum AutomaticCrashHoldResult {
    case confirmed
    case refused(AgentRecoveryAutomaticCrashHoldRefusal)
    /// The proof held but saving failed (`diagnostic` is logged, never shown).
    case saveFailed(diagnostic: String)
    /// Not decided now (inactive, busy, changed, closing, the snapshot catching up): keeps the last
    /// reason; a later trigger decides it.
    case deferred
}

extension AgentRecoveryCoordinator {
    /// Requests a pass (coalesced) over every hold, or only `sessionID`'s. Does nothing before
    /// startup is ready or while inactive.
    func requestAutomaticCrashHoldConfirmation(sessionID: UUID? = nil) {
        guard startupState == .ready, processRegistry != nil, automaticCrashHoldConfirmationActive() else { return }
        if let sessionID {
            automaticCrashHoldPendingSessionIDs.insert(sessionID)
        } else {
            automaticCrashHoldPendingAll = true
        }
        guard automaticCrashHoldTask == nil else { return }
        automaticCrashHoldTask = Task { @MainActor [weak self] in
            await self?.runAutomaticCrashHoldConfirmationPasses()
        }
    }

    /// Waits until the automatic confirmation no longer claims `sessionID` (it may still be
    /// checking other sessions).
    func waitForAutomaticCrashHoldClaim(sessionID: UUID) async {
        while automaticCrashHoldSessionIDs.contains(sessionID) {
            await withCheckedContinuation { continuation in
                automaticCrashHoldClaimWaiters[sessionID, default: []].append(continuation)
            }
        }
    }

    private func runAutomaticCrashHoldConfirmationPasses() async {
        var failedSaves: Set<UUID> = []
        while automaticCrashHoldPendingAll || !automaticCrashHoldPendingSessionIDs.isEmpty {
            let all = automaticCrashHoldPendingAll
            let sessions = automaticCrashHoldPendingSessionIDs
            automaticCrashHoldPendingAll = false
            automaticCrashHoldPendingSessionIDs = []
            pruneAutomaticCrashHoldEntries()
            for hold in unconfirmedCrashHolds where all || sessions.contains(hold.sessionID) {
                let result = await confirmCrashHoldAutomatically(hold)
                if recordAutomaticCrashHoldResult(result, for: hold) {
                    failedSaves.insert(hold.sessionID)
                } else {
                    failedSaves.remove(hold.sessionID)
                }
            }
        }
        automaticCrashHoldTask = nil
        scheduleAutomaticCrashHoldSaveRetry(for: failedSaves)
        publishAutomaticCrashHoldRetryCoverage()
    }

    /// Drops reasons, failure counts and row skips of holds no longer published unconfirmed (or
    /// replaced).
    private func pruneAutomaticCrashHoldEntries() {
        func isLive(_ sessionID: UUID, _ hold: AgentRecoveryCrashHold) -> Bool {
            crashHold(for: sessionID) == hold && !isCrashHoldConfirmed(hold)
        }
        automaticCrashHoldRefusals = automaticCrashHoldRefusals.filter { isLive($0.key, $0.value.hold) }
        for (sessionID, entry) in automaticCrashHoldSaveFailures where !isLive(sessionID, entry.hold) {
            clearAutomaticCrashHoldSaveFailure(sessionID)
        }
        automaticCrashHoldRowDeferredSessionIDs = automaticCrashHoldRowDeferredSessionIDs.filter { sessionID in
            crashHold(for: sessionID).map { !isCrashHoldConfirmed($0) } == true
        }
    }

    /// Confirms `hold` when process records prove its processes exited; otherwise returns why it
    /// still needs the user. Claims the session before its first suspension and releases it when it
    /// ends; only the pass calls it (one claim per session at a time).
    private func confirmCrashHoldAutomatically(_ hold: AgentRecoveryCrashHold) async -> AutomaticCrashHoldResult {
        if automaticCrashHoldBlocked(hold) { return .deferred }
        guard let registry = processRegistry else { return .refused(.needsYou(.ownershipUncertain)) }
        if let refusal = crashHoldProofPreconditionRefusal(hold) { return Self.automaticResult(of: refusal) }
        automaticCrashHoldSessionIDs.insert(hold.sessionID)
        defer { releaseAutomaticCrashHoldClaim(hold.sessionID) }

        let proof = await crashHoldRegistryExitProof(hold, registry: registry)
        if automaticCrashHoldBlocked(hold) { return .deferred }
        if let refusal = Self.crashHoldProofRefusal(proof) { return Self.automaticResult(of: refusal) }

        // The commit: bounded retry on a revision conflict, each attempt re-checking (e) and (f).
        for _ in 0 ..< 3 {
            if automaticCrashHoldBlocked(hold) { return .deferred }
            if let refusal = crashHoldSnapshotRefusal(hold) { return Self.automaticResult(of: refusal) }
            if let refusal = crashHoldWriteDestinationRefusal(hold) { return Self.automaticResult(of: refusal) }
            #if DEBUG
                await test_automaticCrashHoldAtCommit?()
            #endif
            switch await commitCrashHoldAcknowledgement(hold, card: nil) {
            case nil:
                return .refused(.needsYou(.openToConfirm))
            case .success?:
                return publishCrashHoldConfirmation(hold) ? .confirmed : .deferred
            case .failure(.store(.revisionConflict))?:
                continue
            case .failure(.store(.intentConflict))?:
                return .refused(.needsYou(.messageNotOnProvenRun))
            case let .failure(failure)?:
                return .saveFailed(diagnostic: failure.diagnosticName)
            }
        }
        return .saveFailed(diagnostic: "revision_conflict")
    }

    private static func automaticResult(of refusal: AgentRecoveryCrashHoldRefusal) -> AutomaticCrashHoldResult {
        switch refusal {
        case let .needsYou(reason) where !reason.isTransient: .refused(.needsYou(reason))
        case .needsYou, .couldNotCheck: .deferred
        }
    }

    private func releaseAutomaticCrashHoldClaim(_ sessionID: UUID) {
        automaticCrashHoldSessionIDs.remove(sessionID)
        for waiter in automaticCrashHoldClaimWaiters.removeValue(forKey: sessionID) ?? [] {
            waiter.resume()
        }
    }

    /// Whether the automatic confirmation must leave `hold` for now: it is inactive; the hold is no
    /// longer the published, unconfirmed one; something else acts on the session or its card (a
    /// recovery action, It stopped, a working crash-hold row, which is remembered so the row's end
    /// checks it again); or a shutdown freezes it.
    private func automaticCrashHoldBlocked(_ hold: AgentRecoveryCrashHold) -> Bool {
        guard startupState == .ready, automaticCrashHoldConfirmationActive() else { return true }
        guard crashHold(for: hold.sessionID) == hold, !isCrashHoldConfirmed(hold) else { return true }
        if hasRecoveryActionHold(sessionID: hold.sessionID) { return true }
        if userCrashHoldConfirmationCounts[hold.sessionID] != nil { return true }
        // Check (or another surface) is working on the hold's row (usually no row works at all).
        let rowIsWorking = catalogActionStates.contains { itemID, state in
            guard state == .working, let item = catalog.item(id: itemID) else { return false }
            return item.sessionID == hold.sessionID && item.kind == .crashHold
        }
        if rowIsWorking {
            automaticCrashHoldRowDeferredSessionIDs.insert(hold.sessionID)
            return true
        }
        return hasApplicationShutdownFreeze || lane(for: hold.sessionID)?.isShutdownFrozen == true
    }

    /// The latest reason exactly `hold` still needs the user; `nil` before a pass decided it, or
    /// once it was confirmed. A failed save reads `retrying` from the pending timer's coverage.
    package func automaticCrashHoldRefusal(for hold: AgentRecoveryCrashHold) -> AgentRecoveryAutomaticCrashHoldRefusal? {
        guard !isCrashHoldConfirmed(hold), let entry = automaticCrashHoldRefusals[hold.sessionID], entry.hold == hold
        else { return nil }
        if case .saveFailed = entry.refusal {
            return .saveFailed(retrying: automaticCrashHoldSaveRetryEnrolled.contains(hold.sessionID))
        }
        return entry.refusal
    }

    /// Keeps the reason for the banner (a confirmation clears it, in `publishCrashHoldConfirmation`).
    /// Publishes only a change. `true` when the hold's save failed.
    private func recordAutomaticCrashHoldResult(_ result: AutomaticCrashHoldResult, for hold: AgentRecoveryCrashHold) -> Bool {
        let refusal: AgentRecoveryAutomaticCrashHoldRefusal
        let saveFailed: Bool
        switch result {
        case .confirmed, .deferred:
            return false
        case let .refused(reason):
            clearAutomaticCrashHoldSaveFailure(hold.sessionID)
            refusal = reason
            saveFailed = false
        case let .saveFailed(diagnostic):
            AgentRecoveryFailureDiagnostics.automaticCrashHoldConfirmationFailed(diagnostic)
            if automaticCrashHoldSaveFailures[hold.sessionID]?.hold != hold {
                clearAutomaticCrashHoldSaveFailure(hold.sessionID)
                automaticCrashHoldSaveFailures[hold.sessionID] = (hold, 0)
            }
            // Stored without coverage; the accessor reads it from the pending timer.
            refusal = .saveFailed(retrying: false)
            saveFailed = true
        }
        let stored = automaticCrashHoldRefusals[hold.sessionID]
        if stored?.hold != hold || stored?.refusal != refusal {
            automaticCrashHoldRefusals[hold.sessionID] = (hold, refusal)
            postCoordinatorDidChange()
        }
        return saveFailed
    }

    /// Forgets `sessionID`'s failed saves; with none left anywhere, no retry is pending.
    func clearAutomaticCrashHoldSaveFailure(_ sessionID: UUID) {
        automaticCrashHoldSaveFailures[sessionID] = nil
        automaticCrashHoldSaveRetryEnrolled.remove(sessionID)
        if automaticCrashHoldSaveFailures.isEmpty { cancelAutomaticCrashHoldSaveRetry() }
    }

    /// After a pass, covers the holds whose save failed in it with a delayed retry. A hold already
    /// covered by the pending timer is not charged again; each newly covered hold is charged one
    /// retry (`count`), and the least-charged sets the delay. A pending timer firing no later is
    /// kept; otherwise it is replaced, keeping its coverage. Holds whose attempt was deferred, or
    /// whose retries are spent, are not covered.
    private func scheduleAutomaticCrashHoldSaveRetry(for failedSaves: Set<UUID>) {
        let delays = automaticCrashHoldSaveRetryDelays
        let newlyDue = failedSaves.compactMap { sessionID -> (UUID, Int)? in
            guard !automaticCrashHoldSaveRetryEnrolled.contains(sessionID),
                  let entry = automaticCrashHoldSaveFailures[sessionID], crashHold(for: sessionID) == entry.hold,
                  !isCrashHoldConfirmed(entry.hold), entry.count < delays.count
            else { return nil }
            return (sessionID, entry.count)
        }
        guard let fewest = newlyDue.map(\.1).min() else { return }
        for (sessionID, _) in newlyDue {
            automaticCrashHoldSaveFailures[sessionID]?.count += 1
            automaticCrashHoldSaveRetryEnrolled.insert(sessionID)
        }
        let fireDate = ContinuousClock.now + delays[fewest]
        if automaticCrashHoldSaveRetryTask != nil, let pending = automaticCrashHoldSaveRetryFireDate, pending <= fireDate {
            return
        }
        automaticCrashHoldSaveRetryTask?.cancel()
        let token = UUID()
        automaticCrashHoldSaveRetryToken = token
        automaticCrashHoldSaveRetryFireDate = fireDate
        automaticCrashHoldSaveRetryTask = Task { @MainActor [weak self] in
            let slept: Void? = try? await Task.sleep(until: fireDate, clock: .continuous)
            guard let self, slept != nil, !Task.isCancelled, automaticCrashHoldSaveRetryToken == token else { return }
            let covered = automaticCrashHoldSaveRetryEnrolled
            automaticCrashHoldSaveRetryTask = nil
            automaticCrashHoldSaveRetryFireDate = nil
            automaticCrashHoldSaveRetryToken = nil
            automaticCrashHoldSaveRetryEnrolled = []
            for sessionID in covered {
                requestAutomaticCrashHoldConfirmation(sessionID: sessionID)
            }
            // No pass started (inactive): the banner no longer promises a retry.
            if automaticCrashHoldTask == nil { publishAutomaticCrashHoldRetryCoverage() }
        }
    }

    /// Cancels the pending delayed retry and its coverage.
    func cancelAutomaticCrashHoldSaveRetry() {
        automaticCrashHoldSaveRetryTask?.cancel()
        automaticCrashHoldSaveRetryTask = nil
        automaticCrashHoldSaveRetryFireDate = nil
        automaticCrashHoldSaveRetryToken = nil
        automaticCrashHoldSaveRetryEnrolled = []
        publishAutomaticCrashHoldRetryCoverage()
    }

    /// Wakes the banner when the holds a pending retry covers changed since it last read them.
    private func publishAutomaticCrashHoldRetryCoverage() {
        guard automaticCrashHoldSaveRetryPublished != automaticCrashHoldSaveRetryEnrolled else { return }
        automaticCrashHoldSaveRetryPublished = automaticCrashHoldSaveRetryEnrolled
        postCoordinatorDidChange()
    }
}
