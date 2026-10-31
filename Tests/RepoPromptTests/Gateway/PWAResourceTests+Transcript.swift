import Foundation
import JavaScriptCore
@testable import RepoPromptAgentCore
@testable import RepoPromptGateway
import XCTest

/// Phone transcript paging, run through the shipped app.js in JavaScriptCore. A minimal
/// browser stub stands in for the DOM, and `sendCommand` is replaced by a scripted
/// transport that answers `get_log` with the agent_manage.get_log result shape:
/// oldest-first turns `[offset, offset + limit)` and the page as `transcript_xml`.
extension PWAResourceTests {
    func testTranscriptShowsGetLogXMLAsLiteralTextForEmptyAndShortSessions() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        XCTAssertEqual(harness.requests(), [.init(type: "get_log", session: "S", offset: 0, limit: 200)])
        let xml = "<user>Fix &lt;b&gt; please</user>\n<assistant>Done <b>bold</b> &amp; <script>x()</script></assistant>"
        let xmlLiteral = try harness.jsonString(xml)
        harness.run("""
        __calls[0].resolve({
          session_id: 'S', name: 'Phone', turn_offset: 0, turn_limit: 200, returned_turn_count: 1,
          total_turns: 1, completed_turn_count: 1, transcript_xml: \(xmlLiteral)
        });
        """)
        XCTAssertEqual(harness.transcript, xml, "transcript_xml is kept verbatim in Raw transcript, not as JSON metadata")
        XCTAssertEqual(harness.blocks().map(\.className), ["msg user", "msg assistant"])
        XCTAssertEqual(
            harness.blocks().map(\.text),
            ["YouFix &lt;b&gt; please", "AgentDone <b>bold</b> &amp; <script>x()</script>"],
            "the primary view shows labelled bodies verbatim: entities and tags are text"
        )
        XCTAssertEqual(harness.requests().count, 1, "a short session needs one page")
        XCTAssertTrue(harness.loadOlderDisabled)

