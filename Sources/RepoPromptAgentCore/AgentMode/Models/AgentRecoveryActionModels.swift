import Foundation

// Lossless-restart Phase 4 durable recovery actions and history cursors (spec R7/R8; phase4-plan
// "Durable action association", "History ledger").
//
// An action is the durable reservation of one explicit user recovery choice (Continue, Send saved,
// Answer as input, Continue in a new conversation, Reconcile). It is written before any provider
// work, so a relaunch can join it to the attempts it produced: an action whose planned user item
// never became an intent was provably not dispatched; one whose intent is still `queued` with no
// attempt was not handed off; anything else is reported, never retried automatically. A repeated
// click with the same action ID joins the same reservation.
//
// A history cursor is advanced only after the session save that committed the imported rows (see
// `AgentSessionDataService.commitProviderHistoryImport`): rows + native-ID ledger + import receipt
// commit together first, the cursor second. Both shapes keep unknown members and an unknown kind
// raw string, so a newer build's actions survive this build unchanged.

package enum AgentRecoveryActionKind: String, CaseIterable {
    /// A new editable continuation message (default text, or the user's edit) via normal dispatch.
    case continueWithText
    /// Saved, never-handed-off input of the previous launch, dispatched once through normal dispatch.
    case sendSaved
    /// A preserved question's answer, sent as ordinary user input (never the old provider RPC).
    case questionAnswerAsInput
    /// Explicit fresh-conversation continuation after a resume of the previous conversation failed.
    case continueInNewConversation
    /// History-only reconciliation: imports what the provider recorded; never dispatches.
    case reconcileOnly

    /// Whether this kind hands input to a provider (everything but `reconcileOnly`).
    package var dispatches: Bool {
        self != .reconcileOnly
    }

    /// R7 step 2–3: a continuation of an interrupted turn reconciles the provider's own history
    /// first and stops without sending when that turn verifiably finished.
    package var reconcilesBeforeDispatch: Bool {
        self == .continueWithText || self == .continueInNewConversation
    }

    /// Kinds that may follow a previous launch's action whose delivery is uncertain (always as a
    /// new, explicitly confirmed continuation; never a retry of the old input or request).
    package var mayFollowUncertainPriorAction: Bool {
        self == .continueWithText || self == .continueInNewConversation
    }
}

package enum AgentRecoveryActionOutcomeKind: String, CaseIterable {
    /// Nothing was handed to a provider (refused, stale, or proven not handed off).
    case notDispatched
    /// Normal dispatch began; delivery evidence lives on the intent's attempts.
    case dispatched
    /// Reconciliation found verified terminal evidence that the action's source run attempt
    /// finished (rows imported or already present). A continuation stopped here sent nothing.
    case importedCompleted
    /// Reconciliation imported (or found) history without completion proof.
    case importedUnconfirmed
}

/// The provider conversation an action was decided against. Fenced at every await: a different
/// provider or conversation refuses the action instead of retargeting it.
package struct AgentRecoveryActionTarget: Equatable {
    package let providerKindRaw: String?
    package let providerConversationID: String?
    package var extras: AgentRecoveryExtras

    package init(providerKindRaw: String?, providerConversationID: String?, extras: AgentRecoveryExtras = [:]) {
        self.providerKindRaw = providerKindRaw
        self.providerConversationID = providerConversationID
        self.extras = extras
    }

    /// Same target, ignoring unknown members.
    package func matches(_ other: AgentRecoveryActionTarget) -> Bool {
        providerKindRaw == other.providerKindRaw && providerConversationID == other.providerConversationID
    }
}

package struct AgentRecoveryActionOutcome: Equatable {
    package let kindRaw: String
    /// Short user-facing reason (never provider payload or secrets).
    package let reason: String?
    package let recordedAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(kindRaw: String, reason: String?, recordedAt: AgentRecoveryTimestamp, extras: AgentRecoveryExtras = [:]) {
        self.kindRaw = kindRaw
        self.reason = reason
        self.recordedAt = recordedAt
        self.extras = extras
    }

    package init(kind: AgentRecoveryActionOutcomeKind, reason: String?, recordedAt: AgentRecoveryTimestamp) {
        self.init(kindRaw: kind.rawValue, reason: reason, recordedAt: recordedAt)
    }

    package var kind: AgentRecoveryActionOutcomeKind? {
        AgentRecoveryActionOutcomeKind(rawValue: kindRaw)
    }
}

