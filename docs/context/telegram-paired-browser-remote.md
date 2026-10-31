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
- **Phone UI.** It shows a focused structured question form (options, multi-select, custom answer, skip), one text box labelled Steer while running and Follow up when idle, and Stop while running or waiting. Agent and server text reach the page only through DOM text APIs; `PWAResourceTests` bans markup and eval APIs.
- **Transcript.** `get_log`'s `transcript_xml` is shown as literal text, XML tags included. There is no HTML rendering, XML parsing or rich viewer. Pages are oldest-first: the newest page starts at `max(0, total_turns − 200)`, and "Load more transcript" prepends the 200 turns before the oldest one shown. Background refresh pauses while older pages are loaded, and Refresh returns to the newest page. Newest-page loads coalesce overlapping refreshes and make at most one corrective page request; a turn added during that second request can appear on the next refresh.
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
  - literal transcript text.
- **Synthetic only:** older-page transcript paging (JavaScriptCore tests in `PWAResourceTests+Transcript.swift`). Live sessions were too short to page.
- **Inconclusive, not fixed:** after the gateway site's Safari website data was deleted and the page fully reloaded, Safari still had the revoked identity. Access stayed refused, so this is not a bypass, but website-data deletion as a recovery step is unverified. Use Forget pairing instead.
- **Deferred or unverified:**
  - full Brave acceptance: Brave paired and the protected page worked, but Telegram on the owner's phone offers only Telegram, Safari and Chrome for links;
  - pairing reuse after switching between release and Dev builds. The installed release is an older official Developer ID build without this feature, so no build-switch pass is claimed;
  - Brave/iOS storage-retention behavior.