        harness.run("refreshTranscript();")
        harness.answer(1, total: 0)
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 0, limit: 200))
        XCTAssertEqual(harness.transcript, "")
        XCTAssertEqual(harness.blocks().map(\.className), ["transcript-empty"], "an empty transcript says so")
        XCTAssertTrue(harness.loadOlderDisabled)
        harness.assertNoException()
    }

    func testNewestPageUsesTotalTurnsAndLoadOlderPrependsEarlierRanges() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        harness.answer(0, total: 450)
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 250, limit: 200))
        harness.answer(1, total: 450)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(250 ..< 450))
        XCTAssertEqual(harness.visibleTurns(), Array(250 ..< 450))
        XCTAssertFalse(harness.loadOlderDisabled)

        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 50, limit: 200))
        harness.answer(2, total: 450)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(50 ..< 450))
        XCTAssertEqual(harness.visibleTurns(), Array(50 ..< 450))

        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 0, limit: 50))
        harness.answer(3, total: 450)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(0 ..< 450), "no turn is repeated or skipped")
        XCTAssertEqual(harness.visibleTurns(), Array(0 ..< 450))
        XCTAssertTrue(harness.loadOlderDisabled)
        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().count, 4, "nothing is older than turn 0")

        // History browsing pauses background refresh; Refresh returns to the newest page
        // with one request at the known newest offset.
        harness.run("maybeRefreshTranscript();")
        XCTAssertEqual(harness.pendingTimerCount, 0)
        harness.run("refreshTranscript();")
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(250 ..< 450))
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 250, limit: 200))
        harness.answer(4, total: 450)
        XCTAssertEqual(harness.requests().count, 5)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(250 ..< 450))
        harness.assertNoException()
    }

    func testLiveRefreshFollowsNewestPageWhenItsOffsetIsAboveZero() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        harness.answer(0, total: 450)
        harness.answer(1, total: 450)

        harness.run("maybeRefreshTranscript();")
        XCTAssertEqual(harness.pendingTimerCount, 1, "a newest page at offset 250 is not history browsing")
        harness.run("__flushTimers();")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 250, limit: 200))
        harness.answer(2, total: 452)
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 252, limit: 200))
        harness.answer(3, total: 452)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(252 ..< 452))
        harness.assertNoException()
    }

    func testFailedOlderPageKeepsTheWindowAndCanBeRetried() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        harness.answer(0, total: 450)
        harness.answer(1, total: 450)

        harness.run("loadOlderTranscript();")
        XCTAssertTrue(harness.loadOlderDisabled, "one older page at a time")
        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().count, 3)
        let mutations = harness.mutations
        harness.run("__calls[2].reject(new Error('Timed out waiting for get_log.'));")
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(250 ..< 450))
        XCTAssertEqual(harness.visibleTurns(), Array(250 ..< 450))
        XCTAssertEqual(harness.mutations, mutations, "unchanged text leaves the transcript DOM alone")
        XCTAssertFalse(harness.loadOlderDisabled, "the button still follows request state when the text is unchanged")
        XCTAssertEqual(harness.run("String(state.transcriptStart) + ',' + state.transcriptBrowsing").toString(), "250,false")

        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 50, limit: 200))
        harness.answer(3, total: 450)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(50 ..< 450))
        harness.assertNoException(expectedLogFailures: ["get_log failed: Timed out waiting for get_log."])
    }

    func testOverlappingBackgroundRefreshesCommitAndRunOneTrailingLoad() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        // Session updates keep arriving while the first page is slow.
        for _ in 0 ..< 4 {
            harness.run("maybeRefreshTranscript(); __flushTimers();")
        }
        XCTAssertEqual(harness.requests().count, 1, "one newest-page load in flight at a time")
        harness.answer(0, total: 3)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(0 ..< 3), "the in-flight page commits")
        XCTAssertEqual(harness.requests().count, 2, "the coalesced refreshes run once afterwards")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 0, limit: 200))

        // Growth past one page while ticks continue: both requests of the load commit.
        harness.run("maybeRefreshTranscript(); __flushTimers();")
        harness.answer(1, total: 450)
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 250, limit: 200))
        harness.run("maybeRefreshTranscript(); __flushTimers();")
        XCTAssertEqual(harness.requests().count, 3)
        harness.answer(2, total: 450)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(250 ..< 450))
        XCTAssertEqual(harness.requests().count, 4)
        harness.answer(3, total: 450)
        XCTAssertEqual(harness.requests().count, 4, "the pending refresh is delivered once")
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(250 ..< 450))
        harness.assertNoException()
    }

    func testDroppedNewestLoadDoesNotReleaseTheNextLoad() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript(); maybeRefreshTranscript(); __flushTimers();")
        // Refresh drops the in-flight load and its pending refresh.
        harness.run("refreshTranscript();")
        XCTAssertEqual(harness.requests().count, 2)
        harness.answer(0, total: 5)
        XCTAssertEqual(harness.requests().count, 2, "the dropped load starts no trailing load")
        XCTAssertEqual(harness.transcript, "")
        harness.run("maybeRefreshTranscript(); __flushTimers();")
        XCTAssertEqual(harness.requests().count, 2, "the Refresh load is still the one in flight")
        harness.answer(1, total: 3)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(0 ..< 3))
        XCTAssertEqual(harness.requests().count, 3)
        harness.answer(2, total: 3)

        // A new session view drops the old session's in-flight load the same way.
        harness.run("loadTranscript(); maybeRefreshTranscript(); __flushTimers(); openSession('T');")
        let subscribe = try XCTUnwrap(harness.requests().lastIndex { $0.type == "subscribe" })
        harness.run("__calls[\(subscribe)].resolve({});")
        let poll = try XCTUnwrap(harness.requests().lastIndex { $0.type == "poll" })
        harness.run("__calls[\(poll)].resolve({ status: 'running' });")
        let sessionT = harness.requests().count - 1
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "T", offset: 0, limit: 200))
        harness.answer(3, total: 9)
        XCTAssertEqual(harness.requests().count, sessionT + 1)
        XCTAssertEqual(harness.transcript, "")
        harness.answer(sessionT, total: 2)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(0 ..< 2))
        XCTAssertEqual(harness.requests().count, sessionT + 1)
        harness.assertNoException()
    }

    func testOlderPageIsDroppedWhenTheNewestPageMovesTheWindow() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        harness.answer(0, total: 450)
        harness.answer(1, total: 450)
        harness.run("loadOlderTranscript(); loadTranscript();")
        XCTAssertEqual(harness.requests()[2], .init(type: "get_log", session: "S", offset: 50, limit: 200))
        harness.answer(3, total: 452)
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 252, limit: 200))
        harness.answer(4, total: 452)
        harness.answer(2, total: 452)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(252 ..< 452))
        XCTAssertEqual(harness.visibleTurns(), Array(252 ..< 452), "a stale older page adds nothing to the view")
        XCTAssertFalse(harness.loadOlderDisabled)
        XCTAssertEqual(harness.run("String(state.transcriptStart) + ',' + state.transcriptBrowsing").toString(), "252,false")
        harness.assertNoException()
    }

    func testStaleTranscriptResultsDoNotClobberTheCurrentView() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        harness.answer(0, total: 450)
        harness.answer(1, total: 450)

        // A newest page overtaken by a manual Refresh is dropped.
        harness.run("loadTranscript();")
        harness.run("refreshTranscript();")
        harness.answer(3, total: 451)
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 251, limit: 200))
        harness.answer(4, total: 451)
        harness.answer(2, total: 450)
        XCTAssertEqual(harness.requests().count, 5, "a stale page does not start a follow-up request")
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(251 ..< 451))

        // An older page overtaken by Refresh is dropped.
        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 51, limit: 200))
        harness.run("refreshTranscript();")
        harness.answer(6, total: 451)
        harness.answer(5, total: 451)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(251 ..< 451))
        XCTAssertFalse(harness.loadOlderDisabled)

        // A newest page that lands after the reader loaded older pages keeps the history.
        harness.run("loadTranscript(); loadOlderTranscript();")
        harness.answer(8, total: 451)
        harness.answer(7, total: 460)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(51 ..< 451))
        XCTAssertEqual(harness.requests().count, 9)

        // Pages for a session the view has left are dropped.
        harness.run("loadTranscript(); openSession('T');")
        let subscribe = try XCTUnwrap(harness.requests().lastIndex { $0.type == "subscribe" })
        harness.run("__calls[\(subscribe)].resolve({});")
        let poll = try XCTUnwrap(harness.requests().lastIndex { $0.type == "poll" })
        harness.run("__calls[\(poll)].resolve({ status: 'running' });")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "T", offset: 0, limit: 200))
        harness.answer(harness.requests().count - 1, total: 3)
        harness.answer(9, total: 451)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(0 ..< 3))
        XCTAssertEqual(harness.visibleTurns(), Array(0 ..< 3))
        harness.assertNoException()
    }

    // MARK: - Transcript presentation

    func testTranscriptSegmenterKeepsRawTextAndRecognizesSerializerRecords() throws {
        let harness = try PWATranscriptHarness()
        let pageA = """
        <transcript>
        <user>Fix &lt;b&gt; &amp; <script>x()</script> please</user>
        <assistant>Done <b>x</b>
        line two </assistant> mid-line
        end</assistant>
        <tool_call name="a&amp;b&quot;&lt;&gt;"/>
        <tool_call name="read_file">{"path":"x…</tool_call>
        <tool_result name="read_file" status="failed"/>
        <tool_result name="other" status="warning"/>
        <system>s1
        s2</system>
        <error>boom</error>
        <note>3 items omitted to fit 200 item budget.</note>
        </transcript>
        """
        let pageB = """
        <transcript>
        <user id="0F6A3C5E-1111-2222-3333-444455556666" ts="1730390400.125">hi</user>
        <tool_call name="grep" id="0F6A3C5E-1111-2222-3333-444455556666" ts="2.5"/>
        <tool_result name="grep" status="success"/>
        loose text
        <tool_call name="x"/> trailing
        </transcript>
        """ + "\n"
        let joined = pageA + "\n" + pageB
        for text in ["", "<transcript>\n</transcript>", "plain text, no wrapper", pageA, joined] {
            XCTAssertEqual(try harness.segments(text).map(\.raw).joined(), text, "segments reproduce the input exactly")
        }
        XCTAssertEqual(try harness.segments(""), [])
        XCTAssertEqual(try harness.segments("plain text, no wrapper").map(\.kind), ["raw"])

        let segments = try harness.segments(joined)
        XCTAssertEqual(segments.map(\.kind), [
            "wrapper", "user", "assistant", "tool", "tool", "result", "system", "error", "note", "wrapper",
            "wrapper", "user", "tool", "raw", "wrapper"
        ])
        XCTAssertEqual(segments[1].body, "Fix &lt;b&gt; &amp; <script>x()</script> please", "bodies are never decoded")
        XCTAssertEqual(segments[2].body, "Done <b>x</b>\nline two </assistant> mid-line\nend")
        XCTAssertEqual([segments[3].name, segments[3].args, segments[3].status], ["a&b\"<>", nil, nil])
        XCTAssertEqual([segments[4].name, segments[4].args, segments[4].status], ["read_file", "{\"path\":\"x…", "failed"])
        XCTAssertEqual([segments[5].name, segments[5].status], ["other", "warning"], "a result without its call stays a row")
        XCTAssertEqual(segments[6].body, "s1\ns2")
        XCTAssertEqual(segments[7].body, "boom")
        XCTAssertEqual(segments[8].body, "3 items omitted to fit 200 item budget.")
        XCTAssertEqual(segments[11].body, "hi", "optional id and ts attributes are accepted")
        XCTAssertEqual([segments[12].name, segments[12].status], ["grep", "success"])
        XCTAssertEqual(
            segments[13].raw,
            "loose text\n<tool_call name=\"x\"/> trailing\n",
            "unknown lines and a call line with trailing text stay visible"
        )
        harness.assertNoException()
    }

    func testTranscriptSegmenterKeepsFencedProtocolTextInBodiesAndFallsBackVisibly() throws {
        let harness = try PWATranscriptHarness()
        let fenced = """
        <transcript>
        <assistant>Example:
        ```xml
        <assistant>inner</assistant>
        <tool_call name="read_file">{"path":"a"}</tool_call>
        </assistant>
        <tool_call name="x"/>
        ```
        Run:
        ```sh
        ls
        ```</assistant>
        <user>next</user>
        </transcript>
        """
        let segments = try harness.segments(fenced)
        XCTAssertEqual(segments.map(\.raw).joined(), fenced)
        XCTAssertEqual(segments.map(\.kind), ["wrapper", "assistant", "user", "wrapper"], "fenced record lines are body text")
        XCTAssertEqual(segments[1].body?.hasSuffix("ls\n```"), true, "a fence closing on the record's last line still closes it")

        // An unclosed fence makes the record uncertain: it is shown verbatim, not hidden.
        let unclosed = "<transcript>\n<user>```\nunclosed</user>\n<assistant>ok</assistant>\n</transcript>"
        let fallback = try harness.segments(unclosed)
        XCTAssertEqual(fallback.map(\.kind), ["wrapper", "raw", "assistant", "wrapper"])
        XCTAssertEqual(fallback[1].raw, "<user>```\nunclosed</user>\n")
        let neverClosed = "<transcript>\n<user>never closed\n<assistant>ok</assistant>\n</transcript>"
        XCTAssertEqual(try harness.segments(neverClosed).map(\.kind), ["wrapper", "raw", "wrapper"])

        // Rendered: the example is code, with its protocol text visible and no tool disclosure.
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        try harness.answer(0, total: 2, xml: fenced)
        let blocks = harness.blocks()
        XCTAssertEqual(blocks.map(\.className), ["msg assistant", "msg user"])
        XCTAssertEqual(
            harness.run("$('transcript-view').childNodes[0].childNodes[1].childNodes.map(function (n) { return n.className; }).join(',')").toString(),
            "prose,code-block,prose,code-block"
        )
        XCTAssertEqual(
            harness.run("$('transcript-view').childNodes[0].childNodes[1].childNodes[1].textContent").toString(),
            "xml<assistant>inner</assistant>\n<tool_call name=\"read_file\">{\"path\":\"a\"}</tool_call>\n</assistant>\n<tool_call name=\"x\"/>"
        )
        harness.run("refreshTranscript();")
        try harness.answer(1, total: 2, xml: unclosed)
        XCTAssertEqual(harness.blocks().map(\.className), ["msg raw", "msg assistant"])
        XCTAssertEqual(harness.blocks().first?.text, "<user>```\nunclosed</user>", "uncertain text stays in the primary view")
        harness.assertNoException()
    }

    func testSpartanLogXMLRendersAsLabelledSectionsInThePhoneView() throws {
        let invocationID = UUID()
        let userText = "Show <b>bold</b> &lt;tags&gt;\nquoted: </user>\nthanks"
        let example = """
        Example:
        ```xml
        <assistant>inner</assistant>
        <tool_call name="read_file">{"path":"a"}</tool_call>
        </assistant>
        <tool_call name="x"/>
        ```
        Done.
        """
        let argsJSON = #"{"path":"Sources/a.swift"}"#
        let items: [AgentChatItem] = [
            .user(userText, sequenceIndex: 0),
            .assistant(example, sequenceIndex: 1),
            .system("first notice", sequenceIndex: 2),
            .system("second notice", sequenceIndex: 3),
            .toolCall(name: "read_file", invocationID: invocationID, argsJSON: argsJSON, sequenceIndex: 4),
            .toolResult(
                name: "read_file", invocationID: invocationID, argsJSON: argsJSON,
                resultJSON: "Error: missing", isError: true, sequenceIndex: 5
            ),
            .error("Something broke", sequenceIndex: 6),
            .assistant("Fixed & dusted.", sequenceIndex: 7)
        ]
        let transcript = AgentTranscriptIO.buildTranscript(
            from: items, terminalState: .completed, nextSequenceIndex: 8, compact: false
        )
        let xml = AgentTranscriptIO.buildSpartanLogXML(from: transcript)

        let harness = try PWATranscriptHarness()
        let segments = try harness.segments(xml)
        XCTAssertEqual(segments.map(\.raw).joined(), xml, "segments reproduce get_log output exactly")
        // The serializer folds this turn's system rows into a grouped summary that cuts the
        // narration's code fence off unclosed, so that record stays visible as raw text.
        XCTAssertEqual(
            segments.map(\.kind),
            ["wrapper", "user", "assistant", "raw", "tool", "error", "assistant", "wrapper"],
            xml
        )
        let records = segments.filter { $0.kind != "wrapper" }
        XCTAssertEqual(records.map(\.body), [userText, example, nil, nil, "Something broke", "Fixed & dusted."])
        XCTAssertTrue(records[2].raw.hasPrefix("<system>") && records[2].raw.hasSuffix("</system>\n"), records[2].raw)
        let callPrefix = "<tool_call name=\"read_file\">"
        // The last such line is the real call; the first is the assistant's fenced example.
        let callLine = try XCTUnwrap(xml.split(separator: "\n").last { $0.hasPrefix(callPrefix) })
        let serializedArgs = String(callLine.dropFirst(callPrefix.count).dropLast("</tool_call>".count))
        XCTAssertTrue(serializedArgs.contains("Sources"), serializedArgs)
        XCTAssertEqual([records[3].name, records[3].args, records[3].status], ["read_file", serializedArgs, "failed"])

        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        try harness.answer(0, total: 8, xml: xml)
        let blocks = harness.blocks()
        XCTAssertEqual(blocks.map(\.className), ["msg user", "msg assistant", "msg raw", "msg tool", "msg error", "msg assistant"])
        XCTAssertEqual(blocks.map(\.tag), ["div", "div", "pre", "details", "div", "div"], "only the real call is a disclosure")
        XCTAssertEqual(blocks[0].text, "You" + userText)
        XCTAssertTrue(blocks[1].text.contains("<tool_call name=\"read_file\">{\"path\":\"a\"}</tool_call>"))
        XCTAssertEqual(blocks[2].text + "\n", records[2].raw, "uncertain records are shown verbatim")
        XCTAssertEqual(blocks[3].text, "Toolread_filefailed" + serializedArgs)
        XCTAssertFalse(blocks[3].open, "tool arguments start collapsed")
        XCTAssertEqual(blocks[5].text, "AgentFixed & dusted.")
        XCTAssertEqual(harness.transcript, xml)
        harness.assertNoException()
    }

    func testTranscriptViewKeepsNodesAndDisclosuresAcrossRefreshesButNotSessions() throws {
        let harness = try PWATranscriptHarness()
        let tool = "<tool_call name=\"read_file\">{\"path\":\"a\"}</tool_call>\n<tool_result name=\"read_file\" status=\"success\"/>"
        let first = "<transcript>\n<user>go</user>\n\(tool)\n\(tool)\n</transcript>"
        let grown = "<transcript>\n<user>go</user>\n\(tool)\n\(tool)\n<assistant>done</assistant>\n</transcript>"
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        try harness.answer(0, total: 3, xml: first)
        XCTAssertEqual(harness.blocks().map(\.tag), ["div", "details", "details"])
        harness.run("var __saved = $('transcript-view').childNodes.slice(); __saved[2].open = true;")

        harness.run("maybeRefreshTranscript(); __flushTimers();")
        try harness.answer(1, total: 4, xml: grown)
        XCTAssertEqual(harness.blocks().map(\.open), [false, false, true, false], "an opened duplicate tool stays open alone")
        XCTAssertEqual(
            harness.run("__saved.every(function (node, i) { return $('transcript-view').childNodes[i] === node; })").toBool(),
            true,
            "unchanged records keep their nodes"
        )

        let mutations = harness.mutations
        harness.run("maybeRefreshTranscript(); __flushTimers();")
        try harness.answer(2, total: 4, xml: grown)
        XCTAssertEqual(harness.mutations, mutations, "an unchanged page does not touch the DOM")

        harness.run("openSession('T');")
        let subscribe = try XCTUnwrap(harness.requests().lastIndex { $0.type == "subscribe" })
        harness.run("__calls[\(subscribe)].resolve({});")
        let poll = try XCTUnwrap(harness.requests().lastIndex { $0.type == "poll" })
        harness.run("__calls[\(poll)].resolve({ status: 'running' });")
        try harness.answer(harness.requests().count - 1, total: 4, xml: grown)
        XCTAssertEqual(harness.blocks().map(\.open), [false, false, false, false], "another session starts closed")
        XCTAssertEqual(harness.run("$('transcript-view').childNodes[2] === __saved[2]").toBool(), false)
        harness.assertNoException()
    }

    func testTranscriptScrollKeepsTheReadersAnchorAndFollowsOnlyAtTheBottom() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        harness.answer(0, total: 450)
        harness.answer(1, total: 450)
        XCTAssertEqual(
            harness.scrollTop, 700 + 60 + 200 * 100 + 400 - 600,
            "the first page opens at the newest output, below the page and Load earlier"
        )

        // Reading mid-transcript: block 42 (turn 292) is the first block below the header.
        harness.run("document.scrollingElement.scrollTop = 5000;")
        XCTAssertEqual(harness.blockTop(42), -40)
        harness.run("loadOlderTranscript();")
        harness.answer(2, total: 450)
        XCTAssertEqual(harness.visibleTurns().count, 400)
        XCTAssertEqual(harness.scrollTop, 5000 + 200 * 100, "prepended turns keep turn 292 where it was")
        XCTAssertEqual(harness.blocks()[242].text, "Youturn 292")
        XCTAssertEqual(harness.blockTop(242), -40)

        let follow = try PWATranscriptHarness()
        follow.run("state.currentSessionId = 'S'; loadTranscript();")
        follow.answer(0, total: 3)
        XCTAssertEqual(follow.scrollTop, 700 + 3 * 100 + 400 - 600, "Load earlier stays hidden without older turns")
        // Typing in the composer: new output does not pull the page, and the field being
        // typed in stays where it is on screen while records arrive above it.
        follow.run("document.activeElement = $('composer-input');")
        let inputTop = "$('composer-input').getBoundingClientRect().top"
        XCTAssertEqual(follow.run(inputTop).toInt32(), 300)
        follow.run("maybeRefreshTranscript(); __flushTimers();")
        follow.answer(1, total: 5)
        XCTAssertEqual(follow.run(inputTop).toInt32(), 300, "the focused composer keeps its screen position")
        XCTAssertEqual(follow.scrollTop, 800 + 2 * 100, "no forced follow while the composer has focus")
        // Back at the bottom and not typing: new output is followed.
        follow.run("document.activeElement = document.body; document.scrollingElement.scrollTop = 100000;")
        follow.run("maybeRefreshTranscript(); __flushTimers();")
        follow.answer(2, total: 7)
        XCTAssertEqual(follow.scrollTop, 700 + 7 * 100 + 400 - 600)
        follow.assertNoException()
        harness.assertNoException()
    }

    func testFirstRecordsLandOnTheQuestionWhenTheAgentIsWaiting() throws {
        let harness = try PWATranscriptHarness()
        // Focus left in a hidden composer (an earlier session view) does not count as typing.
        harness.run("$('composer').classList.add('hidden'); document.activeElement = $('composer-input');")
        harness.run("$('interaction-box').classList.remove('hidden'); state.currentSessionId = 'S'; loadTranscript();")
        harness.answer(0, total: 200)
        XCTAssertEqual(harness.visibleTurns().count, 200)
        // The question sits below 200 blocks; it lands 8px under the 50px header.
        XCTAssertEqual(harness.scrollTop, 700 + 200 * 100 - 50 - 8)
        XCTAssertEqual(Int(harness.run("$('interaction-box').getBoundingClientRect().top").toInt32()), 58)

        // Later output does not pull a reader who moved away from the question. The window
        // rolls forward, so every record gets a fresh node and the document position is kept.
        harness.run("document.scrollingElement.scrollTop = 3000; var __first = $('transcript-view').childNodes.slice();")
        harness.run("maybeRefreshTranscript(); __flushTimers();")
        harness.answer(1, total: 201)
        harness.answer(2, total: 201)
        XCTAssertEqual(harness.visibleTurns(), Array(1 ..< 201))
        XCTAssertEqual(harness.run("__first.some(function (node) { return node.isConnected; })").toBool(), false)
        XCTAssertEqual(harness.scrollTop, 3000, "no record anchor is carried into a rolled window")
        harness.assertNoException()
    }

    func testFinalOlderPageHidesLoadEarlierWithoutMovingTheReader() throws {
        let harness = try PWATranscriptHarness()
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        harness.answer(0, total: 300)
        harness.answer(1, total: 300)
        // Block 22 (turn 122) is the first block below the header, 40px under it.
        harness.run("document.scrollingElement.scrollTop = 3000;")
        XCTAssertEqual(harness.blockTop(22), -40)

        harness.run("loadOlderTranscript();")
        harness.answer(2, total: 300)
        XCTAssertEqual(harness.visibleTurns(), Array(0 ..< 300))
        XCTAssertEqual(harness.run("$('load-older').classList.contains('hidden')").toBool(), true)
        XCTAssertEqual(harness.blocks()[122].text, "Youturn 122")
        XCTAssertEqual(harness.blockTop(122), -40, "100 prepended blocks and the hidden button are both corrected")
        XCTAssertEqual(harness.scrollTop, 3000 + 100 * 100 - 60)
        harness.assertNoException()
    }

    func testPrependedDuplicateRecordsKeepOnlyTheirOwnNodes() throws {
        let harness = try PWATranscriptHarness()
        let tool = "<tool_call name=\"read_file\">{\"path\":\"a\"}</tool_call>\n<tool_result name=\"read_file\" status=\"success\"/>"
        let page = "<transcript>\n<user>go</user>\n\(tool)\n</transcript>"
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        try harness.answer(0, total: 201, xml: page)
        try harness.answer(1, total: 201, xml: page)
        harness.run("var __newest = $('transcript-view').childNodes.slice(); __newest[1].open = true;")

        // The older page holds an identical copy of each record.
        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 0, limit: 1))
        try harness.answer(2, total: 201, xml: page)
        XCTAssertEqual(harness.blocks().map(\.className), ["msg user", "msg tool", "msg user", "msg tool"])
        XCTAssertEqual(harness.blocks().map(\.open), [false, false, false, true], "only the newest copy is open")
        XCTAssertEqual(
            harness.run("""
            var v = $('transcript-view').childNodes;
            [v[2] === __newest[0], v[3] === __newest[1], v[0] === __newest[0], v[1] === __newest[1]].join(',')
            """).toString(),
            "true,true,false,false",
            "the retained records keep their nodes; the older copies get fresh ones"
        )

        // A rolled newest window: no node is reused, not even for a record that occurs once
        // in both renders, and no open state moves to a repeat.
        let rolling = try PWATranscriptHarness()
        let first = "<transcript>\n<user>a</user>\n\(tool)\n\(tool)\n<user>b</user>\n</transcript>"
        let rolled = "<transcript>\n\(tool)\n<user>b</user>\n\(tool)\n<user>c</user>\n</transcript>"
        rolling.run("state.currentSessionId = 'S'; loadTranscript();")
        try rolling.answer(0, total: 201, xml: first)
        try rolling.answer(1, total: 201, xml: first)
        rolling.run("var __old = $('transcript-view').childNodes.slice(); __old[2].open = true;")
        rolling.run("maybeRefreshTranscript(); __flushTimers();")
        try rolling.answer(2, total: 202, xml: first)
        XCTAssertEqual(rolling.requests().last, .init(type: "get_log", session: "S", offset: 2, limit: 200))
        try rolling.answer(3, total: 202, xml: rolled)
        XCTAssertEqual(rolling.blocks().map(\.className), ["msg tool", "msg user", "msg tool", "msg user"])
        XCTAssertEqual(rolling.blocks().map(\.open), [false, false, false, false], "no open state moves to a repeat")
        XCTAssertEqual(
            rolling.run("""
            var v = $('transcript-view').childNodes;
            [v[1] === __old[3], __old.indexOf(v[0]), __old.indexOf(v[2]), __old.some(function (n) { return n.isConnected; })].join(',')
            """).toString(),
            "false,-1,-1,false"
        )
        harness.assertNoException()
        rolling.assertNoException()
    }

    func testAdvancedStartWithIdenticalTextRendersFreshNodesAndShowsLoadEarlier() throws {
        let harness = try PWATranscriptHarness()
        let tool = "<tool_call name=\"read_file\">{\"path\":\"a\"}</tool_call>\n<tool_result name=\"read_file\" status=\"success\"/>"
        let page = "<transcript>\n<user>same</user>\n\(tool)\n</transcript>"
        harness.run("state.currentSessionId = 'S'; loadTranscript();")
        try harness.answer(0, total: 200, xml: page)
        harness.run("var __old = $('transcript-view').childNodes.slice(); __old[1].open = true; document.scrollingElement.scrollTop = 500;")
        XCTAssertEqual(harness.run("$('load-older').classList.contains('hidden')").toBool(), true)

        // The newest window moves from turn 0 to turn 1 and its text is byte-identical.
        harness.run("maybeRefreshTranscript(); __flushTimers();")
        try harness.answer(1, total: 201, xml: page)
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 1, limit: 200))
        try harness.answer(2, total: 201, xml: page)
        XCTAssertEqual(harness.transcript, page)
        XCTAssertEqual(harness.run("$('load-older').classList.contains('hidden')").toBool(), false)
        XCTAssertEqual(harness.run("transcriptRender.start").toInt32(), 1, "the render records its new start turn")
        XCTAssertEqual(harness.blocks().map(\.open), [false, false], "no open state survives a moved window")
        XCTAssertEqual(harness.run("__old.some(function (n) { return n.isConnected; })").toBool(), false)
        XCTAssertEqual(harness.scrollTop, 500, "the document position is kept")

        // The opened tool rolls off the top while an identical call arrives at the bottom:
        // the new call starts closed and the reader at the top is not moved to it.
        let rolling = try PWATranscriptHarness()
        let first = "<transcript>\n\(tool)\n<user>m1</user>\n<user>m2</user>\n</transcript>"
        let rolled = "<transcript>\n<user>m1</user>\n<user>m2</user>\n\(tool)\n</transcript>"
        rolling.run("state.currentSessionId = 'S'; loadTranscript();")
        try rolling.answer(0, total: 201, xml: first)
        try rolling.answer(1, total: 201, xml: first)
        rolling.run("var __old = $('transcript-view').childNodes.slice(); __old[0].open = true; document.scrollingElement.scrollTop = 760;")
        XCTAssertEqual(rolling.blockTop(0), 0, "the opened tool is at the top of the screen")
        rolling.run("maybeRefreshTranscript(); __flushTimers();")
        try rolling.answer(2, total: 202, xml: first)
        try rolling.answer(3, total: 202, xml: rolled)
        XCTAssertEqual(rolling.blocks().map(\.className), ["msg user", "msg user", "msg tool"])
        XCTAssertEqual(rolling.blocks().map(\.open), [false, false, false])
        XCTAssertEqual(
            rolling.run("""
            var v = $('transcript-view').childNodes;
            [__old[0].isConnected, v[2] === __old[0]].join(',')
            """).toString(),
            "false,false"
        )
        XCTAssertEqual(rolling.scrollTop, 760, "the reader stays at the document position")
        harness.assertNoException()
        rolling.assertNoException()
    }

    func testTranscriptSegmenterNeverLetsATruncatedFenceSwallowLaterRecords() throws {
        let harness = try PWATranscriptHarness()
        // A grouped summary cut off inside a fence, then complete records.
        let truncated = """
        <transcript>
        <system>Explored codebase • read_file
        ```swift
        let x = 1…</system>
        <tool_call name="read_file">{"path":"a"}</tool_call>
        <tool_result name="read_file" status="success"/>
        <assistant>Here:
        ```js
        f()
        ```
        ok</assistant>
        <system>note</system>
        <user>next</user>
        </transcript>
        """
        let segments = try harness.segments(truncated)
        XCTAssertEqual(segments.map(\.raw).joined(), truncated)
        XCTAssertEqual(segments.map(\.kind), ["wrapper", "raw", "tool", "assistant", "system", "user", "wrapper"])
        XCTAssertEqual(segments[1].raw, "<system>Explored codebase • read_file\n```swift\nlet x = 1…</system>\n")
        XCTAssertEqual(segments[4].body, "note", "a later system record is not part of the cut-off summary")

        // Even when a later line outside the fence could close it, a cut-off summary is not
        // labelled System over the records after it. (The user record here never closes on
        // its own, so it stays raw to the end of the page, like any unclosed record.)
        let relabel = "<transcript>\n<system>Explored\n```swift\ncut\u{2026}</system>\n<user>q\n```\ndone</system>\n<assistant>ok</assistant>\n</transcript>"
        XCTAssertEqual(try harness.segments(relabel).map(\.kind), ["wrapper", "raw", "wrapper"])

        // An interrupted body whose fence never closes: each such record is raw text on its
        // own, and the records after it keep their labels.
        let interrupted = (0 ..< 300).map { "<assistant>a\($0)\n```\nx</assistant>\n<user>u\($0)</user>" }
        let page = "<transcript>\n" + interrupted.joined(separator: "\n") + "\n</transcript>"
        let interruptedSegments = try harness.segments(page)
        XCTAssertEqual(interruptedSegments.map(\.raw).joined(), page)
        XCTAssertEqual(
            interruptedSegments.map(\.kind),
            ["wrapper"] + Array(Array(repeating: ["raw", "user"], count: 300).joined()) + ["wrapper"]
        )

        // Uncertain records that would each scan the rest of a long page: the shared scan
        // budget runs out, and the fallback still covers one record at a time.
        let open = ["<user>u\n```js\nx</user>", "<error>e\n```js\nx</error>", "<note>n\n```js\nx</note>"]
        let tail = (0 ..< 3000).map { "<assistant>ok \($0)</assistant>" }
        let long = (["<transcript>"] + open + tail + ["</transcript>"]).joined(separator: "\n")
        let longSegments = try harness.segments(long)
        XCTAssertEqual(longSegments.map(\.raw).joined(), long)
        XCTAssertEqual(longSegments.map(\.kind), ["wrapper", "raw"] + Array(repeating: "assistant", count: 3000) + ["wrapper"])
        XCTAssertEqual(longSegments[1].raw, open.joined(separator: "\n") + "\n")
        harness.assertNoException()
    }

    func testHiddenComposerIsNotMeasuredAndIsSizedWhenShown() throws {
        let harness = try PWATranscriptHarness()
        harness.run("""
        var input = $('composer-input');
        Object.defineProperty(input, 'offsetParent', {
          get: function () { return $('composer').classList.contains('hidden') ? null : document.body; }
        });
        // Reading the content height is a layout pass: the page clamps to its new height.
        var __measured = 120;
        Object.defineProperty(input, 'scrollHeight', { get: function () { __reflow(); return __measured; } });
        input.offsetHeight = 46; input.clientHeight = 44;
        $('composer').classList.add('hidden');
        state.currentSessionId = 'S';
        state.sessions.set('S', { status: 'unknown' });
        input.value = 'a long kept draft';
        sizeComposer();
        renderSessionDetail();
        """)
        XCTAssertEqual(harness.run("String($('composer-input').style.height)").toString(), "undefined", "a hidden composer is not measured")

        harness.run("document.scrollingElement.scrollTop = 300; state.sessions.set('S', { status: 'running' }); renderSessionDetail();")
        XCTAssertEqual(harness.run("$('composer-input').style.height").toString(), "122px", "the kept draft is measured once shown")
        XCTAssertEqual(harness.run("$('composer-input').style.overflowY").toString(), "hidden")
        XCTAssertEqual(harness.scrollTop, 300)

        // At the bottom of the page, the momentary `auto` height shortens the page by 78px
        // and clamps the scroll position; it is put back once the height is restored.
        harness.run("document.scrollingElement.scrollTop = 100000;")
        XCTAssertEqual(harness.scrollTop, 700 + 356 + 122 - 600)
        harness.run("sizeComposer();")
        XCTAssertEqual(harness.scrollTop, 700 + 356 + 122 - 600, "measuring does not move the page")
        // When measuring did not move the page, the position is not written again.
        harness.run("document.scrollingElement.scrollTop = 300; var __writes = __scrollWrites; sizeComposer();")
        XCTAssertEqual(harness.run("__scrollWrites - __writes").toInt32(), 0, "no redundant scroll write")

        harness.run("__measured = 1000; sizeComposer();")
        XCTAssertEqual(harness.run("$('composer-input').style.height").toString(), "240px", "capped at 40% of the window")
        XCTAssertEqual(harness.run("$('composer-input').style.overflowY").toString(), "auto")
        harness.assertNoException()
    }
}

