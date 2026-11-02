import AppKit
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

@MainActor
final class ToolResultBodyPresentationTests: XCTestCase {
    private let longEventID = "evt_" + String(repeating: "0123456789abcdef", count: 6)

    private func present(
        _ payload: String?,
        toolName: String? = "mcp__busycal__list_events",
        argsJSON: String? = nil
    ) -> ToolResultBodyPresentation? {
        ToolResultMarkdownRenderer.presentation(
            toolName: toolName,
            argsJSON: argsJSON,
            resultPayload: payload,
            emitResources: false
        )
    }

    private func value(_ json: String) throws -> Value {
        try XCTUnwrap(Value.fromJSONString(json))
    }

    private func links(for presentation: ToolResultBodyPresentation) -> [String] {
        ToolScrollableMarkdownTextView.detectedFileLinks(
            in: presentation.text,
            enabled: presentation.detectsMarkdownFilePaths
        ).map(\.path)
    }

    func testNilEmptyAndWhitespacePayloadsHaveNoBody() {
        XCTAssertNil(present(nil))
        XCTAssertNil(present(""))
        XCTAssertNil(present(" \n\t "))
        XCTAssertNil(ToolResultMarkdownRenderer.cachedPresentation(
            toolName: nil,
            argsJSON: nil,
            resultPayload: nil
        ))
    }

    func testPlainTextStaysCanonicalWithPathDetection() throws {
        let presentation = try XCTUnwrap(present("  Wrote docs/report.md and `docs/Guide.md`\n"))

        XCTAssertEqual(presentation.kind, .canonicalText)
        XCTAssertEqual(presentation.text, "Wrote docs/report.md and `docs/Guide.md`")
        XCTAssertNil(presentation.rawPayloadForCopy)
        XCTAssertTrue(presentation.detectsMarkdownFilePaths)
        XCTAssertEqual(links(for: presentation), ["docs/report.md", "docs/Guide.md"])
    }

    func testMalformedJSONStaysCanonicalWithOnlyOuterWhitespaceTrimmed() throws {
        let interior = "{\"path\":  \"docs/x.md\",\n  \"id\":"
        let presentation = try XCTUnwrap(present("\n  " + interior + " \n"))

        XCTAssertEqual(presentation.kind, .canonicalText)
        XCTAssertEqual(presentation.text, interior, "Interior bytes are preserved; surrounding whitespace is trimmed")
        XCTAssertNil(presentation.rawPayloadForCopy)
    }

    func testGenericObjectRendersUnfencedStructuredJSONWithFullIDs() throws {
        let compact = """
        {"events":[{"id":"\(longEventID)","notes":"see docs/x.md","title":"Standup"}]}
        """
        let stored = compact + "\n"
        let presentation = try XCTUnwrap(present(stored))

        XCTAssertEqual(presentation.kind, .structuredJSON)
        try XCTAssertEqual(presentation.text, ToolOutputFormatter.prettyJSON(value(compact)))
        XCTAssertFalse(presentation.text.contains("```"))
        XCTAssertTrue(presentation.text.contains(longEventID))
        XCTAssertFalse(presentation.text.contains("…"))
        XCTAssertFalse(presentation.detectsMarkdownFilePaths)
        XCTAssertEqual(links(for: presentation), [])
        XCTAssertEqual(presentation.rawPayloadForCopy, stored, "Raw copy must be the untouched stored payload")
    }

    func testGenericArrayRendersStructuredJSON() throws {
        let payload = "[{\"id\":\"a\"},{\"id\":\"\(longEventID)\"}]"
        let presentation = try XCTUnwrap(present(payload, toolName: nil))

        XCTAssertEqual(presentation.kind, .structuredJSON)
        try XCTAssertEqual(presentation.text, ToolOutputFormatter.prettyJSON(value(payload)))
        XCTAssertTrue(presentation.text.contains(longEventID))
        XCTAssertEqual(presentation.rawPayloadForCopy, payload)
    }

