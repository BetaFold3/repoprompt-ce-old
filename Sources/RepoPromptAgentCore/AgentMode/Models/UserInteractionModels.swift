import CryptoKit
import Foundation

private enum StableUserInteractionIdentity {
    static func uuid(from seed: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        let bytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }
}

/// A question asked by an agent awaiting user response
public struct DiscoveryQuestion: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let question: String
    public let options: [String]?
    public let context: String?
    public let askedAt: Date
    /// Whether the user can select multiple options
    public let multiSelect: Bool
    /// Timeout in seconds for the question
    public let timeoutSeconds: TimeInterval

    public init(
        id: UUID = UUID(),
        question: String,
        options: [String]? = nil,
        context: String? = nil,
        askedAt: Date = Date(),
        multiSelect: Bool = false,
        timeoutSeconds: TimeInterval = 300
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.context = context
        self.askedAt = askedAt
        self.multiSelect = multiSelect
        self.timeoutSeconds = timeoutSeconds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: DiscoveryQuestion, rhs: DiscoveryQuestion) -> Bool {
        lhs.id == rhs.id
    }
}

/// Response from user to a discovery question
public struct UserQuestionResponse: Sendable {
    public let text: String?
    public let timedOut: Bool
    public let elapsedSeconds: Int
    public let skipped: Bool

    public init(text: String?, timedOut: Bool, elapsedSeconds: Int, skipped: Bool) {
        self.text = text
        self.timedOut = timedOut
        self.elapsedSeconds = elapsedSeconds
        self.skipped = skipped
    }

    public static func answered(_ text: String, elapsedSeconds: Int) -> UserQuestionResponse {
        UserQuestionResponse(text: text, timedOut: false, elapsedSeconds: elapsedSeconds, skipped: false)
    }

    public static func timeout(elapsedSeconds: Int) -> UserQuestionResponse {
        UserQuestionResponse(text: nil, timedOut: true, elapsedSeconds: elapsedSeconds, skipped: false)
    }

    public static func skipped(elapsedSeconds: Int) -> UserQuestionResponse {
        UserQuestionResponse(text: nil, timedOut: false, elapsedSeconds: elapsedSeconds, skipped: true)
    }
}

enum AgentAskUserValidationError: LocalizedError, Equatable {
    case emptyQuestions
    case blankQuestionID(index: Int)
    case duplicateQuestionID(String)
    case blankQuestionText(id: String)
    case duplicateOptionLabel(questionID: String, label: String)
    case impossibleQuestion(questionID: String)
    case incompleteQuestion(String)
    case invalidSingleSelectAnswer(questionID: String)
    case invalidCustomAnswer(questionID: String)
    case invalidSelectedOption(questionID: String, label: String)
    case skippedQuestionHasAnswer(questionID: String)
    case inconsistentStructuredAnswer(questionID: String)
    case unknownQuestionID(id: String, validIDs: [String])

    var errorDescription: String? {
        switch self {
        case .emptyQuestions:
            "ask_user requires at least one question."
        case let .blankQuestionID(index):
            "ask_user question at index \(index) has a blank id."
        case let .duplicateQuestionID(id):
            "ask_user question id '\(id)' is duplicated."
        case let .blankQuestionText(id):
            "ask_user question '\(id)' has blank question text."
        case let .duplicateOptionLabel(questionID, label):
            "ask_user question '\(questionID)' has duplicate option label '\(label)'."
        case let .impossibleQuestion(questionID):
            "ask_user question '\(questionID)' has no options and does not allow custom responses."
        case let .incompleteQuestion(questionID):
            "ask_user question '\(questionID)' must be answered or skipped before submitting."
        case let .invalidSingleSelectAnswer(questionID):
            "ask_user question '\(questionID)' accepts only one selected option or one custom response."
        case let .invalidCustomAnswer(questionID):
            "ask_user question '\(questionID)' has an invalid custom response. Custom responses must be allowed and only one custom response may be provided."
        case let .invalidSelectedOption(questionID, label):
            "ask_user question '\(questionID)' has invalid selected option '\(label)'."
        case let .skippedQuestionHasAnswer(questionID):
            "ask_user question '\(questionID)' cannot be skipped and answered at the same time."
        case let .inconsistentStructuredAnswer(questionID):
            "ask_user question '\(questionID)' has inconsistent structured answers."
        case let .unknownQuestionID(id, validIDs):
            "ask_user answer references unknown question_id '\(id)'. Known IDs: \(validIDs.joined(separator: ", "))."
        }
    }
}

