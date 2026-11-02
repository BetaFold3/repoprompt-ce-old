import Foundation
import JavaScriptCore
@testable import RepoPromptGateway
import XCTest

/// Passkey lock flow of the packaged phone client (`app.js`), run in JavaScriptCore against
/// a synthetic DOM and a stub WebSocket. Frames go through the client's real signed send
/// queue and request correlation. These fixtures prove deterministic page transitions only;
/// Safari, 1Password and the native passkey sheet remain live (Step 5) checks.
extension PWAResourceTests {
    // MARK: Locked presentation and metadata

    func testLockedHelloShowsOnlyLockPresentationAndPrefetchesUnlockOptions() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")

        XCTAssertTrue(harness.shown("lock-panel"))
        XCTAssertTrue(harness.shown("unlock-button"))
        XCTAssertFalse(harness.shown("setup-passkey-button"))
        XCTAssertFalse(harness.shown("sessions-panel"))
        XCTAssertFalse(harness.shown("detail-panel"))
        XCTAssertFalse(harness.shown("lock-button"), "Lock is offered only while unlocked")
        XCTAssertTrue(harness.shown("connect-panel"), "identity and connection stay visible")
        XCTAssertEqual(harness.sentTypes(), ["hello", "passkey_unlock_begin"], "no session request while locked")
        XCTAssertEqual(harness.string("state.deepLinkSessionId"), "S1", "the target session is kept")
        XCTAssertEqual(harness.string("state.deviceId"), "remote:5e6f7a8b")
        XCTAssertEqual(harness.string("state.channel"), "debug")

        harness.connectFresh(access: "__access({ enrolled: false, enrollment_open: true })")
        XCTAssertTrue(harness.shown("setup-passkey-button"))
        XCTAssertFalse(harness.shown("unlock-button"))
        XCTAssertEqual(harness.sentTypes(), ["hello", "passkey_register_begin"])

