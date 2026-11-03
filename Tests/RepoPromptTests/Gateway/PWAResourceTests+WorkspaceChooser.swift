import Foundation
import JavaScriptCore
@testable import RepoPromptGateway
import XCTest

/// Workspace chooser of the packaged phone client (`app.js`), run in JavaScriptCore with the
/// passkey harness's synthetic DOM and stub WebSocket. Covers discovery normalization, ID-only
/// listing, list membership, stale-reply fences, lock clearing and deep-link/draft survival.
/// Deterministic page logic only; Safari layout and the live two-window Mac remain manual checks.
extension PWAResourceTests {
    private static let chooserHelpers = #"""
    function __sentOf(type) { return __ws().sent.filter(function (f) { return f.type === type; }); }
    function __pendingAll(type) {
      return __sentOf(type).filter(function (f) { return state.pending.has(f.request_id); });
    }
    function __win(id, workspaceId, name) {
      var row = { window_id: id };
      if (workspaceId !== undefined) row.workspace_id = workspaceId;
      if (name !== undefined) row.workspace_name = name;
      return row;
    }
    function __choiceRows() {
      return $('workspace-choices').childNodes.map(function (li) { return li.childNodes[0]; });
    }
    function __choiceLabels() { return __choiceRows().map(function (row) { return row.childNodes[0].textContent; }); }
    function __choose(id) {
      __choiceRows().filter(function (row) { return row.dataset.workspaceId === id; })[0].onclick();
    }
    function __listedNames() {
      return $('sessions-list').childNodes.map(function (li) { return li.textContent; });
    }
    function __session(id, name) { return { session_id: id, status: 'running', session: { name: name } }; }
    """#

    /// A harness with no deep link, unlocked, on the sessions list with discovery pending.
    private func chooserHarness() throws -> PWAPasskeyHarness {
        let harness = try PWAPasskeyHarness(prelude: "location.search = '';")
        harness.run(Self.chooserHelpers)
        harness.connect(access: "__unlocked()")
        XCTAssertTrue(harness.shown("sessions-panel"))
        XCTAssertEqual(harness.int("__pendingAll('list_workspaces').length"), 1, "entry reads open workspaces fresh")
        XCTAssertEqual(harness.count(type: "list_sessions"), 0, "no unscoped list is ever sent")
        return harness
    }

    /// Entry with one open workspace: auto-selected, then listed by ID with sessions S1, S2.
    private func chooserHarnessListingW1() throws -> PWAPasskeyHarness {
        let harness = try chooserHarness()
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'Only')] });")
        XCTAssertFalse(harness.shown("binding-overlay"), "a sole workspace is chosen without a picker")
        harness.run("""
        __resolveAll('list_sessions', { sessions: [__session('S1', 'First'), __session('S2', 'Second')],
          workspace: { id: 'W1', name: 'Only' } });
        """)
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S1", "S2"])
        return harness
    }

    func testDiscoveryDeduplicatesByIDDisambiguatesNamesAndSkipsRowsWithoutID() throws {
        let harness = try chooserHarness()
        harness.run("""
        __resolveAll('list_workspaces', { windows: [
          __win(2, 'W-A', 'Alpha'), __win(1, 'W-A', 'Alpha'),
          __win(3, 'W-B1', 'Same'), __win(4, 'W-B2', 'Same'),
          __win(5, '', 'Empty id'), __win(6, undefined, 'No id'), __win(7, 42, 'Number id'),
          __win(8, 'W-C', ''),
          __win(10, 'W-D', 'Other'), __win(9, 'W-D', 'Zed')
        ] });
        """)
        XCTAssertTrue(harness.shown("binding-overlay"), "several workspaces open the picker")
        XCTAssertEqual(harness.strings("state.workspaceChoices.map(function (c) { return c.id; })"), ["W-C", "W-A", "W-B1", "W-B2", "W-D"])
        XCTAssertEqual(
            harness.strings("__choiceLabels()"),
            ["Workspace (W-C)", "Alpha", "Same (W-B1)", "Same (W-B2)", "Zed"],
            "two windows of one workspace are one choice; the first name in window order wins"
        )
        let picker = harness.string("$('workspace-choices').textContent") ?? ""
        for skipped in ["Empty id", "No id", "Number id"] {
            XCTAssertFalse(picker.contains(skipped), "\(skipped) is not selectable")
        }
        XCTAssertEqual(harness.count(type: "list_sessions"), 0, "nothing is listed before a choice")
        XCTAssertEqual(harness.string("$('sessions-list').textContent"), "Choose a workspace to list its sessions.")

        harness.run("__choose('W-B2');")
        XCTAssertFalse(harness.shown("binding-overlay"))
        let list = try XCTUnwrap(harness.json("__lastSent('list_sessions').payload") as? NSDictionary)
        XCTAssertEqual(list, ["workspace_id": "W-B2", "limit": 50] as NSDictionary, "ID only, never the name")
        XCTAssertEqual(
            harness.string("$('workspace-label').textContent"), "Workspace: Same (W-B2)",
            "a name shared with another open workspace keeps its ID suffix in the label"
        )
        XCTAssertEqual(harness.string("$('sessions-list').textContent"), "Sessions not loaded yet.", "not claimed empty before a reply")
        XCTAssertEqual(harness.count(type: "open_workspace"), 0, "choosing never changes the Mac")

        // B-WC2-02: Switch clears the choices; after Dismiss and Refresh the label stays distinct.
        harness.run("__resolveAll('list_sessions', { sessions: [], workspace: { id: 'W-B2', name: 'Same' } });")
        harness.run("$('switch-workspace').onclick(); $('binding-dismiss').onclick();")
        harness.run("$('refresh-sessions').onclick();")
        harness.run("__resolveAll('list_sessions', { sessions: [], workspace: { id: 'W-B2', name: 'Same' } });")
        XCTAssertEqual(harness.int("state.workspaceChoices.length"), 0)
        XCTAssertEqual(harness.string("$('workspace-label').textContent"), "Workspace: Same (W-B2)")
        harness.assertNoException()
    }

    func testNoOpenWorkspaceOffersRetryAndSendsNoList() throws {
        let harness = try chooserHarness()
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, '', 'No id')] });")
        XCTAssertTrue(harness.shown("binding-overlay"))
        XCTAssertTrue(harness.string("$('workspace-chooser-status').textContent")?.contains("No open workspace is available") == true)
        XCTAssertTrue(harness.shown("workspace-retry"))
        XCTAssertEqual(harness.count(type: "list_sessions"), 0)

        harness.run("$('workspace-retry').onclick();")
        XCTAssertEqual(harness.int("__pendingAll('list_workspaces').length"), 1, "Retry reads again")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(2, 'W2', 'Opened later')] });")
        XCTAssertFalse(harness.shown("binding-overlay"))
        XCTAssertEqual(harness.json("__lastSent('list_sessions').payload") as? NSDictionary, ["workspace_id": "W2", "limit": 50] as NSDictionary)
        harness.assertNoException()
    }

    func testListMembershipReplacesAndWatchFramesNeverAddSessions() throws {
        let harness = try chooserHarnessListingW1()
        XCTAssertEqual(harness.strings("__listedNames()").count, 2)
        XCTAssertEqual(harness.json("__lastSent('subscribe').payload") as? NSDictionary, ["session_ids": ["S1", "S2"]] as NSDictionary)

        // A watch frame for a session observed elsewhere neither caches nor lists it.
        harness.run("__deliver(__ws(), { v: 1, type: 'session_update', session_id: 'S9', seq: 1, payload: __session('S9', 'Elsewhere') });")
        XCTAssertFalse(harness.bool("state.sessions.has('S9')"))
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S1", "S2"])
        // A listed session updates in place, and expiry removes it from the list.
        harness.run("__deliver(__ws(), { v: 1, type: 'session_update', session_id: 'S1', seq: 1, payload: __session('S1', 'First renamed') });")
        XCTAssertTrue(harness.strings("__listedNames()").first?.contains("First renamed") == true)
        harness.run("__deliver(__ws(), { v: 1, type: 'session_expired', session_id: 'S2', seq: 2, payload: {} });")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S1"])

        // A refresh reply replaces membership rather than appending to it.
        harness.run("$('refresh-sessions').onclick();")
        harness.run("__resolveAll('list_sessions', { sessions: [__session('S3', 'Third')], workspace: { id: 'W1', name: 'Renamed' } });")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S3"])
        XCTAssertEqual(harness.string("$('workspace-label').textContent"), "Workspace: Renamed", "a rename refreshes the label, not the ID")
        XCTAssertEqual(harness.string("state.selectedWorkspaceId"), "W1")
        harness.assertNoException()
    }

    func testSwitchAlwaysRediscoversAndOnlyTheNewestDiscoveryAndListApply() throws {
        let harness = try chooserHarnessListingW1()
        // A W1 refresh is still in flight when the owner switches.
        harness.run("$('refresh-sessions').onclick();")
        harness.run("var __w1List = __pendingAll('list_sessions')[0];")
        harness.run("$('switch-workspace').onclick();")
        harness.run("var __older = __pendingAll('list_workspaces')[0];")
        XCTAssertTrue(harness.shown("binding-overlay"), "Switch opens the chooser even with one workspace")
        XCTAssertEqual(harness.int("$('workspace-choices').childNodes.length"), 0, "no earlier choice is offered while looking")
        XCTAssertEqual(harness.string("$('workspace-chooser-status').textContent"), "Looking for open workspaces…")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S1", "S2"], "opening the chooser keeps the list")
        harness.run("$('switch-workspace').onclick();")
        harness.run("var __newer = __pendingAll('list_workspaces')[1];")
        XCTAssertEqual(harness.count(type: "list_workspaces"), 3, "every Switch is a fresh read")

        // Replies in reverse order: the older discovery cannot replace the newer choices.
        harness.run("__result(__ws(), __newer, { windows: [__win(1, 'W1', 'Only'), __win(2, 'W2', 'Second window')] });")
        harness.run("__result(__ws(), __older, { windows: [__win(3, 'W3', 'Stale')] });")
        XCTAssertEqual(harness.strings("__choiceLabels()"), ["Only", "Second window"])

        harness.run("__choose('W2');")
        harness.run("var __listA = __pendingAll('list_sessions').filter(function (f) { return f.payload.workspace_id === 'W2'; })[0];")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), [], "a new choice clears the old list at once")
        harness.run("$('refresh-sessions').onclick();")
        harness.run("var __listB = __pendingAll('list_sessions').filter(function (f) { return f !== __listA && f !== __w1List; })[0];")
        harness.run("__result(__ws(), __listB, { sessions: [__session('S5', 'Newest')], workspace: { id: 'W2', name: 'Second window' } });")
        harness.run("__result(__ws(), __listA, { sessions: [__session('S6', 'Older list')], workspace: { id: 'W2', name: 'Second window' } });")
        harness.run("__result(__ws(), __w1List, { sessions: [__session('S7', 'Old workspace')], workspace: { id: 'W1', name: 'Only' } });")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S5"])
        XCTAssertFalse(harness.pageText().contains("Old workspace"))
        XCTAssertEqual(harness.count(type: "unsubscribe"), 0, "switching never unsubscribes another tab's watch")
        XCTAssertEqual(harness.count(type: "open_workspace"), 0)

        // Dismissing a later Switch keeps the choice and its list.
        harness.run("$('switch-workspace').onclick(); $('binding-dismiss').onclick();")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(9, 'W9', 'Late')] });")
        XCTAssertFalse(harness.shown("binding-overlay"), "a dismissed discovery reply opens nothing")
        XCTAssertEqual(harness.string("state.selectedWorkspaceId"), "W2")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S5"])
        harness.assertNoException()
    }

    func testOldWorkspaceFramesStayOutOfTheListWhileTheOpenSessionStillUpdates() throws {
        let harness = try chooserHarnessListingW1()
        harness.run("$('switch-workspace').onclick();")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'Only'), __win(2, 'W2', 'Two')] });")
        harness.run("__choose('W2');")
        harness.run("__resolveAll('list_sessions', { sessions: [__session('S5', 'Two session')], workspace: { id: 'W2', name: 'Two' } });")

        harness.run("__deliver(__ws(), { v: 1, type: 'session_update', session_id: 'S1', seq: 5, payload: { status: 'waiting_for_input', session: { name: 'First' } } });")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S5"], "W1's still-watched session does not enter W2's list")
        XCTAssertEqual(harness.string("state.sessions.get('S1').status"), "running", "the frame was not admitted")

        // Opened directly (as from a notification), the session updates regardless of the list.
        harness.run("openSession('S1');")
        harness.run("__deliver(__ws(), { v: 1, type: 'session_update', session_id: 'S1', seq: 6, payload: { status: 'waiting_for_input', session: { name: 'First' } } });")
        XCTAssertEqual(harness.string("state.sessions.get('S1').status"), "waiting_for_input")
        XCTAssertEqual(harness.string("$('detail-status').textContent"), "waiting_for_input")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S5"])
        harness.assertNoException()
    }

    func testClosedWorkspaceRediscoversOnceAndUnrelatedErrorsNeverOpenTheChooser() throws {
        let harness = try chooserHarnessListingW1()
        harness.run("$('refresh-sessions').onclick();")
        harness.run("__reply(__ws(), __pendingAll('list_sessions')[0], 'command_error', { code: 'workspace_not_open', message: 'Workspace is not open.' });")
        XCTAssertNil(harness.string("state.selectedWorkspaceId"), "the closed workspace is no longer chosen")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), [])
        XCTAssertEqual(harness.int("__pendingAll('list_workspaces').length"), 1, "one fresh discovery")
        XCTAssertEqual(harness.int("$('workspace-choices').childNodes.length"), 0, "the closed workspace is not offered while looking")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(2, 'W2', 'Still open')] });")
        XCTAssertTrue(harness.shown("binding-overlay"), "after a choice was made, a sole workspace is offered, not picked")
        XCTAssertEqual(harness.count(type: "list_sessions"), 2, "no automatic retry loop")

        harness.run("__choose('W2');")
        harness.run("__resolveAll('list_sessions', { sessions: [__session('S5', 'Five')], workspace: { id: 'W2', name: 'Still open' } });")
        // Another failure keeps the choice and shows a fixed retryable error.
        harness.run("$('refresh-sessions').onclick();")
        harness.run("__reply(__ws(), __pendingAll('list_sessions')[0], 'command_error', { code: 'app_tool_error', message: 'raw /Users/owner detail' });")
        XCTAssertEqual(harness.string("state.selectedWorkspaceId"), "W2")
        XCTAssertEqual(harness.string("$('sessions-status').textContent"), "Sessions are unavailable. Retry.")
        XCTAssertFalse(harness.pageText().contains("/Users/owner"))
        XCTAssertFalse(harness.shown("binding-overlay"))

        // A binding error on another command (here a session subscribe) never opens the chooser.
        harness.run("openSession('S5');")
        harness.run("__reply(__ws(), __pendingAll('subscribe').slice(-1)[0], 'command_error', { code: 'binding_required', message: 'Bind first.' });")
        XCTAssertFalse(harness.shown("binding-overlay"))
        XCTAssertEqual(harness.string("state.currentSessionId"), "S5")

        // A failed Switch keeps the choice and the list, with an inline Retry.
        harness.run("showSessionsList();")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(2, 'W2', 'Still open')] });")
        harness.run("__resolveAll('list_sessions', { sessions: [__session('S5', 'Five')], workspace: { id: 'W2', name: 'Still open' } });")
        harness.run("$('switch-workspace').onclick();")
        harness.run("__reply(__ws(), __pendingAll('list_workspaces')[0], 'command_error', { code: 'workspace_discovery_unavailable', message: 'Open workspaces are unavailable. Retry.' });")
        XCTAssertTrue(harness.shown("workspace-retry"))
        XCTAssertEqual(harness.string("state.selectedWorkspaceId"), "W2")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S5"])
        harness.assertNoException(expectedLogFailures: [
            "list_sessions failed: workspace_not_open",
            "list_sessions failed: app_tool_error",
            "subscribe failed: binding_required",
            "list_workspaces failed: workspace_discovery_unavailable"
        ])
    }

    /// WC-01: discovery and list work begun on the sessions screen must not reach the session
    /// detail the owner opened before it settled — no chooser over detail, no recovery, no change.
    func testLateDiscoveryAndListRepliesAfterOpeningASessionNeverDisturbTheDetail() throws {
        let harness = try chooserHarnessListingW1()

        func assertDetailUndisturbed(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(harness.shown("binding-overlay"), "\(step): no chooser over the detail", file: file, line: line)
            XCTAssertTrue(harness.shown("detail-panel"), step, file: file, line: line)
            XCTAssertEqual(harness.string("state.currentSessionId"), "S1", step, file: file, line: line)
            XCTAssertEqual(harness.string("state.selectedWorkspaceId"), "W1", "\(step): the choice is kept", file: file, line: line)
        }

        // Entry discovery fails after the owner opened a session from the still-shown list.
        harness.run("showSessionsList();")
        harness.run("var __entryA = __pendingAll('list_workspaces')[0];")
        harness.run("openSession('S1');")
        harness.run("__reply(__ws(), __entryA, 'command_error', { code: 'workspace_discovery_unavailable', message: 'Open workspaces are unavailable. Retry.' });")
        assertDetailUndisturbed("late discovery failure")
        XCTAssertEqual(harness.string("$('sessions-status').textContent"), "")

        // Entry discovery succeeds without the remembered workspace after detail entry.
        harness.run("showSessionsList();")
        harness.run("var __entryB = __pendingAll('list_workspaces')[0];")
        harness.run("openSession('S1');")
        harness.run("__result(__ws(), __entryB, { windows: [__win(2, 'W2', 'Other')] });")
        assertDetailUndisturbed("late missing-workspace discovery")

        // A list started on the sessions screen reports the workspace gone after detail entry.
        harness.run("showSessionsList();")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'Only')] });")
        harness.run("var __list = __pendingAll('list_sessions')[0];")
        harness.run("openSession('S1');")
        let discoveriesBefore = harness.count(type: "list_workspaces")
        harness.run("__reply(__ws(), __list, 'command_error', { code: 'workspace_not_open', message: 'Workspace is not open.' });")
        assertDetailUndisturbed("late workspace-gone list")
        XCTAssertEqual(harness.count(type: "list_workspaces"), discoveriesBefore, "no recovery discovery from a stale list")

        // Back to Sessions works normally again.
        harness.run("$('back-to-sessions').onclick();")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'Only')] });")
        harness.run("__resolveAll('list_sessions', { sessions: [__session('S1', 'First')], workspace: { id: 'W1', name: 'Only' } });")
        XCTAssertEqual(harness.strings("state.listedSessionIds"), ["S1"])
        harness.assertNoException()
    }

    /// A `workspace_not_open` list reply clears the choice and rereads; an empty reread shows the
    /// no-open-workspace chooser with Retry.
    func testWorkspaceNotOpenListClearsChoiceAndRecoversToNoOpenWorkspaceChooser() throws {
        let harness = try chooserHarnessListingW1()
        harness.run("$('refresh-sessions').onclick();")
        harness.run("__reply(__ws(), __pendingAll('list_sessions')[0], 'command_error', { code: 'workspace_not_open', message: 'The requested workspace is not open on the host.' });")
        harness.run("__resolveAll('list_workspaces', { windows: [] });")
        XCTAssertNil(harness.string("state.selectedWorkspaceId"))
        XCTAssertEqual(harness.strings("state.listedSessionIds"), [])
        XCTAssertFalse(harness.pageText().contains("First"), "the closed workspace's sessions are no longer listed")
        XCTAssertTrue(harness.shown("binding-overlay"))
        XCTAssertTrue(harness.string("$('workspace-chooser-status').textContent")?.contains("No open workspace is available") == true)
        XCTAssertTrue(harness.shown("workspace-retry"))
        XCTAssertEqual(harness.count(type: "list_sessions"), 2, "no list is sent without an open workspace")
        harness.assertNoException(expectedLogFailures: ["list_sessions failed: workspace_not_open"])
    }

    /// After the last Mac window closes, the gateway keeps its legacy scoped-list error, so Refresh
    /// shows the retryable sessions-unavailable message and keeps the choice; Switch rereads and
    /// shows the no-open-workspace chooser.
    func testLastWindowClosedRefreshShowsUnavailableAndSwitchShowsNoOpenWorkspace() throws {
        let harness = try chooserHarnessListingW1()
        harness.run("$('refresh-sessions').onclick();")
        harness.run("__reply(__ws(), __pendingAll('list_sessions')[0], 'command_error', { code: 'app_tool_error', message: 'Window lookup unavailable.' });")
        XCTAssertEqual(harness.string("$('sessions-status').textContent"), "Sessions are unavailable. Retry.")
        XCTAssertEqual(harness.string("state.selectedWorkspaceId"), "W1", "a lookup error is not treated as a closed workspace")
        XCTAssertFalse(harness.shown("binding-overlay"))

        harness.run("$('switch-workspace').onclick();")
        harness.run("__resolveAll('list_workspaces', { windows: [] });")
        XCTAssertTrue(harness.shown("binding-overlay"))
        XCTAssertTrue(harness.string("$('workspace-chooser-status').textContent")?.contains("No open workspace is available") == true)
        XCTAssertTrue(harness.shown("workspace-retry"))
        XCTAssertEqual(harness.count(type: "list_sessions"), 2, "nothing more is listed without an open workspace")
        harness.assertNoException(expectedLogFailures: ["list_sessions failed: app_tool_error"])
    }

    func testLockClearsWorkspaceNamesAndChooserAndUnlockRevalidatesTheKeptID() throws {
        let harness = try chooserHarness()
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'Secret workspace'), __win(2, 'W2', 'Other secret')] });")
        harness.run("__choose('W1');")
        harness.run("__resolveAll('list_sessions', { sessions: [__session('S1', 'Secret session')], workspace: { id: 'W1', name: 'Secret workspace' } });")
        // A Switch discovery is in flight when the owner locks.
        harness.run("$('switch-workspace').onclick();")
        harness.run("var __held = __pendingAll('list_workspaces')[0];")
        harness.run("$('lock-button').onclick({ isTrusted: true });")
        harness.run("__result(__ws(), __held, { windows: [__win(3, 'W3', 'Leaked workspace')] });")

        XCTAssertFalse(harness.shown("binding-overlay"))
        XCTAssertEqual(harness.int("$('workspace-choices').childNodes.length"), 0)
        XCTAssertEqual(harness.int("state.workspaceChoices.length"), 0)
        XCTAssertNil(harness.string("state.selectedWorkspaceName"))
        XCTAssertEqual(harness.strings("state.listedSessionIds"), [])
        XCTAssertEqual(harness.string("state.selectedWorkspaceId"), "W1", "only the opaque ID is kept in page memory")
        let page = harness.pageText()
        for secret in ["Secret workspace", "Other secret", "Leaked workspace", "Secret session"] {
            XCTAssertFalse(page.contains(secret), "\(secret) left on the page after the lock")
        }

        harness.run("__lockState(__ws(), __access({ lock_generation: '4' }));")
        harness.unlockViaPasskey(grant: "grant-2", lockGeneration: "4")
        XCTAssertEqual(harness.int("__pendingAll('list_workspaces').length"), 1, "unlock rereads before listing")
        XCTAssertEqual(harness.int("__pendingAll('list_sessions').length"), 0)
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'Fresh name'), __win(2, 'W2', 'Other')] });")
        XCTAssertFalse(harness.shown("binding-overlay"), "the kept choice is still open, so no picker")
        XCTAssertEqual(harness.string("$('sessions-list').textContent"), "Sessions not loaded yet.", "cleared membership is not shown as empty")
        XCTAssertEqual(harness.json("__lastSent('list_sessions').payload") as? NSDictionary, ["workspace_id": "W1", "limit": 50] as NSDictionary)
        XCTAssertEqual(harness.string("$('workspace-label').textContent"), "Workspace: Fresh name")
        harness.assertNoException()
    }

    /// B-WC03: identity reset forgets the workspace entirely, and with protection off a socket that
    /// closes during Switch does not leave "Looking…" up — without hiding a newer discovery's chooser.
    func testIdentityResetAndPolicyOffDisconnectClearTheChooserSafely() throws {
        let harness = try PWAPasskeyHarness(prelude: "location.search = '';")
        harness.run(Self.chooserHelpers)
        harness.connect(access: "__access({ policy_state: 'off', locked: false, enrolled: false })")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'One'), __win(2, 'W2', 'Two')] });")
        harness.run("__choose('W1');")
        harness.run("__resolveAll('list_sessions', { sessions: [__session('S1', 'First')], workspace: { id: 'W1', name: 'One' } });")

        harness.run("$('switch-workspace').onclick();")
        XCTAssertTrue(harness.shown("binding-overlay"))
        harness.run("__drop(__ws());")
        XCTAssertFalse(harness.shown("binding-overlay"), "a closed socket's Looking… chooser is hidden")
        XCTAssertTrue(harness.bool("state.contentOpen"), "protection off keeps content on disconnect")
        XCTAssertEqual(harness.string("state.selectedWorkspaceId"), "W1")

        // A newer discovery started at once after a close keeps its own chooser.
        harness.run("$('connect-button').onclick();")
        harness.run("__open(__ws()); __hello(__ws(), __access({ policy_state: 'off', locked: false, enrolled: false }));")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'One'), __win(2, 'W2', 'Two')] });")
        harness.run("$('switch-workspace').onclick();")
        harness.run("__drop(__ws()); $('switch-workspace').onclick();")
        XCTAssertTrue(harness.shown("binding-overlay"), "the old discovery's failure does not hide the newer chooser")
        XCTAssertEqual(harness.string("$('workspace-chooser-status').textContent"), "Open workspaces are unavailable. Retry.")

        harness.run("resetIdentityState();")
        XCTAssertNil(harness.string("state.selectedWorkspaceId"))
        XCTAssertFalse(harness.bool("state.workspaceSelectedOnce"))
        XCTAssertNil(harness.string("state.selectedWorkspaceName"))
        XCTAssertEqual(harness.int("state.workspaceChoices.length"), 0)
        XCTAssertEqual(harness.strings("state.listedSessionIds"), [])
        XCTAssertFalse(harness.shown("binding-overlay"))
        XCTAssertEqual(harness.string("$('workspace-label').textContent"), "")
        XCTAssertEqual(harness.int("$('workspace-choices').childNodes.length"), 0)
        harness.assertNoException(expectedLogFailures: ["list_workspaces failed: error"])
    }

    /// B-WC07: an older gateway without `list_workspaces` gets a reload/update message, not an endless
    /// generic retry.
    func testUnsupportedDiscoveryFrameAsksToReloadOrUpdate() throws {
        let harness = try chooserHarness()
        harness.run("__reply(__ws(), __pendingAll('list_workspaces')[0], 'command_error', { code: 'unsupported_frame_type', message: 'Unsupported frame type.' });")
        let text = harness.string("$('workspace-chooser-status').textContent") ?? ""
        XCTAssertTrue(text.contains("Reload this page"), text)
        XCTAssertEqual(harness.string("$('sessions-status').textContent"), text)
        XCTAssertEqual(harness.count(type: "list_sessions"), 0)
        harness.assertNoException(expectedLogFailures: ["list_workspaces failed: unsupported_frame_type"])
    }

    /// B-WC06: a draft typed in the composer and partial question answers survive Back → Switch
    /// workspace → reopen, restored as typed and never sent.
    func testTypedDraftsSurviveBackSwitchAndReopen() throws {
        let harness = try PWAPasskeyHarness()
        harness.run(Self.chooserHelpers)
        harness.unlockAndOpenS1()
        harness.editDrafts()
        harness.run("$('back-to-sessions').onclick();")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'One'), __win(2, 'W2', 'Two')] });")
        harness.run("__choose('W1');")
        harness.run("__resolveAll('list_sessions', { sessions: [__session('S1', 'Secret session')], workspace: { id: 'W1', name: 'One' } });")
        harness.run("$('switch-workspace').onclick();")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'One'), __win(2, 'W2', 'Two')] });")
        harness.run("__choose('W2');")
        harness.run("__resolveAll('list_sessions', { sessions: [], workspace: { id: 'W2', name: 'Two' } });")

        harness.run("openSession('S1');")
        harness.openS1()
        XCTAssertEqual(harness.string("$('composer-input').value"), "  draft\n", "the typed draft comes back exactly")
        XCTAssertEqual(harness.json("__formState()") as? NSArray, PWAPasskeyHarness.editedForm)
        XCTAssertEqual(harness.count(type: "steer"), 0)
        XCTAssertEqual(harness.count(type: "respond"), 0)
        harness.assertNoException()
    }

    /// B-WC2-01: a steer still in flight across Back → reopen clears its own restored text on
    /// success, so sent text never reappears; edited text and other sessions' drafts stay.
    func testSteerSentBeforeBackAndReopenClearsOnlyItsOwnText() throws {
        let harness = try PWAPasskeyHarness()
        harness.run(Self.chooserHelpers)
        harness.unlockAndOpenS1(snapshot: "__running")
        harness.run("state.composerDrafts.set('S2', 'other session draft');")
        harness.run("$('composer-input').value = 'fix tests'; $('composer-send').onclick(); $('back-to-sessions').onclick();")
        harness.run("openSession('S1');")
        XCTAssertEqual(harness.string("$('composer-input').value"), "fix tests", "the kept text is shown before the reply")
        harness.run("__result(__ws(), __lastSent('steer'), {});")
        XCTAssertEqual(harness.string("$('composer-input').value"), "", "sent text does not come back")
        XCTAssertFalse(harness.bool("state.composerDrafts.has('S1')"))
        XCTAssertEqual(harness.string("state.composerDrafts.get('S2')"), "other session draft")
        XCTAssertEqual(harness.count(type: "steer"), 1)
        harness.assertNoException()

        // Text edited after reopening is newer than what was sent and stays.
        let edited = try PWAPasskeyHarness()
        edited.run(Self.chooserHelpers)
        edited.unlockAndOpenS1(snapshot: "__running")
        edited.run("$('composer-input').value = 'fix tests'; $('composer-send').onclick(); $('back-to-sessions').onclick();")
        edited.run("openSession('S1'); $('composer-input').value = 'fix tests please';")
        edited.run("__result(__ws(), __lastSent('steer'), {});")
        XCTAssertEqual(edited.string("$('composer-input').value"), "fix tests please")
        XCTAssertEqual(edited.count(type: "steer"), 1)
        edited.assertNoException()
    }

    func testDeepLinkSkipsDiscoveryAndWorkspaceChoiceKeepsDrafts() throws {
        let harness = try PWAPasskeyHarness()
        harness.run(Self.chooserHelpers)
        harness.unlockAndOpenS1(snapshot: "__running")
        XCTAssertEqual(harness.count(type: "list_workspaces"), 0, "a deep link opens its session directly")
        XCTAssertEqual(harness.string("state.currentSessionId"), "S1")

        harness.run("$('composer-input').value = 'kept draft'; $('back-to-sessions').onclick();")
        harness.run("__resolveAll('list_workspaces', { windows: [__win(1, 'W1', 'One'), __win(2, 'W2', 'Two')] });")
        harness.run("__choose('W2');")
        harness.run("__resolveAll('list_sessions', { sessions: [], workspace: { id: 'W2', name: 'Two' } });")
        XCTAssertEqual(harness.string("state.composerDrafts.get('S1')"), "kept draft", "choosing a workspace keeps drafts")
        harness.run("openSession('S1');")
        XCTAssertEqual(harness.string("$('composer-input').value"), "kept draft")
        XCTAssertEqual(harness.count(type: "steer"), 0, "nothing is sent for the draft")
        harness.assertNoException()
    }
}
