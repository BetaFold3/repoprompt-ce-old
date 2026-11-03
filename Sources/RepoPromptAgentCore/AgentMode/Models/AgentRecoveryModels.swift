import Foundation

// Lossless-restart Phase 1b recovery record model (spec R1, R1a, R2).
//
// One record per session lives at `AgentRecovery/v1/sessions/<sessionID>.json` and is written
// only by `AgentRecoveryStore`. Every supported object keeps unknown additive members ("extras")
// so a newer build's fields survive an older build's rewrite. A record with a future schema, a
// malformed required field, or an unknown closed-set variant is preserved byte-for-byte and is
// never writable (see `AgentRecoveryRecordDecoding`).
//
// Lifecycle identity (incarnation and transcript-reset generation) is issued only by
// `AgentSessionDataService`; records reference it and never assign or advance it.

package typealias AgentRecoveryJSONValue = AgentScheduledSendJSONValue
package typealias AgentRecoveryExtras = [String: AgentRecoveryJSONValue]

// MARK: - Opaque revisions

/// Opaque whole-record revision. Equality/CAS only: no ordering, arithmetic, or increment.
package struct AgentRecoveryRecordRevision: Hashable, CustomStringConvertible {
    let token: String

    static func make() -> AgentRecoveryRecordRevision {
        AgentRecoveryRecordRevision(token: UUID().uuidString)
    }

    package var description: String {
        "record-revision(\(token))"
    }
}

/// Opaque composer revision covering text, images, tagged files, workflow, and interview choice.
/// Equality only; the issuing controller alone knows the local order of its own revisions.
package struct AgentRecoveryComposerRevision: Hashable, CustomStringConvertible {
    let token: String

    package static func make() -> AgentRecoveryComposerRevision {
        AgentRecoveryComposerRevision(token: UUID().uuidString)
    }

    package var description: String {
        "composer-revision(\(token))"
    }
}

// MARK: - Timestamps

/// Millisecond wall-clock timestamp. Integer milliseconds round-trip exactly through JSON.
package struct AgentRecoveryTimestamp: Hashable {
    package let millisecondsSince1970: Int64

    package init(millisecondsSince1970: Int64) {
        self.millisecondsSince1970 = millisecondsSince1970
    }

    package init(_ date: Date) {
        millisecondsSince1970 = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    package var date: Date {
        Date(timeIntervalSince1970: TimeInterval(millisecondsSince1970) / 1000)
    }
}

// MARK: - Lifecycle reference

/// Reference to foundation-issued lifecycle authority for one session. Callers obtain it from
/// `AgentSessionDataService` authority; recovery code never creates or advances it.
package struct AgentRecoveryLifecycleBinding: Hashable {
    package let sessionID: UUID
    package let incarnationID: UUID
    package let transcriptResetGeneration: UInt64

    package init(sessionID: UUID, incarnationID: UUID, transcriptResetGeneration: UInt64) {
        self.sessionID = sessionID
        self.incarnationID = incarnationID
        self.transcriptResetGeneration = transcriptResetGeneration
    }
}

// MARK: - Input content

/// Durable image reference. Managed files live under the recovery store's per-session attachment
/// directory and are named relative to it; remote images keep their URL.
package struct AgentRecoveryImageReference: Equatable {
    package enum Location: Equatable {
        case managedFile(fileName: String)
        case remoteURL(String)
    }

    package let id: UUID
    package let location: Location
    package let title: String?
    package let createdAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        id: UUID,
        location: Location,
        title: String?,
        createdAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.id = id
        self.location = location
        self.title = title
        self.createdAt = createdAt
        self.extras = extras
    }

    package var managedFileName: String? {
        guard case let .managedFile(fileName) = location else { return nil }
        return fileName
    }
}

package struct AgentRecoveryTaggedFileReference: Equatable {
    package let id: UUID
    package let relativePath: String
    package let displayName: String
    package let createdAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        id: UUID,
        relativePath: String,
        displayName: String,
        createdAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.id = id
        self.relativePath = relativePath
        self.displayName = displayName
        self.createdAt = createdAt
        self.extras = extras
    }

    package init(_ attachment: AgentTaggedFileAttachment) {
        self.init(
            id: attachment.id,
            relativePath: attachment.relativePath,
            displayName: attachment.displayName,
            createdAt: AgentRecoveryTimestamp(attachment.createdAt)
        )
    }

    package var attachment: AgentTaggedFileAttachment {
        AgentTaggedFileAttachment(
            id: id,
            relativePath: relativePath,
            displayName: displayName,
            createdAt: createdAt.date
        )
    }
}

/// Full workflow snapshot, including the resolved template body. `AgentWorkflowDefinition`'s own
/// Codable form deliberately omits custom templates, so recovery does not reuse it.
package struct AgentRecoveryWorkflowSnapshot: Equatable {
    package enum Source: Equatable {
        case builtIn(AgentWorkflow)
        case custom(id: UUID)
    }

    package let source: Source
    package let displayName: String
    package let iconName: String
    package let accentColorHex: String?
    package let tooltipText: String?
    package let descriptionText: String?
    package let template: String?
    package var extras: AgentRecoveryExtras

    package init(
        source: Source,
        displayName: String,
        iconName: String,
        accentColorHex: String?,
        tooltipText: String?,
        descriptionText: String?,
        template: String?,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.source = source
        self.displayName = displayName
        self.iconName = iconName
        self.accentColorHex = accentColorHex
        self.tooltipText = tooltipText
        self.descriptionText = descriptionText
        self.template = template
        self.extras = extras
    }

    package init(_ definition: AgentWorkflowDefinition) {
        let source: Source = switch definition.source {
        case let .builtIn(workflow): .builtIn(workflow)
        case let .custom(id): .custom(id: id)
        }
        self.init(
            source: source,
            displayName: definition.displayName,
            iconName: definition.iconName,
            accentColorHex: definition.accentColorHex,
            tooltipText: definition.tooltipText,
            descriptionText: definition.descriptionText,
            template: definition.template
        )
    }

    /// The workflow as captured, including its snapshotted template body.
    package var definition: AgentWorkflowDefinition {
        var definition = switch source {
        case let .builtIn(workflow):
            AgentWorkflowDefinition(builtIn: workflow)
        case let .custom(id):
            AgentWorkflowDefinition(
                customID: id,
                displayName: displayName,
                iconName: iconName,
                accentColorHex: accentColorHex,
                tooltipText: tooltipText,
                descriptionText: descriptionText
            )
        }
        definition.template = template
        return definition
    }
}

/// Immutable composer or intent payload: text, images, tagged files, workflow, interview choice.
package struct AgentRecoveryInputContent: Equatable {
    package let text: String
    package let images: [AgentRecoveryImageReference]
    package let taggedFiles: [AgentRecoveryTaggedFileReference]
    package let workflow: AgentRecoveryWorkflowSnapshot?
    package let interviewFirst: Bool
    package var extras: AgentRecoveryExtras

    package init(
        text: String,
        images: [AgentRecoveryImageReference] = [],
        taggedFiles: [AgentRecoveryTaggedFileReference] = [],
        workflow: AgentRecoveryWorkflowSnapshot? = nil,
        interviewFirst: Bool = false,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.text = text
        self.images = images
        self.taggedFiles = taggedFiles
        self.workflow = workflow
        self.interviewFirst = interviewFirst
        self.extras = extras
    }

    /// No user-visible content; an empty composer is stored as an absent composer.
    package var isEmpty: Bool {
        text.isEmpty && images.isEmpty && taggedFiles.isEmpty && workflow == nil && !interviewFirst
    }

    var managedImageFileNames: Set<String> {
        Set(images.compactMap(\.managedFileName))
    }
}

