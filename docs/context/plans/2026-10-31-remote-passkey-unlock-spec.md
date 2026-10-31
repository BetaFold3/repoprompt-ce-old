# Optional passkey unlock for the paired-browser remote — spec

Scope: read when the task touches passkey enrollment, unlock, relock or recovery for an already paired remote browser.
Authority: Reference
Last-verified: 2026-10-31

## Status and goal
Proposed specification only. No passkey behavior is implemented, no dependency is approved yet, and no deployment or relaunch is authorized. This is a separate follow-up to the implemented [paired-browser remote](../telegram-paired-browser-remote.md), not a change to the completed Telegram-link contract.

A Mac-approved browser may additionally require a passkey before receiving session content or operating a session. On the owner's iPhone, the normal experience should be: open a Telegram link, tap Unlock, approve the native passkey prompt using 1Password, read or act, and return without repeated prompts during the unlock window. Use browser WebAuthn, not a 1Password SDK or a new account/password system. The website requests user verification; the authenticator and OS choose the prompt, not necessarily Face ID.

## Proposed defaults, not owner Decisions
- Protection is optional **per paired browser**. Existing and newly paired browsers start with it off; the owner explicitly enables it on the Mac.
- Unlock lasts **15 minutes absolute**, not sliding with activity. It applies to that browser's paired identity across tabs and reconnects, not to other browsers or builds. Lock in any tab locks that browser identity everywhere.
- One passkey credential per paired browser per build. Mac-side Enable, Enroll, Reset and Disable are the only policy-changing controls.
- Expiry does not stop an agent or undo an admitted action. Unlock again and refresh to learn its result; never automatically resend an uncertain action.
- Evaluate a library-backed verifier first. If it cannot meet the security and compatibility gate, stop and recommend deferring the feature, not a handwritten verifier or another service.

These defaults may be revised by the owner before implementation. The timeout and shared-tab behavior are the material convenience choices. Changing them does not require changing the trust architecture.

## Security promise and limits
Existing pairing, browser-key signatures, one-use tickets, counters, scopes, Host validation and HTTPS remain mandatory. A passkey grants no pairing and expands no session permissions. Keep the attention-root/no-MCP-handover rules and Mac-only approvals unchanged. Forwarding a session link still grants nothing.

While protection is required and no grant is live, admit no protected command and release no protected content, including transcript, questions, session lists/status, runtime errors/results, watch broadcasts and deferred catch-up. Enforce this in the gateway, not by hiding controls or shortening ticket TTL.

The precise outgoing boundary is the connection's serialized outbound queue: after a lock transition is applied there, no protected frame is enqueued; every enqueue also checks the monotonic deadline, so an expired grant cannot pass while an expiry notification waits. Bytes already queued before the transition and data already delivered cannot be recalled. An action admitted before locking may finish on the Mac; a withheld response becomes a generic lock error, not an invitation to retry it automatically.

Mac policy changes and revocation normally reach the gateway on its existing approximately 15-second trust refresh. The guarantee begins when the gateway applies the change, not at the Settings click. Settings must distinguish the persisted choice from observed gateway enforcement and show pending/unavailable when it cannot confirm application. With a transport outage, a last-known grant may survive only to its original deadline; no fresh verification is possible until the app link recovers. Do not advertise a strict 15-second revocation/reset guarantee during an outage.

Not covered: a compromised Mac, OS or same-origin script; someone using an already-unlocked browser before its deadline; screenshots, clipboard or previously delivered content; Telegram notification previews. This adds user verification, not stronger TLS or a hardware-bound second device. Existing identifier-only Web Push and Telegram event/content rules stay unchanged.

## Ownership and durable state
**The app is the sole durable authority and the sole WebAuthn challenge issuer/verifier.** Extend the existing app-owned pairing store and gateway-principal `remote_pairing` service. Store only verified public credential material, credential ID, RP hostname, policy requirement and a monotonically changing policy epoch; private passkey material remains with the authenticator. Keep the library in the app target. Do not create a second credential store or verifier in the gateway.

**The gateway owns ephemeral unlock grants and enforcement.** A process-local map keyed by paired device ID stores the monotonic deadline, policy epoch and a local lock generation. Host/build separation is already provided by the gateway instance and app registry; no persistent grant or browser bearer-token store is needed. Reconnects in the same instance may reuse an unexpired grant after proving the same device key. Gateway restart loses grants and locks protected browsers.