private final class PWATranscriptHarness {
    struct Request: Decodable, Equatable {
        let type: String
        let session: String?
        let offset: Int?
        let limit: Int?
    }

    /// A small tree-bearing DOM: child order, textContent, classes, attributes, `open`,
    /// `contains` and `isConnected`. Elements looked up by id count as attached to the
    /// document. Geometry is synthetic, not browser evidence: a 50px sticky header; 700px
    /// of page above the transcript; `#load-older` (60px unless hidden); one 100px block
    /// per `#transcript-view` child; `#interaction-box` (300px unless hidden); then the
    /// tail: 100px of page, `#composer-input` (its `style.height`, 44px when unset or
    /// `auto`) and 256px more. The window is 600px tall. scrollTop clamps on writes and on
    /// `__reflow()` (a layout pass, such as reading an element's size) like a browser, and
    /// writes are counted. Both `#load-older` and `#interaction-box` start hidden, as in
    /// index.html; `#composer-input` is a textarea inside `#composer`. Hidden elements and
    /// their descendants have no client rects.
    private static let browserStub = """
    var __elements = {};
    var __mutations = 0;
    function __detach(child) {
      var parent = child.parentNode;
      if (!parent) return;
      parent.childNodes.splice(parent.childNodes.indexOf(child), 1);
      child.parentNode = null;
      __mutations += 1;
    }
    function __node(tag, id) {
      var node = {
        tagName: String(tag || 'div').toUpperCase(), id: id || '', value: '', className: '', placeholder: '',
        type: '', disabled: false, open: false, dataset: {}, style: {}, attributes: {}, listeners: {},
        childNodes: [], parentNode: null, attached: false, _text: '',
        scrollHeight: 0, clientHeight: 0, offsetHeight: 0
      };
      node.classList = {
        contains: function (name) { return node.className.split(/\\s+/).indexOf(name) >= 0; },
        add: function (name) { if (!node.classList.contains(name)) node.className = (node.className + ' ' + name).trim(); },
        remove: function (name) {
          node.className = node.className.split(/\\s+/).filter(function (c) { return c && c !== name; }).join(' ');
        },
        toggle: function (name, force) {
          var on = force === undefined ? !node.classList.contains(name) : Boolean(force);
          if (on) node.classList.add(name); else node.classList.remove(name);
          return on;
        }
      };
      Object.defineProperty(node, 'textContent', {
        get: function () {
          return node.childNodes.length ? node.childNodes.map(function (c) { return c.textContent; }).join('') : node._text;
        },
        set: function (value) { node.childNodes.slice().forEach(__detach); node._text = String(value); }
      });
      Object.defineProperty(node, 'firstChild', { get: function () { return node.childNodes[0] || null; } });
      Object.defineProperty(node, 'nextSibling', {
        get: function () {
          var parent = node.parentNode;
          return parent ? parent.childNodes[parent.childNodes.indexOf(node) + 1] || null : null;
        }
      });
      Object.defineProperty(node, 'isConnected', {
        get: function () { for (var n = node; n; n = n.parentNode) if (n.attached) return true; return false; }
      });
      node.insertBefore = function (child, ref) {
        __detach(child);
        var index = ref ? node.childNodes.indexOf(ref) : -1;
        if (index < 0) node.childNodes.push(child); else node.childNodes.splice(index, 0, child);
        child.parentNode = node;
        __mutations += 1;
        return child;
      };
      node.appendChild = function (child) { return node.insertBefore(child, null); };
      node.append = function () { for (var i = 0; i < arguments.length; i += 1) node.appendChild(arguments[i]); };
      node.replaceChildren = function () { node.childNodes.slice().forEach(__detach); node.append.apply(null, arguments); };
      node.remove = function () { __detach(node); };
      node.contains = function (other) { for (var n = other; n; n = n.parentNode) if (n === node) return true; return false; };
      node.setAttribute = function (name, value) { node.attributes[name] = String(value); };
      node.getAttribute = function (name) { return name in node.attributes ? node.attributes[name] : null; };
      node.addEventListener = function (type, listener) { (node.listeners[type] = node.listeners[type] || []).push(listener); };
      node.getClientRects = function () {
        for (var n = node; n; n = n.parentNode) if (n.classList.contains('hidden')) return [];
        return [node.getBoundingClientRect()];
      };
      node.getBoundingClientRect = function () {
        if (node.id === 'app-header') return { top: 0, bottom: 50 };
        var y = -__scroller.scrollTop;
        if (node.id === 'load-older') return { top: y + 700, bottom: y + __viewTop() };
        var count = document.getElementById('transcript-view').childNodes.length;
        var questionHeight = __shown('interaction-box') ? 300 : 0;
        if (node.id === 'interaction-box') {
          var top = y + __viewTop() + count * 100;
          return { top: top, bottom: top + questionHeight };
        }
        if (node.id === 'composer-input') {
          var inputTop = y + __viewTop() + count * 100 + questionHeight + 100;
          return { top: inputTop, bottom: inputTop + __composerHeight() };
        }
        var parent = node.parentNode;
        if (!parent || parent.id !== 'transcript-view') return { top: 0, bottom: 0 };
        var blockTop = y + __viewTop() + parent.childNodes.indexOf(node) * 100;
        return { top: blockTop, bottom: blockTop + 100 };
      };
      return node;
    }
    function __shown(id) { return !document.getElementById(id).classList.contains('hidden'); }
    function __viewTop() { return 700 + (__shown('load-older') ? 60 : 0); }
    function __composerHeight() {
      var height = parseFloat(document.getElementById('composer-input').style.height);
      return isNaN(height) ? 44 : height;
    }
    var window = { innerHeight: 600, addEventListener: function () {} };
    var __scrollWrites = 0;
    var __scroller = { _top: 0 };
    Object.defineProperty(__scroller, 'scrollHeight', {
      get: function () {
        var count = document.getElementById('transcript-view').childNodes.length;
        return __viewTop() + count * 100 + (__shown('interaction-box') ? 300 : 0) + 356 + __composerHeight();
      }
    });
    Object.defineProperty(__scroller, 'scrollTop', {
      get: function () { return this._top; },
      set: function (value) {
        __scrollWrites += 1;
        this._top = Math.max(0, Math.min(value, this.scrollHeight - window.innerHeight));
      }
    });
    function __reflow() { __scroller._top = Math.max(0, Math.min(__scroller._top, __scroller.scrollHeight - window.innerHeight)); }
    var document = {
      visibilityState: 'hidden',
      body: __node('body'),
      scrollingElement: __scroller,
      getElementById: function (id) {
        if (!__elements[id]) { __elements[id] = __node('div', id); __elements[id].attached = true; }
        return __elements[id];
      },
      createElement: function (tag) { return __node(tag, ''); },
      addEventListener: function () {}
    };
    document.activeElement = document.body;
    document.getElementById('load-older').className = 'secondary block hidden';
    document.getElementById('interaction-box').className = 'hidden';
    document.getElementById('composer-input').tagName = 'TEXTAREA';
    document.getElementById('composer').appendChild(document.getElementById('composer-input'));
    var location = { search: '', protocol: 'https:', host: 'phone.test' };
    var navigator = {};
    var crypto = { randomUUID: function () { return 'request'; } };
    var WebSocket = { OPEN: 1 };
    var __timers = [];
    function setTimeout(callback) { __timers.push(callback); return __timers.length; }
    function clearTimeout() {}
    function __flushTimers() { __timers.splice(0).forEach(function (callback) { callback(); }); }
    function fetch() { return Promise.reject(new Error('No gateway in tests.')); }
    function URLSearchParams() { this.get = function () { return null; }; }
    function TextEncoder() { this.encode = function () { return new Uint8Array(0); }; }
    """

