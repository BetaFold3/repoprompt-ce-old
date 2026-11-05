import Foundation

// Step 9-activation-b: Check and resolve confirms a crash hold ("Sending paused") from process
// records, never from an empty registry. The proof (all must hold):
//   (a) checks are active and the registry is healthy: started, no storage failure, no unidentified
//       record, no unreadable record naming the session or what it touches;
//   (b) the hold has run attempts and no legacy turn, each run attempt carrying the run-start
//       registration mark (`AgentRecoveryRunAttempt.recordedRuntimeRegistrationRaw`); every
//       uncertain intent qualifies (O43: earlier launch, every attempt on a held run attempt or on
//       one with recorded terminal evidence, `AgentRecoveryRecord.crashHoldSettlementQualifies`);
//   (c) each held attempt is named by an earlier-launch registry record;
//   (d) no earlier-launch record that names the session (any incarnation), names no session, or
//       shares one of its conversations or worktrees is still possibly running (`.exited` and
//       `.stopped` only; `.stopped` is written only after a fresh complete inventory shows no member
//       of the family alive, `AgentProcessRegistry.stop`);
//   (e) the adopted restriction snapshot agrees (no global uncertainty, no send restriction);
//   (f) the hold and its card are unchanged, nothing else acts on the session, Check isn't stopped.
// (a)-(d) come from one registry query (its records never leave `.exited`/`.stopped`, so the
// answer can't go stale); (b) is read before it; (e) and (f) are re-checked after it and before
// every commit attempt, and the card is checked again atomically with the write (the store refuses
// a card dismissed meanwhile). The only write is the exact crash-hold acknowledgement "It stopped"
// writes, settling the hold's uncertain intents to `deliveryUnknown` in the same write (O46; the
// store re-checks the qualification there and refuses the whole write if one no longer qualifies):
// through the session's live lane when one is open, otherwise under the closed-session gate (the
// session is never opened). Publication after the commit is shared with "It stopped"
// (`publishCrashHoldConfirmation`). The same proof also runs without a card, automatically
// (`AgentRecoveryCoordinator+AutomaticCrashHoldConfirmation.swift`); Check waits for a hold the
// automatic confirmation is checking and reports one confirmed meanwhile as resolved.

/// Check and resolve's crash-hold texts (one fixed set).
package enum AgentRecoveryCrashHoldCheckText {
    package static let confirmed = "Process records show every process of the interrupted run exited."
    package static let changed = "It changed since the check started. Review it again."
    package static let busy = "Another action on this session is in progress."
    /// The confirmation's own result when Stop came before its commit. Check's report never shows
    /// it (Stop already finished the item's wait: the report says `stoppedWhileConfirmingText`).
    package static let stoppedBeforeConfirming = "Stopped before confirming."
    package static let saveFailed = "The confirmation couldn't be saved."
    /// The hold was confirmed meanwhile (automatically from process records, or by It stopped).
    package static let alreadyConfirmed = "This session's pause was already confirmed."

    package static let notRegistered = "it started before process checks were active"
    package static let notRecorded = "no process record names this run"
    package static let mayBeRunning = "an agent process may still be running"
    package static let mayBeRunningThisLaunch = "an agent process this launch started may still be running"
    package static let ownershipUncertain = "process ownership is uncertain"
    package static let ownershipUpdating = "process ownership is still being updated"
    package static let notOnlyRuns = "it has a saved message or an older interrupted turn"
    /// O43: an uncertain message has an attempt without a run-attempt reference, or on a run the
    /// proof doesn't cover.
    package static let messageNotOnProvenRun = "a saved message's attempt isn't tied to a proven run"
    package static let openToConfirm = "open this session to confirm it"

    /// The needs-you choice with its reason.
    package static func needsYou(_ reason: String) -> AgentRecoveryCheckOutcome {
        .needsYou("Confirm the previous run stopped (\(reason))")
    }
}