Use the existing principal app link directly for new passkey operations, not a new transport and not an arbitrary per-device session-command route. `main.swift:151–214` passes the same `AppLinkSession` to runtime, pairing relay and trust synchronization. The gateway derives device identity from its authenticated connection; ignore/reject client-supplied device identity in passkey payloads. The app validates the bound device and current policy again.

### Persistence and compatibility
- Introduce a versioned pairing-registry/record schema with explicit required policy fields. Old v1 migrates to protection off; malformed or unknown new policy state is invalid, not off.
- Once the new schema is saved, never silently write the old schema again. Older app builds must fail loudly on the newer registry instead of dropping protection fields on save. Recovery is return to the compatible build or explicit Mac recovery, not deleting registry files.
- A required policy with no credential is valid and locked. There is no implicit fall back to off.
- Include a versioned policy shape and epoch in trust snapshots. Missing/unknown schema or malformed policy in an authoritative response invalidates trust: drop grants, deny content and new hellos, and close affected connections with a generic reason until valid trust returns. Do not continue on stale permissive data after such a response.
- A transport failure is different: retain the last valid policy without turning protection off; existing grants retain their original bounded deadlines. Do not issue new grants without successful app verification. No valid snapshot yet means no protected admission and no static-token access.
- Keep policy-off normal behavior and existing old pairing identities. New protocol fields must not authorize an older client to bypass server enforcement. App and gateway must agree on the new policy capability before Settings reports protection active.

## Enrollment, unlock and recovery
### Mac state machine
Durable states are **off**, **required without a credential**, and **required with a credential**. Enrollment authorization is a separate, in-memory window, not a durable policy state.

1. **Enable:** require a configured browser HTTPS origin first. Persist required-without-credential and a new epoch; open a 120-second enrollment window. Protection takes effect when the gateway applies the state. If already required but unenrolled, Enable/Enroll simply reopens the window. Do not replace an existing credential through Enable.
2. **Enroll:** available whenever required and unenrolled. A window is bound to the device, current policy epoch and expected browser origin. Show “Set up passkey” on the phone only while authorization is open; otherwise show “Finish setup on your Mac”.
3. **Registration:** the app issues a fresh, one-use, 60-second challenge bounded also by the enrollment window. Browser `create()` uses required user verification, ES256 and no attestation request. The app validates the full registration with the selected verifier, saves the credential atomically and advances the epoch. Registration alone does not grant access: use the ordinary fresh assertion path next.
4. **Timeout, denial, cancellation or restart:** close enrollment authorization and discard challenges; required protection stays required. Reopen Enroll on the Mac to retry.
5. **Reset:** clear the credential and pending challenges, advance the epoch and invalidate grants on synchronization; remain required. Open a fresh enrollment window only if a usable HTTPS origin exists. If not, remain locked and explain the setup problem.
6. **Disable:** a separate explicit Mac action removes the requirement and credential and advances the epoch. Warn that this restores pairing-only access. This is the owner's trusted local recovery path.
7. **Revoke:** existing device revocation remains stronger than unlock. A valid passkey never revives a revoked pairing.

No phone enrollment, reset or disable is authorized by a passkey alone. A synced credential in another browser still needs that browser's separate Mac-approved pairing and enrollment.

### Challenge and grant rules
Each challenge binds ceremony kind, authenticated paired device, current origin and policy epoch, and the initiating gateway request/connection generation. Store it only in app memory; replace/cap outstanding challenges per device and ceremony. Consume it on a completion attempt; reject replay, expiration, mismatched context and malformed input. Clear affected challenges on policy/origin changes and restart.

After every asynchronous verification/persistence boundary, recheck the binding and current policy. An assertion response must match the pending request and policy epoch before the gateway installs a grant. A Lock, disconnect of the initiating ceremony, gateway restart or epoch change during verification prevents that delayed result from reviving access. An already-established per-browser grant may survive a routine connection drop until its deadline.

Use monotonic time for the gateway's 15-minute deadline; wall-clock expiry sent to the phone is display/UX information only. New grants require a successful fresh assertion; traffic, polling, reconnect and background refresh never extend them.

