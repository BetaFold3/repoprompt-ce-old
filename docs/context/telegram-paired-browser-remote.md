# Telegram paired-browser remote

Scope: read when the task touches the Telegram "Open session" link, paired-browser (PWA) control of UI-driven root sessions, the gateway's browser HTTPS origin or loopback companion listener, the gateway Host allowlist, or setup and recovery of a phone browser.
Authority: Authoritative
Last-verified: 2026-10-31

Implemented and accepted by the owner for the Dev build with Safari on iPhone, with the limits listed below. Telegram event rules (eligibility, lineage, question audience, terminal order) stay owned by the [Telegram attention notifications contract](plans/2026-10-10-telegram-attention-notifications-contract.md). Code and tests are the behavioral source of truth.

## Invariants
- **No MCP handover.** A gateway app-link caller acting on a session that passes the notifier's `isAttentionNotificationRoot` uses the desktop's session-targeted respond, steer and cancel paths (`AgentModeViewModel+RemoteRootControl.swift`). It never installs MCP control, so the session keeps sending later alerts, including the completion of a phone follow-up. Ordinary MCP callers keep their existing rules. Phone sends to a not-yet-loaded session and native control-plane commands such as `/compact` or `/goal` are refused; use the Mac for those. Tool/edit approvals and Codex `requestUserInput` remain outside phone control.
- **Browser identity.** A non-extractable P-256 key and device record are stored together in one IndexedDB transaction, keyed by the gateway's `/healthz` `channel` (`release` or `debug`). Each build has its own paired-device list and host key. Pairing uses discovery (nonce + channel), the Mac's fingerprint approval, one-use tickets and signed frames.
- **Host allowlist.** HTTP routes and the WebSocket upgrade accept only a single `Host` matching the bind address, the accepted socket's local `ip:port`, or the browser origin's authority (`GatewayHostAllowlist.swift`). Forwarded headers are never trusted.
- **Origin and transport.** The browser origin is `https://<MagicDNS name>:<browserHTTPSPort>`, derived from Tailscale status. There is no typed origin. While an origin is published, the gateway also listens on `127.0.0.1:<gateway port>` for Serve. Direct access over the Tailscale IP stays in place. The link contains only the origin and `?session_id=<uuid>`, so it grants nothing without a paired browser.
- **Telegram button.** Part 1 of a completion or question alert gets an "Open session" URL button only when `browserHTTPSPort` is set and the gateway is running and ready. Otherwise the alert is text only.
- **Phone UI.** It has the following parts:
  - a structured question form (options, multi-select, custom answer, skip);
  - one auto-growing text box with its send button, labelled Steer while running and Follow up when idle;
  - Stop in the sticky header, apart from Send, shown only while the session is running or waiting;
  - session rows that are buttons;
  - an Activity log that starts collapsed.

  The Connection panel stays visible. The page follows the system's light or dark appearance, uses 17px system text (16px minimum in fields, so iOS does not zoom) and 44px controls, respects safe areas and keeps browser zoom. It scrolls as one document, with no nested transcript scroller, and the composer sits in normal flow at the end of the session view. Agent and server text reach the page only through DOM text APIs; `PWAResourceTests` bans markup-parsing and eval APIs.
- **Transcript presentation.** `get_log`'s `transcript_xml` writes role bodies and tool arguments unescaped, so it is never handed to an XML or HTML parser.
  - `segmentTranscript()` in `app.js` is a conservative forward line scan. It recognizes only the serializer's own record lines and has these rules:
    - a close tag counts only at a line end followed by another record line or the end of input;
    - a candidate inside a backtick-fenced example in the body is not a close;
    - the serializer cuts only grouped system summaries and tool arguments, so there a fence-hidden candidate ends the record as raw text and later records are scanned normally;
    - in other bodies, a fence-hidden record is kept only when a later close follows outside the fence, before any same-type opening line and the next unfenced record line; otherwise it shows raw up to its first candidate, so an interrupted fence never swallows later records;
    - unknown or uncertain text, including a record that never closes, stays visible verbatim, and uncertain text is never given a role label;
    - the segments' raw text joins back to the input exactly;
    - bodies are never entity-decoded, and tool names are decoded from the serializer's four attribute escapes.
  - The primary view shows You, Agent, System, Error and Note sections, one collapsed disclosure per tool call with arguments, and complete code fences as code. No other Markdown is interpreted.
  - The exact page text stays in a closed "Raw transcript" disclosure.
  - Known limit: exact record-shaped text outside a code fence can be attributed to the wrong record, though no text is lost. The serializer's grouped "Explored codebase" system summaries can cut a fence off unclosed, so such a row shows as raw text. The same cut applies to a complete fenced example of record lines inside a summary or tool arguments, and an example cut short this way in any body can have its remaining lines shown as records. In other bodies, a fenced example that holds a record's close line followed later by an opening line of the same type shows the whole message as raw text; it stays visible and is not mislabelled.
  - Records keep their DOM nodes, and so their open disclosures and focus, only when their position establishes the same occurrence: the view still starts at the same turn (matched from the start), or older pages were prepended to an earlier start (matched from the end). Whenever the start turn moves forward (the newest window rolls, or Refresh drops older pages), every record gets a fresh, closed node, even for identical text, since `get_log` carries no row identities. Disclosures open in the old nodes close at that point. A session switch discards all nodes.
  - The view re-renders when its text or its start turn changes; the start turn alone decides "Load earlier messages". Scroll is measured once before any layout write (Load earlier, raw text, records) and corrected once after them. A session view's first records land on the newest output, or on the question when the agent is waiting, unless the reader is typing or using a disclosure (focus in a hidden element does not count). Afterwards, new output is followed only when the reader is within 48px of the bottom and is not typing or focused in the transcript. Otherwise an anchor keeps its screen position: a focused, on-screen composer or question field first, else the first visible block whose node survived; with neither (as after a rolled window), the document position is kept. Sending does not scroll.