/// Why a crash hold still needs the user's choice: Check shows its text in the needs-you choice; the
/// automatic confirmation keeps it for the paused banner.
package enum AgentRecoveryCrashHoldNeedsYouReason: Equatable, CaseIterable {
    /// A held run started before process tracking was active.
    case notRegistered
    /// No process record names a held run.
    case notRecorded
    /// A process an earlier launch started for the session (or one touching it) may still run.
    case mayBeRunning
    /// A process this launch started for the session may still run.
    case mayBeRunningThisLaunch
    /// Process records couldn't be read or identified.
    case ownershipUncertain
    /// The adopted snapshot hasn't caught up with the registry yet.
    case ownershipUpdating
    /// The hold has no open run, or an older interrupted turn without one.
    case notOnlyRuns
    /// An uncertain message isn't tied to a run the proof covers.
    case messageNotOnProvenRun
    /// The session is neither open nor writable while closed.
    case openToConfirm

    package var text: String {
        typealias Text = AgentRecoveryCrashHoldCheckText
        return switch self {
        case .notRegistered: Text.notRegistered
        case .notRecorded: Text.notRecorded
        case .mayBeRunning: Text.mayBeRunning
        case .mayBeRunningThisLaunch: Text.mayBeRunningThisLaunch
        case .ownershipUncertain: Text.ownershipUncertain
        case .ownershipUpdating: Text.ownershipUpdating
        case .notOnlyRuns: Text.notOnlyRuns
        case .messageNotOnProvenRun: Text.messageNotOnProvenRun
        case .openToConfirm: Text.openToConfirm
        }
    }

    /// Clears on its own once the adopted snapshot catches up (a pass runs again then): never kept
    /// as the banner's reason.
    var isTransient: Bool {
        self == .ownershipUpdating
    }
}

/// A refusal of the proof's shared steps: why the user still has to choose, or why it can't be
/// decided right now.
enum AgentRecoveryCrashHoldRefusal: Equatable {
    case needsYou(AgentRecoveryCrashHoldNeedsYouReason)
    case couldNotCheck(String)

    /// Check's outcome for it.
    var outcome: AgentRecoveryCheckOutcome {
        switch self {
        case let .needsYou(reason): AgentRecoveryCrashHoldCheckText.needsYou(reason.text)
        case let .couldNotCheck(text): .couldNotCheck(text)
        }
    }
}