package struct AgentAskUserOption: Hashable {
    package let label: String
    package let description: String?

    package init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

package struct AgentAskUserQuestion: Hashable {
    package let id: String
    package let header: String?
    package let question: String
    package let context: String?
    package let options: [AgentAskUserOption]
    package let allowsMultiple: Bool
    package let allowsCustom: Bool

    package init(
        id: String,
        header: String? = nil,
        question: String,
        context: String? = nil,
        options: [AgentAskUserOption] = [],
        allowsMultiple: Bool = false,
        allowsCustom: Bool = true
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.context = context
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsCustom = allowsCustom
    }

    package var optionLabels: [String] {
        options.map(\.label)
    }

    func orderedSelectedOptions(from draft: AgentAskUserDraft) -> [String] {
        let selected = Set(draft.selectedOptionLabels)
        return optionLabels.filter { selected.contains($0) }
    }

    package func answer(from draft: AgentAskUserDraft) -> AgentAskUserAnswer {
        if draft.skipped {
            return AgentAskUserAnswer(answers: [], selectedOptions: [], customResponse: nil, skipped: true)
        }

        var selectedOptions = orderedSelectedOptions(from: draft)
        let trimmedCustom = allowsCustom
            ? draft.customResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let customResponse = trimmedCustom.isEmpty ? nil : trimmedCustom

        if !allowsMultiple, customResponse != nil {
            selectedOptions = []
        }

        var answers = selectedOptions
        if let customResponse {
            answers.append(customResponse)
        }
        return AgentAskUserAnswer(
            answers: answers,
            selectedOptions: selectedOptions,
            customResponse: customResponse,
            skipped: false
        )
    }

    func validate(_ answer: AgentAskUserAnswer) throws {
        guard allowsMultiple || answer.answers.count <= 1 else {
            throw AgentAskUserValidationError.invalidSingleSelectAnswer(questionID: id)
        }
    }
}

package struct AgentAskUserDraft: Hashable {
    package var selectedOptionLabels: [String]
    package var customResponse: String
    package var skipped: Bool

    package init(
        selectedOptionLabels: [String] = [],
        customResponse: String = "",
        skipped: Bool = false
    ) {
        self.selectedOptionLabels = selectedOptionLabels
        self.customResponse = customResponse
        self.skipped = skipped
    }

    package var hasContent: Bool {
        skipped
            || !selectedOptionLabels.isEmpty
            || !customResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

package struct AgentAskUserAnswer: Hashable {
    package let answers: [String]
    package let selectedOptions: [String]
    package let customResponse: String?
    package let skipped: Bool

    package init(
        answers: [String],
        selectedOptions: [String],
        customResponse: String?,
        skipped: Bool
    ) {
        self.answers = answers
        self.selectedOptions = selectedOptions
        self.customResponse = customResponse
        self.skipped = skipped
    }

    var jsonObject: [String: Any] {
        [
            "answers": answers,
            "selected_options": selectedOptions,
            "custom_response": customResponse ?? NSNull(),
            "skipped": skipped
        ]
    }
}

package struct AgentAskUserResponse: Hashable {
    package let answersByQuestionID: [String: AgentAskUserAnswer]
    package let timedOut: Bool
    package let skipped: Bool
    package let elapsedSeconds: Int

    var jsonObject: [String: Any] {
        [
            "answers": answersByQuestionID.reduce(into: [String: [String: Any]]()) { partialResult, entry in
                partialResult[entry.key] = entry.value.jsonObject
            },
            "timed_out": timedOut,
            "skipped": skipped,
            "elapsed_seconds": elapsedSeconds
        ]
    }
}

package struct AgentAskUserInteraction: Identifiable, Hashable {
    package let id: UUID
    package let remoteInteractionID: String?
    package let title: String?
    package let context: String?
    package let timeoutSeconds: TimeInterval
    package let askedAt: Date
    package let questions: [AgentAskUserQuestion]

    package init(
        id: UUID = UUID(),
        remoteInteractionID: String? = nil,
        title: String? = nil,
        context: String? = nil,
        timeoutSeconds: TimeInterval = 300,
        askedAt: Date = Date(),
        questions: [AgentAskUserQuestion]
    ) {
        self.id = id
        self.remoteInteractionID = remoteInteractionID
        self.title = title
        self.context = context
        self.timeoutSeconds = timeoutSeconds
        self.askedAt = askedAt
        self.questions = questions
    }

    package func validate() throws {
        guard !questions.isEmpty else {
            throw AgentAskUserValidationError.emptyQuestions
        }
        var seenIDs = Set<String>()
        for (index, question) in questions.enumerated() {
            let questionID = question.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !questionID.isEmpty else {
                throw AgentAskUserValidationError.blankQuestionID(index: index)
            }
            guard seenIDs.insert(questionID).inserted else {
                throw AgentAskUserValidationError.duplicateQuestionID(questionID)
            }
            guard !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentAskUserValidationError.blankQuestionText(id: questionID)
            }
            guard question.allowsCustom || !question.options.isEmpty else {
                throw AgentAskUserValidationError.impossibleQuestion(questionID: questionID)
            }

            var optionLabels = Set<String>()
            for option in question.options {
                let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else {
                    throw AgentAskUserValidationError.duplicateOptionLabel(questionID: questionID, label: "")
                }
                guard optionLabels.insert(label).inserted else {
                    throw AgentAskUserValidationError.duplicateOptionLabel(questionID: questionID, label: label)
                }
            }
        }
    }

    func emptyDrafts() -> [String: AgentAskUserDraft] {
        questions.reduce(into: [String: AgentAskUserDraft]()) { partialResult, question in
            partialResult[question.id] = AgentAskUserDraft()
        }
    }

    func isComplete(drafts: [String: AgentAskUserDraft]) -> Bool {
        (try? buildSubmittedResponse(drafts: drafts, elapsedSeconds: 0)) != nil
    }

    package func drafts(from answersByQuestionID: [String: AgentAskUserAnswer]) throws -> [String: AgentAskUserDraft] {
        try validateAnswerQuestionIDs(answersByQuestionID.keys)
        return try questions.reduce(into: emptyDrafts()) { partialResult, question in
            guard let answer = answersByQuestionID[question.id] else { return }
            partialResult[question.id] = try draft(from: answer, for: question)
        }
    }

    package func drafts(fromFlatAnswers answersByQuestionID: [String: [String]]) throws -> [String: AgentAskUserDraft] {
        try validateAnswerQuestionIDs(answersByQuestionID.keys)
        return try questions.reduce(into: emptyDrafts()) { partialResult, question in
            guard let answers = answersByQuestionID[question.id] else { return }
            partialResult[question.id] = try draft(fromAnswers: answers, skipped: false, for: question)
        }
    }

    private func validateAnswerQuestionIDs(_ ids: some Sequence<String>) throws {
        let validIDs = questions.map(\.id)
        let validIDSet = Set(validIDs)
        if let unknownID = ids.first(where: { !validIDSet.contains($0) }) {
            throw AgentAskUserValidationError.unknownQuestionID(id: unknownID, validIDs: validIDs)
        }
    }

    private func draft(from answer: AgentAskUserAnswer, for question: AgentAskUserQuestion) throws -> AgentAskUserDraft {
        let trimmedCustom = answer.customResponse?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasStructuredAnswer = !answer.selectedOptions.isEmpty || !trimmedCustom.isEmpty

        if answer.skipped {
            guard answer.answers.isEmpty, answer.selectedOptions.isEmpty, trimmedCustom.isEmpty else {
                throw AgentAskUserValidationError.skippedQuestionHasAnswer(questionID: question.id)
            }
            return AgentAskUserDraft(skipped: true)
        }

        guard hasStructuredAnswer else {
            return try draft(fromAnswers: answer.answers, skipped: false, for: question)
        }

        let optionLabels = question.optionLabels
        let optionSet = Set(optionLabels)
        var selectedSet = Set<String>()
        for selectedOption in answer.selectedOptions {
            let trimmed = selectedOption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard optionSet.contains(trimmed), selectedSet.insert(trimmed).inserted else {
                throw AgentAskUserValidationError.invalidSelectedOption(questionID: question.id, label: trimmed)
            }
        }
        let selectedOptions = optionLabels.filter { selectedSet.contains($0) }

        guard trimmedCustom.isEmpty || question.allowsCustom else {
            throw AgentAskUserValidationError.invalidCustomAnswer(questionID: question.id)
        }
        let totalAnswerCount = selectedOptions.count + (trimmedCustom.isEmpty ? 0 : 1)
        guard question.allowsMultiple || totalAnswerCount <= 1 else {
            throw AgentAskUserValidationError.invalidSingleSelectAnswer(questionID: question.id)
        }

        let expectedAnswers = selectedOptions + (trimmedCustom.isEmpty ? [] : [trimmedCustom])
        guard answer.answers.isEmpty || answer.answers == expectedAnswers else {
            throw AgentAskUserValidationError.inconsistentStructuredAnswer(questionID: question.id)
        }

        return AgentAskUserDraft(
            selectedOptionLabels: selectedOptions,
            customResponse: trimmedCustom,
            skipped: false
        )
    }

    private func draft(fromAnswers answers: [String], skipped: Bool, for question: AgentAskUserQuestion) throws -> AgentAskUserDraft {
        if skipped {
            return AgentAskUserDraft(skipped: true)
        }

        let optionLabels = question.optionLabels
        let optionSet = Set(optionLabels)
        var selectedSet = Set<String>()
        var customAnswers: [String] = []
        for answer in answers {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if optionSet.contains(trimmed) {
                selectedSet.insert(trimmed)
            } else {
                guard question.allowsCustom else {
                    throw AgentAskUserValidationError.invalidCustomAnswer(questionID: question.id)
                }
                customAnswers.append(trimmed)
            }
        }

        guard customAnswers.count <= 1 else {
            throw AgentAskUserValidationError.invalidCustomAnswer(questionID: question.id)
        }
        let selectedOptions = optionLabels.filter { selectedSet.contains($0) }
        let customResponse = customAnswers.first ?? ""
        let totalAnswerCount = selectedOptions.count + (customResponse.isEmpty ? 0 : 1)
        guard question.allowsMultiple || totalAnswerCount <= 1 else {
            throw AgentAskUserValidationError.invalidSingleSelectAnswer(questionID: question.id)
        }
        return AgentAskUserDraft(
            selectedOptionLabels: selectedOptions,
            customResponse: customResponse,
            skipped: false
        )
    }

    package func buildSubmittedResponse(
        drafts: [String: AgentAskUserDraft],
        elapsedSeconds: Int
    ) throws -> AgentAskUserResponse {
        try buildResponse(drafts: drafts, timedOut: false, skipped: false, elapsedSeconds: elapsedSeconds, requireComplete: true)
    }

    package func buildTimedOutResponse(
        drafts: [String: AgentAskUserDraft],
        elapsedSeconds: Int
    ) -> AgentAskUserResponse {
        (try? buildResponse(drafts: drafts, timedOut: true, skipped: false, elapsedSeconds: elapsedSeconds, requireComplete: false))
            ?? AgentAskUserResponse(answersByQuestionID: [:], timedOut: true, skipped: false, elapsedSeconds: elapsedSeconds)
    }

    package func buildSkippedResponse(elapsedSeconds: Int) -> AgentAskUserResponse {
        let skippedAnswers = questions.reduce(into: [String: AgentAskUserAnswer]()) { partialResult, question in
            partialResult[question.id] = AgentAskUserAnswer(answers: [], selectedOptions: [], customResponse: nil, skipped: true)
        }
        return AgentAskUserResponse(
            answersByQuestionID: skippedAnswers,
            timedOut: false,
            skipped: true,
            elapsedSeconds: elapsedSeconds
        )
    }

    private func buildResponse(
        drafts: [String: AgentAskUserDraft],
        timedOut: Bool,
        skipped: Bool,
        elapsedSeconds: Int,
        requireComplete: Bool
    ) throws -> AgentAskUserResponse {
        try validate()
        var answers = [String: AgentAskUserAnswer]()
        for question in questions {
            let answer = question.answer(from: drafts[question.id] ?? AgentAskUserDraft())
            try question.validate(answer)
            if requireComplete, !answer.skipped, answer.answers.isEmpty {
                throw AgentAskUserValidationError.incompleteQuestion(question.id)
            }
            answers[question.id] = answer
        }
        return AgentAskUserResponse(
            answersByQuestionID: answers,
            timedOut: timedOut,
            skipped: skipped,
            elapsedSeconds: elapsedSeconds
        )
    }
}

/// Who is expected to answer a pending Agent Mode `ask_user` question when it is not simply the
/// user of a top-level session (delegated `ask_user` plan §6.1/§6.5). Presentation only: the
/// pending state itself stays the single authority for content, drafts, and the timeout.
package enum AgentAskUserDelegatedRouting: Hashable {
    /// Unchanged behavior (top-level session or verified external controller).
    case direct
    /// Addressed to the parent agent; the timeout is paused and the card shows
    /// "Waiting on parent agent" instead of a countdown.
    case awaitingParentAgent
    /// In-app child that could not be routed to a live parent: the user answers here and
    /// the normal timeout runs.
    case userFallback
}

package struct AgentAskUserPendingState: Identifiable, Hashable {
    package var interaction: AgentAskUserInteraction
    package var draftsByQuestionID: [String: AgentAskUserDraft]
    package var currentQuestionIndex: Int
    package var timeoutStartedAt: Date?
    package var delegatedRouting: AgentAskUserDelegatedRouting = .direct

    package var id: UUID {
        interaction.id
    }

    package var isAwaitingParentAgent: Bool {
        delegatedRouting == .awaitingParentAgent
    }

    package init(
        interaction: AgentAskUserInteraction,
        draftsByQuestionID: [String: AgentAskUserDraft]? = nil,
        currentQuestionIndex: Int = 0,
        timeoutStartedAt: Date? = nil
    ) {
        self.interaction = interaction
        self.draftsByQuestionID = draftsByQuestionID ?? interaction.emptyDrafts()
        self.currentQuestionIndex = currentQuestionIndex
        self.timeoutStartedAt = timeoutStartedAt
    }

    package var currentQuestion: AgentAskUserQuestion? {
        guard interaction.questions.indices.contains(currentQuestionIndex) else { return nil }
        return interaction.questions[currentQuestionIndex]
    }

    package var isComplete: Bool {
        interaction.isComplete(drafts: draftsByQuestionID)
    }

    package var legacyDiscoveryQuestion: DiscoveryQuestion? {
        guard let question = interaction.questions.first else { return nil }
        return DiscoveryQuestion(
            id: interaction.id,
            question: question.question,
            options: question.optionLabels.isEmpty ? nil : question.optionLabels,
            context: interaction.context ?? question.context,
            askedAt: interaction.askedAt,
            multiSelect: question.allowsMultiple,
            timeoutSeconds: interaction.timeoutSeconds
        )
    }
}

/// Response from user instruction input in Agent mode
public struct UserInstructionResponse: Sendable {
    public let text: String?
    public let timedOut: Bool
    public let elapsedSeconds: Int

    public init(text: String?, timedOut: Bool, elapsedSeconds: Int) {
        self.text = text
        self.timedOut = timedOut
        self.elapsedSeconds = elapsedSeconds
    }
}

package enum AgentJSONValue: Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    func toAny() -> Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(values):
            values.map { $0.toAny() }
        case let .object(values):
            values.reduce(into: [String: Any]()) { partialResult, entry in
                partialResult[entry.key] = entry.value.toAny()
            }
        }
    }
}