/// Immutable composer snapshot under one composer revision. It keeps the reset generation it was
/// typed under, so carrying it through a later record rewrite never relabels it as current input.
package struct AgentRecoveryComposerSnapshot: Equatable {
    package let revision: AgentRecoveryComposerRevision
    package let capturedAt: AgentRecoveryTimestamp
    package let transcriptResetGeneration: UInt64
    package let content: AgentRecoveryInputContent
    package var extras: AgentRecoveryExtras

    package init(
        revision: AgentRecoveryComposerRevision,
        capturedAt: AgentRecoveryTimestamp,
        transcriptResetGeneration: UInt64,
        content: AgentRecoveryInputContent,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.revision = revision
        self.capturedAt = capturedAt
        self.transcriptResetGeneration = transcriptResetGeneration
        self.content = content
        self.extras = extras
    }
}

// MARK: - Pending handoff

/// Exact pending-handoff content a send prepends to its provider-facing text, captured on the intent
/// before any handoff. Only the appended handoff is kept (never automatically expanded workspace
/// context). It lives on the intent, not in `AgentRecoveryInputContent`, so composer snapshots never
/// inherit the provider prefix and the user bubble keeps showing the original user input
/// (`AgentRecoveryIntent.payload`).
///
/// `payloadID` is the durable `AgentPendingHandoffState.payloadID`: the join key between a payload
/// still pending in the session and this intent's delivery evidence. `createdAt` has millisecond
/// precision and is never an identity.
package struct AgentRecoveryPendingHandoffSnapshot: Equatable {
    package let payloadID: UUID
    /// Exact original pending payload.
    package let payload: String
    package let createdAt: AgentRecoveryTimestamp?
    package let sourceItemID: UUID?
    /// Exact text prepended to the provider-facing input, separator included.
    package let prependedText: String
    package var extras: AgentRecoveryExtras

    package init(
        payloadID: UUID,
        payload: String,
        createdAt: AgentRecoveryTimestamp?,
        sourceItemID: UUID?,
        prependedText: String,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.payloadID = payloadID
        self.payload = payload
        self.createdAt = createdAt
        self.sourceItemID = sourceItemID
        self.prependedText = prependedText
        self.extras = extras
    }

    /// Captures the session's pending handoff as prepended by one send. `nil` unless the state has a
    /// non-empty payload with a durable payload ID (call `ensurePayloadID()` and persist it first).
    package init?(_ state: AgentPendingHandoffState, prependedText: String) {
        guard state.hasPayload, let payload = state.payload, let payloadID = state.payloadID else {
            return nil
        }
        self.init(
            payloadID: payloadID,
            payload: payload,
            createdAt: state.createdAt.map { AgentRecoveryTimestamp($0) },
            sourceItemID: state.sourceItemID,
            prependedText: prependedText
        )
    }

    /// Same captured content, ignoring unknown members a newer build stored.
    package func hasSameContent(as other: AgentRecoveryPendingHandoffSnapshot) -> Bool {
        payloadID == other.payloadID
            && payload == other.payload
            && createdAt == other.createdAt
            && sourceItemID == other.sourceItemID
            && prependedText == other.prependedText
    }
}

// MARK: - Intents and attempts

/// R2 intent delivery state. Exactly these six values; holds never add a state.
package enum AgentRecoveryDeliveryState: String, CaseIterable {
    /// Saved; no handoff has begun.
    case queued
    /// Handoff may have happened.
    case dispatching
    /// The provider acknowledged it (not "completed").
    case providerAccepted
    /// Sending again might duplicate it.
    case deliveryUnknown
    /// Verified rejection or pre-handoff failure; the payload is kept.
    case failed
    /// The user removed it explicitly.
    case withdrawn

    /// No further delivery action applies. This is not a retention predicate: accepted intents keep
    /// evidence needed to reconcile the transcript, so nothing deletes records based on it.
    package var requiresNoFurtherDelivery: Bool {
        self == .providerAccepted || self == .withdrawn
    }
}

/// Send route that produced an intent (spec "Done when" 1). Closed set: an unknown value makes the
/// record unreadable rather than being coerced.
package enum AgentRecoveryIntentOrigin: String, CaseIterable {
    case composer
    case followUp
    case steering
    case codexFallback
    case scheduled
    case mcp
}

/// R9 receipt-transfer join: the schedule and its dispatching attempt that produced this intent.
package struct AgentRecoveryScheduleReference: Equatable {
    package let scheduleID: UUID
    package let scheduleAttemptID: UUID
    package var extras: AgentRecoveryExtras

    package init(scheduleID: UUID, scheduleAttemptID: UUID, extras: AgentRecoveryExtras = [:]) {
        self.scheduleID = scheduleID
        self.scheduleAttemptID = scheduleAttemptID
        self.extras = extras
    }
}

/// R10: the user's explicit "Cancel pending schedule" decision for one held schedule transfer,
/// persisted on the linked intent. It names the exact schedule and schedule attempt (it never
/// matches a replacement schedule), means only "stop owning this pending schedule" (not "the
/// message was not delivered"), and changes no delivery state or attempt outcome. A startup or
/// owner repair that finds a matching decision finishes the cancellation (clears that exact
/// pending schedule without any receipt); it never resends or asks for another confirmation.
package struct AgentRecoveryScheduledTransferCancellation: Equatable {
    package let decisionID: UUID
    package let scheduleID: UUID
    package let scheduleAttemptID: UUID
    package let recordedAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        decisionID: UUID,
        scheduleID: UUID,
        scheduleAttemptID: UUID,
        recordedAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.decisionID = decisionID
        self.scheduleID = scheduleID
        self.scheduleAttemptID = scheduleAttemptID
        self.recordedAt = recordedAt
        self.extras = extras
    }

    package func matches(scheduleID: UUID, scheduleAttemptID: UUID) -> Bool {
        self.scheduleID == scheduleID && self.scheduleAttemptID == scheduleAttemptID
    }
}

/// Live run an input was admitted against. `runAttemptID` is the existing
/// `AgentRunOwnership.attemptID`; `processRunID` is the process run (`AgentTabSession.runID`),
/// which can span several attempts; `providerConversationID` is the provider's own conversation
/// identity (for example the Codex thread ID) when the route has one. Runtime-only guards
/// (`AgentRunBindingIdentity`, controller identity and generation) are revalidated by the producer
/// and never persisted.
package struct AgentRecoveryRunTarget: Equatable {
    package let runAttemptID: UUID
    package let processRunID: UUID?
    package let providerConversationID: String?
    package var extras: AgentRecoveryExtras

    package init(
        runAttemptID: UUID,
        processRunID: UUID?,
        providerConversationID: String?,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.runAttemptID = runAttemptID
        self.processRunID = processRunID
        self.providerConversationID = providerConversationID
        self.extras = extras
    }
}

/// Immutable target captured at admission. The lifecycle part (incarnation, reset generation) is
/// the record's and the intent's own. An explicit user action never silently retargets an intent.
package struct AgentRecoveryIntentTarget: Equatable {
    /// `nil` = session input (no existing live run is claimed).
    package let liveRun: AgentRecoveryRunTarget?
    package var extras: AgentRecoveryExtras

    package init(liveRun: AgentRecoveryRunTarget?, extras: AgentRecoveryExtras = [:]) {
        self.liveRun = liveRun
        self.extras = extras
    }

    package static let session = AgentRecoveryIntentTarget(liveRun: nil)

    package static func liveRun(_ run: AgentRecoveryRunTarget) -> AgentRecoveryIntentTarget {
        AgentRecoveryIntentTarget(liveRun: run)
    }
}

