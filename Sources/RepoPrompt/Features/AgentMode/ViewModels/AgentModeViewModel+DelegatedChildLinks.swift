import Foundation
import MCP
import RepoPromptAgentCore

// Lossless-restart Step 5b (docs/context/plans/completed/2026-10-18-lossless-app-restart-spec.md, Phase 5):
// durable parent → child linkage for a routed `agent_run.start`, committed before the child's
// first dispatch.
//
// - Admission freezes, synchronously with the existing delegation admission, the dispatcher's
//   server-side MCP invocation UUID (local execution identity, never provider tool-use identity and
//   never a cross-request deduplication key), the admitted parent identity, its full active run
//   ownership (attempt captured once; never rebound), and its exact recovery lane.
// - Every later boundary re-checks the existing fences: the parent tab still holds that session,
//   the same attempt is current for the current binding, the same lane is valid for handoff
//   (not retired, reset-frozen, or shutdown-frozen), and the existing delegation commit check.
// - The child's identity, binding, and parent field are proven durable by a covering `.written`
//   owner save before the link is committed; the link commit is acknowledged before any child
//   dispatch. A failure before handoff dispatches nothing; a committed link may remain unused and
//   is never replayed.
// - The child's existing ownership facts (owner object, persistent binding and its transition
//   generation, persistence state with its transcript-reset generation, and recovery lane) are
//   captured after that covering save and re-checked after the link await and in every final
//   dispatch predicate. Only the creator's own first save may acquire persistence state and a lane;
//   a child reset, rebind, or replacement afterwards dispatches nothing.
// - Task cancellation is rejected after each new persistence await, before the start, and at the
//   final pre-dispatch fences. The owned Codex bounded-ack submission driver is unchanged: it keeps
//   the captured fence's state checks and is never cancelled after it marks its operation started.
// - The scoped fence is released once the start returns or throws, so unstructured work that
//   inherited it no longer arms it.
// - An independent MCP caller (no routed parent) and a parent without durable recovery admission
//   are unchanged.

/// One routed `agent_run.start` admitted under a recovery-tracked parent run attempt.
@MainActor
final class MCPDelegatedChildLinkAdmission {
    let invocationID: UUID
    let operation: String
    let parentTabID: UUID
    let parentSessionID: UUID
    /// The parent's active run ownership at admission (attempt, binding, turn epoch).
    let ownership: AgentRunOwnership
    /// The parent's process run ID at admission, re-checked with the attempt.
    let parentProcessRunID: UUID?
    private(set) weak var parentSession: AgentTabSession?
    private(set) weak var lane: AgentRecoverySessionLane?
    /// The service's existing synchronous delegation commit check.
    let revalidateDelegation: () throws -> Void
    /// Set only after the link commit was acknowledged for this child.
    fileprivate(set) var linkedChildSessionID: UUID?
    /// The linked child and its ownership facts captured after the covering save.
    fileprivate private(set) weak var linkedChild: AgentTabSession?
    fileprivate private(set) var linkedChildIdentity: MCPDelegatedChildIdentity?
    /// One-shot: set when the scoped start returns or throws. A released fence is never armed
    /// again from the TaskLocal; a fence a submission captured explicitly keeps its checks.
    private(set) var isDispatchFenceReleased = false

    func releaseDispatchFence() {
        isDispatchFenceReleased = true
    }

    fileprivate func recordLinkedChild(_ child: AgentTabSession, sessionID: UUID, identity: MCPDelegatedChildIdentity) {
        linkedChild = child
        linkedChildIdentity = identity
        linkedChildSessionID = sessionID
    }

    fileprivate init(
        invocationID: UUID,
        operation: String,
        parentTabID: UUID,
        parentSessionID: UUID,
        ownership: AgentRunOwnership,
        parentProcessRunID: UUID?,
        parentSession: AgentTabSession,
        lane: AgentRecoverySessionLane,
        revalidateDelegation: @escaping () throws -> Void
    ) {
        self.invocationID = invocationID
        self.operation = operation
        self.parentTabID = parentTabID
        self.parentSessionID = parentSessionID
        self.ownership = ownership
        self.parentProcessRunID = parentProcessRunID
        self.parentSession = parentSession
        self.lane = lane
        self.revalidateDelegation = revalidateDelegation
    }
}

/// The existing ownership facts of a delegated child session (no new generation): owner object,
/// persistent binding and transition generation, persistence state (incarnation and
/// transcript-reset generation), recovery lane, and parent.
struct MCPDelegatedChildIdentity: Equatable {
    let tabID: UUID
    let owner: ObjectIdentifier
    let binding: AgentPersistentSessionBindingIdentity?
    let bindingTransitionGeneration: UInt64
    let persistenceState: AgentSessionPersistenceState?
    let lane: ObjectIdentifier?
    let parentSessionID: UUID?

    @MainActor
    init(_ child: AgentTabSession) {
        tabID = child.tabID
        owner = ObjectIdentifier(child)
        binding = child.persistentSessionBindingIdentity
        bindingTransitionGeneration = child.bindingTransitionGeneration
        persistenceState = child.persistenceState
        lane = child.recoveryLane.map(ObjectIdentifier.init)
        parentSessionID = child.parentSessionID
    }