    private static let transportStub = """
    var __calls = [];
    sendCommand = function (frame) {
      return new Promise(function (resolve, reject) {
        __calls.push({ frame: frame, resolve: resolve, reject: reject });
      });
    };
    function __turns(from, to) {
      var lines = [];
      for (var turn = from; turn < to; turn += 1) lines.push('<user>turn ' + turn + '</user>');
      return lines.join('\\n');
    }
    function __answerXML(index, total, xml) {
      var call = __calls[index];
      call.resolve({
        session_id: call.frame.session_id, turn_offset: call.frame.payload.offset, turn_limit: call.frame.payload.limit,
        total_turns: total, completed_turn_count: total, transcript_xml: xml
      });
    }
    function __blocks() {
      return $('transcript-view').childNodes.map(function (node) {
        return { tag: node.tagName.toLowerCase(), className: node.className, text: node.textContent, open: node.open };
      });
    }
    function __answer(index, total) {
      var call = __calls[index];
      var offset = call.frame.payload.offset;
      var limit = call.frame.payload.limit;
      var end = Math.min(total, offset + limit);
      call.resolve({
        session_id: call.frame.session_id, turn_offset: offset, turn_limit: limit,
        returned_turn_count: Math.max(0, end - offset), total_turns: total, completed_turn_count: total,
        transcript_xml: __turns(offset, end)
      });
    }
    """