package struct AgentRecoveryIntent: Equatable {
    package let intentID: UUID
    /// The transcript user item this message is (or will be) shown as. Supplied by the producer from
    /// its actual item identity and retained across every retry, so Send never appends a second bubble.
    package let userItemID: UUID
    package let origin: AgentRecoveryIntentOrigin
    package let target: AgentRecoveryIntentTarget
    package let createdAt: AgentRecoveryTimestamp
    /// Launch instance that owns live draining of this intent. Changes only on an explicit user dispatch.
    package internal(set) var appInstanceID: UUID
    /// Foundation reset generation the intent was committed under (never retargeted on reset).
    package let transcriptResetGeneration: UInt64
    package internal(set) var deliveryState: AgentRecoveryDeliveryState
    package let payload: AgentRecoveryInputContent
    package let scheduleReference: AgentRecoveryScheduleReference?
    /// Pending handoff prepended to this intent's provider-facing text. Set at submission or attached
    /// once to a `queued` intent whose earlier attempts (if any) are all conclusively not delivered
    /// (`AgentRecoveryStore.attachPendingHandoff`); never replaced and never cleared, so delivery
    /// evidence stays joinable to the payload.
    package internal(set) var pendingHandoff: AgentRecoveryPendingHandoffSnapshot?
    /// Persisted stale-target hold: the captured target was lost after admission (for example the run
    /// ended during the store await). Absent means not marked; it is never cleared by a rewrite.
    package internal(set) var staleTargetMarkedAt: AgentRecoveryTimestamp?
    /// Set by an explicit withdrawal. Kept as history if acceptance evidence for an earlier attempt
    /// arrives later (acceptance wins).
    package internal(set) var withdrawnAt: AgentRecoveryTimestamp?
    /// R10 explicit cancellation of this intent's held schedule transfer (see the type).
    package internal(set) var scheduledTransferCancellation: AgentRecoveryScheduledTransferCancellation?
    package var extras: AgentRecoveryExtras

    package init(
        intentID: UUID,
        userItemID: UUID,
        origin: AgentRecoveryIntentOrigin,
        target: AgentRecoveryIntentTarget,
        createdAt: AgentRecoveryTimestamp,
        appInstanceID: UUID,
        transcriptResetGeneration: UInt64,
        deliveryState: AgentRecoveryDeliveryState,
        payload: AgentRecoveryInputContent,
        scheduleReference: AgentRecoveryScheduleReference?,
        pendingHandoff: AgentRecoveryPendingHandoffSnapshot? = nil,
        staleTargetMarkedAt: AgentRecoveryTimestamp? = nil,
        withdrawnAt: AgentRecoveryTimestamp? = nil,
        scheduledTransferCancellation: AgentRecoveryScheduledTransferCancellation? = nil,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.scheduledTransferCancellation = scheduledTransferCancellation
        self.intentID = intentID
        self.userItemID = userItemID
        self.origin = origin
        self.target = target
        self.createdAt = createdAt
        self.appInstanceID = appInstanceID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.deliveryState = deliveryState
        self.payload = payload
        self.scheduleReference = scheduleReference
        self.pendingHandoff = pendingHandoff
        self.staleTargetMarkedAt = staleTargetMarkedAt
        self.withdrawnAt = withdrawnAt
        self.extras = extras
    }
}

package enum AgentRecoveryFailureKind: String, CaseIterable {
    /// The provider verifiably rejected the message.
    case verifiedRejection
    /// The handoff provably never began.
    case preHandoff
}

/// Delivery outcome evidence recorded on an attempt (R2 outcomes by boundary).
package enum AgentRecoveryDeliveryOutcome: Equatable {
    case providerAccepted
    case deliveryUnknown
    case failed(AgentRecoveryFailureKind, message: String?)

    var resultingState: AgentRecoveryDeliveryState {
        switch self {
        case .providerAccepted: .providerAccepted
        case .deliveryUnknown: .deliveryUnknown
        case .failed: .failed
        }
    }
}

package struct AgentRecoveryAttemptOutcome: Equatable {
    /// Extras member carrying the explanation of a `.deliveryUnknown` outcome (a `.failed` outcome
    /// keeps its own message). A forward-compatible member: no schema change.
    package static let deliveryUnknownMessageExtrasKey = "message"

    package let outcome: AgentRecoveryDeliveryOutcome
    package let recordedAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        outcome: AgentRecoveryDeliveryOutcome,
        recordedAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.outcome = outcome
        self.recordedAt = recordedAt
        self.extras = extras
    }
}

/// One delivery attempt (a handoff), written as `dispatching` evidence before any provider handoff.
/// Distinct from a run attempt: several deliveries can share one run attempt.
package struct AgentRecoveryAttempt: Equatable {
    package let attemptID: UUID
    package let intentID: UUID
    package let userItemID: UUID
    /// The existing run attempt (`AgentRunOwnership.attemptID`); attachable once when ownership
    /// becomes available.
    package internal(set) var runAttemptID: UUID?
    /// R1a join key when the producer knows the transcript turn.
    package let transcriptTurnID: UUID?
    package let appInstanceID: UUID
    package let dispatchedAt: AgentRecoveryTimestamp
    package internal(set) var outcome: AgentRecoveryAttemptOutcome?
    /// Earlier non-accepting evidence replaced by later affirmative acceptance for this exact
    /// attempt. `.deliveryUnknown` is a refinement; `.failed` is preserved conflicting evidence.
    package internal(set) var supersededOutcome: AgentRecoveryAttemptOutcome?
    package var extras: AgentRecoveryExtras

    package init(
        attemptID: UUID,
        intentID: UUID,
        userItemID: UUID,
        runAttemptID: UUID?,
        transcriptTurnID: UUID?,
        appInstanceID: UUID,
        dispatchedAt: AgentRecoveryTimestamp,
        outcome: AgentRecoveryAttemptOutcome? = nil,
        supersededOutcome: AgentRecoveryAttemptOutcome? = nil,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.attemptID = attemptID
        self.intentID = intentID
        self.userItemID = userItemID
        self.runAttemptID = runAttemptID
        self.transcriptTurnID = transcriptTurnID
        self.appInstanceID = appInstanceID
        self.dispatchedAt = dispatchedAt
        self.outcome = outcome
        self.supersededOutcome = supersededOutcome
        self.extras = extras
    }
}

// MARK: - Run attempts

/// Recordable per-attempt shutdown or close reasons (spec R5 values). `appCrash` and `unknown` are
/// inferred at cold restore, never recorded by a live process.
package enum AgentRecoveryShutdownReason: String, CaseIterable {
    case appQuit
    case windowClose
    case safeRestart
    case providerProcessLost
}

/// How `ensureRunAttempt` treats a process-run association that differs from the recorded one.
package enum AgentRecoveryRunAssociationPolicy: Equatable {
    /// Start-time evidence: a conflicting process run fails the write.
    case strict
    /// Terminal-time completion: fills only a missing association and keeps an existing one, so
    /// terminal evidence is never lost to an association mismatch.
    case keepExisting
}

