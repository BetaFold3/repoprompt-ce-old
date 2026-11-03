import Foundation

// Shared immutable values for process-owned recovery of provider-accepted scheduled turns.
// No view-model references, provider callbacks, or mutable scheduler state live here.

/// Identity of one retained attempt: rejects stale callbacks and stale UI projections.
package struct AgentScheduledSendRecoveryKey: Hashable {
    package let sessionID: UUID
    let leaseID: UUID
    package let attemptID: UUID

    package init(
        sessionID: UUID,
        leaseID: UUID,
        attemptID: UUID
    ) {
        self.sessionID = sessionID
        self.leaseID = leaseID
        self.attemptID = attemptID
    }
}

/// Stable identity supplied by the owner of an explicit conversation reset. The latest committed
/// receipt is persisted in the session lifecycle together with the reset transcript.
package struct AgentSessionTranscriptResetReceipt: Codable, Hashable {
    let id: UUID

    package init(
        id: UUID
    ) {
        self.id = id
    }
}

/// DataService-issued destination captured under the session persistence gate before provider
/// handoff. Recovery reads and writes only ever target this context, never the currently
/// selected workspace or a tab's replacement session.
package struct AgentScheduledSendRecoveryContext {
    let sessionID: UUID
    let workspaceID: UUID
    /// Pinned workspace storage reference required by the data service's existing folder/index paths.
    let workspace: any AgentWorkspaceStorageReference
    let fileURL: URL
    /// Canonical session-file identity (the DataService's resolved key for `fileURL`). Explicit
    /// deletion notifications carry this key, so matching never depends on the URL spelling
    /// (`/var` vs `/private/var`, a symlinked storage path).
    let fileKey: URL
    let agentSessionsFolderURL: URL
    /// Process-local explicit-deletion generation observed at preparation.
    let deletionGeneration: UInt64
    /// Durable lifecycle incarnation of the prepared session file.
    let incarnationID: UUID
    /// Canonical persisted session (encoded) at preparation, used only when the authoritative
    /// file is accidentally missing. Never overwrites an existing file.
    let canonicalSessionSnapshot: Data
    /// Explicit transcript-reset receipt visible when the snapshot was prepared.
    let transcriptResetReceiptAtPreparation: AgentSessionTranscriptResetReceipt?
    /// Durable committed transcript-reset generation captured with the snapshot. A later
    /// generation wins over every pre-reset transcript item carried by this context.
    let transcriptResetGenerationAtPreparation: UInt64
    /// The same data-service instance whose gate serializes ordinary saves and deletion.
    let dataService: AgentSessionDataService
}

/// Immutable acceptance evidence. Constructed once after provider acceptance; never refreshed
/// from a live working set.
package struct AgentScheduledSendAcceptedPayload {
    let context: AgentScheduledSendRecoveryContext
    package let attempt: AgentScheduledSendPersist.Attempt
    package let receipt: AgentScheduledSendProvenance
    package let acceptedItem: AgentChatItem
    /// The dispatching revision supplied to persistence as `expectedUpdatedAt`.
    let expectedUpdatedAt: Date

    package init(
        context: AgentScheduledSendRecoveryContext,
        attempt: AgentScheduledSendPersist.Attempt,
        receipt: AgentScheduledSendProvenance,
        acceptedItem: AgentChatItem,
        expectedUpdatedAt: Date
    ) {
        self.context = context
        self.attempt = attempt
        self.receipt = receipt
        self.acceptedItem = acceptedItem
        self.expectedUpdatedAt = expectedUpdatedAt
    }
}

enum AgentScheduledSendRecoveryOutcome {
    case committed(AgentScheduledSendMutationResult)
    /// Explicit session deletion committed before this recovery; nothing was reconstructed.
    case explicitlyDeleted
}

enum AgentScheduledSendRecoveryError: Error, Equatable {
    /// The pinned workspace storage root is not available; recovery must not redirect elsewhere.
    case destinationUnavailable(URL)
    case snapshotUndecodable
    /// The file is missing and this service no longer holds authoritative lifecycle/reset state
    /// for the destination; the snapshot cannot prove the current reset state.
    case lifecycleAuthorityUnavailable
}