        harness.connectFresh(access: "__access({ enrolled: false, enrollment_open: false })")
        XCTAssertFalse(harness.shown("setup-passkey-button"))
        XCTAssertFalse(harness.shown("unlock-button"))
        XCTAssertTrue(harness.shown("lock-reconnect"))
        XCTAssertTrue(harness.string("$('lock-message').textContent")?.contains("on your Mac") == true)
        XCTAssertEqual(harness.sentTypes(), ["hello"], "no ceremony without Mac authorization")
        harness.assertNoException()
    }

    func testMissingOrInconsistentAccessMetadataFailsClosed() throws {
        let harness = try PWAPasskeyHarness()
        harness.run("var ws = __ws(); __open(ws); __deliver(ws, { v: 1, type: 'hello_ack', payload: { device_id: 'remote:5e6f7a8b', auth: 'ticket', locked: false } });")
        XCTAssertTrue(harness.shown("lock-panel"))
        XCTAssertFalse(harness.shown("sessions-panel"))
        XCTAssertFalse(harness.shown("detail-panel"))
        XCTAssertTrue(harness.string("$('lock-message').textContent")?.contains("did not report") == true)
        XCTAssertEqual(harness.sentTypes(), ["hello"], "missing metadata is not treated as policy off")

        harness.connectFresh(hello: "{ device_id: 'remote:5e6f7a8b', auth: 'ticket', locked: true, access: __unlocked() }")
        XCTAssertFalse(harness.bool("state.contentOpen"), "top-level locked contradicting access fails closed")
        XCTAssertEqual(harness.sentTypes(), ["hello"])

        harness.connectFresh(access: "__unlocked({ epoch: 7 })")
        XCTAssertFalse(harness.bool("state.contentOpen"), "a numeric epoch is malformed")
        harness.connectFresh(access: "__unlocked({ policy_state: 'maybe' })")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        harness.connectFresh(access: "__unlocked({ grant_id: undefined })")
        XCTAssertFalse(harness.bool("state.contentOpen"), "required and unlocked without a grant reference stays closed")

        // A malformed lock_state on an open page closes it.
        harness.connectFresh(access: "__unlocked()")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        harness.run("__lockState(__ws(), { policy_state: 'required' });")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertFalse(harness.shown("detail-panel"))
        harness.assertNoException()
    }

    func testPolicyOffKeepsOrdinaryAccessAndHasNoLock() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access({ policy_state: 'off', locked: false, enrolled: false })")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertFalse(harness.shown("lock-panel"))
        XCTAssertFalse(harness.shown("lock-button"), "policy-off Lock has no gateway reply, so it is not offered")
        XCTAssertEqual(harness.sentTypes(), ["hello", "subscribe"], "the deep-linked session opens as before")

        harness.run("lockNow();")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.sentTypes(), ["hello", "subscribe"], "no lock frame under policy off")

        // Leaving keeps the ordinary behavior. Returning hides first and asks a fresh
        // hello, since the Mac may have turned protection on meanwhile; policy off reopens.
        harness.run("document.visibilityState = 'hidden'; __fire('visibilitychange', {});")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.int("__sockets.length"), 1)
        harness.run("document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertEqual(harness.int("__sockets.length"), 2)
        harness.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access({ policy_state: 'off', locked: false, enrolled: false }));")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.sentTypes(), ["hello", "subscribe"])

        // A policy-off disconnect keeps the page; reconnecting reopens the same session.
        harness.run("__drop(__ws());")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        // The unanswered open fails as it always has; nothing is cleared under policy off.
        harness.assertNoException(expectedLogFailures: [
            "subscribe failed: Connection closed.", "poll failed: Not connected.", "get_log failed: Not connected."
        ])
    }

    // MARK: Native ceremonies

    func testUnlockTapStartsNativeAssertionBeforeAnyNetworkAwait() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.answerChallenge(kind: "assertion")
        XCTAssertEqual(harness.string("state.ceremony.phase"), "ready")
        XCTAssertFalse(harness.bool("$('unlock-button').disabled"))

        // A signed frame is still held in the send queue (its signature has not finished).
        // The tap must not wait for it, or for anything else.
        harness.run("""
        __signGate = new Promise(function (resolve) { __releaseSign = resolve; });
        enqueueSignedSend(__ws(), { v: 1, type: 'push_unsubscribe', request_id: 'held' }).catch(function () {});
        var __mark = __log.length;
        $('unlock-button').onclick({ isTrusted: true });
        var __syncCalls = __credentialCalls.length;
        var __afterTap = __log.slice(__mark);
        """)
        XCTAssertEqual(harness.int("__syncCalls"), 1, "navigator.credentials.get runs inside the tap handler")
        XCTAssertEqual(harness.strings("__afterTap"), ["credentials.get"], "nothing is sent or awaited before the prompt")
        XCTAssertEqual(harness.string("__credentialCalls[0].kind"), "get")
        let options = try XCTUnwrap(harness.json("""
        (function (o) {
          return { keys: Object.keys(o).sort(), challenge: Array.from(o.challenge), rpId: o.rpId,
            allow: o.allowCredentials.map(function (c) { return { type: c.type, id: Array.from(c.id) }; }),
            uv: o.userVerification, timeout: o.timeout };
        })(__credentialCalls[0].options.publicKey)
        """) as? NSDictionary)
        XCTAssertEqual(options, [
            "keys": ["allowCredentials", "challenge", "rpId", "timeout", "userVerification"],
            "challenge": [1, 2, 3, 4],
            "rpId": "phone.test",
            "allow": [["type": "public-key", "id": [9, 8, 7]]],
            "uv": "required",
            "timeout": 60000
        ] as NSDictionary)
        XCTAssertTrue(harness.bool("$('unlock-button').disabled"), "no second prompt while one is open")

        harness.run("__releaseSign(); __credentialCalls[0].resolve(__assertionCredential());")
        let complete = try XCTUnwrap(harness.json("__lastSent('passkey_unlock_complete')") as? NSDictionary)
        let payload = try XCTUnwrap(complete["payload"] as? NSDictionary)
        XCTAssertEqual(Set(payload.allKeys.compactMap { $0 as? String }), ["ceremony_id", "credential"], "device and connection identity are server-derived")
        XCTAssertEqual(payload["ceremony_id"] as? String, "ceremony-assert-0001")
        let credentialText = try XCTUnwrap(payload["credential"] as? String, "the credential is a JSON string")
        let credential = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(credentialText.utf8)) as? NSDictionary)
        XCTAssertEqual(credential, [
            "id": "AQI", "rawId": "AQI", "type": "public-key",
            "response": ["clientDataJSON": "e30", "authenticatorData": "BAUG", "signature": "Bwg"]
        ] as NSDictionary, "base64url binary, matching id/rawId, null userHandle omitted")
        XCTAssertEqual(harness.strings("__ws().sent.map(function (f) { return f.type; })").suffix(2), ["push_unsubscribe", "passkey_unlock_complete"])

        // Completion ends the ceremony but never unlocks.
        harness.run("__reply(__ws(), __lastSent('passkey_unlock_complete'), 'passkey_ceremony_complete', { kind: 'assertion' });")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertTrue(harness.shown("lock-panel"))
        XCTAssertFalse(harness.shown("unlock-button"), "waits for the gateway's metadata instead of prompting again")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 1, "no new begin while waiting for lock_state")
        XCTAssertEqual(harness.count(type: "subscribe"), 0)

        // Only the authoritative lock_state opens the content.
        harness.run("__lockState(__ws(), __unlocked());")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertFalse(harness.shown("lock-panel"))
        XCTAssertTrue(harness.shown("lock-button"))
        XCTAssertEqual(harness.count(type: "subscribe"), 1, "unlock reopens the target session through the ordinary path")
        XCTAssertEqual(harness.string("state.currentSessionId"), "S1")
        harness.assertNoException()
    }

    func testRegistrationMapsCreationOptionsAndNeverUnlocks() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access({ enrolled: false, enrollment_open: true })")
        harness.answerChallenge(kind: "registration")
        harness.run("""
        var __mark = __log.length;
        $('setup-passkey-button').onclick({ isTrusted: true });
        var __afterTap = __log.slice(__mark);
        """)
        XCTAssertEqual(harness.strings("__afterTap"), ["credentials.create"])
        let options = try XCTUnwrap(harness.json("""
        (function (o) {
          return { keys: Object.keys(o).sort(), challenge: Array.from(o.challenge), rp: o.rp,
            user: { id: Array.from(o.user.id), name: o.user.name, displayName: o.user.displayName, keys: Object.keys(o.user).sort() },
            params: o.pubKeyCredParams, selection: o.authenticatorSelection, attestation: o.attestation, timeout: o.timeout };
        })(__credentialCalls[0].options.publicKey)
        """) as? NSDictionary)
        XCTAssertEqual(options, [
            "keys": ["attestation", "authenticatorSelection", "challenge", "pubKeyCredParams", "rp", "timeout", "user"],
            "challenge": [5, 6, 7],
            "rp": ["id": "phone.test", "name": "RepoPrompt Dev"],
            "user": ["id": [17, 34, 51], "name": "remote:5e6f7a8b", "displayName": "Phone (Dev)", "keys": ["displayName", "id", "name"]],
            "params": [["type": "public-key", "alg": -7]],
            "selection": ["residentKey": "preferred", "userVerification": "required"],
            "attestation": "none",
            "timeout": 60000
        ] as NSDictionary)

        harness.run("__credentialCalls[0].resolve(__registrationCredential());")
        let credentialText = try XCTUnwrap(harness.string("__lastSent('passkey_register_complete').payload.credential"))
        let credential = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(credentialText.utf8)) as? NSDictionary)
        XCTAssertEqual(credential, [
            "id": "AQI", "rawId": "AQI", "type": "public-key",
            "response": ["clientDataJSON": "e30", "attestationObject": "oA"]
        ] as NSDictionary)

        // The gateway publishes the new enrollment before announcing completion. No begin
        // may start while the complete is outstanding.
        harness.run("__lockState(__ws(), __access({ enrolled: true, enrollment_open: false, epoch: '8' }));")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 0)
        XCTAssertEqual(harness.string("state.ceremony.phase"), "completing")

        harness.run("__reply(__ws(), __lastSent('passkey_register_complete'), 'passkey_ceremony_complete', { kind: 'registration' });")
        XCTAssertFalse(harness.bool("state.contentOpen"), "registration alone grants nothing")
        XCTAssertEqual(harness.count(type: "subscribe"), 0)
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 1, "the separate unlock is prepared next")
        XCTAssertTrue(harness.shown("unlock-button"))
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("Passkey saved") == true)
        harness.assertNoException()
    }

    func testStaleOrReplacedOptionsAreRefreshedAndNeedAnotherTap() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.answerChallenge(kind: "assertion")

        // Freshness counts from the begin request on the monotonic clock: the app's 60
        // seconds less a 15-second margin. Wall-clock jumps do not count.
        harness.run("__now += 3600000; __mono += 44999;")
        XCTAssertTrue(harness.bool("ceremonyIsFresh(state.ceremony)"))
        harness.run("__mono += 1; $('unlock-button').onclick({ isTrusted: true });")
        XCTAssertEqual(harness.int("__credentialCalls.length"), 0, "stale options never reach the native prompt")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 2, "fresh options are requested")
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("Tap Unlock again") == true)
        XCTAssertTrue(harness.bool("$('unlock-button').disabled"), "disabled while the options load")
        harness.run("$('unlock-button').onclick({ isTrusted: true });")
        XCTAssertEqual(harness.int("__credentialCalls.length"), 0, "no prompt while the new request is pending")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 2, "no overlapping begin of the same kind")

        harness.answerChallenge(kind: "assertion")
        XCTAssertEqual(harness.string("$('lock-status').textContent"), "", "the wait notice ends with fresh options")
        XCTAssertFalse(harness.bool("$('unlock-button').disabled"))
        harness.run("__mono += 44000; $('unlock-button').onclick({ isTrusted: true });")
        XCTAssertEqual(harness.int("__credentialCalls.length"), 1, "options still inside the bound are used")
        harness.run("__credentialCalls[0].reject(__domError('NotAllowedError'));")

        // New metadata replaces cached options even when they are young.
        harness.answerChallenge(kind: "assertion")
        XCTAssertEqual(harness.string("state.ceremony.phase"), "ready")
        harness.run("__lockState(__ws(), __access({ lock_generation: '4' }));")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 4)
        harness.run("$('unlock-button').onclick({ isTrusted: true });")
        XCTAssertEqual(harness.int("__credentialCalls.length"), 1)

        // A replaced socket makes cached options unusable; the new socket fetches its own.
        harness.answerChallenge(kind: "assertion")
        harness.run("__drop(__ws()); $('connect-button').onclick();")
        harness.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access({ lock_generation: '4' }));")
        XCTAssertEqual(harness.int("__sockets.length"), 2)
        XCTAssertEqual(harness.strings("__ws().sent.map(function (f) { return f.type; })"), ["hello", "passkey_unlock_begin"])
        harness.run("$('unlock-button').onclick({ isTrusted: true });")
        XCTAssertEqual(harness.int("__credentialCalls.length"), 1, "options from the old socket are never used")
        harness.assertNoException()
    }

    func testCancelledDeniedAndRejectedCeremoniesStayLockedWithRetry() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")

        // Native cancellation or denial.
        harness.answerChallenge(kind: "assertion")
        harness.run("$('unlock-button').onclick({ isTrusted: true }); __credentialCalls[0].reject(__domError('NotAllowedError'));")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.count(type: "passkey_unlock_complete"), 0)
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("cancelled or not allowed") == true)
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 2, "fresh options are fetched for the retry tap")
        XCTAssertTrue(harness.shown("unlock-button"))

        // The app rejects the assertion. Its message never reaches the page.
        harness.answerChallenge(kind: "assertion")
        harness.run("$('unlock-button').onclick({ isTrusted: true }); __credentialCalls[1].resolve(__assertionCredential());")
        harness.run("""
        __deliver(__ws(), { v: 1, type: 'command_error', request_id: __lastSent('passkey_unlock_complete').request_id,
          payload: { code: 'authentication_failed', message: 'SECRET app verifier detail' } });
        """)
        XCTAssertFalse(harness.bool("state.contentOpen"))
        let status = harness.string("$('lock-status').textContent") ?? ""
        XCTAssertTrue(status.contains("could not be verified"), status)
        XCTAssertFalse(harness.pageText().contains("SECRET"), "server error text is not shown")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 3)

        // A stale or replaced ceremony.
        harness.answerChallenge(kind: "assertion")
        harness.run("$('unlock-button').onclick({ isTrusted: true }); __credentialCalls[2].resolve(__assertionCredential());")
        harness.run("__reply(__ws(), __lastSent('passkey_unlock_complete'), 'command_error', { code: 'passkey_stale_ceremony', message: 'The request was rejected.' });")
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("expired or was replaced") == true)

        // A completion of the wrong kind does not count as success.
        harness.answerChallenge(kind: "assertion")
        harness.run("$('unlock-button').onclick({ isTrusted: true }); __credentialCalls[3].resolve(__assertionCredential());")
        harness.run("__reply(__ws(), __lastSent('passkey_unlock_complete'), 'passkey_ceremony_complete', { kind: 'registration' });")
        XCTAssertNotEqual(harness.string("state.ceremonyDoneKey"), harness.string("state.accessKey"))
        XCTAssertFalse(harness.bool("state.contentOpen"))

        // A refused begin is not retried automatically; the next tap asks again.
        let begins = harness.count(type: "passkey_unlock_begin")
        harness.run("__reply(__ws(), __lastSent('passkey_unlock_begin'), 'command_error', { code: 'protocol_error', message: 'The request was rejected.' });")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), begins)
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("Could not get a passkey request") == true)
        harness.run("$('unlock-button').onclick({ isTrusted: true });")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), begins + 1)
        XCTAssertEqual(harness.int("__credentialCalls.length"), 4)
        harness.assertNoException()
    }

    func testPasskeysRequireHTTPSSecureContextAndWebAuthn() throws {
        for prelude in [
            "location.protocol = 'http:';",
            "window.isSecureContext = false;",
            "navigator.credentials = undefined;",
            "delete window.PublicKeyCredential;"
        ] {
            let harness = try PWAPasskeyHarness(prelude: prelude)
            harness.connect(access: "__access()")
            XCTAssertTrue(harness.shown("lock-panel"), prelude)
            XCTAssertFalse(harness.shown("unlock-button"), prelude)
            XCTAssertEqual(harness.sentTypes(), ["hello"], "no begin without a usable passkey context: \(prelude)")
            let message = harness.string("$('lock-message').textContent") ?? ""
            XCTAssertTrue(message.contains("HTTPS link") || message.contains("does not support passkeys"), message)
            XCTAssertFalse(message.lowercased().contains("password"), "no password fallback is offered")
            harness.run("beginNativeCeremony('assertion');")
            XCTAssertEqual(harness.int("__credentialCalls.length"), 0, prelude)
            harness.assertNoException()
        }
    }

    // MARK: Lock transition, drafts and stale callbacks

    func testLockClearsContentAtOnceKeepsDraftsAndFencesEveryStaleCallback() throws {
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1(xml: "__codeXML")
        XCTAssertEqual(harness.string("$('detail-name').textContent"), "Secret session")
        XCTAssertTrue(harness.string("$('transcript').textContent")?.contains("secret transcript") == true)
        XCTAssertEqual(harness.string("$('interaction-box').dataset.interactionId"), "I1")
        harness.editDrafts()

        // Work still in flight when the lock happens. A chosen workspace makes the list
        // request a real `list_sessions`.
        harness.run("""
        state.selectedWorkspaceId = 'W1';
        refreshSessions();
        pollSession('S1');
        refreshTranscript();
        maybeRefreshTranscript();
        scheduleDetailRefresh();
        var __detailTick = __timers[detailRefreshTimer];
        var __transcriptTick = __timers[transcriptRefreshTimer];
        __find($('transcript-view'), 'link code-copy').onclick();
        """)
        XCTAssertEqual(harness.int("__clipboard.length"), 1)

        harness.run("""
        var __mark = __log.length;
        $('lock-button').onclick({ isTrusted: true });
        var __sync = {
          detail: __shown('detail-panel'), sessions: __shown('sessions-panel'), lock: __shown('lock-panel'),
          page: __pageText(), composer: $('composer-input').value, cached: state.sessions.size,
          question: state.questionInputs, sent: __log.slice(__mark)
        };
        """)
        XCTAssertEqual(harness.json("__sync") as? NSDictionary, [
            "detail": false, "sessions": false, "lock": true, "page": harness.string("__sync.page") ?? "",
            "composer": "", "cached": 0, "question": NSNull(), "sent": [] as NSArray
        ] as NSDictionary, "cleared before the lock frame is signed and sent")
        let syncPage = harness.string("__sync.page") ?? ""
        for secret in ["Secret session", "secret transcript", "let secret", "Secret question", "draft", "partial"] {
            XCTAssertFalse(syncPage.contains(secret), "\(secret) left on the page")
        }
        let lock = try XCTUnwrap(harness.json("__lastSent()") as? NSDictionary)
        XCTAssertEqual(lock["type"] as? String, "lock")
        XCTAssertNil(lock["request_id"], "Lock is not a correlated request")
        XCTAssertNil(lock["payload"])

        // Every stale completion arrives after the lock.
        let sentBefore = harness.int("__ws().sent.length")
        harness.run("""
        __resolveAll('list_sessions', { sessions: [{ session_id: 'S9', session: { name: 'Leaked list' } }] });
        __resolveAll('poll', __question);
        __resolveAll('get_log', { total_turns: 1, transcript_xml: '<user>leaked transcript</user>' });
        __resolveAll('subscribe', {});
        __deliver(__ws(), { v: 1, type: 'session_update', session_id: 'S1', seq: 9, payload: __question });
        __deliver(__ws(), { v: 1, type: 'interaction_resolved', session_id: 'S1', seq: 10, payload: {} });
        __clipboard[0].resolve();
        __detailTick();
        __transcriptTick();
        """)
        XCTAssertEqual(harness.int("__ws().sent.length"), sentBefore, "no stale callback sent anything")
        XCTAssertEqual(harness.int("state.sessions.size"), 0)
        XCTAssertEqual(harness.int("$('sessions-list').childNodes.length"), 0)
        XCTAssertNil(harness.string("state.currentSessionId"))
        XCTAssertEqual(harness.int("copyResetTimers.size"), 0, "no copy reset timer keeps the code text")
        let page = harness.pageText()
        for leaked in ["Leaked", "leaked transcript", "Secret", "secret"] {
            XCTAssertFalse(page.contains(leaked), "\(leaked) reached the page after the lock")
        }
        XCTAssertFalse(harness.string("$('log').textContent")?.contains("S1") == true, "the activity log is cleared")
        XCTAssertEqual(harness.string("state.deepLinkSessionId"), "S1", "the session to reopen is kept")

        // The gateway's lock_state is followed afterwards.
        harness.run("__lockState(__ws(), __access({ lock_generation: '4' }));")
        XCTAssertTrue(harness.shown("unlock-button"))
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 1)
        harness.assertNoException()
    }

    func testQuestionAndComposerDraftsRestoreOnlyForTheirFreshSessionAndInteraction() throws {
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1()
        harness.editDrafts()
        harness.run("$('lock-button').onclick({ isTrusted: true });")
        harness.run("__lockState(__ws(), __access({ lock_generation: '4' }));")

        // A different question in the same session is not filled in.
        harness.unlockViaPasskey(grant: "grant-2", lockGeneration: "4")
        harness.openS1(snapshot: "__question2")
        XCTAssertEqual(harness.json("__formState()") as? NSArray, PWAPasskeyHarness.untouchedForm)
        XCTAssertEqual(harness.string("$('composer-input').value"), "  draft\n", "the composer draft comes back as typed")

        // The matching fresh question gets the exact partial answers back.
        harness.run("__deliver(__ws(), { v: 1, type: 'session_update', session_id: 'S1', seq: 1, payload: __question });")
        XCTAssertEqual(harness.json("__formState()") as? NSArray, PWAPasskeyHarness.editedForm)
        XCTAssertEqual(harness.count(type: "respond"), 0, "restored answers are not submitted")
        XCTAssertEqual(harness.count(type: "steer"), 0, "the restored draft is not sent")

        // Restored once: a later rebuild of that question starts empty.
        harness.run("$('interaction-box').dataset.interactionId = ''; renderSessionDetail();")
        XCTAssertEqual(harness.json("__formState()") as? NSArray, PWAPasskeyHarness.untouchedForm)

        // Drafts are keyed by session: another session with the same interaction id gets nothing.
        harness.editDrafts()
        harness.run("$('lock-button').onclick({ isTrusted: true }); __lockState(__ws(), __access({ lock_generation: '5' }));")
        harness.unlockViaPasskey(grant: "grant-3", lockGeneration: "5")
        harness.run("showSessionsList(); openSession('S2');")
        harness.run("__resolveAll('subscribe', {}); __resolveAll('list_sessions', { sessions: [] });")
        harness.run("__resolveAll('poll', __question);")
        XCTAssertEqual(harness.string("state.currentSessionId"), "S2")
        XCTAssertEqual(harness.string("$('composer-input').value"), "")
        XCTAssertEqual(harness.json("__formState()") as? NSArray, PWAPasskeyHarness.untouchedForm)
        XCTAssertEqual(harness.int("state.questionDrafts.size"), 1, "S1's answers stay in memory for S1")
        harness.assertNoException()
    }

    func testUncertainActionIsNeverResentAndAsksForInspection() throws {
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1(snapshot: "__running")
        harness.run("$('composer-input').value = 'go now'; $('composer-send').onclick();")
        XCTAssertEqual(harness.count(type: "steer"), 1)

        // The grant ends while the steer is in flight; its reply is withheld as a lock error.
        harness.run("__lockState(__ws(), __access({ lock_generation: '4', reason: 'passkey_locked' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertTrue(harness.shown("lock-uncertain"))
        harness.run("__reply(__ws(), __lastSent('steer'), 'command_error', { code: 'passkey_locked', message: 'This connection is locked and requires passkey verification.' });")
        XCTAssertEqual(harness.count(type: "steer"), 1)

        harness.unlockViaPasskey(grant: "grant-2", lockGeneration: "4")
        harness.openS1(snapshot: "__running")
        XCTAssertEqual(harness.string("$('composer-input').value"), "go now", "the draft is kept, not sent again")
        XCTAssertEqual(harness.count(type: "steer"), 1, "an uncertain action is never resent automatically")
        XCTAssertTrue(harness.string("$('action-status').textContent")?.contains("may have completed") == true)
        XCTAssertTrue(harness.string("$('connect-status').textContent")?.contains("Check the refreshed session") == true)
        harness.assertNoException(expectedLogFailures: [])
    }

    func testOldSocketFramesAreIgnoredAndReconnectReusesALiveGrantWithoutPrompt() throws {
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1(snapshot: "__running")
        harness.run("$('composer-input').value = 'kept'; var ws1 = __ws(); refreshTranscript();")
        harness.run("__drop(ws1);")
        XCTAssertFalse(harness.bool("state.contentOpen"), "a required-mode disconnect clears the page")
        XCTAssertFalse(harness.pageText().contains("Secret session"))

        harness.run("$('connect-button').onclick();")
        harness.run("var ws2 = __ws(); __open(ws2);")
        // Late frames from the closed socket, including a reply to its old request.
        harness.run("""
        __deliver(ws1, { v: 1, type: 'session_update', session_id: 'S1', seq: 4, payload: __question });
        __deliver(ws1, { v: 1, type: 'lock_state', payload: __unlocked({ grant_id: 'forged' }) });
        __deliver(ws1, { v: 1, type: 'hello_ack', payload: { locked: false, access: __unlocked() } });
        """)
        XCTAssertFalse(harness.bool("state.contentOpen"), "nothing from the old socket counts")
        XCTAssertEqual(harness.int("state.sessions.size"), 0)

        harness.run("__hello(ws2, __unlocked());")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.int("__credentialCalls.length"), 0, "a live shared grant needs no passkey prompt")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "subscribe"])
        XCTAssertEqual(harness.string("$('composer-input').value"), "kept")
        harness.assertNoException()
    }

    // MARK: Foreground, restored pages and metadata order

    func testForegroundAndRestoredPageHideBeforeReconnectAndWaitForHello() throws {
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1(snapshot: "__running")
        harness.run("$('composer-input').value = 'typed';")

        harness.run("document.visibilityState = 'hidden'; __fire('visibilitychange', {});")
        XCTAssertFalse(harness.bool("state.contentOpen"), "hidden before the page goes to the background")
        XCTAssertFalse(harness.pageText().contains("Secret session"))
        XCTAssertEqual(harness.int("__sockets.length"), 1, "no timer or reconnect runs in the background")

        harness.run("document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertEqual(harness.int("__sockets.length"), 2, "returning reconnects for an authoritative hello")
        XCTAssertEqual(harness.int("__sockets[0].readyState"), 3)
        harness.run("var ws2 = __ws(); __open(ws2);")
        XCTAssertFalse(harness.bool("state.contentOpen"), "nothing shows before hello")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello"])
        harness.run("__hello(ws2, __unlocked());")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.int("__credentialCalls.length"), 0)
        harness.openS1(snapshot: "__running")
        XCTAssertEqual(harness.string("$('composer-input').value"), "typed")

        // A restored back-forward-cache page hides first, even with its socket still open.
        harness.run("""
        __fireWindow('pageshow', { persisted: true });
        var __restored = { open: state.contentOpen, page: __pageText() };
        """)
        XCTAssertFalse(harness.bool("__restored.open"))
        XCTAssertFalse(harness.string("__restored.page")?.contains("Secret session") == true)
        XCTAssertEqual(harness.int("__sockets.length"), 3)
        harness.run("var ws3 = __ws(); __open(ws3); __hello(ws3, __access({ lock_generation: '9' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"), "an expired grant stays locked after return")
        XCTAssertTrue(harness.shown("unlock-button"))

        // A locked page keeps its socket and open native prompt across a visibility flip.
        harness.answerChallenge(kind: "assertion")
        harness.run("$('unlock-button').onclick({ isTrusted: true });")
        harness.run("document.visibilityState = 'hidden'; __fire('visibilitychange', {}); document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertEqual(harness.int("__sockets.length"), 3)
        harness.run("__credentialCalls[0].resolve(__assertionCredential());")
        XCTAssertEqual(harness.strings("ws3.sent.map(function (f) { return f.type; })").last, "passkey_unlock_complete")
        harness.assertNoException()
    }

    func testPolicyOffPageHidesOnReturnUntilTheGatewayReportsCurrentPolicy() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access({ policy_state: 'off', locked: false, enrolled: false })")
        harness.openS1(snapshot: "__running")
        XCTAssertTrue(harness.pageText().contains("Secret session"))

        // Suspended in the background (no frames) while the Mac turns protection on.
        harness.run("""
        document.visibilityState = 'hidden'; __fire('visibilitychange', {});
        document.visibilityState = 'visible'; __fire('visibilitychange', {});
        var __returned = { open: state.contentOpen, page: __pageText() };
        """)
        XCTAssertFalse(harness.bool("__returned.open"), "hidden synchronously, before any network await")
        XCTAssertFalse(harness.string("__returned.page")?.contains("Secret session") == true)
        XCTAssertEqual(harness.int("__sockets.length"), 2)
        harness.run("var ws2 = __ws(); __open(ws2);")
        XCTAssertFalse(harness.bool("state.contentOpen"), "nothing shows before hello")
        harness.run("__hello(ws2, __access());")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertTrue(harness.shown("unlock-button"))
        XCTAssertFalse(harness.pageText().contains("Secret session"))
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "passkey_unlock_begin"])

        // A restored back-forward-cache entry also hides first under policy off.
        let restored = try PWAPasskeyHarness()
        restored.connect(access: "__access({ policy_state: 'off', locked: false, enrolled: false })")
        restored.openS1(snapshot: "__running")
        restored.run("""
        __fireWindow('pageshow', { persisted: true });
        var __restored = { open: state.contentOpen, page: __pageText() };
        """)
        XCTAssertFalse(restored.bool("__restored.open"))
        XCTAssertFalse(restored.string("__restored.page")?.contains("Secret session") == true)
        XCTAssertEqual(restored.int("__sockets.length"), 2)
        harness.assertNoException()
        restored.assertNoException()
    }

    func testHiddenPageReceivingAnUnlockedGrantStaysSealedUntilAForegroundHello() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.run("document.visibilityState = 'hidden'; __fire('visibilitychange', {});")
        // Another tab unlocks while this one is hidden.
        harness.run("__lockState(__ws(), __unlocked({ grant_id: 'grant-9' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.sentTypes(), ["hello", "passkey_unlock_begin"], "no target fetch while hidden")
        XCTAssertTrue(harness.bool("state.needsFreshHello"))
        XCTAssertTrue(harness.string("$('lock-message').textContent")?.contains("Checking access") == true)
        XCTAssertFalse(harness.shown("unlock-button"))

        // The same holds for an unlocked page that was hidden and then renewed or re-granted.
        harness.run("document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertEqual(harness.int("__sockets.length"), 2, "the foreground return asks a fresh hello")
        harness.run("var ws2 = __ws(); __open(ws2); __lockState(ws2, __unlocked({ grant_id: 'grant-9' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"), "lock_state before hello does not open")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello"])
        XCTAssertFalse(harness.shown("unlock-button"))
        harness.run("__hello(ws2, __unlocked({ grant_id: 'grant-9' }));")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.int("__credentialCalls.length"), 0, "grant reuse without a prompt")
        harness.openS1(snapshot: "__running")
        XCTAssertTrue(harness.pageText().contains("Secret session"))

        harness.run("document.visibilityState = 'hidden'; __fire('visibilitychange', {});")
        harness.run("__lockState(__ws(), __unlocked({ grant_id: 'grant-10', lock_generation: '4' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertFalse(harness.pageText().contains("Secret session"), "no DOM refill while hidden")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "subscribe", "poll", "get_log"])
        harness.run("document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertEqual(harness.int("__sockets.length"), 3)
        XCTAssertFalse(harness.bool("state.contentOpen"))
        harness.run("var ws3 = __ws(); __open(ws3); __hello(ws3, __unlocked({ grant_id: 'grant-10', lock_generation: '4' }));")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.strings("ws3.sent.map(function (f) { return f.type; })"), ["hello", "subscribe"])
        harness.assertNoException()
    }

    func testPasskeyPromptOutlivingABackgroundTripSettlesOnItsSocketThenAwaitsHello() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.answerChallenge(kind: "assertion")
        harness.run("var ws1 = __ws(); $('unlock-button').onclick({ isTrusted: true });")
        // The native prompt may background the page; the socket that began the ceremony stays.
        harness.run("document.visibilityState = 'hidden'; __fire('visibilitychange', {}); document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertEqual(harness.int("__sockets.length"), 1)
        XCTAssertEqual(harness.int("ws1.readyState"), 1)

        harness.run("__credentialCalls[0].resolve(__assertionCredential());")
        XCTAssertEqual(harness.count(type: "passkey_unlock_complete"), 1)
        XCTAssertEqual(harness.strings("ws1.sent.map(function (f) { return f.type; })"), ["hello", "passkey_unlock_begin", "passkey_unlock_complete"])
        // The unlock notice on the original socket does not open the page by itself.
        harness.run("__lockState(ws1, __unlocked({ grant_id: 'grant-2' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.count(type: "subscribe"), 0)
        XCTAssertEqual(harness.int("__sockets.length"), 1, "the complete is still outstanding on that socket")

        harness.run("__reply(ws1, __lastSent('passkey_unlock_complete'), 'passkey_ceremony_complete', { kind: 'assertion' });")
        XCTAssertEqual(harness.int("__sockets.length"), 2, "settled, then a fresh connection")
        XCTAssertEqual(harness.int("ws1.readyState"), 3)
        XCTAssertFalse(harness.bool("state.contentOpen"))
        harness.run("var ws2 = __ws(); __open(ws2);")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello"], "nothing is resent on the new socket")
        harness.run("__hello(ws2, __unlocked({ grant_id: 'grant-2' }));")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.int("__credentialCalls.length"), 1, "the grant is reused without another prompt")
        XCTAssertEqual(harness.count(type: "passkey_unlock_complete"), 1)
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "subscribe"])

        // A prompt cancelled after a background trip also settles first, then reconnects.
        let cancelled = try PWAPasskeyHarness()
        cancelled.connect(access: "__access()")
        cancelled.answerChallenge(kind: "assertion")
        cancelled.run("$('unlock-button').onclick({ isTrusted: true }); document.visibilityState = 'hidden'; __fire('visibilitychange', {}); document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertEqual(cancelled.int("__sockets.length"), 1)
        cancelled.run("__credentialCalls[0].reject(__domError('NotAllowedError'));")
        XCTAssertEqual(cancelled.count(type: "passkey_unlock_complete"), 0)
        XCTAssertEqual(cancelled.int("__sockets.length"), 2)
        cancelled.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access());")
        XCTAssertFalse(cancelled.bool("state.contentOpen"))
        XCTAssertTrue(cancelled.shown("unlock-button"))
        XCTAssertEqual(cancelled.int("__credentialCalls.length"), 1, "no automatic retry of the prompt")
        harness.assertNoException()
        cancelled.assertNoException()
    }

    func testLockedPageReturningFromTheBackgroundIgnoresOldSocketNoticesUntilAFreshHello() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.answerChallenge(kind: "assertion")
        harness.run("var ws1 = __ws(); document.visibilityState = 'hidden'; __fire('visibilitychange', {});")
        XCTAssertNil(harness.string("state.ceremony"), "cached options are dropped on leaving; another tab may replace them")
        // No metadata arrives while away.
        harness.run("document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertEqual(harness.int("__sockets.length"), 2, "a locked page is reconciled by a fresh hello too")
        XCTAssertEqual(harness.int("ws1.readyState"), 3)
        // A buffered unlock notice from the original socket, delivered after the return.
        harness.run("__lockState(ws1, __unlocked({ grant_id: 'grant-5' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.count(type: "subscribe"), 0)
        XCTAssertEqual(harness.count(type: "poll"), 0)

        // A second return event before the new socket's hello keeps that socket.
        harness.run("var ws2 = __ws(); __fireWindow('pageshow', { persisted: true }); __fire('visibilitychange', {});")
        XCTAssertEqual(harness.int("__sockets.length"), 2)
        harness.run("__open(ws2); __lockState(ws2, __unlocked({ grant_id: 'grant-5' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"), "metadata before the fresh hello does not open")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello"])
        harness.run("__hello(ws2, __unlocked({ grant_id: 'grant-5' }));")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.int("__credentialCalls.length"), 0, "the shared grant is reused without a prompt")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "subscribe"])

        // pagehide and a restored back-forward-cache entry of a locked page reconnect too.
        let restored = try PWAPasskeyHarness()
        restored.connect(access: "__access()")
        restored.run("__fireWindow('pagehide', {}); __fireWindow('pageshow', { persisted: true });")
        XCTAssertEqual(restored.int("__sockets.length"), 2)
        harness.assertNoException()
        restored.assertNoException()
    }

    func testDraftsLeftBehindTheSessionsListSurviveLockAndBackground() throws {
        let lock = "$('lock-button').onclick({ isTrusted: true }); __lockState(__ws(), __access({ lock_generation: '4' }));"
        let background = "document.visibilityState = 'hidden'; __fire('visibilitychange', {}); "
            + "document.visibilityState = 'visible'; __fire('visibilitychange', {});"
        let cases: [(transition: String, viaPasskey: Bool, snapshot: String, form: NSArray)] = [
            (lock, true, "__question", PWAPasskeyHarness.editedForm),
            (background, false, "__question", PWAPasskeyHarness.editedForm),
            (lock, true, "__question2", PWAPasskeyHarness.untouchedForm)
        ]
        for (transition, viaPasskey, snapshot, form) in cases {
            let harness = try PWAPasskeyHarness()
            harness.unlockAndOpenS1()
            harness.editDrafts()
            harness.run("$('back-to-sessions').onclick();")
            XCTAssertNil(harness.string("state.currentSessionId"))
            XCTAssertTrue(harness.shown("sessions-panel"))
            harness.run(transition)
            XCTAssertFalse(harness.bool("state.contentOpen"))
            XCTAssertNil(harness.string("state.questionInputs"))
            XCTAssertEqual(harness.int("$('question-form').childNodes.length"), 0)
            XCTAssertEqual(harness.string("$('composer-input').value"), "")

            if viaPasskey {
                harness.unlockViaPasskey(grant: "grant-2", lockGeneration: "4")
            } else {
                harness.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __unlocked());")
            }
            XCTAssertTrue(harness.bool("state.contentOpen"))
            XCTAssertTrue(harness.shown("sessions-panel"), "the list was showing, so the list comes back")
            harness.run("__resolveAll('list_sessions', { sessions: [] }); openSession('S1');")
            harness.run("__resolveAll('subscribe', {});")
            harness.run("__resolveAll('poll', \(snapshot));")
            XCTAssertEqual(harness.json("__formState()") as? NSArray, form, snapshot)
            XCTAssertEqual(harness.string("$('composer-input').value"), "  draft\n", "the raw composer draft comes back")
            XCTAssertEqual(harness.count(type: "respond"), 0, "restored answers are not submitted")
            XCTAssertEqual(harness.count(type: "steer"), 0)
            harness.assertNoException()
        }
    }

    func testReconnectIsOfferedAfterASettledFailureAndReplacesTheSocket() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access({ enrolled: false, enrollment_open: true })")
        harness.answerChallenge(kind: "registration")
        XCTAssertTrue(harness.shown("lock-reconnect"))
        harness.run("var ws1 = __ws(); $('setup-passkey-button').onclick({ isTrusted: true });")
        XCTAssertFalse(harness.shown("lock-reconnect"), "not while the prompt is open")
        harness.run("__credentialCalls[0].resolve(__registrationCredential());")
        XCTAssertFalse(harness.shown("lock-reconnect"), "not while the complete is outstanding")

        // The app saved the passkey but the gateway could not confirm it yet.
        harness.run("__reply(ws1, __lastSent('passkey_register_complete'), 'command_error', { code: 'passkey_unavailable', message: 'The request was rejected.' });")
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("Tap Reconnect") == true)
        XCTAssertFalse(harness.shown("setup-passkey-button"), "no second setup is offered over a saved passkey")
        XCTAssertTrue(harness.shown("lock-reconnect"))
        XCTAssertEqual(harness.count(type: "passkey_register_begin"), 1)

        harness.run("$('lock-reconnect').onclick();")
        XCTAssertEqual(harness.int("__sockets.length"), 2, "Reconnect replaces the socket")
        XCTAssertEqual(harness.int("ws1.readyState"), 3)
        harness.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access());")
        XCTAssertTrue(harness.shown("unlock-button"))
        XCTAssertFalse(harness.shown("setup-passkey-button"))
        XCTAssertEqual(harness.string("$('lock-status').textContent"), "Preparing the passkey request…")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "passkey_unlock_begin"])
        XCTAssertEqual(harness.int("__credentialCalls.length"), 1)
        harness.assertNoException()
    }

    func testLockStatusAndHeadingFollowTheCurrentState() throws {
        let harness = try PWAPasskeyHarness()
        XCTAssertEqual(harness.string("$('lock-title').textContent"), "Connecting")
        harness.run("var ws = __ws(); __open(ws); __hello(ws, __access());")
        XCTAssertEqual(harness.string("$('lock-title').textContent"), "Locked")
        XCTAssertEqual(harness.string("state.ceremony.phase"), "fetching")
        XCTAssertTrue(harness.bool("$('unlock-button').disabled"), "Unlock waits for its options")
        XCTAssertEqual(harness.string("$('lock-status').textContent"), "Preparing the passkey request…")
        harness.run("$('unlock-button').onclick({ isTrusted: true });")
        XCTAssertEqual(harness.int("__credentialCalls.length"), 0)
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 1)
        XCTAssertEqual(harness.string("$('lock-status').textContent"), "Preparing the passkey request…")

        harness.answerChallenge(kind: "assertion")
        XCTAssertFalse(harness.bool("$('unlock-button').disabled"))
        XCTAssertEqual(harness.string("$('lock-status').textContent"), "")
        harness.run("$('unlock-button').onclick({ isTrusted: true }); __credentialCalls[0].resolve(__assertionCredential());")
        harness.run("__reply(ws, __lastSent('passkey_unlock_complete'), 'passkey_ceremony_complete', { kind: 'assertion' });")
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("Passkey verified") == true)
        harness.run("__lockState(ws, __unlocked());")
        XCTAssertTrue(harness.bool("state.contentOpen"))

        // A later relock does not show the earlier ceremony's text.
        harness.run("$('lock-button').onclick({ isTrusted: true }); __lockState(ws, __access({ lock_generation: '4', reason: 'passkey_locked' }));")
        XCTAssertEqual(harness.string("$('lock-title').textContent"), "Locked")
        XCTAssertEqual(harness.string("$('lock-status').textContent"), "Preparing the passkey request…")
        harness.answerChallenge(kind: "assertion")
        XCTAssertEqual(harness.string("$('lock-status').textContent"), "")

        // A policy-off page returning from the background is not called locked.
        let off = try PWAPasskeyHarness()
        off.connect(access: "__access({ policy_state: 'off', locked: false, enrolled: false })")
        off.run("document.visibilityState = 'hidden'; __fire('visibilitychange', {}); document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        XCTAssertTrue(off.shown("lock-panel"))
        XCTAssertEqual(off.string("$('lock-title').textContent"), "Connecting")
        off.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access({ policy_state: 'off', locked: false, enrolled: false }));")
        XCTAssertFalse(off.shown("lock-panel"))
        harness.assertNoException()
        off.assertNoException()
    }

    func testActionSettledWhileHiddenIsNotRestoredOrFlaggedButOthersStayUncertain() throws {
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1(snapshot: "__running")
        harness.run("$('composer-input').value = 'go now'; $('composer-send').onclick();")
        harness.run("var ws1 = __ws(); document.visibilityState = 'hidden'; __fire('visibilitychange', {});")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertTrue(harness.shown("lock-uncertain"))
        harness.run("__result(ws1, __lastSent('steer'), {});")
        XCTAssertFalse(harness.shown("lock-uncertain"), "its reply settled it")
        XCTAssertEqual(harness.int("state.composerDrafts.size"), 0, "text known to be sent is not kept as a draft")

        harness.run("document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        harness.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __unlocked());")
        harness.openS1(snapshot: "__running")
        XCTAssertEqual(harness.string("$('composer-input').value"), "")
        XCTAssertFalse(harness.string("$('action-status').textContent")?.contains("may have completed") == true)
        XCTAssertEqual(harness.count(type: "steer"), 1)

        // Two actions in flight: one success does not settle the other.
        let two = try PWAPasskeyHarness()
        two.unlockAndOpenS1(snapshot: "__running")
        two.run("$('composer-input').value = 'one'; $('composer-send').onclick(); $('composer-input').value = 'two'; $('composer-send').onclick();")
        XCTAssertEqual(two.count(type: "steer"), 2)
        two.run("var ws1 = __ws(); document.visibilityState = 'hidden'; __fire('visibilitychange', {});")
        two.run("__result(ws1, ws1.sent.filter(function (f) { return f.type === 'steer'; })[0], {});")
        XCTAssertTrue(two.shown("lock-uncertain"), "the second steer is still unsettled")
        // The return replaces the socket; the second steer's outcome stays unknown.
        two.run("document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        two.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __unlocked());")
        XCTAssertTrue(two.string("$('action-status').textContent")?.contains("may have completed") == true)
        XCTAssertEqual(two.string("$('composer-input').value"), "two", "the draft is kept, not sent again")
        XCTAssertEqual(two.count(type: "steer"), 2)
        harness.assertNoException()
        two.assertNoException()
    }

    func testSocketLostDuringABackgroundedPromptReconnectsAfterItSettles() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.answerChallenge(kind: "assertion")
        harness.run("""
        var ws1 = __ws(); $('unlock-button').onclick({ isTrusted: true });
        document.visibilityState = 'hidden'; __fire('visibilitychange', {});
        document.visibilityState = 'visible'; __fire('visibilitychange', {});
        """)
        XCTAssertEqual(harness.int("__sockets.length"), 1)
        // The socket closes after the return, while the prompt is still open.
        harness.run("__drop(ws1);")
        XCTAssertEqual(harness.int("__sockets.length"), 1)
        harness.run("__credentialCalls[0].resolve(__assertionCredential());")
        XCTAssertEqual(harness.count(type: "passkey_unlock_complete"), 0, "never completed on another connection")
        XCTAssertEqual(harness.int("__sockets.length"), 2, "the page reconnects by itself")
        harness.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access());")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "passkey_unlock_begin"])
        XCTAssertTrue(harness.shown("unlock-button"))

        // A prompt that never settles does not block a new connection's ceremony.
        let stuck = try PWAPasskeyHarness()
        stuck.connect(access: "__access()")
        stuck.answerChallenge(kind: "assertion")
        stuck.run("var ws1 = __ws(); $('unlock-button').onclick({ isTrusted: true }); __drop(ws1); $('connect-button').onclick();")
        stuck.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access());")
        XCTAssertEqual(stuck.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "passkey_unlock_begin"])
        stuck.answerChallenge(kind: "assertion")
        XCTAssertFalse(stuck.bool("$('unlock-button').disabled"))
        stuck.run("__credentialCalls[0].resolve(__assertionCredential());")
        XCTAssertEqual(stuck.count(type: "passkey_unlock_complete"), 0, "the old prompt's result is discarded")
        XCTAssertEqual(stuck.string("state.ceremony.phase"), "ready")
        harness.assertNoException()
        stuck.assertNoException()
    }

    func testStaleRefreshTimersDoNotStopLaterRefreshes() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access({ policy_state: 'off', locked: false, enrolled: false })")
        harness.openS1(snapshot: "__running")
        harness.run("""
        scheduleDetailRefresh(); maybeRefreshTranscript();
        var __d = __timers[detailRefreshTimer]; var __t = __timers[transcriptRefreshTimer];
        state.accessGeneration += 1; __d(); __t();
        """)
        XCTAssertTrue(harness.bool("detailRefreshTimer === null && transcriptRefreshTimer === null"))
        harness.run("scheduleDetailRefresh(); maybeRefreshTranscript();")
        XCTAssertTrue(harness.bool("detailRefreshTimer !== null && transcriptRefreshTimer !== null"), "refresh still schedules")
        harness.run("resetIdentityState();")
        XCTAssertTrue(harness.bool("detailRefreshTimer === null && transcriptRefreshTimer === null"), "an identity reset clears them")
        harness.assertNoException()
    }

    func testClientReasonCodesMatchTheGateway() throws {
        let harness = try PWAPasskeyHarness()
        XCTAssertEqual(harness.strings("LOCK_CODES"), [
            GatewaySafeControlReason.locked.rawValue, GatewaySafeControlReason.grantExpired.rawValue
        ])
        XCTAssertEqual(harness.json("PASSKEY_FAILURE_CODES") as? NSDictionary, [
            "staleCeremony": GatewaySafeControlReason.staleCeremony.rawValue,
            "unavailable": GatewaySafeControlReason.unavailable.rawValue,
            "authenticationFailure": GatewaySafeControlReason.authenticationFailure.rawValue
        ] as NSDictionary)
        XCTAssertEqual(harness.string("PASSKEY_EXPIRED_REASON"), GatewaySafeControlReason.grantExpired.rawValue)
        // "Saved" wording belongs to registration only.
        XCTAssertFalse(harness.string("completeFailureText('assertion', { code: 'passkey_unavailable' })")?.contains("saved") == true)
    }

    func testSentTextLeftBehindTheSessionsListIsNotRestored() throws {
        // Sent, then Sessions before the reply: the reply clears the kept composer.
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1(snapshot: "__running")
        harness.run("$('composer-input').value = 'go now'; $('composer-send').onclick(); $('back-to-sessions').onclick();")
        harness.run("__result(__ws(), __lastSent('steer'), {});")
        XCTAssertEqual(harness.string("$('composer-input').value"), "")
        harness.run("$('lock-button').onclick({ isTrusted: true }); __lockState(__ws(), __access({ lock_generation: '4' }));")
        XCTAssertEqual(harness.int("state.composerDrafts.size"), 0, "sent text is not saved as a draft")
        harness.unlockViaPasskey(grant: "grant-2", lockGeneration: "4")
        harness.run("__resolveAll('list_sessions', { sessions: [] }); openSession('S1');")
        XCTAssertEqual(harness.string("$('composer-input').value"), "")
        XCTAssertEqual(harness.count(type: "steer"), 1)
        harness.assertNoException()

        // Newer text typed after sending survives, through a background trip.
        let newer = try PWAPasskeyHarness()
        newer.unlockAndOpenS1(snapshot: "__running")
        newer.run("$('composer-input').value = 'one'; $('composer-send').onclick(); $('composer-input').value = 'two'; $('back-to-sessions').onclick();")
        newer.run("__result(__ws(), __lastSent('steer'), {});")
        XCTAssertEqual(newer.string("$('composer-input').value"), "two")
        newer.run("document.visibilityState = 'hidden'; __fire('visibilitychange', {}); document.visibilityState = 'visible'; __fire('visibilitychange', {});")
        newer.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __unlocked());")
        newer.run("__resolveAll('list_sessions', { sessions: [] }); openSession('S1');")
        XCTAssertEqual(newer.string("$('composer-input').value"), "two")
        XCTAssertEqual(newer.count(type: "steer"), 1)
        newer.assertNoException()
    }

    func testBackgroundedPromptFailureStaysReadableAfterTheFollowUpReconnect() throws {
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.answerChallenge(kind: "assertion")
        harness.run("""
        var ws1 = __ws(); $('unlock-button').onclick({ isTrusted: true });
        document.visibilityState = 'hidden'; __fire('visibilitychange', {});
        document.visibilityState = 'visible'; __fire('visibilitychange', {});
        __credentialCalls[0].resolve(__assertionCredential());
        """)
        harness.run("__reply(ws1, __lastSent('passkey_unlock_complete'), 'command_error', { code: 'authentication_failed', message: 'The request was rejected.' });")
        XCTAssertEqual(harness.int("__sockets.length"), 2)
        harness.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access());")
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("could not be verified") == true)
        harness.answerChallenge(kind: "assertion")
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("could not be verified") == true)
        XCTAssertTrue(harness.shown("unlock-button"))
        // A later, ordinary hello clears it.
        harness.run("reconnectNow();")
        harness.run("var ws3 = __ws(); __open(ws3); __hello(ws3, __access());")
        XCTAssertEqual(harness.int("__sockets.length"), 3)
        XCTAssertEqual(harness.string("$('lock-status').textContent"), "Preparing the passkey request…")
        harness.assertNoException()
    }

    func testCompletionAfterTheUnlockNoticeLeavesNoStaleWaiting() throws {
        // The unlocked lock_state arrives before the completion reply.
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.answerChallenge(kind: "assertion")
        harness.run("$('unlock-button').onclick({ isTrusted: true }); __credentialCalls[0].resolve(__assertionCredential());")
        harness.run("__lockState(__ws(), __unlocked());")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        harness.run("__reply(__ws(), __lastSent('passkey_unlock_complete'), 'passkey_ceremony_complete', { kind: 'assertion' });")
        XCTAssertNil(harness.string("state.ceremonyDoneKey"))
        harness.run("$('lock-button').onclick({ isTrusted: true }); __lockState(__ws(), __access({ lock_generation: '4' }));")
        XCTAssertFalse(harness.string("$('lock-status').textContent")?.contains("Passkey verified") == true)
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 2)

        // Expiry reusing the pre-unlock key still offers Unlock. (The gateway advances the
        // lock generation on expiry, so this guards the client only.)
        let expiry = try PWAPasskeyHarness()
        expiry.connect(access: "__access()")
        expiry.unlockViaPasskey(grant: "grant-1", lockGeneration: "3")
        XCTAssertTrue(expiry.bool("state.contentOpen"))
        expiry.run("__lockState(__ws(), __access({ reason: 'passkey_expired' }));")
        XCTAssertTrue(expiry.shown("unlock-button"))
        XCTAssertEqual(expiry.count(type: "passkey_unlock_begin"), 2)
        XCTAssertFalse(expiry.string("$('lock-message').textContent")?.contains("Waiting for your Mac") == true)
        harness.assertNoException()
        expiry.assertNoException()
    }

    func testOwnReconnectsAreNotReportedAsFailures() throws {
        // A socket lost during a foreground prompt reconnects once the prompt settles.
        let harness = try PWAPasskeyHarness()
        harness.connect(access: "__access()")
        harness.answerChallenge(kind: "assertion")
        harness.run("var ws1 = __ws(); $('unlock-button').onclick({ isTrusted: true }); __drop(ws1);")
        harness.run("__credentialCalls[0].resolve(__assertionCredential());")
        XCTAssertEqual(harness.count(type: "passkey_unlock_complete"), 0)
        XCTAssertEqual(harness.int("__sockets.length"), 2)
        harness.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access());")
        XCTAssertTrue(harness.string("$('lock-status').textContent")?.contains("Tap Unlock again") == true)
        XCTAssertTrue(harness.shown("unlock-button"))

        // Reconnect while options load: the dropped request is not a failure to report.
        let reconnect = try PWAPasskeyHarness()
        reconnect.connect(access: "__access()")
        XCTAssertEqual(reconnect.string("state.ceremony.phase"), "fetching")
        reconnect.run("$('lock-reconnect').onclick();")
        XCTAssertFalse(reconnect.string("$('lock-status').textContent")?.contains("Could not get") == true)
        reconnect.run("var ws2 = __ws(); __open(ws2); __hello(ws2, __access());")
        XCTAssertEqual(reconnect.string("$('lock-status').textContent"), "Preparing the passkey request…")

        // While a return's reconnect checks the gateway, the panel says Connecting.
        let returning = try PWAPasskeyHarness()
        returning.connect(access: "__access({ policy_state: 'off', locked: false, enrolled: false })")
        returning.run("""
        __healthGate = new Promise(function (resolve) { __releaseHealth = resolve; });
        document.visibilityState = 'hidden'; __fire('visibilitychange', {});
        document.visibilityState = 'visible'; __fire('visibilitychange', {});
        """)
        XCTAssertNil(returning.string("state.ws"))
        XCTAssertEqual(returning.string("$('lock-title').textContent"), "Connecting")
        XCTAssertEqual(returning.string("$('lock-message').textContent"), "Connecting…")
        returning.run("__healthGate = null; __releaseHealth();")
        XCTAssertEqual(returning.int("__sockets.length"), 2)
        harness.assertNoException()
        reconnect.assertNoException()
        returning.assertNoException()
    }

    func testDuplicateAndEarlyMetadataDoNotRepeatSideEffects() throws {
        let harness = try PWAPasskeyHarness()
        // lock_state may arrive before hello_ack; content waits for the hello.
        harness.run("var ws = __ws(); __open(ws); __lockState(ws, __unlocked());")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertEqual(harness.sentTypes(), ["hello"])
        harness.run("__hello(ws, __unlocked());")
        XCTAssertTrue(harness.bool("state.contentOpen"))
        harness.openS1(snapshot: "__running")
        harness.run("$('composer-input').value = 'still here';")

        // Repeated unchanged metadata (new remaining lifetime or advisory reason only) is ignored.
        let generation = harness.int("state.accessGeneration")
        let sent = harness.int("ws.sent.length")
        harness.run("""
        __lockState(ws, __unlocked({ deadline_seconds_remaining: 1200 }));
        __lockState(ws, __unlocked({ deadline_seconds_remaining: 900, reason: 'passkey_locked' }));
        """)
        XCTAssertEqual(harness.int("state.accessGeneration"), generation, "nothing is cleared")
        XCTAssertEqual(harness.int("ws.sent.length"), sent, "nothing is refetched or renewed")
        XCTAssertEqual(harness.string("$('composer-input').value"), "still here")

        // Locked repeats do not restart option prefetch.
        harness.run("__lockState(ws, __access({ lock_generation: '4' }));")
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 1)
        harness.answerChallenge(kind: "assertion")
        harness.run("""
        __lockState(ws, __access({ lock_generation: '4', reason: 'passkey_locked' }));
        __lockState(ws, __access({ lock_generation: '4' }));
        __deliver(ws, { v: 1, type: 'pong', payload: {} });
        __deliver(ws, { v: 1, type: 'command_result', request_id: 'unknown', payload: {} });
        """)
        XCTAssertEqual(harness.count(type: "passkey_unlock_begin"), 1)
        XCTAssertEqual(harness.string("state.ceremony.phase"), "ready", "cached options survive a repeat")
        harness.assertNoException()
    }

    func testExpiryAndGenericLockErrorsClearContent() throws {
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1(snapshot: "__running")
        harness.run("__lockState(__ws(), __access({ reason: 'passkey_expired' }));")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertTrue(harness.string("$('lock-message').textContent")?.contains("30 minutes without activity") == true)
        XCTAssertTrue(harness.shown("unlock-button"))

        // A withheld reply settled as a generic lock error closes the page before any
        // lock_state, and the page waits for the gateway instead of trusting old metadata.
        harness.unlockViaPasskey(grant: "grant-2", lockGeneration: "3")
        harness.openS1(snapshot: "__running")
        harness.run("pollSession('S1');")
        harness.run("__reply(__ws(), __lastSent('poll'), 'command_error', { code: 'passkey_locked', message: 'This connection is locked and requires passkey verification.' });")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        XCTAssertFalse(harness.pageText().contains("Secret session"))
        XCTAssertFalse(harness.shown("unlock-button"))
        XCTAssertTrue(harness.shown("lock-reconnect"))
        // A repeat of the old unlocked metadata does not reopen it.
        harness.run("__lockState(__ws(), __unlocked({ grant_id: 'grant-2', deadline_seconds_remaining: 600 }));")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        harness.run("__lockState(__ws(), __access({ lock_generation: '4' }));")
        XCTAssertTrue(harness.shown("unlock-button"))
        harness.assertNoException()
    }

    func testLockIsResentAfterReconnectUntilTheGatewayConfirms() throws {
        let harness = try PWAPasskeyHarness()
        harness.unlockAndOpenS1(snapshot: "__running")
        harness.run("__signGate = new Promise(function () {}); $('lock-button').onclick({ isTrusted: true }); __drop(__ws());")
        XCTAssertFalse(harness.bool("state.contentOpen"))
        harness.run("$('connect-button').onclick();")
        harness.run("__signGate = null; var ws2 = __ws(); __open(ws2); __hello(ws2, __unlocked());")
        XCTAssertFalse(harness.bool("state.contentOpen"), "the same unlocked grant does not undo a local Lock")
        XCTAssertEqual(harness.strings("ws2.sent.map(function (f) { return f.type; })"), ["hello", "lock"])
        harness.run("__lockState(ws2, __access({ lock_generation: '4' }));")
        XCTAssertTrue(harness.shown("unlock-button"))
        harness.assertNoException()
    }

    // MARK: Foreground activity

    func testActivityReportsOnlyTrustedForegroundInputWithThrottleAndNoTimer() throws {
        let harness = try PWAPasskeyHarness()
        let types = Set(harness.strings("__docListeners.filter(function (l) { return l.options && l.options.capture; }).map(function (l) { return l.type; })"))
        XCTAssertEqual(types, ["keydown", "input", "change", "click", "touchstart", "wheel"])
        XCTAssertFalse(harness.strings("__docListeners.map(function (l) { return l.type; })").contains("scroll"), "page scrolling is not activity")

        // Locked: no activity.
        harness.connect(access: "__access()")
        harness.run("__fire('keydown', { isTrusted: true, target: document.body });")
        XCTAssertEqual(harness.count(type: "passkey_activity"), 0)

        harness.unlockViaPasskey(grant: "grant-1", lockGeneration: "3")
        harness.openS1(snapshot: "__running")
        // Unlock, polling, rendering and transcript loading are not activity.
        XCTAssertEqual(harness.count(type: "passkey_activity"), 0)

        let timers = harness.int("__pendingTimers()")
        harness.run("__fire('click', { isTrusted: false, target: $('composer-send') });")
        XCTAssertEqual(harness.count(type: "passkey_activity"), 0, "synthetic events do not count")
        harness.run("__fire('keydown', { isTrusted: true, target: $('composer-input') });")
        let activity = try XCTUnwrap(harness.json("__lastSent('passkey_activity')") as? NSDictionary)
        XCTAssertEqual(activity["payload"] as? NSDictionary, ["grant_id": "grant-1", "epoch": "7", "lock_generation": "3"] as NSDictionary)
        XCTAssertNil(activity["request_id"], "fire-and-forget")
        XCTAssertEqual(harness.int("__pendingTimers()"), timers, "no trailing or refresh timer")

        harness.run("__now += 29999; __fire('wheel', { isTrusted: true, target: $('transcript-view') }); __fire('touchstart', { isTrusted: true, target: $('transcript-view') });")
        XCTAssertEqual(harness.count(type: "passkey_activity"), 1, "throttled for 30 seconds, nothing queued")
        harness.run("__now += 1; __fire('change', { isTrusted: true, target: $('question-form') });")
        XCTAssertEqual(harness.count(type: "passkey_activity"), 2)

        // Background, Lock taps, network and reconnects never renew.
        harness.run("__now += 60000; document.visibilityState = 'prerender'; __fire('click', { isTrusted: true, target: $('composer-send') }); document.visibilityState = 'visible';")
        harness.run("__fire('click', { isTrusted: true, target: $('lock-button') });")
        harness.run("__deliver(__ws(), { v: 1, type: 'session_update', session_id: 'S1', seq: 3, payload: __running }); pollSession('S1');")
        XCTAssertEqual(harness.count(type: "passkey_activity"), 2)

        // A renewal notice updates the references used by the next report.
        harness.run("__lockState(__ws(), __unlocked({ deadline_seconds_remaining: 1800, lock_generation: '3' })); __fire('input', { isTrusted: true, target: $('composer-input') });")
        XCTAssertEqual(harness.count(type: "passkey_activity"), 3)
        harness.assertNoException()
    }

    // MARK: Shell

    func testShellPlacesLockPresentationOutsideSessionContent() throws {
        let data = try XCTUnwrap(GatewayPWAResources.data(forAsset: "index.html"))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let order = try ["id=\"connect-panel\"", "id=\"lock-panel\"", "id=\"sessions-panel\"", "id=\"detail-panel\""]
            .map { try XCTUnwrap(text.range(of: $0)?.lowerBound, $0) }
        XCTAssertEqual(order, order.sorted(), "the lock panel sits beside, not inside, session content")
        let lockPanel = try XCTUnwrap(text.range(of: "<section id=\"lock-panel\" class=\"panel hidden\""))
        let panelEnd = try XCTUnwrap(text.range(of: "</section>", range: lockPanel.upperBound ..< text.endIndex))
        let panel = String(text[lockPanel.lowerBound ..< panelEnd.upperBound])
        for control in ["id=\"unlock-button\" type=\"button\"", "id=\"setup-passkey-button\" type=\"button\"", "id=\"lock-reconnect\" type=\"button\""] {
            XCTAssertTrue(panel.contains(control), control)
        }
        let header = try XCTUnwrap(text.range(of: "<header id=\"app-header\">"))
        let headerEnd = try XCTUnwrap(text.range(of: "</header>", range: header.upperBound ..< text.endIndex))
        XCTAssertTrue(text[header.lowerBound ..< headerEnd.lowerBound].contains("<button id=\"lock-button\" class=\"link hidden\" type=\"button\">Lock</button>"))
    }
}