## Origin, build and verifier profile
Derive expected browser origin from the app's published HTTPS launch configuration, not the direct gateway discovery address, incoming Host, forwarded headers or client input. Validate the exact origin, including its port. RP ID is that origin's hostname without port. Origin changes invalidate pending challenges and grants. A legitimate port change can reuse a credential after a fresh assertion; a hostname change requires Mac re-enrollment and a clear Settings explanation.

Release and Dev may use the same HTTPS address, but their pairing registries, credentials and allowed credential IDs remain distinct. Use recognizable build labels in enrollment. Never infer authorization from a credential appearing in 1Password's chooser. An HTTP page cannot unlock a protected browser; show the HTTPS link requirement, with no insecure fallback.

Use a standards-aware verifier, with a narrow supported profile. Validate ceremony type, one-use challenge, expected origin/RP binding, user presence and required user verification, credential/account binding, allowed algorithm, signature and structural integrity. Parse registration authenticator data and public keys together; do not trust separately submitted key/algorithm fields as an alternative to verified registration parsing. Handle valid backup flags/extensions according to the verifier's contract and reject malformed or unsupported structures. Keep input sizes bounded.

Support synced credentials: do not reuse the strictly increasing signed-frame counter rule for WebAuthn. Store a credential's signature counter as verifier metadata, not the sole replay or clone authority; verify the selected library's zero/non-increasing-counter behavior explicitly. Fresh one-use challenges and assertion signatures remain mandatory. No authenticator attestation or 1Password/Face-ID-only guarantee is claimed. These requirements follow [WebAuthn relying-party operations](https://www.w3.org/TR/webauthn-3/#sctn-rp-operations).

## Gateway enforcement and wire contract
Use signed, counter-consuming control frames for `passkey_register_begin`, `passkey_register_complete`, `passkey_unlock_begin`, `passkey_unlock_complete` and `lock`. The gateway relays ceremony requests over the existing principal app link. No new public HTTP ceremony endpoints are needed.

Add non-content lock metadata to `hello_ack` and a `lock_state` frame: policy off/required, enrolled, enrollment-open, locked, optional display deadline and a fixed reason code. Do not put session names, question text, raw app errors, credential material or secrets in this metadata. Keep credential options/results confined to their authenticated, internally correlated ceremony responses.

### Incoming boundary
Verify ticket/device identity, signature and counter before the unlock gate. While locked, allow only the minimal passkey/lock controls, ping, unsubscribe and existing push-management controls needed for the generic notification path; preserve their own scope/validation rules. Deny every protected or unknown operation with a generic lock error before session runtime dispatch. Unlock is not a scope grant. All normal scope and root-eligibility checks still apply when unlocked.

### Outgoing boundary
The final sink covers ordinary responses, errors, broadcast updates, targeted terminal catch-up and deferred subscription results. Unknown frame types are protected by default. Permit only sanitized control metadata and internally identified ceremony replies while locked. Never blanket-allow `command_error` or `command_result`, and never let a client-chosen request ID determine privileged classification. Replace a withheld correlated response/error with a generic lock response using the internal request association; drop passive protected updates rather than buffering them.

Each sink starts closed to protected data. Bind its device and policy before registering it with watches, which can immediately deliver data. Own its lock generation and monotonic deadline on the NIO event loop. Check authorization/deadline and enqueue in one loop operation; do not await an actor check and then enqueue unchecked later. Apply lock/epoch/trust transitions to every sink of the device. Lock acknowledgment follows application of the barriers so no older grant publication can reopen a sink. No replay/buffering infrastructure is added.

Existing developer static-token connections have no paired-device identity. Refuse new ones and close already-open ones whenever any device requires passkey protection or trust is invalid/unavailable. Do not silently preserve that bypass. Ordinary MCP callers and desktop session actions are outside this browser policy.

## Phone UX and lossless lock transition
- Keep the identity, pairing and target session link. Locked presentation shows only connection/lock/setup information, not session content or controls.
- Before clearing protected DOM/state, retain unsent composer and question-form drafts in page memory. Key answers by session and exact interaction ID; restore only against a fresh matching question. No new persistent draft store. Reload/closing the page retains only existing persistence guarantees.
- Lock, required-mode disconnect, expiry and lock errors clear transcript/list/question content and advance a view generation so stale callbacks cannot repopulate it. Do not merely cover it with an overlay while asynchronous rendering continues.
- On restored-page/foreground entry, hide protected content before reconnecting and wait for authoritative hello status. An unexpired per-browser grant permits reconnection without another passkey prompt. Do not rely on iOS timers while backgrounded.
- Prefetch enrollment/unlock options for the authorized overlay. Call `navigator.credentials.create/get` directly from the corresponding user tap with a fresh cached challenge. If stale, refresh options and ask for another tap; do not place the credential call behind a Mac approval round-trip that can consume user activation.
- Cancellation, missing authenticator, denial, unsupported browser and server failures leave the page locked with a clear retry or Mac-recovery route. Never switch to a password, weaker UV setting or HTTP fallback.
- Unlock refetches/subscribes through existing paths. Preserve drafts, but never automatically resend an action whose result was withheld or lost. Explain uncertain outcome and require the owner to inspect refreshed state.

1Password's [iPhone Autofill guide](https://support.1password.com/ios-autofill/) documents native passkey support; its [user-verification guidance](https://1password.com/blog/user-verification-passkeys) distinguishes native mobile/desktop prompting from extension-only behavior. The installed iPhone/provider combination remains a live acceptance gate.

## Steps
Follow [review policy](../review-policy.md) per implementation step: focused validation, independent OracleA/OracleB implementation review, in-scope fixes and local commit. The two OracleD planning consultations do not substitute for those reviews. Do not start implementation from this spec without owner authorization.

### Step 1 — Verifier feasibility and bounded adapter
Change: evaluate the canonical [swift-webauthn repository](https://github.com/brokenhandsio/swift-webauthn) at an exact reviewed revision, license and dependency graph. The previously suggested swift-server URL redirects there; no stable/SSWG-support claim is assumed. Keep any adopted dependency in the app target. Add the smallest adapter and offline registration/assertion fixtures; do not build a custom CBOR/COSE/WebAuthn parser.
Validation: verify toolchain/deployment-target fit, dependency resolution without an unrelated major upgrade, both ceremonies' required-UV enforcement, supported attestation/algorithm and structural rejection, origin/port/RP/challenge/device mismatch, expiry/replay, signature tampering and synced-counter behavior. Use existing security/pairing test ownership, `make dev-test FILTER=<focused suites>`, `make dev-lint`, `make guardrails`. No owner phone action is needed for this offline gate.
Done when: a pinned library meets the profile with positive and negative fixtures, or the step stops with a concrete incompatibility and the recommendation to defer/cut. Dependency adoption is not predetermined by this spec.
Step 1 — todo | rounds 0/2 | open: verifier compatibility gate | downgraded: none | assumed: library-first | deferred: live 1Password check to Step 5

### Step 2 — App-owned policy, enrollment and recovery
Change: versioned pairing persistence, explicit required states/epoch, app challenge/verifier service and principal-only operations; Mac Enable/Enroll/Reset/Disable controls with HTTPS prerequisite and truthful synchronization status. Use the existing trusted link; no new transport. Preserve required state on all unsuccessful setup paths.
Validation: focused store/tool-provider tests for v1 migration, malformed v2 rejection and old-build refusal; enroll timeout/reopen/restart/reset/disable; atomic save failure; one-use challenge binding and revalidation after awaits; revoked-device denial. Run lint and context/guardrail checks for durable docs.
Done when: no setup/recovery failure can silently remove protection, ordinary pairing remains intact, and only an authorized fresh assertion produces the app's verified unlock result.
Step 2 — todo | rounds 0/2 | open: none | downgraded: none | assumed: opt-in per browser; one credential; 120-second enrollment window | deferred: none

### Step 3 — Gateway grants and complete enforcement
Change: versioned trust policy, monotonic absolute grants, epoch/generation reconciliation, safe hello/sink ordering, signed control relay, inbound and loop-local outgoing gates, generic settlement of withheld results, and static-token closure. Scope remains gateway/browser only.
Validation: extend `GatewayAuthDeviceAuthenticatorTests` and `GatewayAuthE2EContractTests` using injected time and software assertions. Cover protected commands/results/errors, watch broadcasts/terminal catch-up, locked new sink before hello, expiry at queue boundary, Lock during verification, reset/invalid snapshot, transport outage, reconnect/other tab, cross-device/build binding and existing static-token connections. Preserve existing ticket/counter/revocation tests. No sleeps for expiration tests.
Done when: every content path is denied while locked, delayed grants cannot revive a lock, and the exact enqueue/in-flight boundary is demonstrated.
Step 3 — todo | rounds 0/2 | open: none | downgraded: none | assumed: 15-minute absolute per-browser grant | deferred: watch polling optimization

### Step 4 — Native passkey phone flow
Change: unlock/enrollment/needs-Mac states, user-gesture-safe ceremonies, Lock, content clearing, draft retention and stale-response fences; preserve deep link and channel identity. No account system or new framework.
Validation: existing `PWAResourceTests` plus focused JavaScriptCore fixtures for locked rendering, denied/cancelled ceremonies, stale challenges, all async lock transitions, uncertain sends, matching question draft restoration, reconnect and foreground restoration; retain unsafe-rendering API bans. Lint and minimal syntax/layout checks only; do not build browser infrastructure.
Done when: all deterministic transitions preserve pairing and unsent work while withholding content; phone-only behavior is explicitly pending, not claimed from fixtures.
Step 4 — todo | rounds 0/2 | open: none | downgraded: none | assumed: hide content while locked; in-page draft retention | deferred: real Safari behavior to Step 5

### Step 5 — Owner-approved deployment and live acceptance
Change: none unless live acceptance exposes an in-scope defect. Ask immediately before deployment/relaunch and every required manual or credential action. First target is Dev + normal iPhone Safari + current 1Password; other build/browser combinations are not prerequisites without separate owner approval.
Validation: enroll with Mac authorization, perform the separate unlock, open a Telegram session link, answer/steer/follow up/Stop, copy/read normally, reconnect/background/second-tab reuse within the window, fixed expiry without traffic extension, Lock across tabs, reset/reenroll, revoke, and plain-HTTP refusal. Confirm no prompt per action, no lost draft, no pre-unlock content flash on foreground, and clear recovery after cancel/provider failure. Use a throwaway credential if capturing a reusable public fixture; never export private credential material or grant secrets. Cross-build/hostname/port cases get deterministic tests first and separate live approval when available.
Done when: the owner accepts the actual Safari/1Password workflow and stated limits. Distill implemented facts into the owning context document, archive the original plan intact with an outcome summary, and handle any unsigned commits at the approved signing boundary.
Step 5 — todo | rounds 0/2 | open: owner deployment and live approvals | downgraded: none | assumed: Dev and Safari first | deferred: release/Brave live coverage unless requested

## Cuts
No public exposure or app-managed Tailscale; no passwords/OTP/recovery codes; no passkey replacing browser pairing; no multiple-credential manager; no grant persistence, sliding timeout, attempt-lockout framework or notification redesign; no attestation service, homemade verifier fallback, blanket header-hardening project or watch-poll optimization. Already-running work is not cancelled on lock. Library failure is a stop/defer decision, not permission to expand scope.

## Decisions
- Owner requested a separate passkey spec for the existing remote and identified 1Password as their preferred credential manager (2026-10-31).
- Owner deferred relaunch approval; this specification task does not authorize deployment or implementation (2026-10-31).

## Open owner choices and implementation gates
- Recommended timeout is 15 minutes absolute; alternatives are a shorter window or 30 minutes.
- Recommended grant scope is the paired browser across its tabs/reconnects; alternative is per connection with more prompts. Protection is opt-in per paired browser, so unprotected approved browsers intentionally retain pairing-only access.
- A verifier-library failure returns to the owner with defer/cut recommended. No dependency or custom fallback is preapproved.
- Real 1Password/native-prompt behavior and phone recovery are unverified until Step 5.

## Planning evidence
`docs/investigations/2026-10-31-remote-passkey-unlock/` holds read-only scouting, source checks, primary-source notes, both OracleD positions and their refinement. The owner named OracleD twice; two independent fresh chats used that exact preset, then each continued with the same narrowed candidate. This provides two independent consultations, not two different models. Both accepted the narrowed direction with corrections incorporated here; this document is a proposed synthesis, not owner approval or implementation-review approval.