extension AgentRecoveryCoordinator {
    /// Confirms `hold` (the captured `item`'s crash hold) when process records prove its processes
    /// exited; otherwise reports why the user still has to choose. Requires checks to be active
    /// (proof condition (a)): only `checkOutcome` calls it, after its `checksActive` guard.
    /// First waits for an automatic confirmation of the same session (the item's work has not
    /// started then). Marks the row `.working` and the item's work started (as a crash-hold
    /// confirmation) before the registry query, and clears that `.working` itself when it ends. Stop before the commit
    /// starts refuses ("Stopped before confirming.", a result Check's report never shows); a commit
    /// already in flight finishes and is published.
    func confirmCrashHoldFromRegistryProof(
        _ item: AgentRecoveryCatalogItem,
        hold: AgentRecoveryCrashHold,
        wait: AgentRecoveryCheckItemWait
    ) async -> AgentRecoveryCheckOutcome {
        typealias Text = AgentRecoveryCrashHoldCheckText
        // The automatic confirmation is checking this session right now: wait for it to finish
        // with this session only (it never waits for Check), then report what it did. Stop ends
        // Check's wait meanwhile, as for any item.
        await waitForAutomaticCrashHoldClaim(sessionID: hold.sessionID)
        if let refusal = crashHoldCheckRefusal(item, hold: hold, wait: wait) { return refusal }
        guard let registry = processRegistry else { return Text.needsYou(Text.ownershipUncertain) }
        guard let captured = item.acknowledgement else { return .couldNotCheck(Text.changed) }
        let card = (key: captured.key, freshness: captured.freshness)
        if let refusal = crashHoldProofPreconditionRefusal(hold) { return refusal.outcome }

        // A row already `.working` belongs to another action (or to an earlier confirmation still
        // writing after a Stop): never share it, so neither clears the other's state.
        if catalogActionStates[item.id] == .working { return .couldNotCheck(Text.busy) }
        setCatalogActionState(.working, for: item.id)
        wait.markCrashHoldConfirmationStarted()
        defer {
            // This work owns the row's `.working` until it ends, also after a Stop (a commit may
            // still be in flight); the window refuses other actions on the row meanwhile. Leaving
            // `.working` also asks the automatic confirmation, which skipped the hold meanwhile, to
            // check it again (`setCatalogActionState`).
            if catalogActionStates[item.id] == .working {
                setCatalogActionState(nil, for: item.id)
            }
        }

        // (a, c, d) from the registry.
        let proof = await crashHoldRegistryExitProof(hold, registry: registry)
        if let refusal = crashHoldCheckRefusal(item, hold: hold, wait: wait) { return refusal }
        if let refusal = Self.crashHoldProofRefusal(proof) { return refusal.outcome }

        // The commit: bounded retry on a revision conflict, each attempt re-checking (e) and (f)
        // first; the store re-checks the card atomically with the write.
        for _ in 0 ..< 3 {
            #if DEBUG
                await test_crashHoldProofBeforeCommit?()
            #endif
            if let refusal = crashHoldCheckRefusal(item, hold: hold, wait: wait) { return refusal }
            if let refusal = crashHoldSnapshotRefusal(hold) { return refusal.outcome }
            if let refusal = crashHoldWriteDestinationRefusal(hold) { return refusal.outcome }
            #if DEBUG
                await test_crashHoldProofAtCommit?()
            #endif
            switch await commitCrashHoldAcknowledgement(hold, card: card) {
            case nil:
                return Text.needsYou(Text.openToConfirm)
            case .success?:
                return publishCrashHoldConfirmation(hold) ? .resolved(Text.confirmed) : .couldNotCheck(Text.changed)
            case .failure(.store(.revisionConflict))?:
                continue
            case .failure(.store(.cardChanged))?:
                return .couldNotCheck(Text.changed)
            case .failure(.store(.intentConflict))?:
                // The store's in-write re-check: an uncertain message no longer qualifies.
                return Text.needsYou(Text.messageNotOnProvenRun)
            case .failure?:
                return .failed(Text.saveFailed)
            }
        }
        return .failed(Text.saveFailed)
    }

    // MARK: Shared by Check and the automatic confirmation

    /// (b) The hold has run attempts and no legacy turn, every run attempt carries the run-start
    /// registration mark and every uncertain intent qualifies (O43); then a write destination
    /// exists. `nil` when the registry may be asked.
    func crashHoldProofPreconditionRefusal(_ hold: AgentRecoveryCrashHold) -> AgentRecoveryCrashHoldRefusal? {
        guard !hold.uncertainRunAttemptIDs.isEmpty, hold.uncertainTranscriptTurnIDs.isEmpty else {
            return .needsYou(.notOnlyRuns)
        }
        let record = reconciliation.resolution(for: hold.sessionID)?.record?.record
        let qualifies = hold.uncertainIntentIDs.allSatisfy { intentID in
            record?.crashHoldSettlementQualifies(
                intentID: intentID,
                exitedRunAttemptIDs: hold.uncertainRunAttemptIDs,
                currentInstanceID: store.appInstanceID
            ) == true
        }
        guard qualifies else { return .needsYou(.messageNotOnProvenRun) }
        let attempts = record?.runAttempts ?? []
        let registered = hold.uncertainRunAttemptIDs.allSatisfy { runAttemptID in
            attempts.first { $0.runAttemptID == runAttemptID }?.recordedRuntimeRegistrationRaw
                == AgentRecoveryRunAttempt.registeredRuntimeRegistration
        }
        guard registered else { return .needsYou(.notRegistered) }
        return crashHoldWriteDestinationRefusal(hold)
    }

    /// (a, c, d) One registry query for the hold's runs, the session's incarnations and every
    /// conversation and worktree it touches.
    func crashHoldRegistryExitProof(
        _ hold: AgentRecoveryCrashHold,
        registry: AgentProcessRegistry
    ) async -> AgentRuntimeCrashHoldExitProof {
        let keys = runtimeOwnershipKeys(hold.sessionID)
        return await registry.crashHoldExitProof(AgentRuntimeCrashHoldExitQuery(
            sessionID: hold.sessionID,
            incarnationID: hold.incarnationID,
            runAttemptIDs: hold.uncertainRunAttemptIDs,
            conversationIDs: Set(keys.compactMap(\.conversationID)),
            worktreePaths: keys.compactMap(\.worktreePath),
            currentAppInstanceID: store.appInstanceID
        ))
    }