    func testStructuredJSONStringsContainingDocPathsStayUnlinkedLikeTheFencedForm() throws {
        let payload = "{\"path\":\"docs/x.md\",\"html\":\"Sources/Page.html\"}"
        let presentation = try XCTUnwrap(present(payload))
        let fenced = try XCTUnwrap(ToolOutputFormatter.formatGeneric(value: value(payload)).first)
        guard case let .text(text: fencedText, annotations: _, _meta: _) = fenced else {
            return XCTFail("Generic formatter should emit text")
        }

        XCTAssertEqual(ToolResultMarkdownLinkifier.matches(in: fencedText), [], "Baseline: fenced JSON is code")
        XCTAssertEqual(presentation.kind, .structuredJSON)
        XCTAssertTrue(presentation.text.contains("docs/x.md"))
        XCTAssertEqual(links(for: presentation), [])
    }

    func testProviderAuthoredFenceInTransportTextStaysCanonicalVerbatim() throws {
        let text = "Result:\n```json\n{\"path\":\"docs/hidden.md\"}\n```\nSee docs/visible.md"
        let payload = try jsonString([
            "Ok": ["content": [["type": "text", "text": text]]]
        ])
        let presentation = try XCTUnwrap(present(payload))

        XCTAssertEqual(presentation.kind, .canonicalText)
        XCTAssertEqual(presentation.text, text)
        XCTAssertNil(presentation.rawPayloadForCopy)
        XCTAssertEqual(links(for: presentation), ["docs/visible.md"])
    }

    func testTransportJSONOnlyTextKeepsExactTextWithoutPathLinks() throws {
        let object = "{\"id\": \"\(longEventID)\",  \"notes\":\"see docs/report.md\"}"
        let array = "[\n  {\"path\": \"docs/a.md\"},\n  \"Sources/Page.html\"\n]"
        for text in [object, array] {
            let payload = try jsonString(["Ok": ["content": [["type": "text", "text": "\n" + text + "  "]]]])
            let presentation = try XCTUnwrap(present(payload), text)

            XCTAssertEqual(presentation.kind, .structuredJSON, text)
            XCTAssertEqual(presentation.text, text, "Provider text is kept exactly (outer trim only)")
            XCTAssertFalse(presentation.detectsMarkdownFilePaths, text)
            XCTAssertEqual(links(for: presentation), [], text)
            XCTAssertNil(presentation.rawPayloadForCopy, "Nothing was reserialized")
        }
        XCTAssertTrue(transported(object).text.contains(longEventID))
    }

    func testTransportProseFencesAndNonContainerJSONStayCanonicalWithLinks() {
        let controls: [(text: String, links: [String])] = [
            ("Event saved: see docs/report.md {\"id\":\"x\"}", ["docs/report.md"]),
            ("{\"id\":\"x\"}\n\nThen read docs/report.md", ["docs/report.md"]),
            ("```json\n{\"path\":\"docs/hidden.md\"}\n```", []),
            ("{\"path\": \"docs/x.md\"", ["docs/x.md"]),
            ("\"docs/x.md\"", ["docs/x.md"])
        ]
        for control in controls {
            let presentation = transported(control.text)

            XCTAssertEqual(presentation.kind, .canonicalText, control.text)
            XCTAssertEqual(presentation.text, control.text, control.text)
            XCTAssertEqual(links(for: presentation), control.links, control.text)
        }
    }