/// Why a run reached its terminal commit (Phase 2). Recorded with terminal evidence and used by
/// the shared interruption classifier; there is deliberately no live `appCrash` cause (a crash
/// never commits). An explicit user cancel is not an interruption.
package enum AgentRunTerminalCause: String, CaseIterable {
    /// Provider completion or failure, or a cancellation that is neither a user stop nor a
    /// lifecycle teardown (workspace switch, reset, delete).
    case ordinary
    case userCancel
    case appQuit
    case windowClose
    case providerProcessLost

    /// The live interruption reason this cause stamps on a non-completed turn; `nil` when the
    /// terminal is not an interruption.
    package var interruptionReason: AgentTranscriptTurnInterruption.Reason? {
        switch self {
        case .ordinary, .userCancel: nil
        case .appQuit: .appQuit
        case .windowClose: .windowClose
        case .providerProcessLost: .providerProcessLost
        }
    }

    package init(shutdownReason: AgentRecoveryShutdownReason) {
        switch shutdownReason {
        case .appQuit: self = .appQuit
        case .windowClose: self = .windowClose
        // Safe restart is a later phase; its teardown is an app quit until then.
        case .safeRestart: self = .appQuit
        case .providerProcessLost: self = .providerProcessLost
        }
    }

    /// The cause a commit records: a completed run is always ordinary (completion wins against a
    /// provisional shutdown reason), an explicit user cancel stays one, and otherwise a lifecycle
    /// teardown cause set before the run was cancelled wins over the runner's own request.
    package static func effective(
        requested: AgentRunTerminalCause,
        terminalState: AgentSessionRunState,
        lifecycleTeardown: AgentRunTerminalCause?
    ) -> AgentRunTerminalCause {
        if terminalState == .completed { return .ordinary }
        if requested == .userCancel { return .userCancel }
        return lifecycleTeardown ?? requested
    }
}

/// Terminal evidence from `AgentRunTerminalCommitRevision`, independent of any MCP envelope.
package struct AgentRecoveryRunTerminalEvidence: Equatable {
    package let commitID: UUID
    /// One of the commit terminal states (`completed`, `cancelled`, `failed`).
    package let terminalState: AgentSessionRunState
    package let expectedRunID: UUID?
    package let recordedAt: AgentRecoveryTimestamp
    /// `nil` for evidence written before Phase 2 or with an unrecognized value (kept in extras).
    package let cause: AgentRunTerminalCause?
    package var extras: AgentRecoveryExtras

    package init(
        commitID: UUID,
        terminalState: AgentSessionRunState,
        expectedRunID: UUID?,
        recordedAt: AgentRecoveryTimestamp,
        cause: AgentRunTerminalCause?,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.commitID = commitID
        self.terminalState = terminalState
        self.expectedRunID = expectedRunID
        self.recordedAt = recordedAt
        self.cause = cause
        self.extras = extras
    }
}

package struct AgentRecoveryRunShutdownEvidence: Equatable {
    package let reason: AgentRecoveryShutdownReason
    package let observedAt: AgentRecoveryTimestamp
    package let lastConfirmedActivityAt: AgentRecoveryTimestamp?
    package var extras: AgentRecoveryExtras

    package init(
        reason: AgentRecoveryShutdownReason,
        observedAt: AgentRecoveryTimestamp,
        lastConfirmedActivityAt: AgentRecoveryTimestamp?,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.reason = reason
        self.observedAt = observedAt
        self.lastConfirmedActivityAt = lastConfirmedActivityAt
        self.extras = extras
    }
}

/// Evidence for one existing logical run attempt, keyed by `AgentRunOwnership.attemptID`. Recovery
/// never allocates run identity. Provider acceptance is not run completion.
package struct AgentRecoveryRunAttempt: Equatable {
    package let runAttemptID: UUID
    /// Reset generation captured when the run evidence was first recorded.
    package let transcriptResetGeneration: UInt64
    package internal(set) var processRunID: UUID?
    package internal(set) var transcriptTurnID: UUID?
    package let startedAt: AgentRecoveryTimestamp
    /// The app instance that first recorded this run's evidence (the launch that owns the run).
    /// Optional run-start evidence: a legacy attempt without it has an unknown owner, never the
    /// current launch. Captured once and never rewritten.
    package let appInstanceID: UUID?
    package internal(set) var terminal: AgentRecoveryRunTerminalEvidence?
    package internal(set) var shutdown: AgentRecoveryRunShutdownEvidence?
    package var extras: AgentRecoveryExtras

    /// Extras member naming the provider kind (`AgentProviderKind` raw value) the run was started
    /// with: optional run-start evidence carried as a forward-compatible member (no schema change).
    package static let providerKindExtrasKey = "providerKind"

    /// The provider kind raw value recorded at run start, or `nil` for a run recorded before it was
    /// captured (or by a path that did not know it).
    package var recordedProviderKindRaw: String? {
        if case let .string(value)? = extras[Self.providerKindExtrasKey] { return value }
        return nil
    }

    /// Extras member naming how the run's provider launches were owned when the run started
    /// (Step 9-activation-b): optional run-start evidence, written only when the attempt is first
    /// recorded by the creator that precedes the run's first provider write, never rewritten.
    package static let runtimeRegistrationExtrasKey = "runtimeRegistration"
    /// `runtimeRegistration` value: every family that can serve the run's provider registered its
    /// launches with the process registry (`AgentRuntimeLaunchAuthority.runStartRegistrationMark`).
    /// A string, so a later authority kind can be told apart without a schema change.
    package static let registeredRuntimeRegistration = "registry"

    /// The run-start registration mark, or `nil` for a run started without registered launches (or
    /// recorded before the mark existed): such a run's processes can never be proven exited.
    package var recordedRuntimeRegistrationRaw: String? {
        if case let .string(value)? = extras[Self.runtimeRegistrationExtrasKey] { return value }
        return nil
    }

    /// Extras member naming the provider's native turn ID (9-live R2, Codex): the turn that last
    /// became authoritative for this run when it is a user turn, written after run start and
    /// rewritten last-wins (a steer Codex accepted into a different turn names the turn running at a
    /// kill). Set to an explicit JSON `null` when a compaction, review or unknown turn becomes
    /// authoritative: the run's turn is then known to be unidentifiable. Reconcile matches the
    /// provider history against it.
    package static let providerTurnIDExtrasKey = "providerTurnID"

    /// The recorded native provider turn ID, or `nil` when none was recorded or it was cleared.
    package var recordedProviderTurnID: String? {
        if case let .string(value)? = extras[Self.providerTurnIDExtrasKey] { return value }
        return nil
    }

    /// Whether the run's provider turn was recorded (an ID, or the cleared `null` marker). When true,
    /// `recordedProviderTurnID` is authoritative and no other source (a transcript span) may stand in
    /// for it; when false (a legacy or unrecorded attempt) a fallback may.
    package var hasProviderTurnRecord: Bool {
        extras[Self.providerTurnIDExtrasKey] != nil
    }

    package init(
        runAttemptID: UUID,
        transcriptResetGeneration: UInt64,
        processRunID: UUID?,
        transcriptTurnID: UUID?,
        startedAt: AgentRecoveryTimestamp,
        appInstanceID: UUID? = nil,
        terminal: AgentRecoveryRunTerminalEvidence? = nil,
        shutdown: AgentRecoveryRunShutdownEvidence? = nil,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.runAttemptID = runAttemptID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.processRunID = processRunID
        self.transcriptTurnID = transcriptTurnID
        self.startedAt = startedAt
        self.appInstanceID = appInstanceID
        self.terminal = terminal
        self.shutdown = shutdown
        self.extras = extras
    }
}

