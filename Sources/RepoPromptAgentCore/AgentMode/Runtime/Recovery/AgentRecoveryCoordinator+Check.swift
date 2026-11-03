import Foundation

// Step 9-check: "Check and resolve" in the Needs Attention sheet. Observational: it works on the
// catalog items captured when the user clicks (never a workspace or folder crawl), one item at a
// time, one check at a time app-wide, and reports each item as resolved, needs you (naming the
// choice), could not check, or failed. Stop ends the check at once: checked items keep their result,
// and the item being checked stops being waited for (its work is never cancelled: a Reconcile keeps
// its session's action hold until it really ends, then reports on its card). It uses only existing machinery, and only when process and provider-history checks are
// active (the window passes `checksActive`: history reconciliation is qualified and verified
// process registration is active):
//   - one runtime-ownership Refresh (`refreshRuntimeOwnership`, which never signals anything);
//   - per run card still as captured, the window's existing Reconcile (`.reconcileOnly`) through
//     the recovery action runner, whose only writes are history imports and the action's own
//     record. Its report comes from the runner's typed result: record commits reach the catalog
//     asynchronously (`store.commitPublisher` → a main-actor adoption task), so a re-read right
//     after the Reconcile may still show the card as it was;
//   - per crash hold ("Sending paused") still as captured, confirmation from process records only
//     (Step 9-activation-b, `AgentRecoveryCoordinator+CrashHoldProof.swift`): its one write is the
//     exact crash-hold acknowledgement, committed only when the registry proves every process an
//     earlier launch started for the session exited and each held run was registered at run start.
//     Confirming lets the session send again, so already-authorized scheduled sends may run;
//   - for every other item, the catalog as it is when the item's turn comes.
// Before activation it does none of these and reports "Process and provider-history checks are not
// active."; items are then reported from the catalog only and nothing is resolved automatically.
// It never sends, stops, discards, dismisses, confirms a schedule, opens a session or starts a turn,
// and confirms a crash hold only from that proof (never from an empty registry).

/// A one-shot wait for one Check item: the first `finish` wins (the item's result, or `nil` for
/// Stop); later ones are ignored, so a late result never reaches a finished report.
@MainActor
final class AgentRecoveryCheckItemWait {
    private var continuation: CheckedContinuation<AgentRecoveryCheckOutcome?, Never>?
    private var result: AgentRecoveryCheckOutcome??
    /// The item's work started: its Reconcile was called (the window marks its row `.working`
    /// before its first suspension) or its crash-hold confirmation marked the row `.working`. A Stop
    /// after a Reconcile started owns that `.working` state; before it, Check set nothing.
    private(set) var workStarted = false
    /// The started work is a crash-hold confirmation: it clears its own `.working` when it ends, and
    /// a Stop reports `stoppedWhileConfirmingText` (the write may or may not have been made).
    private(set) var confirmsCrashHold = false

    /// Finished by its result or by Stop: work that hasn't started yet must not start.
    var isFinished: Bool {
        result != nil
    }

    func markWorkStarted() {
        workStarted = true
    }

    func markCrashHoldConfirmationStarted() {
        workStarted = true
        confirmsCrashHold = true
    }

