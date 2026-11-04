import Foundation
import RepoPromptAgentCore

/// Attached-document (PDF/HTML) delivery gate shared by every provider dispatch path.
///
/// Documents travel as structured `AgentDocumentAttachment` records through every lifecycle
/// carrier. Immediately before provider text is assembled (initial send, steering, queued
/// follow-ups, retries, scheduled sends) the records are preflighted against the destination's
/// qualified capability and the managed originals; only then is the escaped manifest appended. A
/// blocked preflight sends nothing and keeps the draft or queue entry.
extension AgentModeViewModel {
    /// The qualified capability of `session`'s destination, from existing configuration only.
    func documentDeliveryCapability(
        for session: AgentTabSession?,
        agent: AgentProviderKind
    ) -> AgentDocumentDeliveryCapability {
        let profile = session?.profile ?? .standard
        let codexShellToolEnabled = profile != .knowledge
            && (session?.permissionProfile ?? .userConfigured).codexBashToolEnabled(userConfigured: codexShellToolPreference())
        return AgentDocumentDeliveryPolicy.capability(
            agent: agent,
            profile: profile,
            isRemoteHost: session?.remoteHost != nil,
            codexShellToolEnabled: codexShellToolEnabled
        )
    }

    /// Resolves every document through the managed store and the destination's capability.
    func preflightDocumentAttachments(
        _ documents: [AgentDocumentAttachment],
        session: AgentTabSession?,
        agent: AgentProviderKind
    ) -> AgentDocumentPreflightResult {
        guard !documents.isEmpty else { return .ready([]) }
        return AgentDocumentPreflight.evaluate(
            documents,
            capability: documentDeliveryCapability(for: session, agent: agent),
            store: documentAttachmentStore
        )
    }

    /// The user-visible refusal for sending `documents` to `session` now; `nil` when nothing blocks.
    /// Used before any composer consumption, admission, or queueing.
    func documentAttachmentBlockedMessage(
        _ documents: [AgentDocumentAttachment],
        session: AgentTabSession
    ) -> String? {
        preflightDocumentAttachments(documents, session: session, agent: session.selectedAgent).blockedMessage
    }

    /// Settles consumed input that provably reached no provider (a blocked augmentation or final
    /// document check, an ended wait, a dispatch-evidence refusal, or a lost claim). Durable input
    /// is shown as held: its intent keeps its text and attachment records, so nothing is restored
    /// as a second copy. A scheduled attempt's input is owned by its schedule, which keeps the
    /// payload and settles the attempt, so it is never also restored here. Other untracked input has
    /// no other copy: its whole immutable snapshot (raw draft text, images, tagged files, documents)
    /// returns to the composer (deduplicated) with `reason` before its optimistic bubble is removed,
    /// so a retry never shows the turn twice or loses part of it.
    func settleUnsentInput(
        _ identity: AgentQueuedInputIdentity,
        draftText: String,
        images: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        documents: [AgentDocumentAttachment],
        session: AgentTabSession,
        reason: String
    ) {
        settleUnsentInput(
            [identity],
            draftText: draftText,
            images: images,
            taggedFiles: taggedFiles,
            documents: documents,
            session: session,
            reason: reason
        )
    }