    /// The needs-you reason of an unproven exit; `nil` when proven.
    static func crashHoldProofRefusal(_ proof: AgentRuntimeCrashHoldExitProof) -> AgentRecoveryCrashHoldRefusal? {
        switch proof {
        case .proven: nil
        case .ownershipUncertain: .needsYou(.ownershipUncertain)
        case .mayBeRunning: .needsYou(.mayBeRunning)
        case .runNotRecorded: .needsYou(.notRecorded)
        }
    }

    /// One commit attempt of the exact acknowledgement of `hold` with every qualifying intent settled
    /// (`.everyIntent`): through the live lane, else under the closed-session gate; `nil` when
    /// neither destination exists. With `card` (Check), the store refuses a card dismissed meanwhile.
    func commitCrashHoldAcknowledgement(
        _ hold: AgentRecoveryCrashHold,
        card: (key: AgentRecoveryCardKey, freshness: AgentRecoveryCardFreshness)?
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure>? {
        if let lane = lane(for: hold.sessionID) {
            return await recordLaneCrashHoldAcknowledgement(hold, card: card, lane: lane)
        }
        guard let resolution = reconciliation.resolution(for: hold.sessionID),
              let binding = resolution.binding, let workspace = resolution.workspace
        else { return nil }
        return await recordClosedCrashHoldAcknowledgement(hold, card: card, binding: binding, workspace: workspace)
    }

    /// (f) The hold is still the published, unconfirmed one and its card is unchanged; nothing else
    /// acts on the session; Check wasn't stopped. `nil` when the check may go on. (A deleted
    /// session's hold is no longer published, so `crashHold(for:)` no longer equals it.)
    private func crashHoldCheckRefusal(
        _ item: AgentRecoveryCatalogItem,
        hold: AgentRecoveryCrashHold,
        wait: AgentRecoveryCheckItemWait
    ) -> AgentRecoveryCheckOutcome? {
        typealias Text = AgentRecoveryCrashHoldCheckText
        if recoveryCheck?.cancelRequested == true || wait.isFinished {
            return .couldNotCheck(Text.stoppedBeforeConfirming)
        }
        // Confirmed meanwhile (the automatic confirmation, or It stopped in another surface).
        if crashHold(for: hold.sessionID) == hold, isCrashHoldConfirmed(hold) {
            return .resolved(Text.alreadyConfirmed)
        }
        if automaticCrashHoldSessionIDs.contains(hold.sessionID) {
            return .couldNotCheck(Text.busy)
        }
        guard crashHold(for: hold.sessionID) == hold, !isCrashHoldConfirmed(hold),
              let current = catalog.item(id: item.id),
              current.acknowledgement == item.acknowledgement, current.payload == item.payload
        else { return .couldNotCheck(Text.changed) }
        if hasRecoveryActionHold(sessionID: hold.sessionID) {
            return .couldNotCheck(Text.busy)
        }
        return nil
    }

    /// (e) The adopted snapshot agrees. It lags the registry, so an earlier launch's restriction
    /// may remain after the proof (still being updated); this launch's own restriction means a
    /// process of this launch may be writing.
    func crashHoldSnapshotRefusal(_ hold: AgentRecoveryCrashHold) -> AgentRecoveryCrashHoldRefusal? {
        if let restriction = runtimeSendRestriction(sessionID: hold.sessionID) {
            return .needsYou(restriction.isPreviousInstance ? .ownershipUpdating : .mayBeRunningThisLaunch)
        }
        if runtimeRestrictions.hasGlobalUncertainty { return .needsYou(.ownershipUpdating) }
        return nil
    }

    /// Where the acknowledgement would be written: the live lane (same incarnation and reset
    /// generation as the hold, else the hold changed), or the closed-session gate (needs the
    /// session's validated binding and workspace). `nil` when one is available.
    func crashHoldWriteDestinationRefusal(_ hold: AgentRecoveryCrashHold) -> AgentRecoveryCrashHoldRefusal? {
        if let lane = lane(for: hold.sessionID) {
            guard !lane.isRetired,
                  lane.binding.incarnationID == hold.incarnationID,
                  lane.binding.transcriptResetGeneration == hold.transcriptResetGeneration
            else { return .couldNotCheck(AgentRecoveryCrashHoldCheckText.changed) }
            return nil
        }
        guard let resolution = reconciliation.resolution(for: hold.sessionID),
              let binding = resolution.binding, resolution.workspace != nil
        else { return .needsYou(.openToConfirm) }
        guard binding.incarnationID == hold.incarnationID,
              binding.transcriptResetGeneration == hold.transcriptResetGeneration
        else { return .couldNotCheck(AgentRecoveryCrashHoldCheckText.changed) }
        return nil
    }

    /// The exact acknowledgement of `hold` through the session's live lane, refused when `card` was
    /// dismissed meanwhile (checked by the store inside the lane's transaction).
    private func recordLaneCrashHoldAcknowledgement(
        _ hold: AgentRecoveryCrashHold,
        card: (key: AgentRecoveryCardKey, freshness: AgentRecoveryCardFreshness)?,
        lane: AgentRecoverySessionLane
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        let incarnationID = hold.incarnationID
        let generation = hold.transcriptResetGeneration
        let runAttemptIDs = hold.uncertainRunAttemptIDs
        let intentIDs = hold.uncertainIntentIDs
        let turnIDs = hold.uncertainTranscriptTurnIDs
        let cardKey = card?.key
        let cardFreshness = card?.freshness
        return await lane.transaction { store, binding in
            try await store.recordCrashHoldAcknowledgement(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                incarnationID: incarnationID,
                transcriptResetGeneration: generation,
                runAttemptIDs: runAttemptIDs,
                intentIDs: intentIDs,
                transcriptTurnIDs: turnIDs,
                undismissedCard: Self.undismissedCard(cardKey, cardFreshness),
                settlement: .everyIntent
            )
        }
    }

    private nonisolated static func undismissedCard(
        _ key: AgentRecoveryCardKey?,
        _ freshness: AgentRecoveryCardFreshness?
    ) -> (key: AgentRecoveryCardKey, freshness: AgentRecoveryCardFreshness)? {
        guard let key, let freshness else { return nil }
        return (key, freshness)
    }

    /// The exact acknowledgement of `hold` for a session with no live lane, under the closed-session
    /// gate (tombstone, session file and lifecycle validated first; same lock order as lanes),
    /// refused when `card` was dismissed meanwhile.
    private func recordClosedCrashHoldAcknowledgement(
        _ hold: AgentRecoveryCrashHold,
        card: (key: AgentRecoveryCardKey, freshness: AgentRecoveryCardFreshness)?,
        binding: AgentRecoveryLifecycleBinding,
        workspace: AgentRecoveryWorkspaceDestination
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        let store = store
        let incarnationID = hold.incarnationID
        let generation = hold.transcriptResetGeneration
        let runAttemptIDs = hold.uncertainRunAttemptIDs
        let intentIDs = hold.uncertainIntentIDs
        let turnIDs = hold.uncertainTranscriptTurnIDs
        let cardKey = card?.key
        let cardFreshness = card?.freshness
        do {
            return try await .success(dataService.performClosedRecoveryTransaction(binding: binding, workspace: workspace) {
                try await store.recordCrashHoldAcknowledgement(
                    binding: binding,
                    expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                    incarnationID: incarnationID,
                    transcriptResetGeneration: generation,
                    runAttemptIDs: runAttemptIDs,
                    intentIDs: intentIDs,
                    transcriptTurnIDs: turnIDs,
                    undismissedCard: Self.undismissedCard(cardKey, cardFreshness),
                    settlement: .everyIntent
                )
            })
        } catch let error as AgentRecoveryStoreError {
            return .failure(.store(error))
        } catch {
            return .failure(.lifecycleRejected(String(describing: error)))
        }
    }
}