    func testEveryBlockJSONTransportSuppressesLinksButMixedProseDoesNot() throws {
        let jsonOnly = try jsonString(["Ok": ["content": [
            ["type": "text", "text": "{\"path\":\"docs/a.md\"}"],
            ["type": "text", "text": " [\"docs/b.md\"] "]
        ]]])
        let structured = try XCTUnwrap(present(jsonOnly))
        XCTAssertEqual(structured.kind, .structuredJSON)
        XCTAssertEqual(structured.text, "{\"path\":\"docs/a.md\"}\n\n[\"docs/b.md\"]")
        XCTAssertEqual(links(for: structured), [])
        XCTAssertNil(structured.rawPayloadForCopy)

        let mixed = try jsonString(["Ok": ["content": [
            ["type": "text", "text": "{\"path\":\"docs/a.md\"}"],
            ["type": "text", "text": "Saved docs/b.md"]
        ]]])
        let canonical = try XCTUnwrap(present(mixed))
        XCTAssertEqual(canonical.kind, .canonicalText)
        XCTAssertEqual(canonical.text, "{\"path\":\"docs/a.md\"}\n\nSaved docs/b.md")
        XCTAssertEqual(links(for: canonical), ["docs/a.md", "docs/b.md"], "Mixed bodies keep existing detection")
    }

    private func transported(_ text: String) -> ToolResultBodyPresentation {
        ToolResultMarkdownRenderer.transportPresentation(parts: [text])
            ?? ToolResultBodyPresentation(text: "", kind: .canonicalText, rawPayloadForCopy: nil)
    }

    func testMultipleTransportTextBlocksStayJoinedCanonical() throws {
        let payload = try jsonString([
            "Ok": ["content": [
                ["type": "text", "text": "first docs/a.md"],
                ["type": "image", "data": "AAAA", "mimeType": "image/png"],
                ["type": "text", "text": "second"]
            ]]
        ])
        let presentation = try XCTUnwrap(present(payload))

        XCTAssertEqual(presentation.kind, .canonicalText)
        XCTAssertEqual(presentation.text, "first docs/a.md\n\nsecond")
        XCTAssertEqual(links(for: presentation), ["docs/a.md"])
    }

    func testTransportDetectionReadsOriginalEnvelopeThatRawObjectHelperUnwraps() throws {
        let payload = try jsonString([
            "Ok": ["content": [
                ["type": "text", "text": "first"],
                ["type": "text", "text": "{\"id\":\"x\"}"]
            ]]
        ])

        XCTAssertNil(ToolRawJSON.object(from: payload)?["Ok"], "Precondition: the helper hides the envelope")
        XCTAssertEqual(
            ToolResultMarkdownRenderer.mcpTransportMarkdown(from: payload),
            "first\n\n{\"id\":\"x\"}"
        )
    }

    func testErrEnvelopeTransportTextStaysCanonical() throws {
        let payload = try jsonString([
            "Err": ["content": [
                ["type": "text", "text": "Failed: see docs/help.md"],
                ["type": "text", "text": "```\nstack\n```"]
            ]]
        ])
        let presentation = try XCTUnwrap(present(payload))

        XCTAssertEqual(presentation.kind, .canonicalText)
        XCTAssertEqual(presentation.text, "Failed: see docs/help.md\n\n```\nstack\n```")
        XCTAssertEqual(links(for: presentation), ["docs/help.md"])
    }

    func testBareCallResultTransportKeepsEveryTextBlock() throws {
        let jsonText = "{\"id\":\"\(longEventID)\"}"
        let payload = try jsonString([
            "content": [
                ["type": "text", "text": "Found 1 event"],
                ["type": "text", "text": jsonText]
            ],
            "isError": false
        ])
        let presentation = try XCTUnwrap(present(payload))

        XCTAssertEqual(presentation.kind, .canonicalText)
        XCTAssertEqual(presentation.text, "Found 1 event\n\n\(jsonText)")
        XCTAssertNil(presentation.rawPayloadForCopy)
    }

    func testBareCallResultWithStructuredContentKeepsStructuredExtraction() throws {
        let payload = try jsonString([
            "content": [["type": "text", "text": "summary"]],
            "structuredContent": ["id": longEventID]
        ])

        XCTAssertNil(ToolResultMarkdownRenderer.mcpTransportMarkdown(from: payload))
        let presentation = try XCTUnwrap(present(payload))
        XCTAssertEqual(presentation.kind, .structuredJSON)
        XCTAssertTrue(presentation.text.contains(longEventID))
        XCTAssertEqual(presentation.rawPayloadForCopy, payload)
    }