/// Parameters of one explicit recovery choice, as decided by the user against a revision.
package struct AgentRecoveryActionRequest: Equatable {
    /// R7 default continuation text, shown editable in the recovery card before the choice.
    package static let defaultContinuationText =
        "RepoPrompt restarted during the previous turn. Check the current state before repeating any action, then continue."

    package let actionID: UUID
    /// The recovery item (card) the choice was made on.
    package let itemKey: AgentRecoveryCardKey
    package let kind: AgentRecoveryActionKind
    /// Record revision the user saw (`nil` = no record existed).
    package let expectedRevision: AgentRecoveryRecordRevision?
    /// Saved intents this action dispatches (`sendSaved`), in order.
    package let sourceIntentIDs: [UUID]
    package let sourceRunAttemptID: UUID?
    package let sourceInteractionID: UUID?
    package let target: AgentRecoveryActionTarget
    /// Exact text a continuation dispatches (`nil` for `sendSaved` and `reconcileOnly`).
    package let text: String?
    /// Transcript user item the dispatch will be shown as; allocated at reservation so a relaunch
    /// joins it to the intent normal admission creates for it.
    package let plannedUserItemID: UUID?
    /// A previous launch's unresolved action on the same item that this explicit new choice
    /// replaces. The old action is kept unchanged (no outcome is written for it).
    package let supersedesActionID: UUID?
    /// The user explicitly confirmed a new continuation although the superseded action's delivery
    /// is uncertain (dispatch evidence or unjoinable).
    package let confirmsUncertainPriorDelivery: Bool

    package init(
        actionID: UUID,
        itemKey: AgentRecoveryCardKey,
        kind: AgentRecoveryActionKind,
        expectedRevision: AgentRecoveryRecordRevision?,
        sourceIntentIDs: [UUID] = [],
        sourceRunAttemptID: UUID? = nil,
        sourceInteractionID: UUID? = nil,
        target: AgentRecoveryActionTarget,
        text: String? = nil,
        plannedUserItemID: UUID? = nil,
        supersedesActionID: UUID? = nil,
        confirmsUncertainPriorDelivery: Bool = false
    ) {
        self.actionID = actionID
        self.itemKey = itemKey
        self.kind = kind
        self.expectedRevision = expectedRevision
        self.sourceIntentIDs = sourceIntentIDs
        self.sourceRunAttemptID = sourceRunAttemptID
        self.sourceInteractionID = sourceInteractionID
        self.target = target
        self.text = text
        self.plannedUserItemID = plannedUserItemID
        self.supersedesActionID = supersedesActionID
        self.confirmsUncertainPriorDelivery = confirmsUncertainPriorDelivery
    }
}