package struct AgentRequestUserInputOption: Hashable {
    package let label: String
    package let description: String
}

package struct AgentRequestUserInputQuestion: Hashable {
    package static let otherOptionLabel = "None of the above"

    package let id: String
    package let header: String
    package let question: String
    let isOther: Bool
    package let isSecret: Bool
    package let options: [AgentRequestUserInputOption]

    package var isOtherOptionEnabled: Bool {
        isOther && !options.isEmpty
    }
}

package struct AgentRequestUserInputQuestionDraft: Hashable {
    package var selectedOptionIndex: Int?
    package var note: String = ""

    package init(
        selectedOptionIndex: Int? = nil,
        note: String = ""
    ) {
        self.selectedOptionIndex = selectedOptionIndex
        self.note = note
    }
}

/// Session-owned partial answers of one native user-input request (see
/// `AgentTabSession.pendingUserInputDrafts`).
package struct AgentRequestUserInputDraftState: Hashable {
    package let requestID: UUID
    package var draftsByQuestionID: [String: AgentRequestUserInputQuestionDraft]

    package init(requestID: UUID, draftsByQuestionID: [String: AgentRequestUserInputQuestionDraft] = [:]) {
        self.requestID = requestID
        self.draftsByQuestionID = draftsByQuestionID
    }
}