final class PWAPasskeyHarness {
    static let untouchedForm: NSArray = [
        ["selected": [] as NSArray, "custom": "", "skipped": false, "disabled": [false, false]],
        ["selected": [] as NSArray, "custom": "", "skipped": false, "disabled": [false, false, false]],
        ["selected": [] as NSArray, "custom": "", "skipped": false, "disabled": [] as NSArray],
        ["selected": [] as NSArray, "custom": "", "skipped": false, "disabled": [false]]
    ]
    static let editedForm: NSArray = [
        ["selected": ["Blue"], "custom": "", "skipped": false, "disabled": [false, false]],
        ["selected": ["A", "C"], "custom": " also ", "skipped": false, "disabled": [false, false, false]],
        ["selected": [] as NSArray, "custom": "  partial ", "skipped": false, "disabled": [] as NSArray],
        ["selected": [] as NSArray, "custom": "", "skipped": true, "disabled": [true]]
    ]

    /// A small tree-bearing DOM (child order, text, classes, attributes, values), a stub
    /// WebSocket that records signed frames, a held-able signer, controllable credential and
    /// clipboard promises, captured document/window listeners, real timers by id and an
    /// injectable clock. Geometry is zero; nothing here is browser evidence.
    private static let browserStub = #"""
    var __elements = {};
    var __log = [];
    function __detach(child) {
      var parent = child.parentNode;
      if (!parent) return;
      parent.childNodes.splice(parent.childNodes.indexOf(child), 1);
      child.parentNode = null;
    }
    function __node(tag, id) {
      var node = {
        tagName: String(tag || 'div').toUpperCase(), id: id || '', value: '', checked: false, className: '',
        placeholder: '', type: '', name: '', autocomplete: '', disabled: false, open: false, offsetParent: null,
        dataset: {}, style: {}, attributes: {}, listeners: {}, childNodes: [], parentNode: null, attached: false, _text: ''
      };
      node.classList = {
        contains: function (name) { return node.className.split(/\s+/).indexOf(name) >= 0; },
        add: function (name) { if (!node.classList.contains(name)) node.className = (node.className + ' ' + name).trim(); },
        remove: function (name) {
          node.className = node.className.split(/\s+/).filter(function (c) { return c && c !== name; }).join(' ');
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
      Object.defineProperty(node, 'firstElementChild', {
        get: function () { return node.childNodes.filter(function (c) { return c.tagName !== '#TEXT'; })[0] || null; }
      });
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
      node.getClientRects = function () { return []; };
      node.getBoundingClientRect = function () { return { top: 0, bottom: 0 }; };
      return node;
    }
    var __docListeners = [];
    var __windowListeners = [];
    var window = {
      innerHeight: 600, isSecureContext: true, PublicKeyCredential: function () {},
      addEventListener: function (type, listener) { __windowListeners.push({ type: type, listener: listener }); },
      getSelection: function () { return { selectAllChildren: function () {}, rangeCount: 0 }; }
    };
    var document = {
      visibilityState: 'visible',
      body: __node('body'),
      scrollingElement: { scrollTop: 0, scrollHeight: 0 },
      getElementById: function (id) {
        if (!__elements[id]) { __elements[id] = __node('div', id); __elements[id].attached = true; }
        return __elements[id];
      },
      createElement: function (tag) { return __node(tag, ''); },
      createTextNode: function (text) { var node = __node('#text', ''); node._text = String(text); return node; },
      addEventListener: function (type, listener, options) { __docListeners.push({ type: type, listener: listener, options: options }); }
    };
    document.activeElement = document.body;
    ['pair-panel', 'connect-panel', 'lock-panel', 'sessions-panel', 'detail-panel', 'binding-overlay', 'lock-button',
      'unlock-button', 'setup-passkey-button', 'lock-reconnect', 'lock-uncertain', 'interaction-box', 'composer',
      'back-to-sessions', 'stop-button', 'load-older', 'gateway-retry', 'answer-on-mac'].forEach(function (id) {
      document.getElementById(id).className = 'hidden';
    });
    document.getElementById('composer-input').tagName = 'TEXTAREA';
    document.getElementById('composer').appendChild(document.getElementById('composer-input'));
    function __fire(type, event) {
      __docListeners.filter(function (l) { return l.type === type; }).forEach(function (l) { l.listener(event); });
    }
    function __fireWindow(type, event) {
      __windowListeners.filter(function (l) { return l.type === type; }).forEach(function (l) { l.listener(event); });
    }

    var location = { search: '?session_id=S1', protocol: 'https:', host: 'phone.test', hostname: 'phone.test' };
    function URLSearchParams(search) {
      this.get = function (name) {
        var match = new RegExp('[?&]' + name + '=([^&]*)').exec(search || '');
        return match ? decodeURIComponent(match[1]) : null;
      };
    }
    var __credentialCalls = [];
    function __credentialCall(kind) {
      return function (options) {
        var call = { kind: kind, options: options };
        __credentialCalls.push(call);
        __log.push('credentials.' + kind);
        return new Promise(function (resolve, reject) { call.resolve = resolve; call.reject = reject; });
      };
    }
    var __clipboard = [];
    var navigator = {
      credentials: { get: __credentialCall('get'), create: __credentialCall('create') },
      clipboard: {
        writeText: function (text) {
          return new Promise(function (resolve, reject) { __clipboard.push({ text: text, resolve: resolve, reject: reject }); });
        }
      }
    };

    var __now = 1000000;
    Date.now = function () { return __now; };
    // Monotonic clock, separate from the wall clock.
    var __mono = 5000;
    var performance = { now: function () { return __mono; } };
    var __timers = {};
    var __timerId = 0;
    function setTimeout(callback) { __timerId += 1; __timers[__timerId] = callback; return __timerId; }
    function clearTimeout(id) { delete __timers[id]; }
    function __pendingTimers() { return Object.keys(__timers).length; }

    var __uuid = 0;
    var __signGate = null;
    var __releaseSign = null;
    var crypto = {
      randomUUID: function () { __uuid += 1; return 'req-' + __uuid; },
      getRandomValues: function (array) { return array; },
      subtle: {
        digest: function () { return Promise.resolve(new ArrayBuffer(32)); },
        sign: function () {
          var signature = new ArrayBuffer(64);
          return __signGate ? __signGate.then(function () { return signature; }) : Promise.resolve(signature);
        }
      }
    };
    function TextEncoder() {}
    TextEncoder.prototype.encode = function (text) {
      var binary = unescape(encodeURIComponent(String(text)));
      var bytes = new Uint8Array(binary.length);
      for (var i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
      return bytes;
    };
    var __b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    function btoa(binary) {
      var out = '';
      for (var i = 0; i < binary.length; i += 3) {
        var n = (binary.charCodeAt(i) << 16) | ((binary.charCodeAt(i + 1) || 0) << 8) | (binary.charCodeAt(i + 2) || 0);
        out += __b64[(n >> 18) & 63] + __b64[(n >> 12) & 63]
          + (i + 1 < binary.length ? __b64[(n >> 6) & 63] : '=') + (i + 2 < binary.length ? __b64[n & 63] : '=');
      }
      return out;
    }
    function atob(text) {
      var clean = String(text).replace(/=+$/, '');
      if (/[^A-Za-z0-9+/]/.test(clean) || clean.length % 4 === 1) throw new Error('InvalidCharacterError');
      var out = '';
      var bits = 0;
      var value = 0;
      for (var i = 0; i < clean.length; i += 1) {
        value = (value << 6) | __b64.indexOf(clean[i]);
        bits += 6;
        if (bits >= 8) {
          bits -= 8;
          out += String.fromCharCode((value >> bits) & 255);
          value &= (1 << bits) - 1;
        }
      }
      return out;
    }

    var __sockets = [];
    function WebSocket(url) { this.url = url; this.readyState = 0; this.sent = []; __sockets.push(this); }
    WebSocket.OPEN = 1;
    WebSocket.prototype.send = function (data) {
      var frame = JSON.parse(data);
      this.sent.push(frame);
      __log.push('send:' + frame.type);
    };
    WebSocket.prototype.close = function () {
      var ws = this;
      if (ws.readyState === 3) return;
      ws.readyState = 3;
      Promise.resolve().then(function () { if (ws.onclose) ws.onclose(); });
    };
    var __tickets = 0;
    // Set to a pending promise to hold the next connection's build-channel check.
    var __healthGate = null;
    var __releaseHealth = null;
    function __response(body) {
      return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.resolve(body); } });
    }
    function fetch(path) {
      if (path === '/healthz') {
        return (__healthGate || Promise.resolve()).then(function () { return __response({ channel: 'debug' }); });
      }
      if (path === '/api/ticket') { __tickets += 1; return __response({ ticket: { ticket_id: 'TICKET-' + __tickets } }); }
      return Promise.reject(new Error('unexpected fetch ' + path));
    }
    var __identity = {
      keyPair: { privateKey: {} },
      device: { deviceId: 'remote:5e6f7a8b', displayName: 'Phone', scopes: ['interactions:respond', 'sessions:observe', 'sessions:operate'] }
    };
    var indexedDB = {
      open: function () {
        var request = {};
        Promise.resolve().then(function () {
          request.result = {
            transaction: function () {
              return { objectStore: function () {
                return { get: function () {
                  var get = {};
                  Promise.resolve().then(function () { get.result = __identity; get.onsuccess(); });
                  return get;
                } };
              } };
            }
          };
          request.onsuccess();
        });
        return request;
      }
    };
    """#

    private static let fixtures = #"""
    function __ws() { return __sockets[__sockets.length - 1]; }
    function __open(ws) { ws.readyState = 1; ws.onopen(); }
    function __deliver(ws, frame) { if (ws.onmessage) ws.onmessage({ data: JSON.stringify(frame) }); }
    function __drop(ws) { ws.readyState = 3; if (ws.onclose) ws.onclose(); }
    function __lastSent(type) {
      var sent = __ws().sent.filter(function (f) { return !type || f.type === type; });
      return sent[sent.length - 1];
    }
    function __pendingOf(type) {
      var sent = __ws().sent;
      for (var i = sent.length - 1; i >= 0; i -= 1) {
        if (sent[i].type === type && state.pending.has(sent[i].request_id)) return sent[i];
      }
      return null;
    }
    function __reply(ws, request, type, payload) {
      __deliver(ws, { v: 1, type: type, request_id: request.request_id, session_id: request.session_id, payload: payload });
    }
    function __result(ws, request, payload) { __reply(ws, request, 'command_result', payload); }
    function __resolveAll(type, payload) {
      __ws().sent.filter(function (f) { return f.type === type && state.pending.has(f.request_id); })
        .forEach(function (f) { __result(__ws(), f, payload); });
    }
    function __merge(base, overrides) {
      for (var key in overrides || {}) {
        if (overrides[key] === undefined) delete base[key]; else base[key] = overrides[key];
      }
      return base;
    }
    function __access(overrides) {
      return __merge({ policy_state: 'required', locked: true, enrolled: true, enrollment_open: false, epoch: '7', lock_generation: '3' }, overrides);
    }
    function __unlocked(overrides) {
      return __merge(__access({ locked: false, grant_id: 'grant-1', deadline_seconds_remaining: 1800 }), overrides);
    }
    function __hello(ws, access) {
      __deliver(ws, { v: 1, type: 'hello_ack', payload: {
        device_id: 'remote:5e6f7a8b', auth: 'ticket', host_name: 'Mac', locked: access ? access.locked : true, access: access
      } });
    }
    function __lockState(ws, access) { __deliver(ws, { v: 1, type: 'lock_state', payload: access }); }
    function __shown(id) {
      for (var n = $(id); n; n = n.parentNode) if (n.classList.contains('hidden')) return false;
      return true;
    }
    function __find(node, className) {
      if (node.className === className) return node;
      for (var i = 0; i < node.childNodes.length; i += 1) {
        var found = __find(node.childNodes[i], className);
        if (found) return found;
      }
      return null;
    }
    // Text and values of every element the page has shown, hidden or not.
    function __pageText() {
      return Object.keys(__elements).map(function (id) {
        var node = __elements[id];
        return node.textContent + ' ' + node.value;
      }).join('\n');
    }
    function __domError(name) { var error = new Error(name); error.name = name; return error; }
    function __bytes(list) { return new Uint8Array(list).buffer; }
    function __assertionCredential() {
      return { id: 'AQI', rawId: __bytes([1, 2]), type: 'public-key', response: {
        clientDataJSON: __bytes([123, 125]), authenticatorData: __bytes([4, 5, 6]), signature: __bytes([7, 8]), userHandle: null
      } };
    }
    function __registrationCredential() {
      return { id: 'AQI', rawId: __bytes([1, 2]), type: 'public-key', response: {
        clientDataJSON: __bytes([123, 125]), attestationObject: __bytes([160])
      } };
    }
    var __assertionOptions = {
      ok: true, device_id: 'remote:5e6f7a8b', ceremony_id: 'ceremony-assert-0001', challenge: 'AQIDBA', rp_id: 'phone.test',
      allow_credentials: [{ type: 'public-key', id: 'CQgH' }], user_verification: 'required', timeout: 60000
    };
    var __registrationOptions = {
      ok: true, device_id: 'remote:5e6f7a8b', ceremony_id: 'ceremony-register-01', challenge: 'BQYH',
      rp: { id: 'phone.test', name: 'RepoPrompt Dev' },
      user: { id: 'ESIz', name: 'remote:5e6f7a8b', display_name: 'Phone (Dev)' },
      pub_key_cred_params: [{ type: 'public-key', alg: -7 }],
      authenticator_selection: { resident_key: 'preferred', user_verification: 'required' },
      attestation: 'none', timeout: 60000
    };
    function __challenge(kind) {
      var options = kind === 'assertion' ? __assertionOptions : __registrationOptions;
      __reply(__ws(), __pendingOf(kind === 'assertion' ? 'passkey_unlock_begin' : 'passkey_register_begin'),
        'passkey_challenge', { kind: kind, device_id: 'remote:5e6f7a8b', ceremony_id: options.ceremony_id, options: options });
    }
    function __questionSnapshot(interactionId) {
      return { status: 'waiting_for_input', run_id: 'R1', interaction_id: interactionId, session: { name: 'Secret session' },
        interaction: { kind: 'question', title: 'Secret question', fields: [
          { id: 'q1', header: 'Color', options: [{ label: 'Red' }, { label: 'Blue' }] },
          { id: 'q2', header: 'Tools', allows_multiple: true, options: [{ label: 'A' }, { label: 'B' }, { label: 'C' }] },
          { id: 'q3', header: 'Notes', options: [] },
          { id: 'q4', header: 'Skip me', options: [{ label: 'X' }] }
        ] } };
    }
    var __question = __questionSnapshot('I1');
    var __question2 = __questionSnapshot('I2');
    var __running = { status: 'running', run_id: 'R1', session: { name: 'Secret session' } };
    var __secretXML = '<user>secret transcript</user>';
    var __codeXML = '<user>secret transcript</user>\n<assistant>Here:\n```swift\nlet secret = 1\n```\n</assistant>';
    function __formState() {
      return (state.questionInputs || []).map(function (q) {
        return {
          selected: q.optionInputs.filter(function (i) { return i.checked; }).map(function (i) { return i.value; }),
          custom: q.customInput ? q.customInput.value : '',
          skipped: q.skipInput.checked,
          disabled: q.optionInputs.map(function (i) { return i.disabled; })
        };
      });
    }
    """#

    let context: JSContext
    private var exceptions: [String] = []

    init(prelude: String = "") throws {
        let data = try XCTUnwrap(GatewayPWAResources.data(forAsset: "app.js"))
        let appJS = try XCTUnwrap(String(data: data, encoding: .utf8))
        context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { [weak self] _, exception in
            self?.exceptions.append(exception?.toString() ?? "unknown exception")
        }
        run(Self.browserStub)
        run(prelude)
        run(appJS)
        run(Self.fixtures)
        assertNoException()
        XCTAssertEqual(int("__sockets.length"), 1, "the saved pairing connects on load")
    }

    @discardableResult
    func run(_ script: String) -> JSValue {
        // JavaScriptCore drains promise jobs when the evaluation returns.
        context.evaluateScript(script)
    }

    func string(_ expression: String) -> String? {
        let value = run("(\(expression))")
        return value.isNull || value.isUndefined ? nil : value.toString()
    }

    func bool(_ expression: String) -> Bool {
        run("Boolean(\(expression))").toBool()
    }

    func int(_ expression: String) -> Int {
        Int(run("Number(\(expression))").toInt32())
    }

    func json(_ expression: String) -> NSObject? {
        guard let text = string("JSON.stringify(\(expression))") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? NSObject
    }

    func strings(_ expression: String) -> [String] {
        (json(expression) as? [String]) ?? []
    }

    func shown(_ id: String) -> Bool {
        bool("__shown('\(id)')")
    }

    func pageText() -> String {
        string("__pageText()") ?? ""
    }

    /// Frame types sent on the current socket.
    func sentTypes() -> [String] {
        strings("__ws().sent.map(function (f) { return f.type; })")
    }

    /// Frames of `type` sent on any socket.
    func count(type: String) -> Int {
        int("__sockets.reduce(function (n, ws) { return n + ws.sent.filter(function (f) { return f.type === '\(type)'; }).length; }, 0)")
    }

    func connect(access: String) {
        run("var ws = __ws(); __open(ws); __hello(ws, \(access));")
    }

    /// Replaces the current socket with a new authenticated one.
    func connectFresh(access: String) {
        connectFresh(hello: "{ device_id: 'remote:5e6f7a8b', auth: 'ticket', locked: (\(access)).locked, access: \(access) }")
    }

    func connectFresh(hello: String) {
        run("reconnectNow();")
        run("var ws = __ws(); __open(ws); __deliver(ws, { v: 1, type: 'hello_ack', payload: \(hello) });")
    }

    func answerChallenge(kind: String) {
        run("__challenge('\(kind)');")
    }

    /// Answers the deep-linked session's subscribe, poll and first transcript page.
    func openS1(snapshot: String = "__question", xml: String = "__secretXML") {
        run("__resolveAll('subscribe', {});")
        run("__resolveAll('poll', \(snapshot));")
        run("__resolveAll('get_log', { total_turns: 1, transcript_xml: \(xml) });")
    }

    func unlockAndOpenS1(snapshot: String = "__question", xml: String = "__secretXML") {
        connect(access: "__unlocked()")
        openS1(snapshot: snapshot, xml: xml)
    }

    /// The full gesture flow on the current socket, ending in the gateway's unlocked notice.
    func unlockViaPasskey(grant: String, lockGeneration: String) {
        answerChallenge(kind: "assertion")
        run("$('unlock-button').onclick({ isTrusted: true }); __credentialCalls[__credentialCalls.length - 1].resolve(__assertionCredential());")
        run("__reply(__ws(), __lastSent('passkey_unlock_complete'), 'passkey_ceremony_complete', { kind: 'assertion' });")
        run("__lockState(__ws(), __unlocked({ grant_id: '\(grant)', lock_generation: '\(lockGeneration)' }));")
    }

    /// Partial, whitespace-preserving answers and a composer draft.
    func editDrafts() {
        run(#"""
        $('composer-input').value = '  draft\n';
        state.questionInputs[0].optionInputs[1].checked = true;
        state.questionInputs[1].optionInputs[0].checked = true;
        state.questionInputs[1].optionInputs[2].checked = true;
        state.questionInputs[1].customInput.value = ' also ';
        state.questionInputs[2].customInput.value = '  partial ';
        state.questionInputs[3].skipInput.checked = true;
        state.questionInputs[3].skipInput.onchange();
        """#)
    }

    /// Also checks failures the app wrote to its log, oldest first.
    func assertNoException(
        expectedLogFailures: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(exceptions, [], "JavaScript exceptions", file: file, line: line)
        let log = string("$('log').textContent") ?? ""
        let failures = log.split(separator: "\n").reversed()
            .filter { $0.contains("failed") }
            .map { entry in String(entry.drop { $0 != "]" }.dropFirst(2)) }
        XCTAssertEqual(failures, expectedLogFailures, "failures written to the app log", file: file, line: line)
    }
}
