import Foundation
import RepoPromptWorkspace

package enum AgentRunInteractionStateChangeReason: String, Equatable {
    case userInputResponseSubmitted
    case pendingQuestionCancelled
    case pendingApprovalCancelled
    case approvalResponseSubmitted
    case permissionsResponseSubmitted
    case mcpElicitationResponseSubmitted
}

package struct AgentMCPControlContext: Equatable {
    package let sessionID: UUID
    package let activationID: UUID
    package let registration: AgentRunSessionStore.Registration
    package var currentEpoch: AgentRunTurnEpoch?
    package var preparedEpoch: AgentRunTurnEpoch?
    package var pendingEpochTransition: AgentRunEpochTransitionIntent?
    package let originatingConnectionID: UUID?
    let interactionTransport: AgentInteractionTransport
    let suppressUserNotifications: Bool
    package let forceAutoEditEnabled: Bool
    package let autoEditEnabledBeforeOverride: Bool
    /// The task label kind for this MCP-controlled run (e.g. explore, engineer).
    /// Used to customize tool advertisement and system prompts for role-specific behavior.
    package let taskLabelKind: AgentModelCatalog.TaskLabelKind?

    package init(
        sessionID: UUID,
        activationID: UUID,
        registration: AgentRunSessionStore.Registration,
        currentEpoch: AgentRunTurnEpoch? = nil,
        preparedEpoch: AgentRunTurnEpoch? = nil,
        pendingEpochTransition: AgentRunEpochTransitionIntent? = nil,
        originatingConnectionID: UUID?,
        interactionTransport: AgentInteractionTransport,
        suppressUserNotifications: Bool,
        forceAutoEditEnabled: Bool,
        autoEditEnabledBeforeOverride: Bool,
        taskLabelKind: AgentModelCatalog.TaskLabelKind?
    ) {
        self.sessionID = sessionID
        self.activationID = activationID
        self.registration = registration
        self.currentEpoch = currentEpoch
        self.preparedEpoch = preparedEpoch
        self.pendingEpochTransition = pendingEpochTransition
        self.originatingConnectionID = originatingConnectionID
        self.interactionTransport = interactionTransport
        self.suppressUserNotifications = suppressUserNotifications
        self.forceAutoEditEnabled = forceAutoEditEnabled
        self.autoEditEnabledBeforeOverride = autoEditEnabledBeforeOverride
        self.taskLabelKind = taskLabelKind
    }

    package func replacingRegistration(_ registration: AgentRunSessionStore.Registration) -> Self {
        Self(
            sessionID: sessionID,
            activationID: activationID,
            registration: registration,
            currentEpoch: currentEpoch,
            preparedEpoch: preparedEpoch,
            pendingEpochTransition: pendingEpochTransition,
            originatingConnectionID: originatingConnectionID,
            interactionTransport: interactionTransport,
            suppressUserNotifications: suppressUserNotifications,
            forceAutoEditEnabled: forceAutoEditEnabled,
            autoEditEnabledBeforeOverride: autoEditEnabledBeforeOverride,
            taskLabelKind: taskLabelKind
        )
    }
}