package extension AgentRequestUserInputQuestionDraft {
    /// Any answer at all (a selection or typed text): for a secret question, content that would be
    /// lost by shutdown and is never persisted.
    var hasContent: Bool {
        selectedOptionIndex != nil || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

package struct AgentRequestUserInputResponse: Hashable {
    let answersByQuestionID: [String: [String]]

    package init(
        answersByQuestionID: [String: [String]]
    ) {
        self.answersByQuestionID = answersByQuestionID
    }

    var jsonObject: [String: Any] {
        let answers = answersByQuestionID.reduce(into: [String: [String: Any]]()) { partialResult, entry in
            partialResult[entry.key] = ["answers": entry.value]
        }
        return ["answers": answers]
    }
}

package struct AgentRequestUserInputRequest: Identifiable, Hashable {
    package let id: UUID
    package let remoteInteractionID: String?
    package let requestID: CodexAppServerRequestID
    let method: String
    let threadID: String
    let turnID: String
    let itemID: String
    package let askedAt: Date
    package let questions: [AgentRequestUserInputQuestion]
    /// R6: the issuing Codex transport's immutable receipt; the reply routes by it (never by the
    /// wire ID alone). Nil for requests that did not come from a Codex transport.
    package var codexReceipt: CodexServerRequestReceipt?

    init(
        id: UUID? = nil,
        remoteInteractionID: String? = nil,
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String,
        askedAt: Date = Date(),
        questions: [AgentRequestUserInputQuestion]
    ) {
        self.id = id ?? Self.stableID(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        self.remoteInteractionID = remoteInteractionID
        self.requestID = requestID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.askedAt = askedAt
        self.questions = questions
    }

    static func stableID(
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "request-user-input|\(requestID.displayValue)|\(method)|\(threadID)|\(turnID)|\(itemID)"
        )
    }

    package func buildResponse(from drafts: [String: AgentRequestUserInputQuestionDraft]) -> AgentRequestUserInputResponse {
        let answers = questions.reduce(into: [String: [String]]()) { partialResult, question in
            let draft = drafts[question.id]
            let trimmedNote = draft?.note.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var questionAnswers: [String] = []

            if let selectedIndex = draft?.selectedOptionIndex {
                if selectedIndex >= 0, selectedIndex < question.options.count {
                    questionAnswers.append(question.options[selectedIndex].label)
                } else if selectedIndex == question.options.count, question.isOtherOptionEnabled {
                    questionAnswers.append(AgentRequestUserInputQuestion.otherOptionLabel)
                }
            }

            if !trimmedNote.isEmpty {
                questionAnswers.append("user_note: \(trimmedNote)")
            }

            partialResult[question.id] = questionAnswers
        }
        return AgentRequestUserInputResponse(answersByQuestionID: answers)
    }
}

package struct AgentMCPElicitationRequest: Identifiable, Hashable {
    package let id: UUID
    package let remoteInteractionID: String?
    let requestID: CodexAppServerRequestID
    package let method: String
    let threadID: String
    let turnID: String
    let itemID: String
    /// R6: the issuing Codex transport's immutable receipt (see `AgentRequestUserInputRequest`).
    package var codexReceipt: CodexServerRequestReceipt?
    package let serverName: String?
    package let toolName: String?
    package let title: String
    package let prompt: String?
    package let message: String?
    let schemaJSON: String?
    let defaultContentJSON: String?
    let rawParamsJSON: String
    package let details: [AgentApprovalDetail]
    /// When the request was received (stamped once at creation, like the other question requests),
    /// so a durable snapshot's ask time never changes between captures.
    package let askedAt: Date

    init(
        id: UUID? = nil,
        remoteInteractionID: String? = nil,
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String,
        serverName: String? = nil,
        toolName: String? = nil,
        title: String = "MCP Elicitation Requested",
        prompt: String? = nil,
        message: String? = nil,
        schemaJSON: String? = nil,
        defaultContentJSON: String? = nil,
        rawParamsJSON: String,
        details: [AgentApprovalDetail] = [],
        askedAt: Date = Date()
    ) {
        self.id = id ?? Self.stableID(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        self.remoteInteractionID = remoteInteractionID
        self.requestID = requestID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.serverName = serverName
        self.toolName = toolName
        self.title = title
        self.prompt = prompt
        self.message = message
        self.schemaJSON = schemaJSON
        self.defaultContentJSON = defaultContentJSON
        self.rawParamsJSON = rawParamsJSON
        self.details = details
        self.askedAt = askedAt
    }

    static func stableID(
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "mcp-elicitation-request|\(requestID.displayValue)|\(method)|\(threadID)|\(turnID)|\(itemID)"
        )
    }
}

package struct AgentMCPElicitationResponse: Equatable {
    package enum Action: String, Equatable {
        case accept
        case decline
        case cancel
    }

    let action: Action
    let content: [String: AgentJSONValue]
    let meta: [String: AgentJSONValue]

    package init(
        action: Action,
        content: [String: AgentJSONValue] = [:],
        meta: [String: AgentJSONValue] = [:]
    ) {
        self.action = action
        self.content = content
        self.meta = meta
    }

    var jsonObject: [String: Any] {
        [
            "action": action.rawValue,
            "content": content.reduce(into: [String: Any]()) { partialResult, entry in
                partialResult[entry.key] = entry.value.toAny()
            },
            "_meta": meta.reduce(into: [String: Any]()) { partialResult, entry in
                partialResult[entry.key] = entry.value.toAny()
            }
        ]
    }
}

package struct AgentApprovalDetail: Identifiable, Hashable {
    package let id: UUID
    package let label: String
    package let value: String
    package let isCode: Bool

    static func stableID(
        requestSeed: String,
        index: Int,
        label: String,
        value: String,
        isCode: Bool
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "approval-detail|\(requestSeed)|\(index)|\(label)|\(isCode)|\(value)"
        )
    }

    private static func defaultStableID(
        label: String,
        value: String,
        isCode: Bool
    ) -> UUID {
        StableUserInteractionIdentity.uuid(from: "approval-detail-default|\(label)|\(isCode)|\(value)")
    }

    package init(id: UUID? = nil, label: String, value: String, isCode: Bool = false) {
        self.id = id ?? Self.defaultStableID(label: label, value: value, isCode: isCode)
        self.label = label
        self.value = value
        self.isCode = isCode
    }
}

package enum AgentApprovalKind: String, Hashable {
    case commandExecution
    case fileChange
}

package enum AgentApprovalDecision: Hashable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment(String)
    case decline
    case cancel
}

