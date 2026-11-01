@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class AskUserQuestionPresentationTests: XCTestCase {
    func testStructuredExchangePreservesContextOptionsAndCustomResponse() throws {
        let args = #"""
        {
          "title": "Decision",
          "context": "Shared context\nSecond shared line",
          "questions": [
            {
              "id": "mode",
              "header": "Mode",
              "question": "Which mode?\nConsider the tradeoffs.",
              "context": "Question context\nSecond context line",
              "options": [
                "Quick",
                {"label": "Careful", "description": "More analysis\nSecond description line"},
                {"label": "Audit", "description": null}
              ]
            },
            {
              "id": "scope",
              "question": "Which areas?",
              "options": [{"label": "UI", "description": "Presentation"}, "Runtime"]
            }
          ]
        }
        """#
        let result = #"""
        {
          "answers": {
            "mode": {
              "answers": ["Careful", "Additional constraints\nPreserve the details"],
              "selected_options": ["Careful"],
              "custom_response": "Additional constraints\nPreserve the details",
              "skipped": false
            },
            "scope": {
              "selected_options": ["UI", "Runtime"],
              "custom_response": "Keep pending UI unchanged"
            }
          }
        }
        """#

        let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

        XCTAssertFalse(summary.isHistoricalScalar)
        XCTAssertFalse(summary.skipped)
        XCTAssertFalse(summary.timedOut)
        XCTAssertNil(summary.statusText)
        XCTAssertEqual(summary.title, "Decision")
        XCTAssertEqual(summary.displayTitle, "Decision (2 questions)")
        XCTAssertEqual(summary.contextLine, "Shared context\nSecond shared line")
        XCTAssertEqual(summary.questions.count, 2)

        let mode = try XCTUnwrap(summary.questions.first)
        XCTAssertEqual(mode.id, "mode")
        XCTAssertEqual(mode.header, "Mode")
        XCTAssertEqual(mode.question, "Which mode?\nConsider the tradeoffs.")
        XCTAssertEqual(mode.context, "Question context\nSecond context line")
        XCTAssertEqual(mode.options.map(\.label), ["Quick", "Careful", "Audit"])
        XCTAssertEqual(mode.options.map(\.description), [nil, "More analysis\nSecond description line", nil])
        XCTAssertEqual(mode.options.map(\.isSelected), [false, true, false])
        XCTAssertEqual(mode.answer, "Careful, Additional constraints\nPreserve the details")
        XCTAssertEqual(mode.customResponse, "Additional constraints\nPreserve the details")
        XCTAssertFalse(mode.skipped)

        let scope = try XCTUnwrap(summary.questions.last)
        XCTAssertEqual(scope.id, "scope")
        XCTAssertNil(scope.header)
        XCTAssertNil(scope.context)
        XCTAssertEqual(scope.options.map(\.label), ["UI", "Runtime"])
        XCTAssertEqual(scope.options.map(\.description), ["Presentation", nil])
        XCTAssertEqual(scope.options.map(\.isSelected), [true, true])
        XCTAssertEqual(scope.answer, "UI, Runtime, Keep pending UI unchanged")
        XCTAssertEqual(scope.customResponse, "Keep pending UI unchanged")
        XCTAssertFalse(scope.skipped)
    }

    func testMalformedOptionalEntriesDoNotDiscardQuestionOrAnswerText() throws {
        let args = #"""
        {
          "title": [],
          "context": true,
          "questions": [{
            "id": 27,
            "header": {},
            "question": "Keep this question",
            "context": {"unexpected": "shape"},
            "options": [
              null, false, 15,
              {"description": "Missing label"},
              {"label": 25},
              " ",
              {"label": " \t "},
              "First",
              {"label": "Second", "description": "Second details"},
              {"label": "Third", "description": false}
            ]
          }]
        }
        """#
        let result = #"""
        {
          "answers": {
            "question_1": {
              "answers": ["First", null, 17, "Stored answer", false],
              "selected_options": [false, "Second", 77, null],
              "custom_response": {},
              "skipped": "invalid"
            }
          },
          "timed_out": {},
          "skipped": [],
          "response": 21
        }
        """#

        let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

        XCTAssertFalse(summary.isHistoricalScalar)
        XCTAssertNil(summary.title)
        XCTAssertNil(summary.contextLine)
        XCTAssertNil(summary.statusText)
        XCTAssertFalse(summary.skipped)
        XCTAssertFalse(summary.timedOut)
        XCTAssertEqual(summary.questions.count, 1)
        let question = try XCTUnwrap(summary.questions.first)
        XCTAssertEqual(question.id, "question_1")
        XCTAssertNil(question.header)
        XCTAssertEqual(question.question, "Keep this question")
        XCTAssertNil(question.context)
        XCTAssertEqual(question.options.map(\.label), ["First", "Second", "Third"])
        XCTAssertEqual(question.options.map(\.description), [nil, "Second details", nil])
        XCTAssertEqual(question.options.map(\.isSelected), [false, true, false])
        XCTAssertEqual(question.answer, "First, Stored answer")
        XCTAssertNil(question.customResponse)
        XCTAssertFalse(question.skipped)
    }

    func testMalformedOptionalContainersAndSiblingEntriesPreserveValidExchange() throws {
        let args = #"""
        {
          "question": [],
          "questions": [
            null,
            true,
            {
              "id": "first",
              "question": "First question",
              "context": "First context",
              "options": {"invalid": "container"}
            },
            {"question": 25},
            {
              "id": "second",
              "question": "Second question",
              "options": ["Kept"]
            }
          ]
        }
        """#
        let result = #"""
        {
          "answers": {
            "first": {
              "answers": ["First answer"],
              "selected_options": "invalid",
              "custom_response": [],
              "skipped": {}
            },
            "second": {
              "answers": "invalid",
              "selected_options": ["Kept"],
              "custom_response": "Second detail",
              "skipped": false
            },
            "unreadable": 7
          },
          "response": []
        }
        """#

        let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

        XCTAssertFalse(summary.isHistoricalScalar)
        XCTAssertEqual(summary.questions.map(\.id), ["first", "second"])
        XCTAssertEqual(summary.questions.map(\.question), ["First question", "Second question"])
        XCTAssertEqual(summary.questions.map(\.answer), ["First answer", "Kept, Second detail"])

        let first = try XCTUnwrap(summary.questions.first)
        XCTAssertEqual(first.context, "First context")
        XCTAssertTrue(first.options.isEmpty)
        XCTAssertNil(first.customResponse)

        let second = try XCTUnwrap(summary.questions.last)
        XCTAssertEqual(second.options.map(\.label), ["Kept"])
        XCTAssertEqual(second.options.map(\.isSelected), [true])
        XCTAssertEqual(second.customResponse, "Second detail")
    }

    func testMalformedLeadingSiblingPreservesImplicitQuestionIDAndAnswer() throws {
        let args = #"{"questions":[null,{"question":"Second?","options":["Yes","No"]}]}"#
        let result = #"""
        {
          "answers": {
            "question_1": {
              "answers": ["Wrong sibling answer"],
              "selected_options": ["No"]
            },
            "question_2": {
              "answers": ["Yes"],
              "selected_options": ["Yes"],
              "custom_response": "Second detail"
            }
          }
        }
        """#

        let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

        XCTAssertFalse(summary.isHistoricalScalar)
        XCTAssertEqual(summary.questions.count, 1)
        let question = try XCTUnwrap(summary.questions.first)
        XCTAssertEqual(question.id, "question_2")
        XCTAssertEqual(question.question, "Second?")
        XCTAssertEqual(question.answer, "Yes")
        XCTAssertEqual(question.customResponse, "Second detail")
        XCTAssertEqual(question.options.map(\.label), ["Yes", "No"])
        XCTAssertEqual(question.options.map(\.isSelected), [true, false])
        XCTAssertFalse(question.skipped)
    }

    /// Contract change: answers for a malformed (discarded) question sibling are no longer hidden. They stay
    /// off the surviving question and appear as unmatched saved answers labeled by their answer ID.
    func testMalformedSiblingAnswerRemainsVisibleWithoutPositionalMatching() {
        let args = #"{"questions":[null,{"question":"Second?","options":["Yes","No"]}]}"#
        let result = #"{"answers":{"question_1":{"answers":["Wrong sibling answer"]},"question_2":{"answers":["Yes"]}}}"#

        let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

        XCTAssertEqual(summary.questions.map(\.id), ["question_2"])
        XCTAssertEqual(summary.questions.map(\.answer), ["Yes"])
        XCTAssertEqual(summary.unmatchedAnswers.map(\.id), ["question_1"])
        XCTAssertEqual(summary.unmatchedAnswers.map(\.answer), ["Wrong sibling answer"])
        XCTAssertFalse(summary.isQuestionTextUnavailable)
        XCTAssertNotNil(summary.unmatchedAnswersCaption)
    }

    /// A completed exchange whose arguments were lost still shows every saved answer, by answer ID, without
    /// inventing question text; it is not rendered as a historical scalar "No response" card.
    func testAnswersOnlyExchangeShowsSavedAnswersByID() {
        let result = #"""
        {
          "answers": {
            "stop_blocks_send": {"selected_options": ["Yes"], "custom_response": "Only while offline"},
            "actions": {"answers": ["Ship"], "selected_options": ["Ship"]},
            "notice": {"skipped": true}
          },
          "timed_out": false
        }
        """#

        for args in [nil, "", #"{"questions":[null, 7]}"#] {
            let label = args ?? "nil"
            let summary = parseAskUserQuestionSummaryRobust(args: args, result: result)

            XCTAssertFalse(summary.isHistoricalScalar, label)
            XCTAssertTrue(summary.questions.isEmpty, label)
            XCTAssertTrue(summary.isQuestionTextUnavailable, label)
            XCTAssertEqual(summary.displayTitle, "Saved answers (3)", label)
            XCTAssertEqual(summary.unmatchedAnswers.map(\.id), ["actions", "notice", "stop_blocks_send"], label)
            XCTAssertEqual(summary.unmatchedAnswers.map(\.answer), ["Ship", "Skipped", "Yes, Only while offline"], label)
            XCTAssertEqual(summary.unmatchedAnswers.map(\.skipped), [false, true, false], label)
            XCTAssertEqual(summary.unmatchedAnswers.map(\.customResponse), [nil, nil, "Only while offline"], label)
            XCTAssertEqual(
                summary.unmatchedAnswersCaption,
                "Question text unavailable. Saved answers are shown by answer ID.",
                label
            )
            XCTAssertNil(summary.statusText, label)
        }
    }

    /// Saved questions whose IDs match none of the saved answers keep their text, do not claim "No response",
    /// and the surviving answers remain visible separately.
    func testMismatchedAndPartiallyMatchedAnswersRemainVisible() {
        let args = #"{"questions":[{"id":"stop_blocks_send","question":"Block sends?"},{"id":"notice","question":"Notice style?"}]}"#

        let mismatched = parseAskUserQuestionSummaryRobust(
            args: args,
            result: #"{"answers":{"actions":{"answers":["Ship"]}}}"#
        )
        XCTAssertFalse(mismatched.isHistoricalScalar)
        XCTAssertEqual(mismatched.questions.map(\.question), ["Block sends?", "Notice style?"])
        XCTAssertEqual(mismatched.questions.map(\.answer), [nil, nil])
        XCTAssertEqual(mismatched.missingAnswerText, "No matching saved answer")
        XCTAssertEqual(mismatched.unmatchedAnswers.map(\.id), ["actions"])
        XCTAssertEqual(mismatched.unmatchedAnswers.map(\.answer), ["Ship"])
        XCTAssertEqual(
            mismatched.unmatchedAnswersCaption,
            "Saved answers that match none of the questions above, shown by answer ID."
        )

        let partial = parseAskUserQuestionSummaryRobust(
            args: args,
            result: #"{"answers":{"notice":{"answers":["Banner"]},"zeta":{"answers":["Orphan"]}}}"#
        )
        XCTAssertEqual(partial.questions.map(\.answer), [nil, "Banner"])
        XCTAssertEqual(partial.unmatchedAnswers.map(\.id), ["zeta"])
        XCTAssertEqual(partial.unmatchedAnswers.map(\.answer), ["Orphan"])

        let matched = parseAskUserQuestionSummaryRobust(
            args: args,
            result: #"{"answers":{"notice":{"answers":["Banner"]}}}"#
        )
        XCTAssertTrue(matched.unmatchedAnswers.isEmpty)
        XCTAssertNil(matched.unmatchedAnswersCaption)
        XCTAssertEqual(matched.missingAnswerText, "No response")
    }

    /// Supported ToolJSON result envelopes decode the same answers-only exchange.
    func testAnswersOnlyExchangeDecodesSupportedResultEnvelopes() {
        let inner = #"{"answers":{"actions":{"answers":["Ship"]}},"timed_out":true}"#
        let escaped = inner.replacingOccurrences(of: "\"", with: "\\\"")
        let envelopes = [
            "direct": inner,
            "content text": #"{"content":[{"type":"text","text":"\#(escaped)"}]}"#,
            "structured content": #"{"structuredContent":\#(inner)}"#
        ]

        for (label, result) in envelopes {
            let summary = parseAskUserQuestionSummaryRobust(args: nil, result: result)
            XCTAssertTrue(summary.isQuestionTextUnavailable, label)
            XCTAssertEqual(summary.unmatchedAnswers.map(\.id), ["actions"], label)
            XCTAssertEqual(summary.unmatchedAnswers.map(\.answer), ["Ship"], label)
            XCTAssertTrue(summary.timedOut, label)
            XCTAssertEqual(summary.statusText, "Timed out", label)
        }
    }

    /// Review R3: mixed history (scalar arguments, structured answers) keeps the scalar question and can expand
    /// to show the surviving multiline answer in full; genuine scalar-only exchanges keep their fixed preview.
    func testScalarArgumentsWithStructuredAnswersCanExpandUnmatchedAnswers() {
        let scalarArgs = #"{"question":"Historical question"}"#
        let mixed = parseAskUserQuestionSummaryRobust(
            args: scalarArgs,
            result: #"{"answers":{"notes":{"answers":["Line one\nLine two\nLine three\nLine four"]}}}"#
        )
        XCTAssertTrue(mixed.isHistoricalScalar)
        XCTAssertEqual(mixed.questions.map(\.question), ["Historical question"])
        XCTAssertEqual(mixed.unmatchedAnswers.map(\.id), ["notes"])
        XCTAssertEqual(mixed.unmatchedAnswers.map(\.answer), ["Line one\nLine two\nLine three\nLine four"])
        XCTAssertTrue(mixed.allowsExpansion)

        let scalarOnly = parseAskUserQuestionSummaryRobust(args: scalarArgs, result: #"{"response":"Legacy answer"}"#)
        XCTAssertTrue(scalarOnly.isHistoricalScalar)
        XCTAssertTrue(scalarOnly.unmatchedAnswers.isEmpty)
        XCTAssertFalse(scalarOnly.allowsExpansion)

        let structured = parseAskUserQuestionSummaryRobust(
            args: #"{"questions":[{"id":"notes","question":"Notes?"}]}"#,
            result: #"{"answers":{"notes":{"answers":["Kept"]}}}"#
        )
        XCTAssertTrue(structured.allowsExpansion)
    }

    func testHistoricalScalarPayloadsRemainUnchanged() throws {
        let args = #"{"question":"  Historical question  ","title":"Ignored title","context":"Ignored context"}"#
        let cases: [(name: String, result: String?, answer: String, skipped: Bool, timedOut: Bool, status: String?)] = [
            ("submitted", #"{"response":"  Legacy answer  "}"#, "Legacy answer", false, false, nil),
            ("raw response", "  Raw response \n", "Raw response", false, false, nil),
            ("no response", nil, "No response", false, false, nil),
            ("skip takes precedence", #"{"response":"ignored","skipped":true,"timed_out":true}"#, "Skipped", true, true, "Skipped"),
            ("timeout with response", #"{"response":"Late response","timed_out":true}"#, "Late response", false, true, "Timed out"),
            ("timeout without response", #"{"timed_out":true}"#, "Timed out", false, true, "Timed out")
        ]

        for testCase in cases {
            let summary = parseAskUserQuestionSummaryRobust(args: args, result: testCase.result)

            XCTAssertTrue(summary.isHistoricalScalar, testCase.name)
            XCTAssertNil(summary.title, testCase.name)
            XCTAssertNil(summary.contextLine, testCase.name)
            XCTAssertEqual(summary.displayTitle, "Question", testCase.name)
            XCTAssertEqual(summary.statusText, testCase.status, testCase.name)
            XCTAssertEqual(summary.skipped, testCase.skipped, testCase.name)
            XCTAssertEqual(summary.timedOut, testCase.timedOut, testCase.name)
            XCTAssertEqual(summary.questions.count, 1, testCase.name)

            let question = try XCTUnwrap(summary.questions.first, testCase.name)
            XCTAssertEqual(question.id, "question", testCase.name)
            XCTAssertNil(question.header, testCase.name)
            XCTAssertEqual(question.question, "Historical question", testCase.name)
            XCTAssertNil(question.context, testCase.name)
            XCTAssertTrue(question.options.isEmpty, testCase.name)
            XCTAssertNil(question.customResponse, testCase.name)
            XCTAssertEqual(question.answer, testCase.answer, testCase.name)
            XCTAssertEqual(question.skipped, testCase.skipped, testCase.name)
        }
    }

    func testStructuredSkippedAndTimedOutSemanticsRemainUnchanged() throws {
        let args = #"{"questions":[{"id":"answer","question":"Decision?","context":"Details","options":["Yes","No"]}]}"#
        let cases: [(name: String, result: String, answer: String?, questionSkipped: Bool, skipped: Bool, timedOut: Bool, status: String?)] = [
            ("overall skip", #"{"skipped":true}"#, "Skipped", true, true, false, "Skipped"),
            ("question skip", #"{"answers":{"answer":{"skipped":true,"answers":[],"selected_options":[]}}}"#, "Skipped", true, false, false, nil),
            ("timeout without answer", #"{"timed_out":true}"#, "No response (timed out)", false, false, true, "Timed out"),
            ("empty answer", #"{"answers":{"answer":{"answers":[],"selected_options":[],"custom_response":" \n "}}}"#, "No response", false, false, false, nil),
            ("missing answer", "{}", nil, false, false, false, nil),
            ("timeout with answer", #"{"timed_out":true,"answers":{"answer":{"answers":["Late response"]}}}"#, "Late response", false, false, true, "Timed out")
        ]

        for testCase in cases {
            let summary = parseAskUserQuestionSummaryRobust(args: args, result: testCase.result)

            XCTAssertFalse(summary.isHistoricalScalar, testCase.name)
            XCTAssertEqual(summary.statusText, testCase.status, testCase.name)
            XCTAssertEqual(summary.skipped, testCase.skipped, testCase.name)
            XCTAssertEqual(summary.timedOut, testCase.timedOut, testCase.name)
            XCTAssertEqual(summary.questions.count, 1, testCase.name)
            let question = try XCTUnwrap(summary.questions.first, testCase.name)
            XCTAssertEqual(question.answer, testCase.answer, testCase.name)
            XCTAssertEqual(question.skipped, testCase.questionSkipped, testCase.name)
            XCTAssertNil(question.customResponse, testCase.name)
            XCTAssertEqual(question.options.map(\.isSelected), [false, false], testCase.name)
        }
    }
}
