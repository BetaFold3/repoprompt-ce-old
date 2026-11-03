import CryptoKit
import Foundation

// MARK: - Edit proposals (Phase 5, Step 5a)

/// What the target file looked like when its proposal was previewed: whether it existed, and the
/// SHA-256 of the preview's decoded original text (its UTF-8 encoding, in `domain`). This describes
/// decoded host text, never the file's raw bytes (an encoding-only change can compare equal). It
/// only observes content: a match never proves whether a proposal was applied.
package struct AgentRecoveryEditProposalBase: Equatable {
    /// SHA-256 (lowercase hex) of the UTF-8 encoding of the text the edit host decoded.
    package static let decodedTextDomain = "repoprompt.applyEdits.decodedTextUTF8.sha256.v1"

    package let exists: Bool
    /// Present exactly when `exists`. An unknown domain (a newer build's) is kept but never compared.
    package let domain: String?
    package let digest: String?
    package var extras: AgentRecoveryExtras

    package init(exists: Bool, domain: String?, digest: String?, extras: AgentRecoveryExtras = [:]) {
        self.exists = exists
        self.domain = domain
        self.digest = digest
        self.extras = extras
    }

    /// The base of a preview: `nil` text means the target did not exist.
    package static func preview(originalText: String?) -> AgentRecoveryEditProposalBase {
        guard let originalText else {
            return AgentRecoveryEditProposalBase(exists: false, domain: nil, digest: nil)
        }
        return AgentRecoveryEditProposalBase(
            exists: true,
            domain: decodedTextDomain,
            digest: digest(ofDecodedText: originalText)
        )
    }

    package static func digest(ofDecodedText text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `text` (decoded by the same host) has this base's content. `nil` when this base's
    /// domain is unknown, so no comparison is possible.
    package func matches(decodedText text: String) -> Bool? {
        guard exists else { return false }
        guard domain == Self.decodedTextDomain, let digest else { return nil }
        return Self.digest(ofDecodedText: text) == digest
    }
}

/// Durable progress of one reviewed proposal. A proposal that was applied (and recorded) or
/// explicitly withdrawn is removed from the record, so only these two states are ever stored.
package enum AgentRecoveryEditProposalState: String, CaseIterable {
    /// Stored before its review was shown; nothing was written for it.
    case pending
    /// Acknowledged before the accepted edit's file write began. After a crash whether the file
    /// changed is uncertain; a matching file never upgrades it to applied.
    case applicationStarted
}

/// One reviewed `apply_edits` proposal of this record's session, stored before its live review is
/// shown. Restored only as historical data (View, Copy, Discard): never an old continuation, a
/// permission scope, a tool result, or an automatic or recovered write.
package struct AgentRecoveryEditProposal: Equatable {
    /// The live review card's identity.
    package let reviewID: UUID
    /// `AgentRunOwnership.attemptID` of the session's run when the proposal was made, if any.
    package let runAttemptID: UUID?
    package let transcriptResetGeneration: UInt64
    package let appInstanceID: UUID
    package let proposedAt: AgentRecoveryTimestamp
    /// The resolved path the live write targets.
    package let physicalPath: String
    package let displayPath: String
    /// Exactly the diff the review displays.
    package let unifiedDiff: String
    /// Exactly the text the accepted write stores.
    package let proposedText: String
    package let base: AgentRecoveryEditProposalBase
    package internal(set) var state: AgentRecoveryEditProposalState
    package internal(set) var applicationStartedAt: AgentRecoveryTimestamp?
    package var extras: AgentRecoveryExtras

    package init(
        reviewID: UUID,
        runAttemptID: UUID?,
        transcriptResetGeneration: UInt64,
        appInstanceID: UUID,
        proposedAt: AgentRecoveryTimestamp,
        physicalPath: String,
        displayPath: String,
        unifiedDiff: String,
        proposedText: String,
        base: AgentRecoveryEditProposalBase,
        state: AgentRecoveryEditProposalState = .pending,
        applicationStartedAt: AgentRecoveryTimestamp? = nil,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.reviewID = reviewID
        self.runAttemptID = runAttemptID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.appInstanceID = appInstanceID
        self.proposedAt = proposedAt
        self.physicalPath = physicalPath
        self.displayPath = displayPath
        self.unifiedDiff = unifiedDiff
        self.proposedText = proposedText
        self.base = base
        self.state = state
        self.applicationStartedAt = applicationStartedAt
        self.extras = extras
    }

    /// The same proposal content and owner (state, timestamps of progress, and unknown fields aside).
    package func hasSameProposal(as other: AgentRecoveryEditProposal) -> Bool {
        reviewID == other.reviewID
            && runAttemptID == other.runAttemptID
            && transcriptResetGeneration == other.transcriptResetGeneration
            && appInstanceID == other.appInstanceID
            && physicalPath == other.physicalPath
            && displayPath == other.displayPath
            && unifiedDiff == other.unifiedDiff
            && proposedText == other.proposedText
            && base.exists == other.base.exists
            && base.domain == other.base.domain
            && base.digest == other.base.digest
    }
}

/// How a reviewed proposal's durable state changes (typed; never inferred from a reason string).
package enum AgentRecoveryEditProposalTransition: Equatable {
    /// Acknowledged before the live write begins (`pending` → `applicationStarted`).
    case applicationStarted
    /// The accepted write was refused after `applicationStarted` but before it began
    /// (`applicationStarted` → `pending`): nothing was written.
    case applicationNotStarted
    /// The live write completed: the proposal is removed.
    case applied
    /// Explicit user rejection or Discard: the proposal is removed. The file is never touched.
    case withdrawn
}