package enum AgentApprovalRequestID: Hashable {
    case codex(CodexAppServerRequestID)
    case claudeControl(String)
    case acp(String)
    case remoteGateway(interactionID: String)

    var displayValue: String {
        switch self {
        case let .codex(id):
            id.displayValue
        case let .claudeControl(id):
            id
        case let .acp(id):
            id
        case let .remoteGateway(interactionID):
            "remote:\(interactionID)"
        }
    }
}

package struct AgentPermissionsRequest: Identifiable, Hashable {
    package let id: UUID
    let requestID: CodexAppServerRequestID
    let method: String
    let threadID: String
    let turnID: String
    let itemID: String
    /// R6: the issuing Codex transport's immutable receipt (see `AgentRequestUserInputRequest`).
    package var codexReceipt: CodexServerRequestReceipt?
    package let cwd: String
    package let reason: String?
    package let permissionsJSON: String
    let details: [AgentApprovalDetail]

    init(
        id: UUID? = nil,
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String,
        cwd: String,
        reason: String? = nil,
        permissionsJSON: String,
        details: [AgentApprovalDetail] = []
    ) {
        self.id = id ?? Self.stableID(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        self.requestID = requestID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.cwd = cwd
        self.reason = reason
        self.permissionsJSON = permissionsJSON
        self.details = details
    }

    static func stableID(
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "permissions-request|\(requestID.displayValue)|\(method)|\(threadID)|\(turnID)|\(itemID)"
        )
    }

    package var title: String {
        "Permissions Approval"
    }

    var permissionsObject: [String: Any] {
        guard let data = permissionsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }
}