package enum AgentScheduledSendRecoveryAttentionReason: Equatable {
    case persistenceExhausted(lastFailure: String)
    case destinationUnavailable
    case invalidAcceptanceEvidence(String)
    case unresolvedProviderOutcome
}

package enum AgentScheduledSendRecoveryPhase: Equatable {
    /// Process ownership is reserved at the guarded handoff; acceptance not yet reported.
    case awaitingProviderOutcome
    case saving(attemptNumber: Int)
    case waitingToRetry(nextAttemptNumber: Int, notBefore: Date)
    /// Automatic work stopped; ownership, payload, and duplicate protection remain retained.
    case needsAttention(AgentScheduledSendRecoveryAttentionReason)
}

package struct AgentScheduledSendRecoveryStatus: Equatable {
    package let key: AgentScheduledSendRecoveryKey
    package let lease: AgentScheduledSendAdmissionLease
    package let phase: AgentScheduledSendRecoveryPhase
    let attemptCount: Int
    package let hasAcceptedPayload: Bool
}

package enum AgentScheduledSendRecoveryChangeKind: String {
    case reserved
    case accepted
    case saving
    case waitingToRetry
    case needsAttention
    case committed
    case explicitlyDeleted
    case released
}

// MARK: - R9 receipt transfer (lossless restart)

/// Decision for one `.dispatching` schedule attempt against the session's durable recovery record.
package enum AgentScheduledSendTransferResolution: Equatable {
    /// No recovery intent references this schedule or its item: the legacy delivery-unknown
    /// normalization applies (the input never left the schedule).
    case noLinkedIntent
    /// Exactly one matching linked intent exists with certain evidence (affirmative acceptance, or
    /// durably `queued`): write this receipt and clear the pending schedule in one CAS. Attachments
    /// are not released by this step.
    case completeTransfer(AgentScheduledSendProvenance)
    /// The linked intent is a rolled-back admission of this exact attempt that never left this
    /// process (queued, no delivery attempt, withdrawn): the schedule keeps owning the input.
    case rolledBack
    /// Unknown, conflicting, uncertain (`dispatching`, `deliveryUnknown`), failed, or
    /// withdrawn-after-attempt evidence. Held with the pending schedule and its payload unchanged
    /// until explicit resolution; never a confirmation, an automatic drain, or a dispatch.
    case hold(String)
    /// R10: the exact linked intent carries the user's cancellation decision for this schedule
    /// attempt: clear this pending schedule without any receipt. Never a resend, never a
    /// "not delivered" claim; the intent's delivery evidence is unchanged.
    case cancelTransfer
}