- **Transcript paging.** Pages are oldest-first: the newest page starts at `max(0, total_turns − 200)`, and "Load earlier messages" prepends the 200 turns before the oldest one shown. Background refresh pauses while older pages are loaded, and Refresh returns to the newest page. Newest-page loads coalesce overlapping refreshes and make at most one corrective page request; a turn added during that second request can appear on the next refresh.
- **Revocation.** A phone revoked on the Mac is disconnected within about 15 s (the gateway's trust-refresh loop). After that, ticket requests are refused and the page tells the user to pair again. The owner accepted the delay; there is no per-action re-check.

## Setup (owner-run)
1. In the Tailscale admin console, enable MagicDNS and HTTPS certificates.
2. In Remote Control settings, set Browser link (HTTPS) to 8443 (never 443) and make sure the gateway is running and ready.
3. Run the command Settings shows for the running build: `tailscale serve --bg --https=8443 http://127.0.0.1:<gateway port>`. Live setup used 47392 for Dev; 47391 is the default release port. Check `tailscale serve status` and confirm the 443 configuration is unchanged. One Serve port forwards to one build. After switching builds, re-run the command shown in the build in use.
4. On the iPhone, set Telegram → Privacy and Security → Open Links in → Safari. Open a link in a normal Safari tab, check that the fingerprint matches, and approve pairing on the Mac. A session link opened before pairing opens that session after pairing.

## Recovery
- **Revoked or stale pairing:** tap Forget pairing on the page, then pair again and approve on the Mac.
- **Private Safari tabs** have a separate, isolated identity and ask to pair again. Use a normal tab.
- **Links fail after a build switch:** re-run that build's Serve command.
- **Telegram rejects the URL button:** clear the browser HTTPS port. Alerts go back to text only, and the Serve setup stays in place.

## Verification status (2026-10-31)
- **Live, owner-confirmed on Dev with iPhone Safari:**
  - an unpaired page shows no session content;
  - pairing with Mac approval, and pairing reuse in normal tabs;
  - a multi-question answer (options, multi-select, custom answer, skip);
  - steering a running root;
  - a completion link leading to an idle follow-up;
  - the follow-up's later completion alert;
  - Stop;
  - revocation disconnect within about 15 s, then refused reconnect;
  - recovery with Forget pairing and Mac re-approval;
  - the earlier literal-text transcript view (historical; replaced by the presentation above).
- **Pending live acceptance (2026-10-31 presentation):** the structured transcript view and the new layout are not yet checked on iPhone Safari. Still to check:
  - light and dark appearance, and Dynamic Type sizes;
  - the keyboard with the composer in normal flow;
  - safe areas in a tab and in standalone mode; in standalone mode, the `black-translucent` status bar and the manifest colors still predate the light theme (deferred to a standalone-scope change);
  - disclosure persistence and reading-position stability during live refreshes, including reading near the top while the newest window rolls; a focused disclosure removed near the bottom can allow automatic following again (nonblocking follow-up);
  - opening a long session from Telegram shows the newest output or the question at once;
  - typing a Steer with the keyboard up while output streams keeps the composer visible;
  - collapsing and expanding the toolbar with a multi-line draft;
  - while reading inside the opened Raw transcript, new records push the raw text down (no anchor there; accepted for a debug view);
  - VoiceOver.
- **Synthetic only:**
  - older-page transcript paging, segmentation, `buildSpartanLogXML` parity, primary-view rendering, node reuse, and scroll anchoring with synthetic geometry (JavaScriptCore tests in `PWAResourceTests+Transcript.swift`). Live sessions were too short to page.
  - Headless desktop-browser screenshots at 320, 390 and 1280px, light and dark, and headless Chromium checks of first-page landing, question landing, prepend anchoring (including the final older page), a focused composer holding still during new output, and header wrapping with enlarged text at 320 and 390px, are layout evidence only, not iPhone acceptance.
- **Inconclusive, not fixed:** after the gateway site's Safari website data was deleted and the page fully reloaded, Safari still had the revoked identity. Access stayed refused, so this is not a bypass, but website-data deletion as a recovery step is unverified. Use Forget pairing instead.
- **Deferred or unverified:**
  - full Brave acceptance: Brave paired and the protected page worked, but Telegram on the owner's phone offers only Telegram, Safari and Chrome for links;
  - pairing reuse after switching between release and Dev builds. The installed release is an older official Developer ID build without this feature, so no build-switch pass is claimed;
  - Brave/iOS storage-retention behavior.