package struct AgentApprovalRequest: Identifiable, Hashable {
    package let id: UUID
    package let requestID: AgentApprovalRequestID
    package let method: String
    package let kind: AgentApprovalKind
    /// R6: the issuing Codex transport's immutable receipt (see `AgentRequestUserInputRequest`).
    package var codexReceipt: CodexServerRequestReceipt?
    let threadID: String
    let turnID: String
    let itemID: String
    package let reason: String?
    package let command: String?
    package let cwd: String?
    package let grantRoot: String?
    package let proposedExecpolicyAmendmentJSON: String?
    package let details: [AgentApprovalDetail]

    package init(
        id: UUID? = nil,
        requestID: AgentApprovalRequestID,
        method: String,
        kind: AgentApprovalKind,
        threadID: String,
        turnID: String,
        itemID: String,
        reason: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        grantRoot: String? = nil,
        proposedExecpolicyAmendmentJSON: String? = nil,
        details: [AgentApprovalDetail] = []
    ) {
        self.id = id ?? Self.stableID(
            requestID: requestID,
            method: method,
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        self.requestID = requestID
        self.method = method
        self.kind = kind
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.reason = reason
        self.command = command
        self.cwd = cwd
        self.grantRoot = grantRoot
        self.proposedExecpolicyAmendmentJSON = proposedExecpolicyAmendmentJSON
        self.details = details
    }

    static func stableID(
        requestID: AgentApprovalRequestID,
        method: String,
        kind: AgentApprovalKind,
        threadID: String,
        turnID: String,
        itemID: String
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "approval-request|\(requestID.displayValue)|\(method)|\(kind.rawValue)|\(threadID)|\(turnID)|\(itemID)"
        )
    }

    package var title: String {
        switch kind {
        case .commandExecution:
            "Command Approval"
        case .fileChange:
            "File Change Approval"
        }
    }

    package var supportsAlwaysAllow: Bool {
        true
    }
}
