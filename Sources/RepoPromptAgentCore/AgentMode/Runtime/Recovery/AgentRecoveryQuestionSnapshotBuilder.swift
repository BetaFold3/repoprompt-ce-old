import Foundation

/// Builds durable pending-question snapshots: per interaction for live persistence (creation before
/// the request is published, and each non-secret draft change; plan §E), and in aggregate for
/// shutdown preparation (spec R4).
///
/// Only display data and non-secret partial answers are captured: never a continuation, request
/// routing, provider identity, or anything typed or selected for a secret question. A non-empty
/// secret answer cannot be preserved, so it is reported for the caller to veto Stage A while the
/// live question stays usable.
package enum AgentRecoveryQuestionSnapshotBuilder {
    package struct Capture: Equatable {
        package let snapshots: [AgentRecoveryQuestionSnapshot]
        /// A secret question holds a non-empty answer or selection that shutdown would lose.
        package let hasUnsavableSecretAnswer: Bool
    }

    /// Identity and generation stamped on every snapshot of one session.
    package struct Context: Equatable {
        package let runAttemptID: UUID?
        package let transcriptResetGeneration: UInt64
        package let appInstanceID: UUID

        package init(runAttemptID: UUID?, transcriptResetGeneration: UInt64, appInstanceID: UUID) {
            self.runAttemptID = runAttemptID
            self.transcriptResetGeneration = transcriptResetGeneration
            self.appInstanceID = appInstanceID
        }

        @MainActor
        package init(session: AgentTabSession, appInstanceID: UUID, transcriptResetGeneration: UInt64) {
            self.init(
                runAttemptID: session.activeRunAttemptID,
                transcriptResetGeneration: transcriptResetGeneration,
                appInstanceID: appInstanceID
            )
        }
    }

    @MainActor
    package static func capture(
        session: AgentTabSession,
        appInstanceID: UUID,
        transcriptResetGeneration: UInt64
    ) -> Capture {
        let context = Context(session: session, appInstanceID: appInstanceID, transcriptResetGeneration: transcriptResetGeneration)
        var snapshots: [AgentRecoveryQuestionSnapshot] = []
        var hasUnsavableSecretAnswer = false

        if let pending = session.pendingAskUser {
            snapshots.append(snapshot(askUser: pending, context: context))
        }
        for request in userInputRequests(of: session) {
            let drafts = userInputDrafts(for: request, in: session)
            if hasSecretContent(request, drafts: drafts) { hasUnsavableSecretAnswer = true }
            snapshots.append(snapshot(userInput: request, drafts: drafts, context: context))
        }
        for request in elicitationRequests(of: session) {
            snapshots.append(snapshot(elicitation: request, context: context))
        }
        return Capture(snapshots: snapshots, hasUnsavableSecretAnswer: hasUnsavableSecretAnswer)
    }

    /// The current snapshot of one live interaction of `session` (active or queued), or `nil` when it
    /// is no longer live there.
    @MainActor
    package static func snapshot(
        interactionID: UUID,
        session: AgentTabSession,
        appInstanceID: UUID,
        transcriptResetGeneration: UInt64
    ) -> AgentRecoveryQuestionSnapshot? {
        let context = Context(session: session, appInstanceID: appInstanceID, transcriptResetGeneration: transcriptResetGeneration)
        if let pending = session.pendingAskUser, pending.interaction.id == interactionID {
            return snapshot(askUser: pending, context: context)
        }
        if let request = userInputRequests(of: session).first(where: { $0.id == interactionID }) {
            return snapshot(userInput: request, drafts: userInputDrafts(for: request, in: session), context: context)
        }
        if let request = elicitationRequests(of: session).first(where: { $0.id == interactionID }) {
            return snapshot(elicitation: request, context: context)
        }
        return nil
    }

    // MARK: Per-interaction capture

    package static func snapshot(askUser pending: AgentAskUserPendingState, context: Context) -> AgentRecoveryQuestionSnapshot {
        let interaction = pending.interaction
        return AgentRecoveryQuestionSnapshot(
            interactionID: interaction.id,
            kind: .askUser,
            runAttemptID: context.runAttemptID,
            transcriptResetGeneration: context.transcriptResetGeneration,
            appInstanceID: context.appInstanceID,
            askedAt: AgentRecoveryTimestamp(interaction.askedAt),
            title: interaction.title,
            message: interaction.context,
            items: interaction.questions.map { question in
                AgentRecoveryQuestionItem(
                    questionID: question.id,
                    header: question.header,
                    text: question.question,
                    options: question.optionLabels,
                    isSecret: false,
                    answer: pending.draftsByQuestionID[question.id].flatMap(askUserAnswerText)
                )
            }
        )
    }

    /// A secret item never carries an answer (dropped here and again by the item initializer).
    package static func snapshot(
        userInput request: AgentRequestUserInputRequest,
        drafts: [String: AgentRequestUserInputQuestionDraft],
        context: Context
    ) -> AgentRecoveryQuestionSnapshot {
        AgentRecoveryQuestionSnapshot(
            interactionID: request.id,
            kind: .userInput,
            runAttemptID: context.runAttemptID,
            transcriptResetGeneration: context.transcriptResetGeneration,
            appInstanceID: context.appInstanceID,
            askedAt: AgentRecoveryTimestamp(request.askedAt),
            title: nil,
            message: nil,
            items: request.questions.map { question in
                AgentRecoveryQuestionItem(
                    questionID: question.id,
                    header: question.header,
                    text: question.question,
                    options: question.options.map(\.label),
                    isSecret: question.isSecret,
                    answer: question.isSecret ? nil : drafts[question.id].flatMap { userInputAnswerText($0, question: question) }
                )
            }
        )
    }

    /// Title and message only (elicitation has no partial-answer surface); the ask time is the
    /// request's own, stamped once at creation.
    package static func snapshot(elicitation request: AgentMCPElicitationRequest, context: Context) -> AgentRecoveryQuestionSnapshot {
        AgentRecoveryQuestionSnapshot(
            interactionID: request.id,
            kind: .elicitation,
            runAttemptID: context.runAttemptID,
            transcriptResetGeneration: context.transcriptResetGeneration,
            appInstanceID: context.appInstanceID,
            askedAt: AgentRecoveryTimestamp(request.askedAt),
            title: request.title,
            message: request.message ?? request.prompt,
            items: []
        )
    }

    // MARK: Session surfaces

    @MainActor
    private static func userInputRequests(of session: AgentTabSession) -> [AgentRequestUserInputRequest] {
        [session.pendingUserInputRequest].compactMap(\.self) + session.queuedUserInputRequests
    }

    @MainActor
    private static func elicitationRequests(of session: AgentTabSession) -> [AgentMCPElicitationRequest] {
        [session.pendingMCPElicitationRequest].compactMap(\.self) + session.queuedMCPElicitationRequests
    }

    @MainActor
    private static func userInputDrafts(
        for request: AgentRequestUserInputRequest,
        in session: AgentTabSession
    ) -> [String: AgentRequestUserInputQuestionDraft] {
        let liveDrafts = session.pendingUserInputDrafts
        return liveDrafts?.requestID == request.id ? liveDrafts?.draftsByQuestionID ?? [:] : [:]
    }

    private static func hasSecretContent(
        _ request: AgentRequestUserInputRequest,
        drafts: [String: AgentRequestUserInputQuestionDraft]
    ) -> Bool {
        request.questions.contains { $0.isSecret && drafts[$0.id]?.hasContent == true }
    }

    // MARK: Answer text

    static func askUserAnswerText(_ draft: AgentAskUserDraft) -> String? {
        guard !draft.skipped else { return nil }
        var parts = draft.selectedOptionLabels
        let custom = draft.customResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func userInputAnswerText(
        _ draft: AgentRequestUserInputQuestionDraft,
        question: AgentRequestUserInputQuestion
    ) -> String? {
        guard !question.isSecret else { return nil }
        var parts: [String] = []
        if let index = draft.selectedOptionIndex {
            if question.options.indices.contains(index) {
                parts.append(question.options[index].label)
            } else if index == question.options.count, question.isOtherOptionEnabled {
                parts.append(AgentRequestUserInputQuestion.otherOptionLabel)
            }
        }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