    /// Across the covering save only the creator's own first save may acquire persistence state
    /// (and with it a lane); everything else is unchanged.
    func isContinued(bySaved saved: MCPDelegatedChildIdentity) -> Bool {
        guard tabID == saved.tabID,
              owner == saved.owner,
              binding == saved.binding,
              bindingTransitionGeneration == saved.bindingTransitionGeneration,
              parentSessionID == saved.parentSessionID
        else {
            return false
        }
        guard let persistenceState else { return saved.persistenceState != nil }
        return persistenceState == saved.persistenceState && lane == saved.lane
    }
}

/// Scoped only around a linked child's start: the final dispatch predicate re-checks the parent
/// admission and the linked child's identity for that exact child session.
enum MCPDelegatedChildDispatchFence {
    @TaskLocal static var current: MCPDelegatedChildLinkAdmission?
}

extension AgentModeViewModel {
    /// Freezes the link admission for a routed spawn. Returns nil for an independent MCP caller or a
    /// parent without durable recovery admission (both unchanged). A tracked parent without its
    /// invocation identity, a current run attempt, or a valid owned lane fails closed.
    func mcpAdmitDelegatedChildLink(
        sourceTabID: UUID?,
        admittedCallerSessionID: UUID?,
        invocationID: UUID?,
        operation: String,
        revalidateDelegation: @escaping () throws -> Void
    ) throws -> MCPDelegatedChildLinkAdmission? {
        guard let sourceTabID else { return nil }
        guard let parent = sessions[sourceTabID],
              let admittedCallerSessionID,
              parent.activeAgentSessionID == admittedCallerSessionID
        else {
            throw Self.delegatedChildLinkRefusal(operation, "the calling agent session changed while the request was in flight")
        }
        guard requiresDurableRecoveryAdmission(for: parent) else { return nil }
        guard let invocationID else {
            throw Self.delegatedChildLinkRefusal(operation, "the request carried no MCP invocation identity to link the child to")
        }
        guard let ownership = parent.activeRunOwnership,
              ownership.binding.persistentSessionID == admittedCallerSessionID,
              parent.isCurrentRunAttemptForCurrentBinding(ownership)
        else {
            throw Self.delegatedChildLinkRefusal(operation, "the calling agent session has no current run attempt")
        }
        guard let lane = parent.recoveryLane,
              lane.isValidForHandoff,
              lane.isOwned(by: parent),
              lane.sessionID == admittedCallerSessionID
        else {
            throw Self.delegatedChildLinkRefusal(operation, "the calling agent session's recovery state is not available")
        }
        return MCPDelegatedChildLinkAdmission(
            invocationID: invocationID,
            operation: operation,
            parentTabID: sourceTabID,
            parentSessionID: admittedCallerSessionID,
            ownership: ownership,
            parentProcessRunID: parent.runID,
            parentSession: parent,
            lane: lane,
            revalidateDelegation: revalidateDelegation
        )
    }

    /// The admission's fences, without the delegation re-check.
    private func delegatedChildLinkParentIsCurrent(_ admission: MCPDelegatedChildLinkAdmission) -> Bool {
        guard let parent = admission.parentSession,
              sessions[admission.parentTabID] === parent,
              parent.activeAgentSessionID == admission.parentSessionID,
              parent.isCurrentRunAttemptForCurrentBinding(admission.ownership, expectedRunID: admission.parentProcessRunID),
              let lane = admission.lane,
              parent.recoveryLane === lane,
              lane.isValidForHandoff,
              lane.isOwned(by: parent)
        else {
            return false
        }
        return true
    }

    /// The child still holds exactly the identity captured after its covering save, under the same
    /// owner, with a valid owned lane when it has one.
    private func delegatedChildIsCurrent(
        _ child: AgentTabSession,
        sessionID: UUID,
        identity: MCPDelegatedChildIdentity,
        admission: MCPDelegatedChildLinkAdmission
    ) -> Bool {
        guard sessions[identity.tabID] === child,
              !child.bindingTransitionInProgress,
              child.activeAgentSessionID == sessionID,
              child.parentSessionID == admission.parentSessionID,
              MCPDelegatedChildIdentity(child) == identity
        else {
            return false
        }
        guard let lane = child.recoveryLane else { return true }
        return lane.isValidForHandoff && lane.isOwned(by: child) && lane.sessionID == sessionID
    }

    /// Throwing re-check for commit boundaries (child create, after each await) and, once linked,
    /// the dispatch fences. Nil is unchanged.
    func mcpRequireDelegatedChildLinkAdmissionCurrent(_ admission: MCPDelegatedChildLinkAdmission?) throws {
        guard let admission else { return }
        try admission.revalidateDelegation()
        guard delegatedChildLinkParentIsCurrent(admission) else {
            throw Self.delegatedChildLinkRefusal(
                admission.operation,
                "the calling agent's run attempt or recovery state changed while the request was in flight"
            )
        }
        guard let childSessionID = admission.linkedChildSessionID else { return }
        guard let child = admission.linkedChild,
              let identity = admission.linkedChildIdentity,
              delegatedChildIsCurrent(child, sessionID: childSessionID, identity: identity, admission: admission)
        else {
            throw Self.delegatedChildLinkRefusal(
                admission.operation,
                "the delegated child session was reset, rebound, or replaced after it was linked"
            )
        }
    }