    func value() async -> AgentRecoveryCheckOutcome? {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ outcome: AgentRecoveryCheckOutcome?) {
        guard result == nil else { return }
        result = .some(outcome)
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

/// One item's Check and resolve result.
package enum AgentRecoveryCheckOutcome: Equatable {
    /// The item no longer needs anything (how).
    case resolved(String)
    /// The user has to choose (the choice, e.g. "Send or discard the saved message").
    case needsYou(String)
    /// The check could not decide (why).
    case couldNotCheck(String)
    /// The check itself failed (why).
    case failed(String)

    package var text: String {
        switch self {
        case let .resolved(detail): "Resolved: \(detail)"
        case let .needsYou(choice): "Needs you: \(choice)"
        case let .couldNotCheck(reason): "Could not check: \(reason)"
        case let .failed(reason): "Failed: \(reason)"
        }
    }
}

/// What the window's existing Reconcile did for one run card.
package enum AgentRecoveryCheckReconcile: Equatable {
    /// Not attempted (why: the session isn't open in this window, no provider conversation, ...).
    case notAttempted(String)
    /// Performed through the recovery action runner: its typed result, and the history observation
    /// it ran (`nil` when it ran none, e.g. a provider without history reconciliation).
    case performed(AgentRecoveryActionResult, observed: AgentRecoveryReconcileResult?)

    /// A choice on the card was already reserved or performed (the runner joined it, never repeats it).
    package static let alreadyChosenText = "A choice on this card was already made. Review it on the card."
    package static let unconfirmedChoice =
        "Provider history didn't confirm it finished. Continue it or dismiss the note."

    /// The run card's report from the runner's typed result (never a catalog re-read):
    /// confirmed completion with its rows saved is resolved; confirmed completion whose import or
    /// save failed is failed, naming the failure (the runner keeps its completion evidence); an
    /// unconfirmed, empty or unassociated observation needs the user; a refusal or a provider
    /// without history could not be checked; a transport or read failure failed.
    package var outcome: AgentRecoveryCheckOutcome {
        switch self {
        case let .notAttempted(reason):
            return .couldNotCheck(reason)
        case let .performed(result, observed):
            switch result {
            case let .disabled(text), let .refused(text):
                return .couldNotCheck(text)
            case .joined:
                return .couldNotCheck(Self.alreadyChosenText)
            case .priorAction:
                return .couldNotCheck("A choice made before RepoPrompt restarted is still open on this card. Review it on the card.")
            case let .outcomeUnrecorded(kind, _):
                let text = kind == .importedCompleted
                    ? "The turn had finished, but that couldn't be recorded."
                    : "The result couldn't be recorded."
                return .failed(text)
            case let .completed(kind, reason):
                switch kind {
                case .importedCompleted:
                    guard let reason else { return .resolved("Provider history shows the turn finished.") }
                    return .failed("The turn had finished, but its history couldn't be saved: \(reason)")
                case .importedUnconfirmed:
                    return .needsYou(Self.unconfirmedChoice)
                case .notDispatched:
                    switch observed {
                    case let .nothingImported(text)?, let .associationUnavailable(_, text)?:
                        return .needsYou("Continue it or dismiss the note. \(text)")
                    case let .blocked(text, _)?:
                        return .failed(text)
                    case .imported?:
                        return .failed(reason ?? "The history couldn't be recorded.")
                    case nil:
                        return .couldNotCheck(reason ?? "Provider history is unavailable.")
                    }
                case .dispatched:
                    return .failed(reason ?? "Reconcile reported a send. Check the conversation.")
                }
            }
        }
    }
}

package struct AgentRecoveryCheckEntry: Equatable {
    package let itemID: String
    package let label: String
    package let outcome: AgentRecoveryCheckOutcome
}

/// Progress and report of one Check and resolve (transient, never persisted).
package struct AgentRecoveryCheckStatus: Equatable {
    package static let checksInactiveText = "Process and provider-history checks are not active."
    /// The item being checked when Stop was pressed (its check continues on its card).
    package static let abandonedText = "Stopped while checking. Its check continues; the card shows the result."
    /// The item Stop reached before its check started (it never starts, so no result follows).
    package static let stoppedBeforeCheckingText = "Stopped before checking this item."
    /// The crash hold being confirmed when Stop was pressed: its write may have been made or not.
    package static let stoppedWhileConfirmingText = "Stopped while confirming. If it was saved, its card shows sending resumed."
    package static let restrictionWarningText =
        "Clearing a restriction or confirming a paused session may let already-authorized scheduled sends run."
    /// What an active check does (header, help, and the sheet's text before a check starts).
    package static let activeDescriptionText =
        "Checks process ownership and provider history, and confirms a paused session stopped when process records prove its processes exited."
    /// The authorization text shown before a check starts while checks are active.
    package static let activeNoticeText = "\(activeDescriptionText) \(restrictionWarningText)"

    package let checksActive: Bool
    /// Captured items, in displayed order.
    package let total: Int
    package internal(set) var entries: [AgentRecoveryCheckEntry] = []
    package internal(set) var isRunning = true
    /// The initial runtime-ownership Refresh is running (checks active only).
    package internal(set) var isRefreshing = false
    package internal(set) var cancelRequested = false
    /// Items not reached because the check was stopped.
    package internal(set) var notChecked = 0

    package init(checksActive: Bool, total: Int) {
        self.checksActive = checksActive
        self.total = total
    }

    /// The report header: inactive checks, or what is checked and the restriction warning (a
    /// Refresh that proves a process exited clears its restriction; a proven crash-hold
    /// confirmation lets its session send again).
    package var headerText: String {
        checksActive
            ? Self.activeNoticeText
            : "\(Self.checksInactiveText) Items are reported as they are; nothing was changed."
    }

    /// e.g. "Checked 4 of 4 · 1 resolved · 2 need you · 1 could not check", or
    /// "Cancelled: checked 1 of 3, 2 not checked · 1 need you".
    package var summaryText: String {
        if isRunning, isRefreshing {
            return cancelRequested ? "Refreshing process ownership… Stopping before the first item." : "Refreshing process ownership…"
        }
        if isRunning {
            let progress = "Checking \(min(entries.count + 1, max(total, 1))) of \(total)…"
            return cancelRequested ? "\(progress) Stopping…" : progress
        }
        // Stop always gives the cancelled heading, also when it abandoned the last or only item.
        let lead = if cancelRequested || notChecked > 0 {
            notChecked > 0
                ? "Cancelled: checked \(entries.count) of \(total), \(notChecked) not checked"
                : "Cancelled: checked \(entries.count) of \(total)"
        } else {
            "Checked \(entries.count) of \(total)"
        }
        var parts = [lead]
        let counts: [(String, (AgentRecoveryCheckOutcome) -> Bool)] = [
            ("resolved", { if case .resolved = $0 { true } else { false } }),
            ("need you", { if case .needsYou = $0 { true } else { false } }),
            ("could not check", { if case .couldNotCheck = $0 { true } else { false } }),
            ("failed", { if case .failed = $0 { true } else { false } })
        ]
        for (label, matches) in counts {
            let count = entries.count { matches($0.outcome) }
            if count > 0 { parts.append("\(count) \(label)") }
        }
        return parts.joined(separator: " · ")
    }
}

package extension AgentRecoveryCoordinator {
    var isRecoveryCheckRunning: Bool {
        recoveryCheck?.isRunning == true
    }

    /// Checks the displayed `items` as captured now (hidden ones are dropped), one at a time in
    /// order. With `checksActive`, refreshes runtime ownership once, then gives each run card that
    /// is still the captured, uncleared one to `reconcile` (the window's existing Reconcile) and
    /// reports its typed result; other items are reported from the catalog when their turn comes.
    /// Without it, nothing is refreshed, reconciled or written. Returns the final status,
    /// or `nil` without doing anything while another check runs.
    ///
    /// Stop (`requestRecoveryCheckCancel`) during an item ends the wait for it (a Reconcile has no
    /// time limit: a Codex cold start or a Claude history read can't be interrupted): the item is
    /// reported `abandonedText`, the `.working` state its Reconcile set is released (never another
    /// action's), the rest are not checked. An item whose work had not started yet never starts and
    /// is reported `stoppedBeforeCheckingText`.
    /// The item's work keeps running and keeps its session's recovery action hold (every other
    /// choice there is still refused; a repeated identical choice joins it); its late result goes
    /// only to its card, never to this finished report.
    @discardableResult
    func checkCatalogItems(
        _ items: [AgentRecoveryCatalogItem],
        checksActive: Bool,
        reconcile: @escaping @MainActor (AgentRecoveryCatalogItem) async -> AgentRecoveryCheckReconcile
    ) async -> AgentRecoveryCheckStatus? {
        guard !isRecoveryCheckRunning else { return nil }
        let captured = items.filter { !$0.isHidden }
        recoveryCheck = AgentRecoveryCheckStatus(checksActive: checksActive, total: captured.count)
        postCatalogChange()
        if checksActive {
            recoveryCheck?.isRefreshing = true
            postCatalogChange()
            await refreshRuntimeOwnership()
            recoveryCheck?.isRefreshing = false
            postCatalogChange()
        }
        for (index, item) in captured.enumerated() {
            if recoveryCheck?.cancelRequested == true {
                recoveryCheck?.notChecked = captured.count - index
                break
            }
            let waited = await waitForCheckOutcome(of: item, checksActive: checksActive, reconcile: reconcile)
            guard let outcome = waited.outcome else {
                // Stopped while this item was being checked: stop waiting for it (never cancel it).
                // Its Reconcile, if started, continues and reports on its card; a crash-hold
                // confirmation may already be writing (or may refuse); otherwise it never runs.
                let stopText = if !waited.workStarted {
                    AgentRecoveryCheckStatus.stoppedBeforeCheckingText
                } else if waited.confirmsCrashHold {
                    AgentRecoveryCheckStatus.stoppedWhileConfirmingText
                } else {
                    AgentRecoveryCheckStatus.abandonedText
                }
                recoveryCheck?.entries.append(AgentRecoveryCheckEntry(
                    itemID: item.id,
                    label: item.checkLabel,
                    outcome: .couldNotCheck(stopText)
                ))
                recoveryCheck?.notChecked = captured.count - index - 1
                // Only the `.working` this item's own Reconcile set (the window sets it before the
                // Reconcile's first suspension, so it is in place whenever Stop can run); a crash-hold
                // confirmation clears its own when it ends (a commit may still be in flight). If its
                // work never started, a `.working` row belongs to another action and is left alone.
                if waited.workStarted, !waited.confirmsCrashHold, catalogActionStates[item.id] == .working {
                    setCatalogActionState(nil, for: item.id)
                }
                break
            }
            recoveryCheck?.entries.append(AgentRecoveryCheckEntry(itemID: item.id, label: item.checkLabel, outcome: outcome))
            postCatalogChange()
        }
        recoveryCheck?.isRunning = false
        postCatalogChange()
        return recoveryCheck
    }

    /// Stops the running check: before the next item, and without waiting any longer for the item
    /// being checked (its work is not cancelled). Repeated Stops are ignored.
    func requestRecoveryCheckCancel() {
        guard recoveryCheck?.isRunning == true, recoveryCheck?.cancelRequested == false else { return }
        recoveryCheck?.cancelRequested = true
        postCatalogChange()
        recoveryCheckItemWait?.finish(nil)
    }

    /// One item's outcome, or `nil` when Stop ended the wait first; whether its work (Reconcile or
    /// crash-hold confirmation) started, and whether that work confirms a crash hold. The item's work
    /// runs in its own unstructured task that nothing cancels; whichever of its result or Stop comes
    /// first resumes the one-shot wait, and the other is ignored. A task that runs only after Stop
    /// finished its wait does nothing (no new Reconcile after Stop).
    private func waitForCheckOutcome(
        of item: AgentRecoveryCatalogItem,
        checksActive: Bool,
        reconcile: @escaping @MainActor (AgentRecoveryCatalogItem) async -> AgentRecoveryCheckReconcile
    ) async -> (outcome: AgentRecoveryCheckOutcome?, workStarted: Bool, confirmsCrashHold: Bool) {
        let wait = AgentRecoveryCheckItemWait()
        recoveryCheckItemWait = wait
        defer { if recoveryCheckItemWait === wait { recoveryCheckItemWait = nil } }
        let tracked: @MainActor (AgentRecoveryCatalogItem) async -> AgentRecoveryCheckReconcile = { item in
            wait.markWorkStarted()
            return await reconcile(item)
        }
        Task { @MainActor [weak self] in
            guard !wait.isFinished else { return }
            guard let self else { return wait.finish(.couldNotCheck("Recovery isn't available right now.")) }
            await wait.finish(checkOutcome(of: item, checksActive: checksActive, wait: wait, reconcile: tracked))
        }
        #if DEBUG
            test_recoveryCheckItemQueued?()
        #endif
        let outcome = await wait.value()
        return (outcome, wait.workStarted, wait.confirmsCrashHold)
    }

    /// Clears the last finished check's report (the sheet was closed); a running one stays.
    func clearRecoveryCheckReport() {
        guard let status = recoveryCheck, !status.isRunning else { return }
        recoveryCheck = nil
        postCatalogChange()
    }

    private func checkOutcome(
        of item: AgentRecoveryCatalogItem,
        checksActive: Bool,
        wait: AgentRecoveryCheckItemWait,
        reconcile: @MainActor (AgentRecoveryCatalogItem) async -> AgentRecoveryCheckReconcile
    ) async -> AgentRecoveryCheckOutcome {
        if catalogActionStates[item.id] == .working {
            return .couldNotCheck("Another action on this item is in progress.")
        }
        guard let current = catalog.item(id: item.id) else {
            // Items also leave for other reasons (a closed window, a removed session, survivors
            // replaced by the global-uncertainty warning): only a proven exit is claimed.
            if checksActive, case let .survivingRuntime(restriction) = item.payload, runtimeExitIsProven(restriction.runtimeID) {
                return .resolved("The process exited.")
            }
            return .couldNotCheck("It is no longer listed.")
        }
        guard checksActive else {
            return current.checkOutcome(unresolvedRun: .couldNotCheck("Provider history checks are not active."))
        }
        // Cleared or dismissed while the check waited (e.g. another window reconciled it): reported
        // from that state, never reconciled again.
        if let clear = current.automaticClear {
            return .resolved(Self.checkClearText(clear))
        }
        if current.isDismissed {
            return .couldNotCheck("It was dismissed.")
        }
        // A crash hold: confirmed only from process-record proof (checks are active here). The proof
        // compares the card with the captured one, sets the row `.working` and marks its work started
        // before its first suspension.
        if case let .crashHold(hold) = current.payload {
            return await confirmCrashHoldFromRegistryProof(item, hold: hold, wait: wait)
        }
        guard current.isRunCard, current.attention == .informational else {
            return current.checkOutcome(unresolvedRun: .couldNotCheck("This card needs action; Check doesn't reconcile it."))
        }
        guard current.acknowledgement == item.acknowledgement, current.payload == item.payload else {
            return .couldNotCheck("It changed since the check started. Review it again.")
        }
        return await reconcile(item).outcome
    }

    /// The adopted snapshot positively lacks `runtimeID` and carries no global uncertainty.
    private func runtimeExitIsProven(_ runtimeID: UUID) -> Bool {
        hasProcessRegistry
            && !runtimeRestrictions.hasGlobalUncertainty
            && !runtimeRestrictions.restrictions.contains { $0.runtimeID == runtimeID }
    }

    private static func checkClearText(_ clear: AgentRecoveryCatalogAutomaticClear) -> String {
        switch clear {
        case .resolved: "A recovery action resolved it."
        case .conversationCleared: "The conversation was cleared after this run."
        case .sessionContinued: "The session continued after this run."
        }
    }
}

package extension AgentRecoveryCatalogItem {
    /// A run card (interrupted turn, closed turn, recovery-only run).
    var isRunCard: Bool {
        switch payload {
        case .turn, .outcomeTurn, .recoveryOnlyRun: true
        default: false
        }
    }

    /// The report label: what the item is and its session.
    var checkLabel: String {
        let kindName = switch kind {
        case .interruptedTurn: "Interrupted run"
        case .terminalOutcome: "Run result"
        case .savedInput: "Saved message"
        case .savedDraft: "Saved draft"
        case .unansweredQuestion: "Question"
        case .scheduleNeedsConfirmation: "Scheduled send"
        case .crashHold: "Sending paused"
        case .heldScheduleTransfer: "Held scheduled send"
        case .statusUnknown: "Status unknown"
        case .saveFailure: "Save failed"
        case .survivingProcess: "Agent process"
        case .pendingEditReview: "Edit proposal"
        }
        guard let name = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return kindName }
        return "\(kindName) · \(name)"
    }

    /// The item's result from the catalog alone (no reads, no writes): the user's named choice, or
    /// why it can't be checked. `unresolvedRun` is the result of an informational run card.
    /// Exhaustive so a new payload cannot compile unreported.
    func checkOutcome(unresolvedRun: AgentRecoveryCheckOutcome) -> AgentRecoveryCheckOutcome {
        switch payload {
        case .turn, .outcomeTurn, .recoveryOnlyRun:
            if actionFacts.hasUnfinishedAction {
                return .needsYou("Check the conversation, then continue it or dismiss the card")
            }
            if actionFacts.hasUnsentContinuation {
                return .needsYou("Send your continuation again or dismiss the card")
            }
            return unresolvedRun
        case .intent:
            return .needsYou("Send or discard the saved message")
        case .question:
            return .needsYou("Answer the question")
        case .crashHold:
            return .needsYou("Confirm the previous run stopped")
        case .survivingRuntime:
            return .needsYou("Let it finish or Stop")
        case .scheduleNeedsConfirmation:
            return .needsYou("Confirm or cancel the scheduled send")
        case .scheduleTransfer:
            return .needsYou("Keep or cancel the held scheduled send")
        case .editProposal:
            return .needsYou("Review, copy or discard the edit proposal")
        case .heldDraft, .closedSessionDraft:
            return .needsYou("Restore or discard the draft")
        case .unsavedPredecessor, .ownerlessDraft:
            return .needsYou("Restore or discard the unsaved text")
        case let .workspaceFailure(reason):
            return .couldNotCheck(reason)
        case .nonactionable:
            return .couldNotCheck("Its saved conversation or recovery data couldn't be read.")
        case .duplicateDestination, .noDestination:
            return .couldNotCheck("It couldn't be matched to one saved session.")
        case .composerRestoreFailed, .composerWriteFailed, .composerPreparationFailed, .questionSaveFailed:
            return .couldNotCheck("A save failed. Retry it from its card.")
        case let .scheduleIndexUnavailable(workspaceName):
            return .couldNotCheck("Scheduled sends in \(workspaceName) couldn't be read.")
        case .runtimeOwnershipUnknown:
            return .couldNotCheck("Agent processes from an earlier launch couldn't be identified.")
        }
    }
}