/// The user's explicit acknowledgement of one exact prior-run crash hold ("I acknowledged this
/// prior-run warning and chose to continue"). It never marks a run completed, cancelled or
/// aborted, hides no recovery row, and authorizes no replay of uncertain input. The write that
/// records it may settle the hold's qualifying `dispatching` messages to `deliveryUnknown`
/// (`AgentRecoveryCrashHoldIntentSettlement`, O43/O46); their rows become informational. A later
/// startup treats a hold as acknowledged when this covers it: same incarnation and reset
/// generation, and every uncertain identity of the hold is in this decision (an identity that left
/// the hold since, such as a withdrawn message, needs no new decision); additional or changed
/// uncertainty asks again. ID sets are encoded sorted, so the value round-trips deterministically.
package struct AgentRecoveryCrashHoldAcknowledgement: Equatable {
    package let decisionID: UUID
    package let incarnationID: UUID
    package let transcriptResetGeneration: UInt64
    package let runAttemptIDs: Set<UUID>
    package let intentIDs: Set<UUID>
    package let transcriptTurnIDs: Set<UUID>
    package let recordedAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        decisionID: UUID,
        incarnationID: UUID,
        transcriptResetGeneration: UInt64,
        runAttemptIDs: Set<UUID>,
        intentIDs: Set<UUID>,
        transcriptTurnIDs: Set<UUID>,
        recordedAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.decisionID = decisionID
        self.incarnationID = incarnationID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.runAttemptIDs = runAttemptIDs
        self.intentIDs = intentIDs
        self.transcriptTurnIDs = transcriptTurnIDs
        self.recordedAt = recordedAt
        self.extras = extras
    }

    /// Whether this decision acknowledged all of the uncertainty described by these identities (the
    /// same lifecycle, and each set a subset of the acknowledged one). 9-live review B P2-3: Edit or
    /// Remove of a settled message shrinks the next launch's hold and must not ask again.
    package func covers(
        incarnationID: UUID,
        transcriptResetGeneration: UInt64,
        runAttemptIDs: Set<UUID>,
        intentIDs: Set<UUID>,
        transcriptTurnIDs: Set<UUID>
    ) -> Bool {
        self.incarnationID == incarnationID
            && self.transcriptResetGeneration == transcriptResetGeneration
            && runAttemptIDs.isSubset(of: self.runAttemptIDs)
            && intentIDs.isSubset(of: self.intentIDs)
            && transcriptTurnIDs.isSubset(of: self.transcriptTurnIDs)
    }
}

/// O43/O46: how a crash-hold acknowledgement settles the hold's delivery-uncertain messages in the
/// same write. A qualifying `dispatching` intent becomes `deliveryUnknown` (one already
/// `deliveryUnknown` stays so) and each of its open attempts gets a `.deliveryUnknown` outcome with
/// `message`; the payload is never removed and nothing is resent
/// (`AgentRecoveryRecord.crashHoldSettlementQualifies`).
package enum AgentRecoveryCrashHoldIntentSettlement: Equatable {
    /// Check and resolve's registry proof: every listed intent must qualify, otherwise the write is
    /// refused (`AgentRecoveryStoreError.intentConflict`) and nothing is written.
    case everyIntent
    /// "It stopped": qualifying intents are settled; any other stays as it is (acknowledged only).
    case qualifyingIntents

    package static let provenExitMessage =
        "Process records show every process of this run exited before the provider confirmed the message."
    package static let userConfirmedStopMessage =
        "You confirmed the run stopped before the provider confirmed the message."

    /// The explanation recorded on each settled attempt.
    package var message: String {
        switch self {
        case .everyIntent: Self.provenExitMessage
        case .qualifyingIntents: Self.userConfirmedStopMessage
        }
    }
}

// MARK: - Recovery card acknowledgements (durable Dismiss)

/// Typed semantic identity of one recovery card (lossless restart Phase 2 §D): session incarnation,
/// the item's own reset generation where it has one, kind, and durable entity ID (run-attempt ID,
/// legacy turn ID, intent ID, interaction ID, composer revision, schedule/attempt identity, or crash
/// hold identity). Never row text, array position, record revision, or `updatedAt`. The kind is kept
/// as its raw string so an acknowledgement a newer build wrote round-trips unchanged.
package struct AgentRecoveryCardKey: Hashable {
    package enum Kind: String, CaseIterable {
        /// An interrupted turn or a run's recorded terminal outcome.
        case run
        case savedInput
        case savedDraft
        case question
        case schedule
        case crashHold
    }

    package let kindRaw: String
    package let incarnationID: UUID
    package let transcriptResetGeneration: UInt64?
    package let entityID: String

    package init(kind: Kind, incarnationID: UUID, transcriptResetGeneration: UInt64?, entityID: String) {
        self.init(kindRaw: kind.rawValue, incarnationID: incarnationID, transcriptResetGeneration: transcriptResetGeneration, entityID: entityID)
    }

    package init(kindRaw: String, incarnationID: UUID, transcriptResetGeneration: UInt64?, entityID: String) {
        self.kindRaw = kindRaw
        self.incarnationID = incarnationID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.entityID = entityID
    }

    /// `nil` for a kind this build does not know (kept, never matched).
    package var kind: Kind? {
        Kind(rawValue: kindRaw)
    }
}

/// The semantic state of a card when it was acknowledged, derived only from typed facts that make
/// it reappear when they change materially (outcome or interruption cause, delivery classification
/// and holds, a new composer revision, a new confirmation occurrence or reason, a changed
/// uncertainty set). Ordinary edits, receipts, and unrelated record writes do not change it.
package struct AgentRecoveryCardFreshness: Hashable {
    package let token: String

    package init(_ token: String) {
        self.token = token
    }
}

/// The user's durable Dismiss of one card in one semantic state. It hides that card only while its
/// freshness is unchanged. It never resolves a turn, withdraws or edits input, removes a question
/// or draft, confirms or cancels a schedule, releases a crash hold or restriction, or changes run
/// or process ownership.
package struct AgentRecoveryCardAcknowledgement: Equatable {
    package let key: AgentRecoveryCardKey
    package let freshness: AgentRecoveryCardFreshness
    package let acknowledgedAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        key: AgentRecoveryCardKey,
        freshness: AgentRecoveryCardFreshness,
        acknowledgedAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.key = key
        self.freshness = freshness
        self.acknowledgedAt = acknowledgedAt
        self.extras = extras
    }
}

// MARK: - Delegated child links (Phase 5, Step 5b)

/// One routed `agent_run.start` admitted under this record's session (the parent), committed after
/// the child's covering session stub and before the child's first dispatch. It records local
/// execution identity only: the existing server-side MCP invocation UUID of the admitted tool call
/// and the parent run attempt active at admission. It is not a provider-native tool-use identity,
/// not a cross-request deduplication key, and not proof that the child started: recovery uses it to
/// find the existing child instead of replaying `agent_run`, and never dispatches from it.
package struct AgentRecoveryDelegatedChildLink: Equatable {
    package let invocationID: UUID
    /// `AgentRunOwnership.attemptID` of the parent run active when the call was admitted.
    package let parentRunAttemptID: UUID
    package let childSessionID: UUID
    package let linkedAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        invocationID: UUID,
        parentRunAttemptID: UUID,
        childSessionID: UUID,
        linkedAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.invocationID = invocationID
        self.parentRunAttemptID = parentRunAttemptID
        self.childSessionID = childSessionID
        self.linkedAt = linkedAt
        self.extras = extras
    }
}

// MARK: - Record