/// One durable action reservation (store-issued).
package struct AgentRecoveryAction: Equatable {
    package let actionID: UUID
    package let itemKey: AgentRecoveryCardKey
    package let kindRaw: String
    package let expectedRevision: AgentRecoveryRecordRevision?
    package let incarnationID: UUID
    package let transcriptResetGeneration: UInt64
    package let sourceIntentIDs: [UUID]
    package let sourceRunAttemptID: UUID?
    package let sourceInteractionID: UUID?
    package let target: AgentRecoveryActionTarget
    package let text: String?
    package let plannedUserItemID: UUID?
    /// The previous launch's unresolved action this one replaced (kept unchanged as evidence).
    package let supersedesActionID: UUID?
    package let confirmedUncertainPriorDelivery: Bool
    package let appInstanceID: UUID
    package let reservedAt: AgentRecoveryTimestamp
    package internal(set) var outcome: AgentRecoveryActionOutcome?
    package var extras: AgentRecoveryExtras

    package init(
        actionID: UUID,
        itemKey: AgentRecoveryCardKey,
        kindRaw: String,
        expectedRevision: AgentRecoveryRecordRevision?,
        incarnationID: UUID,
        transcriptResetGeneration: UInt64,
        sourceIntentIDs: [UUID],
        sourceRunAttemptID: UUID?,
        sourceInteractionID: UUID?,
        target: AgentRecoveryActionTarget,
        text: String?,
        plannedUserItemID: UUID?,
        supersedesActionID: UUID? = nil,
        confirmedUncertainPriorDelivery: Bool = false,
        appInstanceID: UUID,
        reservedAt: AgentRecoveryTimestamp,
        outcome: AgentRecoveryActionOutcome? = nil,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.actionID = actionID
        self.itemKey = itemKey
        self.kindRaw = kindRaw
        self.expectedRevision = expectedRevision
        self.incarnationID = incarnationID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.sourceIntentIDs = sourceIntentIDs
        self.sourceRunAttemptID = sourceRunAttemptID
        self.sourceInteractionID = sourceInteractionID
        self.target = target
        self.text = text
        self.plannedUserItemID = plannedUserItemID
        self.supersedesActionID = supersedesActionID
        self.confirmedUncertainPriorDelivery = confirmedUncertainPriorDelivery
        self.appInstanceID = appInstanceID
        self.reservedAt = reservedAt
        self.outcome = outcome
        self.extras = extras
    }

    /// `nil` for a kind this build does not know: kept, shown as unavailable, never performed.
    package var kind: AgentRecoveryActionKind? {
        AgentRecoveryActionKind(rawValue: kindRaw)
    }

    package var isResolved: Bool {
        outcome != nil
    }

    /// Whether `request` is the same choice (a repeated click joins it). The expected revision is
    /// not compared: a repeat after the reservation's own write necessarily sees a newer revision.
    package func hasSameParameters(as request: AgentRecoveryActionRequest) -> Bool {
        actionID == request.actionID
            && itemKey == request.itemKey
            && kindRaw == request.kind.rawValue
            && sourceIntentIDs == request.sourceIntentIDs
            && sourceRunAttemptID == request.sourceRunAttemptID
            && sourceInteractionID == request.sourceInteractionID
            && target.matches(request.target)
            && text == request.text
            && plannedUserItemID == request.plannedUserItemID
            && supersedesActionID == request.supersedesActionID
            && confirmedUncertainPriorDelivery == request.confirmsUncertainPriorDelivery
    }
}

/// Relaunch classification of an action against the record (never a retry decision).
package enum AgentRecoveryActionJoin: Equatable {
    case resolved(AgentRecoveryActionOutcome)
    /// The planned item never became an intent (or reconciliation never committed): provably not
    /// dispatched. The user may choose again.
    case notDispatched
    /// The intent exists and is still `queued` without an attempt: not handed off.
    case notHandedOff(intentID: UUID)
    /// Dispatch began; its outcome is whatever the intent's delivery evidence says. Shown as
    /// "Resume was interrupted; status unknown" unless that evidence is affirmative.
    case dispatchEvidence(intentID: UUID, state: AgentRecoveryDeliveryState)
    /// A newer build's kind, or evidence this build cannot join: never performed or retried.
    case unknown
}

