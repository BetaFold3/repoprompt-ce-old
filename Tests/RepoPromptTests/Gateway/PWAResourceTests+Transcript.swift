import Foundation
import JavaScriptCore
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
        XCTAssertEqual(harness.transcript, xml, "transcript_xml is shown verbatim, not as JSON metadata")
        XCTAssertEqual(harness.requests().count, 1, "a short session needs one page")
        XCTAssertTrue(harness.loadOlderDisabled)

        harness.run("refreshTranscript();")
        harness.answer(1, total: 0)
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 0, limit: 200))
        XCTAssertEqual(harness.transcript, "")
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
        XCTAssertFalse(harness.loadOlderDisabled)

        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 50, limit: 200))
        harness.answer(2, total: 450)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(50 ..< 450))

        harness.run("loadOlderTranscript();")
        XCTAssertEqual(harness.requests().last, .init(type: "get_log", session: "S", offset: 0, limit: 50))
        harness.answer(3, total: 450)
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(0 ..< 450), "no turn is repeated or skipped")
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
        harness.run("__calls[2].reject(new Error('Timed out waiting for get_log.'));")
        XCTAssertEqual(harness.transcript, PWATranscriptHarness.turns(250 ..< 450))
        XCTAssertFalse(harness.loadOlderDisabled)
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

    private static let browserStub = """
    var __elements = {};
    function __node(id) {
      return {
        id: id, textContent: '', value: '', className: '', placeholder: '', type: '', disabled: false,
        dataset: {}, style: {}, scrollTop: 0, scrollHeight: 0, clientHeight: 0,
        classList: { add: function () {}, remove: function () {}, toggle: function () {}, contains: function () { return false; } },
        appendChild: function () {}, append: function () {}, replaceChildren: function () {}, addEventListener: function () {}
      };
    }
    var document = {
      visibilityState: 'hidden',
      getElementById: function (id) { return __elements[id] || (__elements[id] = __node(id)); },
      createElement: function () { return __node(''); },
      addEventListener: function () {}
    };
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
        return (try? JSONDecoder().decode([Request].self, from: Data(json.utf8))) ?? []
    }

    var transcript: String {
        run("$('transcript').textContent").toString() ?? ""
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