package struct AgentRecoveryRecord: Equatable {
    package static let currentSchemaVersion = 1

    package let sessionID: UUID
    package let revision: AgentRecoveryRecordRevision
    package let incarnationID: UUID
    /// Latest foundation reset generation that wrote this record.
    package let transcriptResetGeneration: UInt64
    package let updatedAt: AgentRecoveryTimestamp
    package let composer: AgentRecoveryComposerSnapshot?
    /// Intents in submission order.
    package let intents: [AgentRecoveryIntent]
    package let attempts: [AgentRecoveryAttempt]
    package let runAttempts: [AgentRecoveryRunAttempt]
    /// Latest explicit crash-hold acknowledgement; absent means unacknowledged.
    package let crashHoldAcknowledgement: AgentRecoveryCrashHoldAcknowledgement?
    /// Pending questions preserved by the latest shutdown preparation (empty = none). Display and
    /// explicit composer restore only: never a continuation, routing, or provider request.
    package let questions: [AgentRecoveryQuestionSnapshot]
    /// Durable card acknowledgements (Dismiss), one per card key (empty = none). Additive: a record
    /// without them decodes empty and keeps its existing bytes.
    package let cardAcknowledgements: [AgentRecoveryCardAcknowledgement]
    /// Durable recovery action reservations (Phase 4), in reservation order (empty = none).
    /// Additive: absent when empty, so older records keep their bytes.
    package let actions: [AgentRecoveryAction]
    /// Provider history cursors (Phase 4), one per provider conversation (empty = none).
    package let historyCursors: [AgentRecoveryHistoryCursor]
    /// Delegated child links (Step 5b), in commit order (empty = none). Additive: absent when
    /// empty, so older records keep their bytes.
    package let delegatedChildLinks: [AgentRecoveryDelegatedChildLink]
    /// Step 5a: reviewed `apply_edits` proposals, in commit order (empty = none). A proposal is
    /// stored before its live review is shown and removed only once it is applied (and recorded) or
    /// explicitly withdrawn. Additive: absent when empty, so older records keep their bytes.
    package let editProposals: [AgentRecoveryEditProposal]
    package let extras: AgentRecoveryExtras

    package init(
        sessionID: UUID,
        revision: AgentRecoveryRecordRevision,
        incarnationID: UUID,
        transcriptResetGeneration: UInt64,
        updatedAt: AgentRecoveryTimestamp,
        composer: AgentRecoveryComposerSnapshot?,
        intents: [AgentRecoveryIntent],
        attempts: [AgentRecoveryAttempt],
        runAttempts: [AgentRecoveryRunAttempt],
        crashHoldAcknowledgement: AgentRecoveryCrashHoldAcknowledgement? = nil,
        questions: [AgentRecoveryQuestionSnapshot] = [],
        cardAcknowledgements: [AgentRecoveryCardAcknowledgement] = [],
        actions: [AgentRecoveryAction] = [],
        historyCursors: [AgentRecoveryHistoryCursor] = [],
        delegatedChildLinks: [AgentRecoveryDelegatedChildLink] = [],
        editProposals: [AgentRecoveryEditProposal] = [],
        extras: AgentRecoveryExtras = [:]
    ) {
        self.actions = actions
        self.editProposals = editProposals
        self.historyCursors = historyCursors
        self.delegatedChildLinks = delegatedChildLinks
        self.crashHoldAcknowledgement = crashHoldAcknowledgement
        self.questions = questions
        self.cardAcknowledgements = cardAcknowledgements
        self.sessionID = sessionID
        self.revision = revision
        self.incarnationID = incarnationID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.updatedAt = updatedAt
        self.composer = composer
        self.intents = intents
        self.attempts = attempts
        self.runAttempts = runAttempts
        self.extras = extras
    }

    package func intent(id: UUID) -> AgentRecoveryIntent? {
        intents.first { $0.intentID == id }
    }

    package func attempts(forIntent intentID: UUID) -> [AgentRecoveryAttempt] {
        attempts.filter { $0.intentID == intentID }
    }

    package func runAttempt(id: UUID) -> AgentRecoveryRunAttempt? {
        runAttempts.first { $0.runAttemptID == id }
    }

    /// O43: the intent has at least one delivery attempt and every one references a run attempt in
    /// `exitedRunAttemptIDs` or one with recorded terminal evidence (a T4-style retry on a finished
    /// run). An attempt without a run-attempt reference is never covered.
    package func intentAttemptsAreOnExitedRuns(intentID: UUID, exitedRunAttemptIDs: Set<UUID>) -> Bool {
        let attempts = attempts(forIntent: intentID)
        return !attempts.isEmpty && attempts.allSatisfy { attempt in
            guard let runAttemptID = attempt.runAttemptID else { return false }
            return exitedRunAttemptIDs.contains(runAttemptID) || runAttempt(id: runAttemptID)?.terminal != nil
        }
    }

    /// O50: the intent has at least one delivery attempt and every one ran in a run attempt whose
    /// end this app recorded (terminal or shutdown evidence). Its delivery uncertainty then does not
    /// come from an unclean exit, so it is never worded as "RepoPrompt stopped".
    package func intentRunsEndedWithRecordedEvidence(intentID: UUID) -> Bool {
        let attempts = attempts(forIntent: intentID)
        return !attempts.isEmpty && attempts.allSatisfy { attempt in
            guard let runAttemptID = attempt.runAttemptID, let run = runAttempt(id: runAttemptID) else { return false }
            return run.terminal != nil || run.shutdown != nil
        }
    }

    /// O51: a `deliveryUnknown` intent left by a run RepoPrompt itself ended normally: it has at
    /// least one attempt, and every attempt closed `deliveryUnknown` in a run attempt with terminal
    /// cause `ordinary` and state `completed` or `cancelled`, without shutdown evidence. Anything
    /// else (an open attempt, a run without terminal evidence, a crash, quit, user-cancel,
    /// provider-loss, legacy or failed run) does not qualify.
    package func ordinaryExitSettlementQualifies(intentID: UUID) -> Bool {
        guard intent(id: intentID)?.deliveryState == .deliveryUnknown else { return false }
        let attempts = attempts(forIntent: intentID)
        return !attempts.isEmpty && attempts.allSatisfy { attempt in
            guard attempt.outcome?.outcome == .deliveryUnknown,
                  let runAttemptID = attempt.runAttemptID,
                  let run = runAttempt(id: runAttemptID),
                  run.shutdown == nil,
                  let terminal = run.terminal,
                  terminal.cause == .ordinary
            else { return false }
            return terminal.terminalState == .completed || terminal.terminalState == .cancelled
        }
    }

    /// O43 qualification: a crash-hold confirmation whose run attempts `exitedRunAttemptIDs` exited
    /// may settle this intent: it is delivery-uncertain (`dispatching` or `deliveryUnknown`), it and
    /// every attempt of it were started by an earlier launch than `currentInstanceID`, and its
    /// attempts are on exited runs (`intentAttemptsAreOnExitedRuns`).
    package func crashHoldSettlementQualifies(
        intentID: UUID,
        exitedRunAttemptIDs: Set<UUID>,
        currentInstanceID: UUID
    ) -> Bool {
        guard let intent = intent(id: intentID),
              intent.deliveryState == .dispatching || intent.deliveryState == .deliveryUnknown,
              intent.appInstanceID != currentInstanceID,
              attempts(forIntent: intentID).allSatisfy({ $0.appInstanceID != currentInstanceID })
        else { return false }
        return intentAttemptsAreOnExitedRuns(intentID: intentID, exitedRunAttemptIDs: exitedRunAttemptIDs)
    }

    /// O46: the intent was settled by the stored crash-hold acknowledgement: it lists the intent,
    /// the intent is `deliveryUnknown`, and its attempts are on the acknowledged (or finished) runs.
    package func isSettledByCrashHoldExitProof(intentID: UUID) -> Bool {
        guard let acknowledgement = crashHoldAcknowledgement,
              acknowledgement.incarnationID == incarnationID,
              acknowledgement.intentIDs.contains(intentID),
              intent(id: intentID)?.deliveryState == .deliveryUnknown
        else { return false }
        return intentAttemptsAreOnExitedRuns(intentID: intentID, exitedRunAttemptIDs: acknowledgement.runAttemptIDs)
    }

    package func delegatedChildLink(invocationID: UUID) -> AgentRecoveryDelegatedChildLink? {
        delegatedChildLinks.first { $0.invocationID == invocationID }
    }

    /// Links admitted under one parent run attempt, in commit order.
    package func delegatedChildLinks(parentRunAttemptID: UUID) -> [AgentRecoveryDelegatedChildLink] {
        delegatedChildLinks.filter { $0.parentRunAttemptID == parentRunAttemptID }
    }

    package func editProposal(reviewID: UUID) -> AgentRecoveryEditProposal? {
        editProposals.first { $0.reviewID == reviewID }
    }

    package func cardAcknowledgement(for key: AgentRecoveryCardKey) -> AgentRecoveryCardAcknowledgement? {
        cardAcknowledgements.first { $0.key == key }
    }

    /// Whether the card is dismissed in exactly this semantic state.
    package func isCardAcknowledged(_ key: AgentRecoveryCardKey, freshness: AgentRecoveryCardFreshness) -> Bool {
        cardAcknowledgement(for: key)?.freshness == freshness
    }

    /// Intents (in submission order) whose captured pending handoff has `payloadID`: the hydration
    /// join for a payload still pending in the session.
    package func intents(carryingPendingHandoff payloadID: UUID) -> [AgentRecoveryIntent] {
        intents.filter { $0.pendingHandoff?.payloadID == payloadID }
    }

    /// Managed image file names referenced by the composer or any intent payload.
    var referencedManagedImageFileNames: Set<String> {
        var names = composer?.content.managedImageFileNames ?? []
        for intent in intents {
            names.formUnion(intent.payload.managedImageFileNames)
        }
        return names
    }
}

