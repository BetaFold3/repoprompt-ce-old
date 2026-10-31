# Telegram link to paired web remote — specs

Scope: read when the task touches a remote-control link in Telegram attention notifications, paired-browser (PWA) control of UI-driven root sessions, the gateway's browser HTTPS origin, or Host validation.
Authority: Reference
Last-verified: 2026-10-30

## Goal
Each Telegram completion or `ask_user` alert carries an "Open session" link to the gateway's browser remote. Only a browser paired with and approved on the executing Mac can see or act. From the phone I can answer the pending question (all questions, options, multi-select, custom answer), steer a running agent, send a follow-up to an idle session, and Stop: notification → open → act → done. Acting from the phone must not stop that session's later alerts.

## Non-goals
New sessions, file browsing, tool/edit approvals, Codex `requestUserInput`; passkey/password unlock; app-managed Tailscale or Funnel; Telegram replies or callback buttons; Web Push changes; CSP, Origin checks and other header hardening (see Disagreements); notification eligibility, lineage, question audience or terminal-order changes. This is the "later contract" deferred by `2026-10-10-telegram-attention-notifications-contract.md`; that contract's event rules are unchanged.

## Evidence directory
`docs/investigations/2026-10-30-telegram-remote-link/` (git-excluded, not committed): scouting findings, Oracle positions.

## Design
- **No MCP handover.** Today, remote `respond` needs an MCP-controlled session, steering a running UI root is refused, and steering an idle one installs MCP control, which permanently excludes that root from alerts. Instead, a gateway caller acting on a session that passes the notifier's own `isAttentionNotificationRoot` uses the same session-targeted operations the desktop uses. "Sessions the phone can act on" is then the same set as "sessions that alert". Ordinary MCP callers keep today's rules.
- **Truthful view.** For sessions without an MCP registration, the live session takes precedence over the index. It reports the real running/waiting status and the structured pending question.
- **Access.** Private HTTPS from a `tailscale serve` listener the owner runs, pointing at the existing Tailscale-IP gateway. Identity is the existing paired non-extractable browser key, one-use tickets and signed frames. A Host allowlist blocks DNS rebinding. The link contains only `https://<mac>.<tailnet>.ts.net:<port>/?session_id=<uuid>`, so forwarding it grants nothing.

## Steps