    /// Non-throwing re-check for dispatch predicates.
    func mcpDelegatedChildLinkAdmissionIsCurrent(_ admission: MCPDelegatedChildLinkAdmission) -> Bool {
        (try? mcpRequireDelegatedChildLinkAdmissionCurrent(admission)) != nil
    }

    /// Proves the child's identity, binding, and parent field durable with a covering `.written`
    /// owner save, then commits the parent's link, re-checking the admission, the child's saved
    /// identity, and Task cancellation after every await. An exact repeat for the same child is
    /// joined; another child for this invocation conflicts.
    func mcpCommitDelegatedChildLink(
        _ admission: MCPDelegatedChildLinkAdmission,
        childTabID: UUID,
        childSessionID: UUID
    ) async throws {
        try Task.checkCancellation()
        if let linked = admission.linkedChildSessionID {
            guard linked == childSessionID else {
                throw Self.delegatedChildLinkRefusal(admission.operation, "this request is already linked to another child session")
            }
            try mcpRequireDelegatedChildLinkAdmissionCurrent(admission)
            return
        }
        try mcpRequireDelegatedChildLinkAdmissionCurrent(admission)
        guard let child = sessions[childTabID],
              !child.bindingTransitionInProgress,
              child.activeAgentSessionID == childSessionID,
              child.parentSessionID == admission.parentSessionID
        else {
            throw Self.delegatedChildLinkRefusal(admission.operation, "the new child session is not the calling session's child")
        }
        let beforeSave = MCPDelegatedChildIdentity(child)
        guard await commitRecoverySavedPlacement(child) else {
            throw Self.delegatedChildLinkRefusal(admission.operation, "the new child session could not be saved before it was linked")
        }
        try Task.checkCancellation()
        try mcpRequireDelegatedChildLinkAdmissionCurrent(admission)
        let saved = MCPDelegatedChildIdentity(child)
        guard beforeSave.isContinued(bySaved: saved),
              delegatedChildIsCurrent(child, sessionID: childSessionID, identity: saved, admission: admission),
              let lane = admission.lane
        else {
            throw Self.delegatedChildLinkRefusal(admission.operation, "the new child session changed while it was being saved")
        }
        #if DEBUG
            if let hook = test_delegatedChildLinkAwaitHook {
                await hook(child)
            }
        #endif
        let link = AgentRecoveryDelegatedChildLink(
            invocationID: admission.invocationID,
            parentRunAttemptID: admission.ownership.attemptID,
            childSessionID: childSessionID,
            linkedAt: AgentRecoveryTimestamp(Date())
        )
        if case .failure = await lane.commitDelegatedChildLink(
            link,
            parentOwnership: admission.ownership,
            parentProcessRunID: admission.parentProcessRunID
        ) {
            throw Self.delegatedChildLinkRefusal(admission.operation, "RepoPrompt could not record the child session under the calling run")
        }
        try Task.checkCancellation()
        try mcpRequireDelegatedChildLinkAdmissionCurrent(admission)
        guard delegatedChildIsCurrent(child, sessionID: childSessionID, identity: saved, admission: admission) else {
            throw Self.delegatedChildLinkRefusal(admission.operation, "the new child session was reset, rebound, or replaced while it was being linked")
        }
        admission.recordLinkedChild(child, sessionID: childSessionID, identity: saved)
    }

    /// The linked admission scoped over this start, when it targets `sessionID`. An unrelated
    /// session, no scope, or a released fence returns nil and is unchanged.
    func mcpDelegatedChildDispatchFence(for sessionID: UUID) -> MCPDelegatedChildLinkAdmission? {
        guard let fence = MCPDelegatedChildDispatchFence.current,
              !fence.isDispatchFenceReleased,
              fence.linkedChildSessionID == sessionID
        else {
            return nil
        }
        return fence
    }

    /// Final pre-dispatch check for a linked child start (parent admission, the child's saved
    /// identity, and Task cancellation); nil holds trivially.
    func mcpRequireDelegatedChildDispatchFence(_ fence: MCPDelegatedChildLinkAdmission?) throws {
        guard let fence else { return }
        try Task.checkCancellation()
        // Propagates the specific parent, delegation, or child-identity refusal.
        try mcpRequireDelegatedChildLinkAdmissionCurrent(fence)
    }

    private static func delegatedChildLinkRefusal(_ operation: String, _ reason: String) -> MCPError {
        MCPError.invalidParams(
            "\(operation): \(reason). Refusing to start the delegated child; nothing was sent to it. Retry after the source session is active."
        )
    }
}