package struct AgentAutoEditPermissionGuidance: Equatable {
    package enum Provider: Equatable {
        case codex
        case claude
    }

    package enum Action: Equatable {
        case setCodexReadOnly
        case setClaudeRequireApproval
    }

    package let provider: Provider
    package let message: String
    package let actionTitle: String
    package let action: Action

    package init(
        provider: Provider,
        message: String,
        actionTitle: String,
        action: Action
    ) {
        self.provider = provider
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
}

package struct AgentNonCodexTurnTokenAccumulator {
    var estimatedUserInputTokens: Int = 0
    var estimatedToolInputTokens: Int = 0
    var estimatedToolOutputTokens: Int = 0
    /// Exact stream-derived context snapshot for the current turn (from usage events),
    /// tracked separately from the session-wide display value to prevent billed-turn
    /// aggregates from overwriting it.
    var observedContextUsedTokens: Int?

    var estimatedInputTokens: Int {
        estimatedUserInputTokens + estimatedToolInputTokens + estimatedToolOutputTokens
    }
}

package enum AgentAttachmentTurnDisposition: Equatable {
    case restoreToPending
    case deleteFiles
    case keepFiles
}

package enum AgentAttachmentTurnState: Equatable {
    case idle
    case reserved(reservationID: UUID, attachments: [AgentImageAttachment])
    case consumed(reservationID: UUID, attachments: [AgentImageAttachment])
}

package struct AgentCodexComputerUseActivation: Equatable {
    package let id: UUID
    let createdAt: Date

    package init(
        id: UUID,
        createdAt: Date
    ) {
        self.id = id
        self.createdAt = createdAt
    }
}

/// Identity of one staging of a pending-handoff payload into one provider input. Outcomes settle only
/// the stage they name: a late outcome of an earlier stage never consumes or releases a newer one, and
/// an outcome for another payload never clears this one.
package struct AgentPendingHandoffStage: Equatable, Hashable {
    package let payloadID: UUID
    package let stageID: UUID

    package init(payloadID: UUID, stageID: UUID = UUID()) {
        self.payloadID = payloadID
        self.stageID = stageID
    }
}

/// Why a pending-handoff payload is neither consumed nor available for automatic prepend.
package enum AgentPendingHandoffDeliveryHold: Equatable {
    /// Its stage entered the provider boundary without proof either way (this launch).
    case deliveryUnknown
    /// Hydrated payload whose recovery-intent join has not resolved yet.
    case recoveryJoinPending
    /// Hydrated payload carried by a recovery intent whose delivery is in flight or unknown.
    case recoveryDeliveryUncertain
    /// Hydrated payload whose snapshot a still-owning recovery intent (`queued` or `failed`) carries:
    /// that intent may still be sent explicitly with it, so the payload stays reserved until the
    /// carrier is withdrawn or its delivery settles.
    case recoveryCarriedByIntent
    /// Hydrated payload whose recovery authority is missing or unreadable.
    case recoveryAuthorityUnavailable

    /// Holds resolved only by the recovery join (never by a runtime stage outcome).
    package var isRecoveryHold: Bool {
        self != .deliveryUnknown
    }
}

package struct AgentPendingHandoffState: Equatable {
    package var payload: String?
    package var createdAt: Date?
    package var sourceItemID: UUID?
    /// Durable identity of `payload`, assigned once when the payload is created (or, for a legacy
    /// payload, by `ensurePayloadID()` before any provider dispatch) and preserved through saves and
    /// hydration. Recovery intents carry it (`AgentRecoveryPendingHandoffSnapshot.payloadID`) so a
    /// still-pending payload can be joined against delivery evidence after a restart.
    package var payloadID: UUID?
    /// True only for a freshly-created handoff tab. Keeps agent selection editable
    /// until the destination tab successfully sends its first real user turn.
    package var defersProviderLockUntilSend: Bool = false
    package var isStagedForSend: Bool = false
    /// The stage currently carrying `payload` in a provider input (runtime only, never persisted).
    package var stage: AgentPendingHandoffStage?
    /// Set while the payload may already have been delivered (runtime only; a hydrated hold is
    /// recomputed from recovery evidence). A held payload is never prepended automatically.
    package var deliveryHold: AgentPendingHandoffDeliveryHold?

    package init(
        payload: String? = nil,
        createdAt: Date? = nil,
        sourceItemID: UUID? = nil,
        payloadID: UUID? = nil,
        defersProviderLockUntilSend: Bool = false,
        isStagedForSend: Bool = false
    ) {
        self.payload = payload
        self.createdAt = createdAt
        self.sourceItemID = sourceItemID
        self.payloadID = payloadID
        self.defersProviderLockUntilSend = defersProviderLockUntilSend
        self.isStagedForSend = isStagedForSend
    }

    package var hasPayload: Bool {
        guard let payload else { return false }
        return !payload.isEmpty
    }

    /// The payload is staged into an input awaiting its outcome, or held as possibly delivered:
    /// it is neither prepended again nor captured for another admission.
    package var isReservedForSend: Bool {
        isStagedForSend || stage != nil || deliveryHold != nil
    }

    /// The next send would prepend this payload (`stagePendingHandoffIfNeeded`'s guards): non-empty
    /// after trimming and not reserved.
    package var hasStageablePayload: Bool {
        guard let payload, !isReservedForSend else { return false }
        return !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The payload's durable identity, assigning a new one only to a legacy payload that has none.
    /// `nil` when there is no payload. The caller persists an assigned ID through its existing
    /// fenced session save before dispatch; it never changes an ID that is already set.
    package mutating func ensurePayloadID() -> UUID? {
        guard hasPayload else { return nil }
        if let payloadID { return payloadID }
        let assigned = UUID()
        payloadID = assigned
        return assigned
    }

    package mutating func clearAfterSend() {
        payload = nil
        createdAt = nil
        sourceItemID = nil
        payloadID = nil
        defersProviderLockUntilSend = false
        isStagedForSend = false
        stage = nil
        deliveryHold = nil
    }
}

struct AgentCodexWatchdogState: Equatable {
    var lastProgressAt: Date?
    var suppressUntil: Date?
    var ambiguousActiveProbeCount: Int = 0
    var isPausedAfterWarning: Bool = false
    var warnedSinceLastProgress: Bool = false
    var requiresColdTeardownOnCancel: Bool = false
}

/// Consecutive `thread/resume` timeouts for one saved target. It only drives failure guidance
/// and never changes which request is sent. It resets on success, a target change, or a
/// failure that is neither a timeout nor a cancellation; Stop leaves it unchanged.
struct AgentCodexResumeTimeoutState: Equatable {
    var conversationID: String?
    var rolloutPath: String?
    var consecutiveTimeouts: Int = 0
}

struct AgentCodexNativeToolLivenessState: Equatable {
    struct Key: Hashable {
        let invocationID: UUID?
        let fallbackSignature: String
    }

    struct Execution: Equatable {
        let toolName: String
        let startedAt: Date
        var lastSignalAt: Date
        var processID: String?
        var sawRunningUpdate: Bool = false
    }

    var inFlight: [Key: Execution] = [:]
}

package struct AgentBashLiveExecutionState: Equatable {
    private static let runningStatusWords: Set<String> = ["running", "in_progress", "inprogress", "in-progress", "pending"]

    let executionKey: String
    let transcriptItemID: UUID
    let toolName: String
    let invocationID: UUID?
    let fallbackSignature: String
    var processID: String?
    var command: String?
    var statusWord: String?
    var exitCode: Int?
    package var output: String?
    var isSummaryOnly: Bool
    var lastSignalAt: Date
    /// `codexControllerGeneration` of the controller whose events drive this execution; `nil`
    /// when it was rebuilt from saved rows with no owning controller (e.g. after relaunch).
    var ownerControllerGeneration: UUID?

    var isRunning: Bool {
        guard let statusWord = statusWord?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !statusWord.isEmpty
        else {
            return exitCode == nil
        }
        return Self.runningStatusWords.contains(statusWord)
    }

    package var parsedResult: BashToolResultParser.ParsedResult {
        .init(
            isRunning: isRunning,
            command: command,
            statusWord: statusWord,
            exitCode: exitCode,
            output: output,
            processID: processID,
            isSummaryOnly: isSummaryOnly
        )
    }

    var renderedResultJSON: String {
        BashToolResultParser.resultJSON(
            statusWord: statusWord ?? (isRunning ? "running" : "completed"),
            command: command,
            processID: processID,
            output: output,
            exitCode: exitCode,
            summaryOnly: isSummaryOnly
        )
    }
}

package enum AgentInitialStartLocation: Equatable {
    case local
    case newWorktree
    case existingWorktree(AgentExecutionWorktreeSelection)

    package var label: String {
        switch self {
        case .local:
            "Work locally"
        case .newWorktree:
            "New worktree"
        case let .existingWorktree(selection):
            selection.label
        }
    }
}

package enum AgentInteractionTransport: Equatable {
    case ui
    case mcp(sessionID: UUID, originatingConnectionID: UUID?)
}

package struct AgentRunEpochTransitionIntent: Equatable {
    package let token: UUID
    package let kind: AgentRunEpochTransitionKind
    package let expectedCurrentEpoch: AgentRunTurnEpoch?

    package init(
        token: UUID,
        kind: AgentRunEpochTransitionKind,
        expectedCurrentEpoch: AgentRunTurnEpoch?
    ) {
        self.token = token
        self.kind = kind
        self.expectedCurrentEpoch = expectedCurrentEpoch
    }
}

package struct AgentExecutionWorktreeSelection: Equatable, Identifiable {
    package let repositoryID: String
    let repoKey: String
    package let worktreeID: String
    package let path: String
    package let name: String?
    package let branch: String?
    package let head: String?
    package let isDetached: Bool
    package let label: String
    package let colorHex: String?
    package let isLocked: Bool
    package let lockReason: String?
    package let isPrunable: Bool
    package let prunableReason: String?

    package init(
        repositoryID: String,
        repoKey: String,
        worktreeID: String,
        path: String,
        name: String?,
        branch: String?,
        head: String?,
        isDetached: Bool,
        label: String,
        colorHex: String?,
        isLocked: Bool,
        lockReason: String?,
        isPrunable: Bool,
        prunableReason: String?
    ) {
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.worktreeID = worktreeID
        self.path = path
        self.name = name
        self.branch = branch
        self.head = head
        self.isDetached = isDetached
        self.label = label
        self.colorHex = colorHex
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
    }

    package var id: String {
        presentationID
    }

    /// Stable SwiftUI identity for picker presentation. Selection semantics
    /// remain repositoryID + worktreeID; this ID also includes the normalized
    /// path so malformed duplicate Git records cannot collide in ForEach.
    package var presentationID: String {
        let checkoutPath = CheckoutPathIdentity.canonicalPathOrOriginal(path)
        return "\(repositoryID)::\(worktreeID)::\(checkoutPath)"
    }
}