    let context: JSContext
    private var exceptions: [String] = []

    init() throws {
        let data = try XCTUnwrap(GatewayPWAResources.data(forAsset: "app.js"))
        let appJS = try XCTUnwrap(String(data: data, encoding: .utf8))
        context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { [weak self] _, exception in
            self?.exceptions.append(exception?.toString() ?? "unknown exception")
        }
        run(Self.browserStub)
        run(appJS)
        run(Self.transportStub)
        assertNoException()
    }

    static func turns(_ range: Range<Int>) -> String {
        range.map { "<user>turn \($0)</user>" }.joined(separator: "\n")
    }

    @discardableResult
    func run(_ script: String) -> JSValue {
        // JavaScriptCore drains promise jobs when the evaluation returns.
        context.evaluateScript(script)
    }

    func answer(_ index: Int, total: Int) {
        run("__answer(\(index), \(total));")
    }

    func requests() -> [Request] {
        let json = run("""
        JSON.stringify(__calls.map(function (call) {
          var payload = call.frame.payload || {};
          return { type: call.frame.type, session: call.frame.session_id, offset: payload.offset, limit: payload.limit };
        }))
        """).toString() ?? "[]"
        return decodeOrFail(json)
    }

    struct Block: Decodable, Equatable {
        let tag: String
        let className: String
        let text: String
        let open: Bool
    }