### Step 1 — Phone actions on UI roots without MCP control
Change: in `AgentRunMCPToolService` respond, steer and cancel, when the caller is the gateway app-link connection and the session resolved by `authoritativeLiveSession(for:)` satisfies `isAttentionNotificationRoot`, skip the `mcpControlledSession` requirement. Then call a session-parameterized core extracted from `mcpResolvePendingInteraction` and `mcpDispatchInstruction`. The core is the normal send path: no selected-tab composer handler and no direct `startAgentRun`. Stop uses the desktop cancel path. After every `await`, re-run the predicate and, for answers, the exact interaction ID. Set `remote:<device_id>` attribution from authenticated app-link metadata (add only that field if it isn't forwarded) and clear it with `defer`. In `currentSnapshot` (`:4213-4219`), try the live session before the index, with true status and `mcpPendingInteraction(for:)`.
Validation: new cases in the existing `AgentRunMCPToolService` test suite (locate with `rg`) and `AttentionNotificationAdmissionTests`, all stub/fixture; `make dev-lint`.
Done when: a gateway caller answers a multi-question form, steers a running root, follows up an idle root and stops one, while `mcpControlContext` stays nil and controlled-tab membership is unchanged; a plain MCP caller is still refused; the remote follow-up's completion is still admitted for an alert; a live waiting root reports `waiting_for_input` with the question fields.
Step 1 — done | rounds 2/2 | open: none | downgraded: none | assumed: refuse phone sends while loading and native control commands (owner question timed out) | deferred: P3 follow-ups in step1-review-disposition.md; Stop sends observed run_id in Step 2; live acceptance in Step 4

### Step 2 — Focused phone UI and pairing repair
Change (`pwa/app.js`, `index.html`, `GatewayHTTPServer`):
- Add `"channel"` to the existing `/healthz` JSON.
- Pairing calls discovery (nonce + channel) and forwards `approval_context` to `/api/pair/begin`. Fixes today's guaranteed pairing failure.
- Store the key and device record in one IndexedDB transaction, keyed by the `/healthz` channel. Prevents a half-saved identity, and stops every switch between the release and Dev builds forcing a re-pair (each build has its own paired-device list and host key, `RemoteControlBuildIdentity.swift:45-58,85-88`, but both share one browser address).
- Connect automatically when an identity exists, and keep `?session_id` through first-time pairing. Fixes the first tap from a notification landing nowhere.
- Subscribe to that session directly. Doesn't depend on the bound workspace's list.
- Render the structured question form and send `answers[questionID]` = `{selected_options, custom_response}` or `skipped`.
- Show one text box, labelled "Steer" while running and "Follow up" when idle, and show Stop only while running or waiting. Remove the Start-session UI.
- Serialize signing and sending with a per-frame counter. Fixes a steer being rejected while a poll is in flight (`app.js:256-273`).
- Reject pending requests on socket close. Fixes a hang after the phone drops the connection.
- Render all agent text through DOM text APIs only.
Validation: one `PWAResourceTests` assertion that no served PWA asset contains `innerHTML|outerHTML|insertAdjacentHTML|document.write|eval(|new Function`; a gateway test for the `/healthz` channel; `make dev-lint`. Real WebKit behaviour is checked in Step 4.
Done when: with a stored identity, `?session_id` opens that session without manual Connect, and every form or action emits the existing wire shape.
Step 2 — todo | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: none

### Step 3 — HTTPS origin, Host allowlist, Telegram button
Change:
- First read: confirm the gateway process knows its build channel. If not, pass it in the launch configuration.
- Add an optional `browserHTTPSPort` remote-gateway setting (≠443, default unset, suggested 8443; the same value is used in both builds).
- Remote Control settings show the exact `tailscale serve` command for the running build (its gateway port), copyable. Recovery after switching builds: one Serve port can forward to only one build's gateway, so links fail until the command is re-run.
- `ServerController.applyRemoteGatewaySettings` derives `https://<Self dnsName>:<port>` from the status snapshot it already fetches (`TailscaleStatusClient.swift:46-51`), passes it to the gateway launch and publishes it with gateway status.
- `GatewayHTTPServer` route and WS upgrade accept only Host `{bind ip:port, derived authority}`, with no forwarded-header trust.
- `TelegramSendMessageClient.send`/`makeRequest` take an optional URL button (`reply_markup` inline keyboard, "Open session").
- `TelegramPacedAttentionDelivery` attaches it to part 1 only, using the origin snapshotted with the delivery configuration. An unset port or inactive gateway gives today's text-only alert plus a settings hint. Renderer and text budgets are unchanged.
Validation: `TelegramSendMessageClientTests`, `TelegramPacedAttentionDeliveryTests`, `TelegramAttentionNotificationServiceTests`, `TelegramAttentionMessageRendererTests` unchanged, a new gateway Host-allowlist test (HTTP and WS), all with stub HTTP; `make dev-lint`, `make guardrails`.
Done when: stubbed requests carry the correct session link on part 1 only, content and admission are unchanged, and a wrong Host is refused on HTTP and WS.
Step 3 — todo | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: none

### Step 4 — Owner setup and live acceptance (manual; approvals at each action)
Change: none in code, except a Host allowlist fix if the check below fails. Setup:
1. Enable MagicDNS and HTTPS certificates in the Tailscale admin console.
2. Run the command Settings shows for the build in use, e.g. `tailscale serve --bg --https=8443 http://<tailscale-ip>:47392` for Dev (47391 for release), then check `tailscale serve status`: 8443 is present and T3 Code's 443 is unchanged. Re-run it after switching builds; it replaces the 8443 target.
3. Set the port to 8443 in Settings and approve a relaunch.
4. Record the Host header Serve forwards. If the allowlist refuses it, every phone request fails loudly; fix the allowlist then.
5. Pair Brave, then Safari. Set Telegram → Privacy and Security → Open Links in → the browser under test. Pair each browser once per build; after a build switch and a Serve re-run, the earlier pairing is reused.
On approval, trigger one real completion alert and one real question alert.
Validation: on the iPhone, open each link, then answer, steer, follow up and Stop; switch builds, re-run the Serve command and confirm the link opens without re-pairing; revoke the phone on the Mac and confirm its connection closes within about 15 s and `/api/ticket` refuses it; delete site data and confirm a clear "pair again on your Mac" state. Record the results in the evidence directory as live results.
Done when: both browsers pass. An unpaired browser sees no session content. When the plan completes, record the setup and recovery steps in the owning context document.
Step 4 — todo | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: none

## Decisions
- Goal confirmed: Telegram link to the paired browser remote, with a focused phone UI (owner answer 2026-10-30).
- Phone: iPhone, with Safari and Brave (owner answer 2026-10-30).
- No extra unlock (passkey/password) in v1 (owner answer 2026-10-30).
- Phone scope: answer questions, steer running, follow up idle, Stop (owner answer 2026-10-30).
- HTTPS: the owner runs one documented `tailscale serve` command on a non-443 port; no app-managed Tailscale (owner answer 2026-10-30).
- Link form: an "Open session" button is fine; it doesn't break the plain-text rule (owner answer 2026-10-30).
- Builds: release and Dev, never at the same time; one HTTPS port for both is fine (owner answer 2026-10-30).
- Revocation: the ~15 s delay before a revoked phone is cut off is acceptable (owner answer 2026-10-30).
- Live test order: Brave first, then Safari (owner answer 2026-10-30).
- A follow-up sent from the phone alerts on completion under the normal rules (owner answer 2026-10-30).
- Unsigned local commits are allowed during this plan; re-sign them at plan closure (owner answer 2026-10-31).

## Disagreements
- Control path: an authority envelope plus an extracted operations file vs a gateway-caller gate reusing the notifier predicate. Gate chosen; the envelope's lane withdrew it.
- Serve target: a loopback companion listener vs the existing Tailscale-IP listener. Tailscale IP chosen (Tailscale source accepts IP targets); the listener's lane withdrew it.
- Header hardening: Host + Origin + CSP vs none. Host allowlist only (DNS rebinding), plus the text-only rendering assertion; both lanes agreed by round 2.
- Link form: a URL line in the text vs a button. Button, so the renderer is untouched; both agreed.
- Origin setting: a typed, validated origin vs a port derived from the Tailscale DNS name. Port-derived, with channel in `/healthz`; both agreed.
- Home Screen install to avoid Safari's 7-day storage deletion. Cut: its storage is separate from the Safari/Brave pages Telegram opens; re-pairing is the recovery.
- App-side revocation check: one lane wanted to re-check the device before each phone action, to close the ≤15 s sync window; the other would cut it. Survived two rounds; the owner accepted the delay, so it is cut and documented.

## Open Questions
- Unverified until Step 4: the installed Tailscale version accepts an IP target; which Host Serve forwards; a `ts.net:port` button opens correctly from Telegram iOS; Brave on iOS follows Safari's 7-day storage rule.
- Inferred: gateway watches may poll rather than push for unregistered sessions; the post-action refresh must keep the phone current.