    /// Multi-constituent form (a coalesced queue entry): any durable constituent holds the entry's
    /// durable intents, which keep its text and attachments, so nothing is restored as a draft.
    func settleUnsentInput(
        _ identities: [AgentQueuedInputIdentity],
        draftText: String,
        images: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        documents: [AgentDocumentAttachment],
        session: AgentTabSession,
        reason: String
    ) {
        guard !identities.contains(where: \.isDurable) else {
            holdBlockedDurableInput(identities, session: session, reason: reason)
            return
        }
        guard !identities.contains(where: session.isScheduledAttemptInput) else {
            showScheduledInputRefusal(reason, session: session)
            return
        }
        // R1-01: the complete snapshot returns first; only then does its bubble go.
        let restoredAttachments = restoreUnsentComposerAttachments(
            images: images,
            taggedFiles: taggedFiles,
            documents: documents,
            session: session
        )
        var removedBubble = false
        for userItemID in identities.compactMap(\.userItemID) {
            guard let index = session.items.firstIndex(where: { $0.id == userItemID && $0.kind == .user }) else { continue }
            removedBubble = session.removeItem(at: index) != nil || removedBubble
        }
        if removedBubble || restoredAttachments {
            session.isDirty = true
            scheduleSave(for: session.tabID)
        }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard restoredAttachments || removedBubble else { return }
            session.appendItem(AgentChatItem.error(reason, sequenceIndex: session.nextSequenceIndex))
            syncComposerUIState()
            requestUIRefresh(tabID: session.tabID, urgent: true)
        } else {
            restoreComposerDraft(tabID: session.tabID, text: text, message: reason, strategy: .prependAlways)
        }
    }

    /// Returns unsent untracked attachments to the composer by identity (never duplicated). Images a
    /// runner reserved for this input (exactly these, by identity) come back through that
    /// reservation's own restore, which releases it, so the runner's later terminal cleanup finds no
    /// reservation and deletes nothing; images reserved by no one are restored directly. Returns
    /// whether anything came back.
    private func restoreUnsentComposerAttachments(
        images: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        documents: [AgentDocumentAttachment],
        session: AgentTabSession
    ) -> Bool {
        var restoredAny = false
        if !images.isEmpty {
            let imageIDs = Set(images.map(\.id))
            let before = session.pendingImageAttachments.map(\.id)
            if case let .reserved(reservationID, reserved) = session.attachmentTurnState,
               Set(reserved.map(\.id)) == imageIDs
            {
                finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: .restoreToPending)
            } else {
                let known = Set(before)
                let unique = images.filter { !known.contains($0.id) }
                if !unique.isEmpty {
                    session.pendingImageAttachments = unique + session.pendingImageAttachments
                }
            }
            restoredAny = session.pendingImageAttachments.map(\.id) != before
        }
        var knownTaggedIDs = Set(session.pendingTaggedFileAttachments.map(\.id))
        let restoredTagged = taggedFiles.filter { knownTaggedIDs.insert($0.id).inserted }
        if !restoredTagged.isEmpty {
            session.pendingTaggedFileAttachments.append(contentsOf: restoredTagged)
            restoredAny = true
        }
        var knownDocumentIDs = Set(session.pendingDocumentAttachments.map(\.id))
        let restoredDocuments = documents.filter { knownDocumentIDs.insert($0.id).inserted }
        if !restoredDocuments.isEmpty {
            session.pendingDocumentAttachments.append(contentsOf: restoredDocuments)
            restoredAny = true
        }
        return restoredAny
    }

    /// A scheduled attempt's refused input: its schedule keeps the one copy (bubble and payload), so
    /// only the reason is shown here.
    private func showScheduledInputRefusal(_ reason: String, session: AgentTabSession) {
        session.appendItem(AgentChatItem.error(reason, sequenceIndex: session.nextSequenceIndex))
        scheduleSave(for: session.tabID)
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    /// Settles input a runner owned that its provider send seam refused for its documents at the
    /// final boundary (DOC-02). The handoff already recorded no handoff and held durable input with
    /// the reason, so durable input only shows it; untracked input is settled like any unsent input
    /// (its whole snapshot back to the composer, or kept by its schedule).
    func settleProviderBoundaryRefusedInput(
        _ identities: [AgentQueuedInputIdentity],
        draftText: String,
        images: [AgentImageAttachment],
        taggedFiles: [AgentTaggedFileAttachment],
        documents: [AgentDocumentAttachment],
        session: AgentTabSession,
        reason: String
    ) {
        guard identities.contains(where: \.isDurable) else {
            settleUnsentInput(
                identities,
                draftText: draftText,
                images: images,
                taggedFiles: taggedFiles,
                documents: documents,
                session: session,
                reason: reason
            )
            return
        }
        session.appendItem(AgentChatItem.error(reason, sequenceIndex: session.nextSequenceIndex))
        scheduleSave(for: session.tabID)
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    /// Settles a queued follow-up whose start provably handed nothing off. Durable input stays
    /// queued with the same intents, except when its own documents refused it: a head refused by
    /// its documents would be refused again at every later turn boundary and wedge the queue, so
    /// it is held for explicit recovery instead. Untracked input carrying documents returns to the
    /// composer (text, documents, no duplicate bubble); untracked text-only input keeps the
    /// existing drop-on-failure behavior.
    func settleUnsentFollowUpInstruction(
        _ instruction: AgentPendingInstruction,
        outcome: CodexAgentModeCoordinator.NativeSendOutcome?,
        session: AgentTabSession
    ) {
        let documentBlock: String? = if !instruction.documentAttachments.isEmpty,
                                        case let .failed(message)? = outcome,
                                        documentAttachmentBlockedMessage(instruction.documentAttachments, session: session) != nil
        {
            message
        } else {
            nil
        }
        if instruction.isDurable, documentBlock == nil {
            session.pendingInstructions.insert(instruction, at: 0)
        } else if instruction.isDurable || !instruction.documentAttachments.isEmpty {
            // A queued follow-up carries no images or tagged files (only text and documents).
            settleUnsentInput(
                instruction.constituents,
                draftText: instruction.text,
                images: [],
                taggedFiles: [],
                documents: instruction.documentAttachments,
                session: session,
                reason: documentBlock ?? Self.unsentQueuedDocumentMessageReturnedNotice
            )
        } else {
            return
        }
        session.isDirty = true
        scheduleSave(for: session.tabID)
    }

    /// Restoration notice for a queued message with documents that failed to start for a reason
    /// already reported by the start itself (never repeated as a second error).
    static let unsentQueuedDocumentMessageReturnedNotice =
        "A queued message with attached documents was not sent, so it was returned to the composer."

    /// Appends the manifest for `documents` to provider text, or reports why it must not be sent.
    /// The manifest carries only escaped metadata and managed paths; no document content.
    func appendDocumentManifestForProviderSend(
        _ text: String,
        documents: [AgentDocumentAttachment],
        session: AgentTabSession?,
        agent: AgentProviderKind
    ) -> Result<String, AgentDocumentManifestBlocked> {
        switch preflightDocumentAttachments(documents, session: session, agent: agent) {
        case let .blocked(issues):
            return .failure(AgentDocumentManifestBlocked(
                message: AgentDocumentPreflightResult.blocked(issues).blockedMessage ?? ""
            ))
        case let .ready(resolved):
            guard let manifest = AgentDocumentManifestRenderer.render(resolved) else { return .success(text) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(trimmed.isEmpty ? manifest : "\(text)\n\n\(manifest)")
        }
    }
}

/// Records the document refusal of a final handoff authorization, so the start that it revoked
/// reports the document's own message instead of a generic revocation.
@MainActor
final class AgentDocumentHandoffGate {
    var blockedMessage: String?
}

/// A document preflight refusal carried as a blocked provider-text assembly.
struct AgentDocumentManifestBlocked: Error, Equatable {
    let message: String
}