    struct Segment: Decodable, Equatable {
        let kind: String
        let raw: String
        var body: String?
        var name: String?
        var args: String?
        var status: String?
    }

    /// The exact text in the closed "Raw transcript" disclosure.
    var transcript: String {
        run("$('transcript').textContent").toString() ?? ""
    }

    /// The primary transcript view's top-level blocks, in order.
    func blocks(file: StaticString = #filePath, line: UInt = #line) -> [Block] {
        decodeOrFail(run("JSON.stringify(__blocks())").toString(), file: file, line: line)
    }

    /// The turn numbers of the visible user blocks (`<user>turn N</user>` fixtures).
    func visibleTurns() -> [Int] {
        blocks().filter { $0.className == "msg user" }.compactMap { Int($0.text.replacingOccurrences(of: "Youturn ", with: "")) }
    }

    func segments(_ text: String) throws -> [Segment] {
        try decode(run("JSON.stringify(segmentTranscript(\(jsonString(text))))").toString())
    }

    var mutations: Int {
        Int(run("__mutations").toInt32())
    }

    var scrollTop: Int {
        Int(run("document.scrollingElement.scrollTop").toInt32())
    }

    func answer(_ index: Int, total: Int, xml: String) throws {
        try run("__answerXML(\(index), \(total), \(jsonString(xml)));")
    }