    func testStructuredSiblingsKeepExtractionPrecedenceForWrappedAndBareResults() throws {
        let structuredKeys = [
            "structuredContent",
            "structured_content",
            "structuredResult",
            "structured_result",
            "toolResult",
            "tool_result"
        ]
        let wrappers: [String?] = ["Ok", "ok", "Err", "err", nil]
        for wrapper in wrappers {
            for structuredKey in structuredKeys {
                let result: [String: Any] = [
                    "content": [["type": "text", "text": "Found one event"]],
                    structuredKey: ["id": longEventID, "title": "Standup"]
                ]
                let payloadObject = wrapper.map { [$0: result] as [String: Any] } ?? result
                let payload = try jsonString(payloadObject)
                let label = "wrapper=\(wrapper ?? "bare") key=\(structuredKey)"

                XCTAssertNil(ToolResultMarkdownRenderer.mcpTransportMarkdown(from: payload), label)
                let presentation = try XCTUnwrap(present(payload), label)
                XCTAssertEqual(presentation.kind, .structuredJSON, label)
                XCTAssertTrue(presentation.text.contains(longEventID), label)
                XCTAssertTrue(presentation.text.contains("Standup"), label)
                XCTAssertEqual(presentation.rawPayloadForCopy, payload, label)
            }
        }
    }