package enum AgentScheduledSendTransfer {
    /// R9 join carried by the recovery intent admitted for this schedule attempt.
    package static func recoveryScheduleReference(
        scheduleID: UUID,
        attempt: AgentScheduledSendPersist.Attempt
    ) -> AgentRecoveryScheduleReference {
        AgentRecoveryScheduleReference(scheduleID: scheduleID, scheduleAttemptID: attempt.attemptID)
    }

    /// Receipt for a live or repaired transfer to `intentID`.
    package static func savedInQueueReceipt(
        record: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt,
        intentID: UUID,
        sentAt: Date
    ) -> AgentScheduledSendProvenance {
        AgentScheduledSendProvenance(
            scheduleID: record.id,
            attemptID: attempt.attemptID,
            scheduledFor: record.notBefore,
            sentAt: sentAt,
            kind: .savedInQueue(AgentScheduledSendQueueLink(intentID: intentID, userItemID: attempt.itemID))
        )
    }

    /// Receipt for affirmative acceptance evidence of this exact attempt.
    package static func providerAcceptedReceipt(
        record: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt,
        sentAt: Date
    ) -> AgentScheduledSendProvenance {
        AgentScheduledSendProvenance(
            scheduleID: record.id,
            attemptID: attempt.attemptID,
            scheduledFor: record.notBefore,
            sentAt: sentAt,
            kind: .providerAccepted
        )
    }

    /// The intent is still `queued` and no delivery attempt was ever started for it: verified
    /// evidence that this intent was not handed off. `false` when the record or intent is missing.
    package static func intentNeverDispatched(intentID: UUID, in recoveryRecord: AgentRecoveryRecordState) -> Bool {
        guard let record = recoveryRecord.record,
              let intent = record.intents.first(where: { $0.intentID == intentID })
        else { return false }
        return intent.deliveryState == .queued && !record.attempts.contains { $0.intentID == intentID }
    }

    /// Legacy restart normalization of an unowned `.dispatching` attempt nothing links to: delivery
    /// is unknown and sending again needs explicit confirmation. Shared by the gate-held repair and
    /// the hydrated owner.
    package static func deliveryUnknownNormalization(
        of record: AgentScheduledSendPersist,
        duplicateItemExists: Bool,
        now: Date = Date()
    ) -> AgentScheduledSendPersist {
        var normalized = record
        normalized.state = .needsConfirmation
        normalized.confirmationReason = .deliveryUnknown
        normalized.updatedAt = now
        normalized.lastFailureMessage = duplicateItemExists
            ? "The app closed while this message was being sent and it may already have been delivered. Sending it again could deliver it twice."
            : "The app closed while this message was being sent. Delivery could not be confirmed."
        return normalized
    }

    /// Delivery state of the single intent linked to this exact attempt (same schedule, schedule
    /// attempt, deterministic item, `.scheduled` origin); `nil` when there is none or several.
    package static func linkedIntentDeliveryState(
        record: AgentScheduledSendPersist,
        recoveryRecord: AgentRecoveryRecordState
    ) -> AgentRecoveryDeliveryState? {
        let linked = linkedIntents(record: record, recoveryRecord: recoveryRecord)
        return linked.count == 1 ? linked[0].deliveryState : nil
    }

    /// Intent ID of the single intent linked to this exact attempt (same matching as
    /// `linkedIntentDeliveryState`); `nil` when there is none or several.
    package static func linkedIntentID(
        record: AgentScheduledSendPersist,
        recoveryRecord: AgentRecoveryRecordState
    ) -> UUID? {
        let linked = linkedIntents(record: record, recoveryRecord: recoveryRecord)
        return linked.count == 1 ? linked[0].intentID : nil
    }

    private static func linkedIntents(
        record: AgentScheduledSendPersist,
        recoveryRecord: AgentRecoveryRecordState
    ) -> [AgentRecoveryIntent] {
        guard let attempt = record.attempt, let supported = recoveryRecord.record else { return [] }
        return supported.intents.filter {
            $0.origin == .scheduled
                && $0.scheduleReference?.scheduleID == record.id
                && $0.scheduleReference?.scheduleAttemptID == attempt.attemptID
                && $0.userItemID == attempt.itemID
        }
    }

    /// Pure R9 repair decision for `record` (must be `.dispatching` with an attempt) against the
    /// session's durable recovery record. Matching requires the exact schedule ID, schedule attempt
    /// ID, deterministic user item, and `.scheduled` origin; anything else touching the schedule or
    /// its item is conflicting evidence. Certainty stays separate (R2): only affirmative acceptance
    /// yields `providerAccepted`, only a durably `queued` intent yields `savedInQueue`, and only a
    /// withdrawal that never began a delivery attempt is `rolledBack`. Every other state is held.
    package static func resolve(
        record: AgentScheduledSendPersist,
        recoveryRecord: AgentRecoveryRecordState,
        sentAt: Date
    ) -> AgentScheduledSendTransferResolution {
        guard record.state == .dispatching, let attempt = record.attempt else { return .noLinkedIntent }
        let intents: [AgentRecoveryIntent]
        let attempts: [AgentRecoveryAttempt]
        switch recoveryRecord {
        case .absent:
            return .noLinkedIntent
        case .preserved:
            return .hold("The recovery record for this session is unreadable.")
        case let .supported(supported):
            intents = supported.intents
            attempts = supported.attempts
        }
        let competing = competingIntents(record: record, attempt: attempt, intents: intents, attempts: attempts)
        guard !competing.isEmpty else { return .noLinkedIntent }
        guard competing.count == 1, let intent = competing.first else {
            return .hold("Several saved inputs claim this scheduled message.")
        }
        guard intent.origin == .scheduled,
              intent.scheduleReference?.scheduleAttemptID == attempt.attemptID,
              intent.scheduleReference?.scheduleID == record.id,
              intent.userItemID == attempt.itemID
        else {
            return .hold("A saved input conflicts with this scheduled message.")
        }
        if intent.scheduledTransferCancellation?.matches(scheduleID: record.id, scheduleAttemptID: attempt.attemptID) == true {
            return .cancelTransfer
        }
        let hasDeliveryAttempt = attempts.contains { $0.intentID == intent.intentID }
        switch intent.deliveryState {
        case .providerAccepted:
            return .completeTransfer(providerAcceptedReceipt(record: record, attempt: attempt, sentAt: sentAt))
        case .queued:
            // Durably saved and not in flight (never dispatched, or settled back after a proven
            // non-handoff or verified rejection): the queue owns it. Saved input, not acceptance.
            return .completeTransfer(
                savedInQueueReceipt(record: record, attempt: attempt, intentID: intent.intentID, sentAt: sentAt)
            )
        case .withdrawn where !hasDeliveryAttempt:
            return .rolledBack
        case .dispatching:
            return .hold("Delivery of this scheduled message is still unconfirmed.")
        case .deliveryUnknown:
            return .hold("Delivery of this scheduled message could not be confirmed.")
        case .failed:
            return .hold("This scheduled message failed after it was handed off.")
        case .withdrawn:
            return .hold("This scheduled message's saved copy was removed after a delivery attempt.")
        }
    }

    /// R10: the intent whose held transfer the user may cancel — only when the transfer is held
    /// (`resolve` is `.hold`) because of the single exactly linked intent's own evidence. A hold
    /// caused by several or conflicting claims has no cancellable owner. `nil` otherwise.
    package static func cancellableHeldTransferIntentID(
        record: AgentScheduledSendPersist,
        recoveryRecord: AgentRecoveryRecordState
    ) -> UUID? {
        guard case .hold = resolve(record: record, recoveryRecord: recoveryRecord, sentAt: Date()),
              let attempt = record.attempt,
              let supported = recoveryRecord.record
        else { return nil }
        let competing = competingIntents(
            record: record,
            attempt: attempt,
            intents: supported.intents,
            attempts: supported.attempts
        )
        guard competing.count == 1, let intent = competing.first,
              intent.origin == .scheduled,
              intent.scheduleReference?.scheduleID == record.id,
              intent.scheduleReference?.scheduleAttemptID == attempt.attemptID,
              intent.userItemID == attempt.itemID
        else { return nil }
        return intent.intentID
    }

    /// Intents touching this schedule or its item. An earlier attempt's admission that was rolled
    /// back before any handoff (withdrawn with no delivery attempt) is history, not a competing owner.
    private static func competingIntents(
        record: AgentScheduledSendPersist,
        attempt: AgentScheduledSendPersist.Attempt,
        intents: [AgentRecoveryIntent],
        attempts: [AgentRecoveryAttempt]
    ) -> [AgentRecoveryIntent] {
        intents.filter {
            $0.scheduleReference?.scheduleID == record.id || $0.userItemID == attempt.itemID
        }.filter { intent in
            let isRolledBackEarlierAttempt = intent.deliveryState == .withdrawn
                && intent.scheduleReference?.scheduleID == record.id
                && intent.scheduleReference?.scheduleAttemptID != attempt.attemptID
                && !attempts.contains { $0.intentID == intent.intentID }
            return !isRolledBackEarlierAttempt
        }
    }
}

package extension Notification.Name {
    /// Retry/attention/terminal changes of a retained recovery. `userInfo`: `sessionID`,
    /// `workspaceID`, `leaseID`, `attemptID`, `changeKind` (raw). Observers query the
    /// coordinator for current status; the payload is not durable authority.
    static let agentScheduledSendRecoveryDidChange = Notification.Name("AgentScheduledSendCoordinator.recoveryDidChange")
    /// Published by the data service after an explicit session deletion committed under the
    /// session gate. `userInfo`: `sessionID` (when parseable), `fileKey` (URL), `generation`.
    static let agentSessionDeletionDidCommit = Notification.Name("AgentSessionDataService.deletionDidCommit")
}
