import Foundation
import MCP

/// Identity of one delegated child question: the asking child's durable session ID plus the
/// `ask_user` interaction ID its MCP snapshot exposes (`AgentAskUserInteraction.id`).
///
/// Related:
/// - AgentDelegatedQuestionAudience.swift (who a child's `ask_user` is addressed to)
/// - AgentModeViewModel+DelegatedQuestions.swift (runtime notice registry and delivery)
/// - docs/context/agent-mcp-delegation-depth.md ("Delegated questions" contract)
package struct AgentDelegatedQuestionNoticeKey: Hashable {
    package let childSessionID: UUID
    package let interactionID: UUID

    package init(
        childSessionID: UUID,
        interactionID: UUID
    ) {
        self.childSessionID = childSessionID
        self.interactionID = interactionID
    }
}

/// Model-visible notice for one pending child question, resolved fresh from the child's
/// `pendingAskUser` at delivery time. It carries the question content and selection
/// constraints only — never the user's unsubmitted drafts — and is not an answer or approval.
package struct AgentDelegatedQuestionNoticePayload: Equatable {
    package struct Option: Equatable {
        let label: String
        let description: String?

        package init(
            label: String,
            description: String?
        ) {
            self.label = label
            self.description = description
        }
    }

    package struct Question: Equatable {
        let id: String
        let header: String?
        let question: String
        let context: String?
        let options: [Option]
        package let allowsMultiple: Bool
        package let allowsCustom: Bool

        package init(
            id: String,
            header: String?,
            question: String,
            context: String?,
            options: [Option],
            allowsMultiple: Bool,
            allowsCustom: Bool
        ) {
            self.id = id
            self.header = header
            self.question = question
            self.context = context
            self.options = options
            self.allowsMultiple = allowsMultiple
            self.allowsCustom = allowsCustom
        }
    }

    package let key: AgentDelegatedQuestionNoticeKey
    let childSessionName: String
    package let title: String?
    package let context: String?
    package let questions: [Question]

    init(
        key: AgentDelegatedQuestionNoticeKey,
        childSessionName: String,
        title: String?,
        context: String?,
        questions: [Question]
    ) {
        self.key = key
        self.childSessionName = childSessionName
        self.title = title
        self.context = context
        self.questions = questions
    }

    /// Builds the payload from the authoritative interaction only (no drafts are read).
    package init(childSessionID: UUID, childSessionName: String, interaction: AgentAskUserInteraction) {
        self.init(
            key: AgentDelegatedQuestionNoticeKey(childSessionID: childSessionID, interactionID: interaction.id),
            childSessionName: childSessionName,
            title: interaction.title,
            context: interaction.context,
            questions: interaction.questions.map { question in
                Question(
                    id: question.id,
                    header: question.header,
                    question: question.question,
                    context: question.context,
                    options: question.options.map { Option(label: $0.label, description: $0.description) },
                    allowsMultiple: question.allowsMultiple,
                    allowsCustom: question.allowsCustom
                )
            }
        )
    }

    /// Point-of-need guidance (plan §6.3), verbatim apart from the substituted identifiers.
    var guidanceText: String {
        let sessionID = key.childSessionID.uuidString
        let interactionID = key.interactionID.uuidString
        return "Child session \"\(childSessionName)\" (`\(sessionID)`) is waiting for your answer to an `ask_user` question (interaction `\(interactionID)`). Use your own judgment and the information you have to answer it with `agent_run respond`. If you cannot decide, ask your own controller with `ask_user`, then relay the answer. This notice is not a user answer or approval; confirm the interaction is still pending before responding."
    }

    /// Labeled, ID-bearing text block shown to the parent model and persisted with the tool
    /// result or turn input that delivered it. Child-controlled strings can never form a runtime
    /// notice wrapper tag (`AgentDelegatedQuestionNoticeWire.neutralizingRuntimeNoticeDelimiters`).
    var renderedText: String {
        let lines = [AgentDelegatedQuestionNoticeWire.noticeHeader, guidanceText] + contentLines
        return AgentDelegatedQuestionNoticeWire.neutralizingRuntimeNoticeDelimiters(lines.joined(separator: "\n"))
    }

    /// Persistence-only record of a question the parent already received inside its covering
    /// `agent_run` result snapshot (plan §6.2 persistence). The ordinary storage summary of that
    /// result keeps only the interaction identity, so this labeled, ID-bearing record keeps the
    /// complete question content (title, context, questions, options, and selection constraints)
    /// in the parent transcript. It carries no guidance, because the parent never saw any, and it
    /// is never added to the returned result.
    var coveredRecordText: String {
        let sessionID = key.childSessionID.uuidString
        let interactionID = key.interactionID.uuidString
        let lines = [
            AgentDelegatedQuestionNoticeWire.coveredRecordHeader,
            "Child session \"\(childSessionName)\" (`\(sessionID)`) asked an `ask_user` question (interaction `\(interactionID)`). The parent received it in its `agent_run` result; this record preserves the complete question for history."
        ] + contentLines
        return AgentDelegatedQuestionNoticeWire.neutralizingRuntimeNoticeDelimiters(lines.joined(separator: "\n"))
    }

    /// Question content shared by the delivered notice and the covered record.
    private var contentLines: [String] {
        Self.contentLines(title: title, context: context, questions: questions)
    }

    /// Question content (title, context, questions, per-question context, selection
    /// constraints, and options). Also used by `ToolOutputFormatter` to render a structured
    /// `ask_user` interaction carried by an `agent_run` snapshot, so both surfaces share wording.
    package static func contentLines(title: String?, context: String?, questions: [Question]) -> [String] {
        var lines: [String] = []
        if let title = Self.nonEmpty(title) {
            lines.append("Title: \(title)")
        }
        if let context = Self.nonEmpty(context) {
            lines.append("Context: \(context)")
        }
        lines.append("Questions:")
        for (index, question) in questions.enumerated() {
            let header = Self.nonEmpty(question.header).map { "\($0): " } ?? ""
            lines.append("\(index + 1). [id `\(question.id)`] \(header)\(question.question)")
            if let context = Self.nonEmpty(question.context) {
                lines.append("   Context: \(context)")
            }
            lines.append("   Selection: \(Self.selectionConstraint(for: question))")
            for option in question.options {
                if let description = Self.nonEmpty(option.description) {
                    lines.append("   - \(option.label) — \(description)")
                } else {
                    lines.append("   - \(option.label)")
                }
            }
        }
        return lines
    }

    /// Structured entry carried under `AgentDelegatedQuestionNoticeWire.resultKey`. The `text`
    /// field is the rendered block so the formatter never re-derives notice wording.
    func wireValue() -> Value {
        var object: [String: Value] = [
            "kind": .string(AgentDelegatedQuestionNoticeWire.entryKind),
            "child_session_id": .string(key.childSessionID.uuidString),
            "child_session_name": .string(childSessionName),
            "interaction_id": .string(key.interactionID.uuidString),
            "guidance": .string(guidanceText),
            "questions": .array(questions.map { question in
                var questionObject: [String: Value] = [
                    "id": .string(question.id),
                    "question": .string(question.question),
                    "allows_multiple": .bool(question.allowsMultiple),
                    "allows_custom": .bool(question.allowsCustom),
                    "options": .array(question.options.map { option in
                        var optionObject: [String: Value] = ["label": .string(option.label)]
                        if let description = option.description {
                            optionObject["description"] = .string(description)
                        }
                        return .object(optionObject)
                    })
                ]
                if let header = question.header {
                    questionObject["header"] = .string(header)
                }
                if let context = question.context {
                    questionObject["context"] = .string(context)
                }
                return .object(questionObject)
            }),
            "text": .string(renderedText)
        ]
        if let title {
            object["title"] = .string(title)
        }
        if let context {
            object["context"] = .string(context)
        }
        return .object(object)
    }

    private static func selectionConstraint(for question: Question) -> String {
        let choice = if question.options.isEmpty {
            "free-form answer"
        } else if question.allowsMultiple {
            "choose any number of options"
        } else {
            "choose one option"
        }
        let custom = question.allowsCustom ? "custom answer allowed" : "custom answer not allowed"
        return "\(choice); \(custom)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Wire constants and pure helpers shared by the Agent Mode delivery registry and the MCP
/// result path (`MCPServerViewModel.runTool`, `ToolOutputFormatter`, wait services).
package enum AgentDelegatedQuestionNoticeWire {
    /// Dedicated root key on an object tool result carrying `[AgentDelegatedQuestionNoticePayload.wireValue()]`.
    /// Reserved runtime metadata, never tool data; also an optional property of every MCP
    /// `outputSchema` (`MCPToolOutputSchemas.delegatedQuestionNotices`).
    package static let resultKey = "delegated_question_notices"
    /// Per-entry `kind` discriminator.
    static let entryKind = "delegated_question"
    /// `agent_run` wait result when woken early by a pending child question.
    package static let agentRunWaitResult = "interrupted_by_child_question"
    /// `ask_oracle` bounded-wait `_meta.wake_reason` for a child-question wake.
    package static let oracleWakeReason = "delegated_question"
    /// `ask_oracle` pending `reason` for a child-question wake (steering keeps its own reason).
    package static let oraclePendingReason = "interrupted_by_child_question"
    /// First line of every rendered notice block.
    static let noticeHeader = "[RepoPrompt runtime notice: delegated child question — not user input]"
    /// First line of every persistence-only covered-question record
    /// (`AgentDelegatedQuestionNoticePayload.coveredRecordText`).
    static let coveredRecordHeader = "[RepoPrompt runtime record: delegated child question delivered in an agent_run result — not user input]"
    /// Tag name of the block wrapping next-turn notices in a parent's provider input.
    package static let runtimeNoticeTagName = "repoprompt_runtime_notice"

    /// Explicit allowlist of RepoPrompt MCP tools whose object results may carry notices in
    /// `resultKey`. Excludes tools whose results the app or model parses structurally without
    /// a dedicated field (`ask_user`, `apply_edits`) and mutating or side-effect tools. Bounded
    /// waits (`ask_oracle`, `oracle_send`, `agent_run`) are included: their results are the
    /// natural handoff point for a parent blocked in them.
    static let eligibleToolNames: Set<String> = [
        MCPWindowToolName.readFile,
        MCPWindowToolName.search,
        MCPWindowToolName.getFileTree,
        MCPWindowToolName.getCodeStructure,
        MCPWindowToolName.manageSelection,
        MCPWindowToolName.workspaceContext,
        MCPWindowToolName.prompt,
        MCPWindowToolName.git,
        MCPWindowToolName.gitReviewSnapshot,
        MCPWindowToolName.oracleUtils,
        MCPWindowToolName.oracleChatLog,
        MCPWindowToolName.askOracle,
        MCPWindowToolName.oracleSend,
        MCPWindowToolName.agentRun,
        MCPWindowToolName.agentManage,
        MCPWindowToolName.history,
        // The parent attaches notices once after its children; children never reserve them.
        MCPWindowToolName.codeMode
    ]

    package static func isEligible(toolName: String) -> Bool {
        eligibleToolNames.contains(toolName)
    }

    /// Returns `value` with `payloads` appended under `resultKey`, preserving every original
    /// key. Returns nil when `value` is not an object or `payloads` is empty, so callers never
    /// consume a notice they could not attach.
    package static func attaching(_ payloads: [AgentDelegatedQuestionNoticePayload], to value: Value) -> Value? {
        guard !payloads.isEmpty, case var .object(object) = value else { return nil }
        var entries = object[resultKey]?.arrayValue ?? []
        entries.append(contentsOf: payloads.map { $0.wireValue() })
        object[resultKey] = .array(entries)
        return .object(object)
    }

    /// Splits a tool result into the original payload (without `resultKey`) and the joined
    /// rendered notice text, if any. Non-object values pass through unchanged.
    package static func splitting(_ value: Value) -> (original: Value, noticeText: String?) {
        guard case var .object(object) = value,
              let entries = object.removeValue(forKey: resultKey)
        else {
            return (value, nil)
        }
        let texts = (entries.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }
        return (.object(object), texts.isEmpty ? nil : renderedText(texts))
    }

    /// Returns `value` without the notice entries for `keys` (matched by child session and
    /// interaction ID), dropping `resultKey` once no entry remains. Every other key and value
    /// passes through unchanged. Used at the final result handoff to remove notices that are no
    /// longer deliverable (plan §6.2).
    package static func removing(_ keys: Set<AgentDelegatedQuestionNoticeKey>, from value: Value) -> Value {
        guard !keys.isEmpty,
              case var .object(object) = value,
              let entries = object[resultKey]?.arrayValue
        else {
            return value
        }
        let kept = entries.filter { entry in
            guard let key = noticeKey(of: entry) else { return true }
            return !keys.contains(key)
        }
        guard kept.count != entries.count else { return value }
        if kept.isEmpty {
            object.removeValue(forKey: resultKey)
        } else {
            object[resultKey] = .array(kept)
        }
        return .object(object)
    }

    /// Joined rendered text of the notice entries for `keys` in `value`, in entry order, or nil
    /// when none is present. Used to record exactly the notices committed at a result handoff.
    package static func renderedText(for keys: Set<AgentDelegatedQuestionNoticeKey>, in value: Value) -> String? {
        guard !keys.isEmpty, let entries = value.objectValue?[resultKey]?.arrayValue else { return nil }
        let texts = entries.compactMap { entry -> String? in
            guard let key = noticeKey(of: entry), keys.contains(key) else { return nil }
            return entry.objectValue?["text"]?.stringValue
        }
        return texts.isEmpty ? nil : renderedText(texts)
    }

    /// Identity of one structured notice entry, when well-formed.
    static func noticeKey(of entry: Value) -> AgentDelegatedQuestionNoticeKey? {
        guard let object = entry.objectValue,
              let childSessionID = object["child_session_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let interactionID = object["interaction_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        else {
            return nil
        }
        return AgentDelegatedQuestionNoticeKey(childSessionID: childSessionID, interactionID: interactionID)
    }

    /// Neutralizes every `<repoprompt_runtime_notice` / `</repoprompt_runtime_notice` opener
    /// (case-insensitive, optional inner whitespace) by replacing its `<` with `‹`, so text a
    /// child controls (session name, title, questions, options) can never close the next-turn
    /// wrapper early or open a nested one (plan §6.2, OracleB finding 3).
    package static func neutralizingRuntimeNoticeDelimiters(_ text: String) -> String {
        guard text.range(of: runtimeNoticeTagName, options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(
                  pattern: "<(\\s*/?\\s*\(runtimeNoticeTagName))",
                  options: [.caseInsensitive]
              )
        else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "‹$1")
    }

    /// Joined notice block for one delivery (tool result or turn input).
    package static func renderedText(for payloads: [AgentDelegatedQuestionNoticePayload]) -> String? {
        let texts = payloads.map(\.renderedText)
        return texts.isEmpty ? nil : renderedText(texts)
    }

    /// Joined persistence-only record of the covered questions committed by one result handoff.
    package static func coveredRecordText(for payloads: [AgentDelegatedQuestionNoticePayload]) -> String? {
        let texts = payloads.map(\.coveredRecordText)
        return texts.isEmpty ? nil : renderedText(texts)
    }

    private static func renderedText(_ texts: [String]) -> String {
        texts.joined(separator: "\n\n")
    }
}