    func testExplicitNullStructuredSiblingsDoNotBlockTransportText() throws {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": "first"],
                ["type": "text", "text": "second"]
            ],
            "structuredContent": NSNull(),
            "isError": false
        ]
        for payloadObject in [["Ok": result], result] as [[String: Any]] {
            let payload = try jsonString(payloadObject)
            let presentation = try XCTUnwrap(present(payload))

            XCTAssertEqual(presentation.kind, .canonicalText, payload)
            XCTAssertEqual(presentation.text, "first\n\nsecond", payload)
            XCTAssertNil(presentation.rawPayloadForCopy, payload)
        }
    }

    func testStructuredContentBlocksDeferToExistingExtraction() throws {
        let payload = try jsonString([
            "Ok": ["content": [
                ["type": "json", "json": ["id": longEventID]],
                ["type": "text", "text": "summary"]
            ]]
        ])

        XCTAssertNil(ToolResultMarkdownRenderer.mcpTransportMarkdown(from: payload))
        let presentation = try XCTUnwrap(present(payload))
        XCTAssertEqual(presentation.kind, .structuredJSON)
        XCTAssertTrue(presentation.text.contains(longEventID))
        XCTAssertEqual(presentation.rawPayloadForCopy, payload)
    }

    func testStructuredKeyOnTextBlockDefersToExistingExtraction() throws {
        for key in ["json", "structuredContent", "structured_content"] {
            let payload = try jsonString(["Ok": ["content": [
                ["type": "text", "text": "Deleted", key: ["id": longEventID]]
            ]]])

            XCTAssertNil(ToolResultMarkdownRenderer.mcpTransportMarkdown(from: payload), key)
            let presentation = try XCTUnwrap(present(payload), key)
            XCTAssertEqual(presentation.kind, .structuredJSON, key)
            XCTAssertTrue(presentation.text.contains(longEventID), key)
            XCTAssertEqual(presentation.rawPayloadForCopy, payload, key)

            let nullPayload = try jsonString(["Ok": ["content": [
                ["type": "text", "text": "Deleted", key: NSNull()]
            ]]])
            let nullPresentation = try XCTUnwrap(present(nullPayload), key)
            XCTAssertEqual(nullPresentation.kind, .canonicalText, key)
            XCTAssertEqual(nullPresentation.text, "Deleted", key)
            XCTAssertNil(nullPresentation.rawPayloadForCopy, key)
        }
    }

    func testStructuredWrapperExtractionOffersFullStoredPayloadForCopy() throws {
        let payload = "{\"structuredContent\":{\"id\":\"\(longEventID)\"},\"meta\":{\"kept\":true}}"
        let presentation = try XCTUnwrap(present(payload))
        let extracted = try XCTUnwrap(ToolJSON.preferredStructuredResultJSON(from: payload))

        XCTAssertEqual(presentation.kind, .structuredJSON)
        try XCTAssertEqual(presentation.text, ToolOutputFormatter.prettyJSON(value(extracted)))
        XCTAssertFalse(presentation.text.contains("kept"), "Display follows the existing extraction")
        XCTAssertEqual(presentation.rawPayloadForCopy, payload, "Raw copy keeps the dropped wrapper data")
    }

    func testSpecializedFormatterOutputStaysCanonical() throws {
        let payload = "{\"action\":\"create\",\"path\":\"docs/new.md\",\"status\":\"ok\"}"
        let presentation = try XCTUnwrap(present(payload, toolName: "file_actions"))

        XCTAssertEqual(presentation.kind, .canonicalText)
        XCTAssertTrue(presentation.text.hasPrefix("## File Action"), presentation.text)
        XCTAssertNil(presentation.rawPayloadForCopy)
        XCTAssertEqual(links(for: presentation), ["docs/new.md"])
    }

    func testRawJSONArgumentOutputIsStructuredWithoutPathLinks() throws {
        let payload = "{\"b\":1,\"a\":\"docs/x.md\"}"
        let presentation = try XCTUnwrap(present(payload, argsJSON: "{\"_rawJSON\":true}"))

        XCTAssertEqual(presentation.kind, .structuredJSON)
        try XCTAssertEqual(presentation.text, ToolOutputFormatter.rawJSONString(value(payload)))
        XCTAssertEqual(links(for: presentation), [])
        XCTAssertEqual(presentation.rawPayloadForCopy, payload)
    }

    func testGeneratedJSONProvenanceRequiresExactGenericOutput() throws {
        let jsonValue = try value("{\"id\":\"x\"}")
        let generic = try XCTUnwrap(ToolOutputFormatter.formatGeneric(value: jsonValue).first)
        guard case let .text(text: genericText, annotations: _, _meta: _) = generic else {
            return XCTFail("Generic formatter should emit text")
        }

        XCTAssertEqual(
            ToolResultMarkdownRenderer.appGeneratedJSONDisplay(formattedText: genericText, value: jsonValue),
            ToolOutputFormatter.prettyJSON(jsonValue)
        )
        XCTAssertNil(
            ToolResultMarkdownRenderer.appGeneratedJSONDisplay(
                formattedText: genericText + "\n\nA delegated question is waiting.",
                value: jsonValue
            ),
            "Appended notices keep the canonical fenced text"
        )
        XCTAssertNil(
            ToolResultMarkdownRenderer.appGeneratedJSONDisplay(
                formattedText: "```json\n{\"other\":true}\n```",
                value: jsonValue
            ),
            "A fence that does not match the app's output for this value is not stripped"
        )
        XCTAssertNil(ToolResultMarkdownRenderer.appGeneratedJSONDisplay(formattedText: "## Heading", value: jsonValue))
    }

    func testCachedPresentationMatchesDirectBuild() {
        let payload = "{\"id\":\"\(longEventID)\"}"
        let emitResources = UserDefaults.standard.bool(forKey: "mcp.emitResourceContent")
        let direct = ToolResultMarkdownRenderer.presentation(
            toolName: "mcp__busycal__get_event",
            argsJSON: nil,
            resultPayload: payload,
            emitResources: emitResources
        )
        let cachedFirst = ToolResultMarkdownRenderer.cachedPresentation(
            toolName: "mcp__busycal__get_event",
            argsJSON: nil,
            resultPayload: payload
        )
        let cachedSecond = ToolResultMarkdownRenderer.cachedPresentation(
            toolName: "mcp__busycal__get_event",
            argsJSON: nil,
            resultPayload: payload
        )

        XCTAssertEqual(cachedFirst, direct)
        XCTAssertEqual(cachedSecond, direct)
    }

    private func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
