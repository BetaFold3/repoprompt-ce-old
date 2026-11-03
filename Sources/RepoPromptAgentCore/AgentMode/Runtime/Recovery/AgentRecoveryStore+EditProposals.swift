import Foundation

// Lossless-restart Step 5a store mutations: a reviewed `apply_edits` proposal, committed before its
// live review is shown, marked `applicationStarted` before the accepted write begins, and removed
// once applied or explicitly withdrawn. Same lifecycle validation, gate, and atomic replacement as
// every other store mutation; only an exact repeat of one review's own proposal is joined.

package extension AgentRecoveryStore {
    /// Stores `proposal` (`state` must be `pending`) in the session's record, creating the record
    /// when absent.
    ///
    /// Like every store mutation, call it only while holding the existing foundation session gate
    /// for `binding` (production: `AgentRecoverySessionLane.commitEditProposal`).
    ///
    /// - An exact repeat of the same proposal is `unchanged`.
    /// - The same review ID with another proposal conflicts. Nothing is written.
    func commitEditProposal(
        binding: AgentRecoveryLifecycleBinding,
        proposal: AgentRecoveryEditProposal
    ) throws -> AgentRecoveryLocalReceipt {
        guard proposal.state == .pending,
              proposal.applicationStartedAt == nil,
              proposal.transcriptResetGeneration == binding.transcriptResetGeneration
        else {
            throw AgentRecoveryStoreError.editProposalIneligible(
                reviewID: proposal.reviewID,
                reason: "A new proposal must be pending and of the session's current reset generation."
            )
        }
        let current = try writableRecord(binding: binding)
        if let existing = current?.editProposal(reviewID: proposal.reviewID) {
            guard existing.hasSameProposal(as: proposal) else {
                throw AgentRecoveryStoreError.editProposalConflict(reviewID: proposal.reviewID)
            }
            return AgentRecoveryLocalReceipt(
                binding: binding,
                recordRevision: current?.revision,
                disposition: .unchanged,
                composerRevision: current?.composer?.revision
            )
        }
        let record = try replace(
            current,
            binding: binding,
            composer: current?.composer,
            intents: current?.intents ?? [],
            attempts: current?.attempts ?? [],
            runAttempts: current?.runAttempts ?? [],
            editProposals: (current?.editProposals ?? []) + [proposal]
        )
        return AgentRecoveryLocalReceipt(
            binding: binding,
            recordRevision: record.revision,
            disposition: .committed,
            composerRevision: record.composer?.revision
        )
    }

    /// Applies `transition` to the stored proposal `reviewID`.
    ///
    /// - `applicationStarted`: only for a proposal of the binding's reset generation (checked first,
    ///   so an earlier reset's started proposal is never joined), then only from `pending`; already
    ///   started is `unchanged`; a missing proposal is ineligible.
    /// - `applicationNotStarted`: back to `pending`; already pending is `unchanged`.
    /// - `applied` / `withdrawn`: removes exactly that proposal; a missing one is `unchanged`.
    ///
    /// Nothing else in the record changes; the target file is never read or written here.
    func transitionEditProposal(
        binding: AgentRecoveryLifecycleBinding,
        reviewID: UUID,
        transition: AgentRecoveryEditProposalTransition
    ) throws -> AgentRecoveryLocalReceipt {
        let current = try writableRecord(binding: binding)
        func unchanged() -> AgentRecoveryLocalReceipt {
            AgentRecoveryLocalReceipt(
                binding: binding,
                recordRevision: current?.revision,
                disposition: .unchanged,
                composerRevision: current?.composer?.revision
            )
        }
        var proposals = current?.editProposals ?? []
        guard let index = proposals.firstIndex(where: { $0.reviewID == reviewID }), let current else {
            switch transition {
            case .applied, .withdrawn:
                return unchanged()
            case .applicationStarted, .applicationNotStarted:
                throw AgentRecoveryStoreError.editProposalIneligible(
                    reviewID: reviewID,
                    reason: "The proposal is no longer stored."
                )
            }
        }
        switch transition {
        case .applicationStarted:
            guard proposals[index].transcriptResetGeneration == binding.transcriptResetGeneration else {
                throw AgentRecoveryStoreError.editProposalIneligible(
                    reviewID: reviewID,
                    reason: "The proposal belongs to an earlier conversation reset."
                )
            }
            if proposals[index].state == .applicationStarted { return unchanged() }
            proposals[index].state = .applicationStarted
            proposals[index].applicationStartedAt = AgentRecoveryTimestamp(now())
        case .applicationNotStarted:
            if proposals[index].state == .pending { return unchanged() }
            proposals[index].state = .pending
            proposals[index].applicationStartedAt = nil
        case .applied, .withdrawn:
            proposals.remove(at: index)
        }
        let record = try replace(
            current,
            binding: binding,
            composer: current.composer,
            intents: current.intents,
            attempts: current.attempts,
            runAttempts: current.runAttempts,
            editProposals: proposals
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
    /// Commits a pending proposal inside the foundation session gate.
    func commitEditProposal(
        _ proposal: AgentRecoveryEditProposal
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.commitEditProposal(binding: binding, proposal: proposal)
        }
    }

    /// Applies a typed proposal transition inside the foundation session gate.
    func transitionEditProposal(
        reviewID: UUID,
        _ transition: AgentRecoveryEditProposalTransition
    ) async -> Result<AgentRecoveryLocalReceipt, AgentRecoveryControllerFailure> {
        await transaction { store, binding in
            try await store.transitionEditProposal(binding: binding, reviewID: reviewID, transition: transition)
        }
    }
}