package extension AgentRecoveryRecord {
    func action(id: UUID) -> AgentRecoveryAction? {
        actions.first { $0.actionID == id }
    }

    /// Whether a later explicit choice replaced `action` (it stays unresolved, kept as evidence).
    func isSuperseded(_ action: AgentRecoveryAction) -> Bool {
        actions.contains { $0.supersedesActionID == action.actionID }
    }

    /// The open (unresolved, not superseded) action reserved for `itemKey`, if any (at most one).
    func unresolvedAction(for itemKey: AgentRecoveryCardKey) -> AgentRecoveryAction? {
        actions.last { $0.itemKey == itemKey && !$0.isResolved && !isSuperseded($0) }
    }

    /// Durable verified completion of `runAttemptID`: its own recorded terminal evidence classifies
    /// as completed (the shared classifier: a completed terminal with an ordinary or legacy cause),
    /// or an earlier recovery action on it recorded `importedCompleted` (written only when the
    /// evidence was bound to that attempt).
    func hasVerifiedCompletion(ofRunAttempt runAttemptID: UUID?) -> Bool {
        guard let runAttemptID else { return false }
        if let run = runAttempt(id: runAttemptID),
           AgentRecoveryInterruptedTurn.Status.classify(attempt: run) == .completedTailMayBeMissing
        {
            return true
        }
        return actions.contains { $0.sourceRunAttemptID == runAttemptID && $0.outcome?.kind == .importedCompleted }
    }

    /// Whether `runAttemptID` verifiably never delivered its input (review A P1-06): it has at least
    /// one delivery attempt, every one of them closed as a pre-handoff failure or a verified
    /// rejection, and every intent they carried is back to `queued`. Its saved intent (original
    /// IDs and attachments) is the route, never a generic continuation.
    func isVerifiedNeverHandedOff(runAttemptID: UUID?) -> Bool {
        guard let runAttemptID else { return false }
        let deliveries = attempts.filter { $0.runAttemptID == runAttemptID }
        guard !deliveries.isEmpty else { return false }
        return deliveries.allSatisfy { attempt in
            guard case .failed? = attempt.outcome?.outcome else { return false }
            return intent(id: attempt.intentID)?.deliveryState == .queued
        }
    }

    /// The action that already resolved `itemKey` by sending (`dispatched`) or by proving the
    /// interrupted turn finished (`importedCompleted`). Such an item is never offered a duplicate
    /// send (review B F3b); Reconcile stays available.
    func resolvingAction(for itemKey: AgentRecoveryCardKey) -> AgentRecoveryAction? {
        actions.last { $0.itemKey == itemKey && Self.resolvesItem($0) }
    }

    /// Whether `action` resolved its item: it sent (`dispatched`) or proved the interrupted turn
    /// finished (`importedCompleted`).
    private static func resolvesItem(_ action: AgentRecoveryAction) -> Bool {
        guard let kind = action.outcome?.kind else { return false }
        return kind == .dispatched || kind == .importedCompleted
    }

    /// Whether typed text chosen on `itemKey` was never sent and exists only on its action, so the
    /// card still asks for a decision. It is the latest action carrying non-empty text on the item (a newer
    /// typed choice decides by its own state) that has ended without resolving: an outcome other
    /// than `dispatched` / `importedCompleted`, or replaced by a later choice before it had one.
    /// An action still open is not "unsent" (`unresolvedAction(for:)` covers it). Cleared only when
    /// - a saved intent carries the text (`userItemID == plannedUserItemID`), or
    /// - a later action on the item resolves it (`dispatched` / `importedCompleted`).
    /// A later textless action that does not resolve (Reconcile recorded `notDispatched` or
    /// `importedUnconfirmed`) only checked history; it never discards the text.
    func hasUnsentContinuation(for itemKey: AgentRecoveryCardKey) -> Bool {
        unsentContinuationText(for: itemKey) != nil
    }

    /// 9-live R4b: the exact typed text of the action `hasUnsentContinuation(for:)` selects (the
    /// same rule, so the two never disagree), or `nil` when the card has no unsent continuation.
    func unsentContinuationText(for itemKey: AgentRecoveryCardKey) -> String? {
        guard let index = actions.lastIndex(where: { $0.itemKey == itemKey && $0.text?.isEmpty == false }) else { return nil }
        let continuation = actions[index]
        if continuation.outcome != nil {
            if Self.resolvesItem(continuation) { return nil }
        } else if !isSuperseded(continuation) {
            return nil
        }
        if let itemID = continuation.plannedUserItemID, intents.contains(where: { $0.userItemID == itemID }) {
            return nil
        }
        if actions[(index + 1)...].contains(where: { $0.itemKey == itemKey && Self.resolvesItem($0) }) { return nil }
        return continuation.text
    }

    /// Relaunch join of one action to the record's intents and attempts (phase4-plan "Restart
    /// join"). Reuses existing delivery evidence; never infers acceptance or completion.
    func join(_ action: AgentRecoveryAction) -> AgentRecoveryActionJoin {
        if let outcome = action.outcome {
            return .resolved(outcome)
        }
        guard let kind = action.kind else { return .unknown }
        let intent: AgentRecoveryIntent? = switch kind {
        case .sendSaved:
            action.sourceIntentIDs.first.flatMap { self.intent(id: $0) }
        case .continueWithText, .questionAnswerAsInput, .continueInNewConversation:
            action.plannedUserItemID.flatMap { itemID in intents.last { $0.userItemID == itemID } }
        case .reconcileOnly:
            nil
        }
        guard let intent else {
            // A saved intent that vanished is not proof either way.
            return kind == .sendSaved ? .unknown : .notDispatched
        }
        if intent.deliveryState == .queued, attempts(forIntent: intent.intentID).isEmpty {
            return .notHandedOff(intentID: intent.intentID)
        }
        if kind == .sendSaved, intent.deliveryState == .queued, intent.appInstanceID != action.appInstanceID {
            // Claimed by the action but never handed off by it.
            return .notHandedOff(intentID: intent.intentID)
        }
        return .dispatchEvidence(intentID: intent.intentID, state: intent.deliveryState)
    }
}

// MARK: - History cursor