    /// Bridge results must decode; a missing or malformed result is a test failure, not an
    /// empty list.
    private func decode<T: Decodable>(_ json: String?) throws -> [T] {
        let json = try XCTUnwrap(json, "the JavaScript bridge returned no JSON")
        return try JSONDecoder().decode([T].self, from: Data(json.utf8))
    }

    private func decodeOrFail<T: Decodable>(_ json: String?, file: StaticString = #filePath, line: UInt = #line) -> [T] {
        do {
            return try decode(json)
        } catch {
            XCTFail("undecodable bridge result \(json ?? "nil"): \(error)", file: file, line: line)
            return []
        }
    }

    /// The viewport top of the `index`th transcript block.
    func blockTop(_ index: Int) -> Int {
        Int(run("$('transcript-view').childNodes[\(index)].getBoundingClientRect().top").toInt32())
    }

    var loadOlderDisabled: Bool {
        run("$('load-older').disabled").toBool()
    }

    var pendingTimerCount: Int {
        Int(run("__timers.length").toInt32())
    }

    func jsonString(_ text: String) throws -> String {
        let data = try JSONEncoder().encode(text)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// Also checks failures the app caught and wrote to its log, oldest first.
    func assertNoException(
        expectedLogFailures: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(exceptions, [], "JavaScript exceptions", file: file, line: line)
        let log = run("$('log').textContent").toString() ?? ""
        let failures = log.split(separator: "\n").reversed()
            .filter { $0.contains("failed") }
            .map { entry in String(entry.drop { $0 != "]" }.dropFirst(2)) }
        XCTAssertEqual(failures, expectedLogFailures, "failures written to the app log", file: file, line: line)
    }
}