// MARK: - Pending-question snapshots

/// Which live question surface a snapshot was taken from.
package enum AgentRecoveryQuestionKind: String, CaseIterable {
    /// RepoPrompt `ask_user` wizard.
    case askUser
    /// Provider-native `request_user_input`.
    case userInput
    /// MCP elicitation (title and message only; it has no partial-answer surface).
    case elicitation
}

/// One question of a snapshot with its partial answer. A secret item never carries an answer, a
/// selection, or any plaintext derived from one: the initializer drops it.
package struct AgentRecoveryQuestionItem: Equatable {
    package let questionID: String
    package let header: String?
    package let text: String
    package let options: [String]
    package let isSecret: Bool
    /// Rendered partial answer (selected options and typed text); always `nil` for a secret item.
    package let answer: String?
    package var extras: AgentRecoveryExtras

    package init(
        questionID: String,
        header: String?,
        text: String,
        options: [String],
        isSecret: Bool,
        answer: String?,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.questionID = questionID
        self.header = header
        self.text = text
        self.options = options
        self.isSecret = isSecret
        let trimmed = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.answer = isSecret || trimmed.isEmpty ? nil : answer
        self.extras = extras
    }
}

/// A pending question preserved before shutdown (spec R4). Restored only as historical text: a
/// later launch offers an explicit copy into the composer and never resumes the old request.
package struct AgentRecoveryQuestionSnapshot: Equatable {
    /// Live interaction identity (stable per request).
    package let interactionID: UUID
    package let kind: AgentRecoveryQuestionKind
    package let runAttemptID: UUID?
    package let transcriptResetGeneration: UInt64
    package let appInstanceID: UUID
    package let askedAt: AgentRecoveryTimestamp
    package let title: String?
    package let message: String?
    package let items: [AgentRecoveryQuestionItem]
    package var extras: AgentRecoveryExtras

    package init(
        interactionID: UUID,
        kind: AgentRecoveryQuestionKind,
        runAttemptID: UUID?,
        transcriptResetGeneration: UInt64,
        appInstanceID: UUID,
        askedAt: AgentRecoveryTimestamp,
        title: String?,
        message: String?,
        items: [AgentRecoveryQuestionItem],
        extras: AgentRecoveryExtras = [:]
    ) {
        self.interactionID = interactionID
        self.kind = kind
        self.runAttemptID = runAttemptID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.appInstanceID = appInstanceID
        self.askedAt = askedAt
        self.title = title
        self.message = message
        self.items = items
        self.extras = extras
    }

    /// This snapshot written in place of `stored` (same interaction): the first stored ask time is
    /// kept, so a recapture never manufactures freshness, and unknown fields of the stored snapshot
    /// and of its items survive unless this snapshot carries the same key.
    package func mergingStored(_ stored: AgentRecoveryQuestionSnapshot) -> AgentRecoveryQuestionSnapshot {
        guard stored.interactionID == interactionID else { return self }
        let storedItems = Dictionary(stored.items.map { ($0.questionID, $0.extras) }, uniquingKeysWith: { first, _ in first })
        let mergedItems = items.map { item in
            guard let storedExtras = storedItems[item.questionID], !storedExtras.isEmpty else { return item }
            var merged = item
            merged.extras = storedExtras.merging(item.extras) { _, new in new }
            return merged
        }
        return AgentRecoveryQuestionSnapshot(
            interactionID: interactionID,
            kind: kind,
            runAttemptID: runAttemptID,
            transcriptResetGeneration: transcriptResetGeneration,
            appInstanceID: appInstanceID,
            askedAt: stored.askedAt,
            title: title,
            message: message,
            items: mergedItems,
            extras: stored.extras.merging(extras) { _, new in new }
        )
    }

    /// Plain text for an explicit composer restore (question text plus any non-secret partial
    /// answer). Contains nothing from a secret item except its question text.
    package var composerText: String {
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append(title) }
        if let message, !message.isEmpty { lines.append(message) }
        for item in items {
            lines.append("Q: \(item.text)")
            if let answer = item.answer { lines.append("A: \(answer)") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Holds

/// R2 hold reasons. Holds block automatic draining without changing delivery state. Effective holds
/// are computed on every read from persisted markers and current authority.
package enum AgentRecoveryHoldReason: String, CaseIterable {
    /// Persisted stale-target marker, or the intent's reset generation differs from current authority.
    case staleTarget
    /// A referenced managed image file is missing.
    case missingAttachment
    /// The intent belongs to an earlier app launch instance.
    case previousInstance
}

// MARK: - Receipts

/// Receipts are issued only by `AgentRecoveryStore` (internal initializers) and prove a committed
/// local state, never provider acceptance or permission to dispatch later.
package enum AgentRecoveryCommitDisposition: Equatable {
    case committed
    /// The requested durable state already existed and was revalidated; nothing was written or consumed.
    case unchanged
}

/// Composer-only commit receipt.
package struct AgentRecoveryLocalReceipt: Equatable {
    package let binding: AgentRecoveryLifecycleBinding
    /// Record revision after this operation (`nil` only when no record exists).
    package let recordRevision: AgentRecoveryRecordRevision?
    package let disposition: AgentRecoveryCommitDisposition
    /// Stored composer revision after this operation (`nil` = no stored composer).
    package let composerRevision: AgentRecoveryComposerRevision?
}

package struct AgentRecoveryIntentReceipt: Equatable {
    package let binding: AgentRecoveryLifecycleBinding
    package let recordRevision: AgentRecoveryRecordRevision
    package let disposition: AgentRecoveryCommitDisposition
    package let intentID: UUID
    package let userItemID: UUID
    package let deliveryState: AgentRecoveryDeliveryState
    /// The intent's captured pending handoff: on a dispatch receipt, the exact text to prepend.
    package let pendingHandoff: AgentRecoveryPendingHandoffSnapshot?
    /// Stored current-generation composer revision after this operation (`nil` = none stored).
    package let composerRevision: AgentRecoveryComposerRevision?
    /// Stored composer from another reset generation (held input; never consumed or replaced
    /// implicitly). Kept separate so it never becomes a current composer baseline.
    package let heldComposerRevision: AgentRecoveryComposerRevision?
    /// Whether this operation removed the stored composer.
    package let composerConsumed: Bool
}

/// Issued only for a durable `queued` intent with no hold, owned by `owningAppInstanceID`.
package struct AgentRecoveryQueueReceipt: Equatable {
    package let intent: AgentRecoveryIntentReceipt
    package let owningAppInstanceID: UUID
}

/// Issued only while the intent is `dispatching` on this open delivery attempt.
package struct AgentRecoveryDispatchReceipt: Equatable {
    package let intent: AgentRecoveryIntentReceipt
    package let attemptID: UUID
}

package struct AgentRecoveryOutcomeReceipt: Equatable {
    package let intent: AgentRecoveryIntentReceipt
    package let attemptID: UUID
    package let outcome: AgentRecoveryDeliveryOutcome
    /// Earlier evidence this acceptance superseded (`.failed` here is exposed conflicting evidence).
    package let supersededOutcome: AgentRecoveryDeliveryOutcome?
}

package struct AgentRecoveryRunReceipt: Equatable {
    package let binding: AgentRecoveryLifecycleBinding
    package let recordRevision: AgentRecoveryRecordRevision
    package let disposition: AgentRecoveryCommitDisposition
    package let runAttemptID: UUID
}

// MARK: - Mutation inputs

package struct AgentRecoveryIntentSubmission: Equatable {
    package let intentID: UUID
    package let userItemID: UUID
    package let origin: AgentRecoveryIntentOrigin
    package let target: AgentRecoveryIntentTarget
    package let payload: AgentRecoveryInputContent
    package let scheduleReference: AgentRecoveryScheduleReference?
    /// Pending handoff this submission's send prepends (committed with the intent, before handoff).
    package let pendingHandoff: AgentRecoveryPendingHandoffSnapshot?

    package init(
        intentID: UUID,
        userItemID: UUID,
        origin: AgentRecoveryIntentOrigin,
        target: AgentRecoveryIntentTarget,
        payload: AgentRecoveryInputContent,
        scheduleReference: AgentRecoveryScheduleReference? = nil,
        pendingHandoff: AgentRecoveryPendingHandoffSnapshot? = nil
    ) {
        self.intentID = intentID
        self.userItemID = userItemID
        self.origin = origin
        self.target = target
        self.payload = payload
        self.scheduleReference = scheduleReference
        self.pendingHandoff = pendingHandoff
    }
}

package struct AgentRecoveryAttemptStart: Equatable {
    package let attemptID: UUID
    package let runAttemptID: UUID?
    package let transcriptTurnID: UUID?

    package init(attemptID: UUID, runAttemptID: UUID? = nil, transcriptTurnID: UUID? = nil) {
        self.attemptID = attemptID
        self.runAttemptID = runAttemptID
        self.transcriptTurnID = transcriptTurnID
    }
}

/// One constituent of an atomic multi-intent dispatch (`beginDispatches`), in handoff order.
package struct AgentRecoveryDispatchRequest: Equatable {
    package let intentID: UUID
    package let attempt: AgentRecoveryAttemptStart

    package init(intentID: UUID, attempt: AgentRecoveryAttemptStart) {
        self.intentID = intentID
        self.attempt = attempt
    }
}

/// Conditional composer removal in the same replacement as an intent insertion. The stored
/// composer is consumed only when it has the binding's reset generation and its revision is one of
/// `consumableRevisions` (the submitted revision and revisions the issuing controller knows it
/// superseded); otherwise it is preserved.
package struct AgentRecoveryComposerConsumption: Equatable {
    package let submittedRevision: AgentRecoveryComposerRevision
    package let consumableRevisions: Set<AgentRecoveryComposerRevision>

    package init(
        submittedRevision: AgentRecoveryComposerRevision,
        supersededRevisions: Set<AgentRecoveryComposerRevision> = []
    ) {
        self.submittedRevision = submittedRevision
        consumableRevisions = supersededRevisions.union([submittedRevision])
    }
}

/// Who is starting a dispatch. Recovered (previous-instance), failed, or delivery-unknown intents
/// dispatch only on an explicit user action; live queues drain only their own instance's unheld
/// intents. An explicit action may claim a previous-instance intent but never bypasses a stale
/// target or missing attachment (retargeting is a separate, explicit transfer).
package enum AgentRecoveryDispatchAuthorization: Equatable {
    case liveQueue
    case explicitUserAction
}

// MARK: - Held composer resolution

/// Explicit user resolution of a stored composer typed under another reset generation (held
/// input). Never chosen automatically: reset, restore, and submission all leave it held.
package enum AgentRecoveryHeldComposerResolution: Equatable {
    /// Removes the held composer. Live typing is untouched and is written afterwards.
    case discard
    /// Moves the held content into the current generation's composer under `revision` (issued by
    /// the session's composer controller). Valid only while the live composer has no unsaved
    /// content; the store never merges or retargets it implicitly.
    case restoreToComposer(revision: AgentRecoveryComposerRevision)
    /// Discards the held composer and stores `snapshot` (current-generation live typing captured by
    /// the session's composer controller) in the same record replacement, so the new typing is
    /// never left memory-only between the discard and a later write.
    case discardReplacingWith(AgentRecoveryComposerSnapshot)
}

// MARK: - Launch state

/// Run mark persisted for each app launch at `AgentRecovery/v1/launch-state.json`. Two-stage app
/// quit writes `shutdownInProgress` when Stage A begins and `cleanExit` only as its last step;
/// window close never writes a launch mark.
package struct AgentRecoveryLaunchMark: Equatable {
    package enum State: String, CaseIterable {
        case running
        /// App quit began but did not finish. Never proves a clean exit and implies no R5 reason.
        case shutdownInProgress
        case cleanExit
    }

    package let appInstanceID: UUID
    package let state: State
    package let recordedAt: AgentRecoveryTimestamp

    package init(appInstanceID: UUID, state: State, recordedAt: AgentRecoveryTimestamp) {
        self.appInstanceID = appInstanceID
        self.state = state
        self.recordedAt = recordedAt
    }
}

/// Evidence about the launch before this one, read before the current mark replaces it.
package enum AgentRecoveryPreviousLaunch: Equatable {
    /// No mark: first launch with recovery, or a build that never wrote one.
    case none
    case mark(AgentRecoveryLaunchMark)
    /// Unreadable or future mark bytes.
    case unreadable(String)

    /// Only an explicit clean-exit mark from another instance proves a clean previous exit; a
    /// missing or unreadable mark is classified conservatively as unclean.
    package func provesCleanExit(currentInstanceID: UUID) -> Bool {
        guard case let .mark(mark) = self else { return false }
        return mark.state == .cleanExit && mark.appInstanceID != currentInstanceID
    }
}