/// File identity of an imported native history file, read from the open descriptor.
package struct AgentRecoveryHistoryFileIdentity: Equatable {
    package let device: UInt64
    package let inode: UInt64
    /// Birth time when the filesystem reports one (`nil` otherwise).
    package let birthSeconds: Int64?
    package let birthNanoseconds: Int64?

    package init(device: UInt64, inode: UInt64, birthSeconds: Int64?, birthNanoseconds: Int64?) {
        self.device = device
        self.inode = inode
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }
}

package enum AgentRecoveryHistoryProvider: String, CaseIterable {
    case claude
    case codex
}

/// An opaque byte-integrity fence over one native history file (Step 4d2): the lowercase hex
/// SHA-256 of the exact captured raw bytes `[0, completeLineOffset)` (original newlines, no
/// normalization, never a partial trailing record). Unrelated to the semantic envelope digest.
/// `file == nil` with offset 0 is verified absence; an existing empty file keeps its identity.
package struct AgentRecoveryHistoryPrefixFence: Equatable {
    package let file: AgentRecoveryHistoryFileIdentity?
    package let completeLineOffset: UInt64
    /// `nil` = no usable proof (legacy or malformed). Never synthesized; verification fails closed.
    package let prefixSHA256: String?

    package init(file: AgentRecoveryHistoryFileIdentity?, completeLineOffset: UInt64, prefixSHA256: String?) {
        self.file = file
        self.completeLineOffset = completeLineOffset
        self.prefixSHA256 = prefixSHA256
    }
}

/// The recovery-side cursor of one provider conversation's imported history. Advanced only by
/// compare-and-swap on the previous import ID, after the session commit that holds the rows.
package struct AgentRecoveryHistoryCursor: Equatable {
    package let providerRaw: String
    package let conversationID: String
    /// Import receipt this cursor follows (equal to the session's committed import receipt).
    package let importID: UUID
    /// `nil` for observational sources without a file (Codex).
    package let file: AgentRecoveryHistoryFileIdentity?
    /// Byte offset just after the last complete line imported.
    package let completeLineOffset: UInt64
    /// Prefix fence proof of `[0, completeLineOffset)` (Claude, Step 4d2). `nil` for Codex, legacy
    /// cursors, and a malformed stored value (kept verbatim in `extras`).
    package let prefixSHA256: String?
    package let committedAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        providerRaw: String,
        conversationID: String,
        importID: UUID,
        file: AgentRecoveryHistoryFileIdentity?,
        completeLineOffset: UInt64,
        prefixSHA256: String? = nil,
        committedAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.providerRaw = providerRaw
        self.conversationID = conversationID
        self.importID = importID
        self.file = file
        self.completeLineOffset = completeLineOffset
        self.prefixSHA256 = prefixSHA256
        self.committedAt = committedAt
        self.extras = extras
    }

    package var provider: AgentRecoveryHistoryProvider? {
        AgentRecoveryHistoryProvider(rawValue: providerRaw)
    }

    /// The byte fence this cursor's boundary represents.
    package var prefixFence: AgentRecoveryHistoryPrefixFence {
        AgentRecoveryHistoryPrefixFence(file: file, completeLineOffset: completeLineOffset, prefixSHA256: prefixSHA256)
    }
}

package extension AgentRecoveryRecord {
    func historyCursor(providerRaw: String, conversationID: String) -> AgentRecoveryHistoryCursor? {
        historyCursors.first { $0.providerRaw == providerRaw && $0.conversationID == conversationID }
    }
}

/// A recovery dispatch's resume of the previous Claude conversation failed while the implicit fresh
/// fallback was suppressed. Nothing was written to the provider; the user chooses explicitly whether
/// to continue in a new conversation (`AgentRecoveryActionKind.continueInNewConversation`).
package struct AgentRecoveryResumeFallbackRequired: LocalizedError, Equatable {
    package let conversationID: String

    package init(conversationID: String) {
        self.conversationID = conversationID
    }

    package static let message =
        "The previous conversation could not be resumed. Nothing was sent. Choose Continue in a new conversation to start fresh."

    package var errorDescription: String? {
        Self.message
    }
}

/// Store receipt for an action reservation or outcome.
package struct AgentRecoveryActionReceipt: Equatable {
    package let binding: AgentRecoveryLifecycleBinding
    package let recordRevision: AgentRecoveryRecordRevision
    package let disposition: AgentRecoveryCommitDisposition
    package let action: AgentRecoveryAction
}
