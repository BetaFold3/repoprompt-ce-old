import Foundation

// Lossless-restart Step 5b store mutation: the parent's delegated child link, committed after the
// child's covering session stub and before the child's first dispatch. Same lifecycle validation,
// gate, and atomic replacement as every other store mutation; no generic deduplication: only an
// exact repeat of one MCP invocation's own link is joined.

package extension AgentRecoveryStore {
    /// Appends `link` to the parent's record (`binding` is the parent's lifecycle binding).
    ///
    /// Like every store mutation, call it only while holding the existing foundation session gate
    /// for `binding` (production: `AgentRecoverySessionLane.commitDelegatedChildLink`, inside the
    /// lane's `transaction`); the store does not take the gate itself.
    ///
    /// - An exact repeat (same invocation, child, and parent attempt) is `unchanged`.
    /// - The same invocation with another child or parent attempt conflicts. Nothing is written.
    /// - The admitted parent run attempt must already be recorded, still open, and from the
    ///   binding's reset generation; otherwise nothing is written.
    func commitDelegatedChildLink(
        binding: AgentRecoveryLifecycleBinding,
        link: AgentRecoveryDelegatedChildLink
    ) throws -> AgentRecoveryLocalReceipt {
        guard let current = try writableRecord(binding: binding) else {
            throw AgentRecoveryStoreError.delegatedChildLinkIneligible(reason: "The parent session has no recovery record.")
        }
        if let existing = current.delegatedChildLink(invocationID: link.invocationID) {
            guard existing.childSessionID == link.childSessionID,
                  existing.parentRunAttemptID == link.parentRunAttemptID
            else {
                throw AgentRecoveryStoreError.delegatedChildLinkConflict(invocationID: link.invocationID)
            }
            return AgentRecoveryLocalReceipt(
                binding: binding,
                recordRevision: current.revision,
                disposition: .unchanged,
                composerRevision: current.composer?.revision
            )
        }
        guard let run = current.runAttempt(id: link.parentRunAttemptID),
              run.terminal == nil,
              run.shutdown == nil,
              run.transcriptResetGeneration == binding.transcriptResetGeneration
        else {
            throw AgentRecoveryStoreError.delegatedChildLinkIneligible(
                reason: "The parent run that started this delegated session is no longer open."
            )
        }
        let record = try replace(
            current,
            binding: binding,
            composer: current.composer,
            intents: current.intents,
            attempts: current.attempts,
            runAttempts: current.runAttempts,
            delegatedChildLinks: current.delegatedChildLinks + [link]
        )
        return AgentRecoveryLocalReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: .committed,
            composerRevision: record.composer?.revision
        )
    }
}

package extension AgentRecoverySessionLane {
    /// Commits the parent's delegated child link inside the foundation session gate. The admitted
    /// parent attempt's evidence is ensured first with the existing run-attempt mutation
    /// (`.keepExisting`: never fails on an existing process-run association), so a parent whose
    /// run began before its lane was claimed still records the attempt the link belongs to (with
    /// the parent run's run-start provider, `parentOwnership.providerKindRaw`, only when that write
    /// creates it).
    func commitDelegatedChildLink(
        _ link: AgentRecoveryDelegatedChildLink,
        parentOwnership: AgentRunOwnership,
        parentProcessRunID: UUID?
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        guard parentOwnership.attemptID == link.parentRunAttemptID else {
            return .failure(.store(.delegatedChildLinkIneligible(
                reason: "The link does not name the admitted parent run attempt."
            )))
        }
        return await transaction { store, binding in
            _ = try await store.ensureRunAttempt(
                binding: binding,
                expectedRevision: store.currentRevision(sessionID: binding.sessionID),
                ownership: parentOwnership,
                processRunID: parentProcessRunID,
                transcriptTurnID: nil,
                processRunAssociation: .keepExisting,
                providerKindRaw: parentOwnership.providerKindRaw,
                // A child link never precedes the parent run's first provider write: no mark.
                runtimeRegistrationRaw: nil
            )
            return try await store.commitDelegatedChildLink(binding: binding, link: link)
        }
    }
}
