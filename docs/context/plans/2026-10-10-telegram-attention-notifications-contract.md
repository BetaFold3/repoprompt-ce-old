# Telegram attention notifications — work contract

Scope: read when the task touches Telegram (or other outbound) alerts for root Agent Mode turn completion or `ask_user` questions.
Authority: Reference
Last-verified: 2026-10-10

## Goal
Send me a Telegram message when a root Agent Mode session I drive needs me — a turn finished and the session settled, or an `ask_user` question is waiting — so I can step away and return only when needed. Desktop banners never fire while the app is frontmost and never reach my phone.

## Done when
- Enabled, a root turn that completes and settles idle (no queued follow-up or provider successor taking over) sends one notification: workspace, session name, and that turn's final assistant text; long text goes in up to 3 numbered parts, the last ending with a visible truncation marker.
- A root `ask_user` sends one notification with every question, every option (with description), and the multi-select/custom-answer flags, split into numbered parts rather than dropping anything.
- Nothing is sent for children at any depth (including orphaned children whose questions fall back to me), Knowledge workers, roots under external MCP control, unknown or conflicting lineage, or cancelled/failed turns.
- The app sends each event (session + turn attempt, or session + interaction ID) at most once; a question answered, skipped, timed out or cancelled before send admission is not sent. One attempt per event; the outcome (sent, failed, unknown) is recorded, never auto-retried.
- If Mac input idle time is readable without a permission prompt, send only when idle ≥5 min at event time; otherwise always send. App focus never matters.
- A hanging or failing Telegram call never delays the run, successor start, question installation or its timeout (fenced test, no sleeps).
- The bot token stays in secure storage; a forced failing request leaves no token in logs, crash breadcrumbs or the last-error text (test). Ephemeral storage or a missing token is shown in settings.
- Settings: off by default; enable, token, chat ID, Send test, last delivery result, last suppression reason.
- Focused tests pass against a stubbed HTTP client; then, with my approval, I confirm one real completion and one real question on my phone.

## Non-goals
Remote-control link and Telegram replies/buttons (separate contract; the implemented paired-browser link is documented in [Telegram paired-browser remote](../telegram-paired-browser-remote.md)); Codex native `requestUserInput`, tool/edit approvals, instruction waits; gateway Web Push changes or a gateway-hosted sink; a generic webhook framework; delivery while the app is not running; Markdown/HTML formatting.

## Boundaries (need my approval)
Any real Telegram send; visible app launch/relaunch; push; wider event coverage or message content; changes to delegation lineage, question audience, terminal-commit ordering, or gateway/remote contracts; any new macOS permission prompt.

## Budget
Advisory: about a week of focused work, a mid-sized change (notifier, settings, tests), reviewed per the review policy (initial review plus up to two re-review rounds per step). Stop and report past ~2× or if lineage itself must change.

## Facts
- Completion hook runs at terminal commit when `notifyTurnComplete` is set, after the successor kind is computed but without checking it — `AgentRunTerminalCommitBarrier.swift:289–316`; providers set that flag only for completed turns (scout-reported: `ClaudeIntegratedAgentModeRunner.swift:129–175`, `ACPIntegratedAgentModeRunner.swift:1631–1666`, `CodexAgentModeCoordinator.swift:6221–6284`, `HeadlessAgentModeRunner.swift:228–286`).
- Full final text is available; desktop truncation happens later — `AgentTranscriptServices.swift:2981–3039`, `NotificationService.swift:268–294` (scout-reported).
- `askUser` installs `pendingAskUser`, routes the delegated audience, and sends no alert — `AgentModeViewModel.swift:19075–19108`; answer/skip/timeout/cancel clear it at ~19176–19379 (scout-reported). Question audience and text rendering already exist — `AgentDelegatedQuestionAudience.swift:15`, `AgentDelegatedQuestionNotice.swift:115`.
- Claude native `AskUserQuestion` is disallowed — `ClaudeCodeIntegrationConfiguration.swift:65,100,133`; Codex `requestUserInput` bypasses `askUser` — `CodexAgentModeCoordinator.swift:6573–6574`.
- Root lineage resolves via `mcpDelegationLineage` and fails closed on unknown/conflicting parents — `AgentModeViewModel.swift:6739–6806`; `agent-mcp-delegation-depth.md` (Lineage).
- Desktop alerts return early while the app is active — `NotificationService.swift:97,119`; no app-level notification setting exists (scout search).
- Secure storage can fall back to an ephemeral store — `SecureKeyValueStorageBackend.swift:51–75`. An injectable `HTTPClient` exists — `Infrastructure/Networking/HTTPClient.swift:3–46`.
- Telegram `sendMessage`: 1–4096 chars, token in the URL path, ~1 msg/s per chat — core.telegram.org/bots/api#sendmessage, core.telegram.org/bots/faq. No Telegram/webhook code exists (repo search 2026-10-10).
- Mac idle time: CoreGraphics `CGEventSource.secondsSinceLastEventType`; unused in repo, permission need unverified (search 2026-10-10).
- The PWA can't take a link yet: gateway off by default (`GlobalSettingsManager.swift:1253–1254`), HTTP-only tailnet origin (`RemoteDiscovery.swift:88–94`), pairing posts `{}` but host requires `approval_context` (`app.js:168`, `MCPRemotePairingToolProvider.swift:303`), no structured-question UI (`app.js:525–541`).

## Directions (ranked)
1. Settled-event admission in the app: capture completion identity and text at terminal commit but admit only once successor selection settles idle; capture `ask_user` at installation and admit only while that exact pending interaction is current; reuse lineage, audience and question-text authorities; send off the main actor. Why: reuses existing authorities and covers every provider. Kill: a queued-successor chain yields an intermediate alert or misses/misattributes the final one and the fix needs terminal-commit reordering; or pause-before-send then resolve/rebind/disable still yields a POST; or a cold-started UI root resolves unknown and needs a lineage change.
2. Pure run-state observation (session becomes idle / waiting-for-user). Why: no hook edits, naturally skips intermediates. Kill: completed vs cancelled/failed is indistinguishable, the final text or interaction ID is unavailable, approval waits look like questions, or two consecutive questions collapse into one alert.

## Evidence directory
`docs/investigations/2026-10-10-telegram-attention-notifications/` (git-excluded, not committed).

## Slices

### Slice 1
Check the live settled-event direction for boundary-breaking kill results before implementing it; budget used so far: one read-only probe, no source changes.

Step 1 — done | rounds 0/2 | open: none | downgraded: none | assumed: static feasibility is not runtime acceptance | deferred: runtime kill tests in Slice 2

Slice 1 result: Source tracing found existing root, successor, question and binding authorities sufficient for a boundary-preserving admission seam, with structural checks passing and no runtime result yet, so Slice 2 tests that seam before adding transport (evidence: `slice-1-findings.txt`).

### Slice 2
Add only the settled completion/question admission seam and prove Direction 1 kill conditions with deterministic stub delivery; budget used so far: Slice 1 source probe and structural checks, no production source change.

Step 2 — done | rounds 1/2 | open: none | downgraded: none | assumed: all MCP-controlled roots are excluded; remote-host roots are eligible; provider/root coverage is fixture evidence, not live acceptance | deferred: secure transport and settings; real restore, UI-handoff and scheduled-send integration; R1 selected generic follow-up abandoned before starting stays silent; R3 rejected publication then declined duplicate does not recover an alert; R4 remote-child projection requires proof before enabling delivery

Material implementation choices: Keep one app-wide event ledger for at-most-once admission across windows, and add notification-only capture/settlement hooks without reordering existing terminal calls; preserve the owner’s five-minute event-time drop rule.

Budget used so far: about two hours elapsed including Oracle and shared-build-slot waits, one completed source slice and three scoped worker sessions; no real sends or app lifecycle actions.

Slice 2 result: The disabled admission seam passed 15 fenced stub tests, 139 lifecycle tests, 23 fallback tests and 24 delegated-question tests plus lint and structural checks, and both review lanes cleared it with no open P0/P1, so the next slice adds isolated secure Telegram delivery before settings enable it (evidence: `slice-2-parent-final-tests.txt`, `slice-2-parent-final-lint.txt`, `slice-2-review-fixes-lifecycle.txt`, `slice-2-review-fixes-fallback.txt`, `slice-2-parent-delegated-check.txt`, `slice-2-oracleA-rereview-1.md`, `slice-2-oracleB-rereview-1.md`).

Review follow-up: Static tracing found only the Codex fallback successor factory; a temporary decline leaves its queue nonempty and a successful claim starts new ownership synchronously, so neither can pass the admission fence; eligible roots publish synchronously as accepted, making R3 a synthetic noneligible publication case (evidence: `slice-2-provider-successor-search.txt`, `slice-2-publication-scope.txt`).

### Slice 3
Add isolated plain-text Telegram rendering, single-attempt HTTP delivery and noninteractive secure token storage, with stubbed failure/leak and multipart tests before production wiring; budget used so far: about two hours elapsed, one committed source slice and three scoped worker sessions.

Step 3 — done | rounds 1/2 | open: none | downgraded: none | assumed: no real HTTP calls or live-session delivery; server errors and offline drops may mean unknown delivery; full names share the completion's three-part budget | deferred: settings UI, paced pre-send admission, event-time system idle sampling, integration and phone acceptance; R1-2 capacity-filling splits can divide words

Material implementation choices: Use the existing HTTPClient and secure-storage backend, fixed Telegram endpoint and plain JSON, and keep raw URL/request/error/response details out of diagnostics; split without loss for questions and cap completions at three numbered parts with a visible marker only when truncated; treat all API server errors and offline drops as unknown rather than claim non-delivery, with no retry.

Budget used so far: about three hours elapsed including shared-slot and review waits, two completed source slices and four scoped worker sessions; no real sends, credential access or app lifecycle actions.

Slice 3 result: Isolated rendering, HTTP delivery and secure token storage passed 45 focused stub tests after a reproduced paragraph-loss regression was fixed, with lint and guardrails passing and both review lanes clearing P0/P1 in one re-review round, so the next slice joins pacing to admission while live delivery remains disconnected (evidence: `slice-3-fixes-renderer-red.txt`, `slice-3-fixes-renderer-green.txt`, `slice-3-parent-final-client.txt`, `slice-3-final-TelegramBotTokenStoreTests.txt`, `slice-3-final-SecureStorageAccountCatalogTests.txt`, `slice-3-oracleA-rereview-1.md`, `slice-3-oracleB-rereview-1.md`).

Review follow-up: Shared ephemeral storage and noninteractive reason semantics were confirmed from the existing factory and Keychain query; the redirect test checks the SDK selector and refusal directly, not a live URLSession redirect; the final cheap P3 outcome fixes were rerun without a review round solely for P3 (evidence: `slice-3-storage-authority.txt`, `slice-3-parent-final-client.txt`).

### Slice 4
Join paced single-attempt Telegram delivery to event admission behind deterministic HTTP and queue fences, keeping production disconnected; budget used so far: about three hours elapsed, two committed source slices and four scoped worker sessions.

Step 4 — done | rounds 0/2 | open: none | downgraded: none | assumed: queued events revalidate after pacing and before their first POST; admitted attempts retain their credential snapshot, with no withdrawal promise after admission; no live settings or secure-storage reads in tests | deferred: settings must share one pacer across replacements and route Send test through the same queue (B S4-1); sanitized part-failure reason for settings (B S4-4); shared test-double file move (B S4-5); settings and live wiring, root restore/handoff/schedule and remote-child integration, R1 selected follow-up abort recovery, phone acceptance

Material implementation choices: Keep the FIFO and duplicate-pending ownership inside the existing admission authority rather than add a separate permit ledger; retain one event's queue head through all its parts, so a hanging request holds later notifications only, not run or question processing; share pacing state across credential replacements, with one-second private-chat spacing and conservative three-second spacing for groups/channel usernames; keep shared test doubles together rather than introduce a support file solely for an organizational finding (planning evidence: `slice-4-plan.md`).

Budget used so far: about four hours elapsed including shared-slot and review waits, three completed source slices and five scoped worker sessions, reusing the Pair worker for fixes; no real sends, credential access or app lifecycle actions.

Slice 4 result: Paced queued admission passed 29 stub tests after the new coverage test's premature outcome read was corrected, with lint and guardrails passing and both review lanes clearing P0/P1, so the next slice proves restored and projected session eligibility and selected follow-up abort recovery before settings enable production (evidence: `slice-4-final-AttentionNotificationAdmissionTests.txt`, `slice-4-fixes-paced-delivery-run-3.txt`, `slice-4-fixes-lint-2.txt`, `slice-4-guardrails.txt`, `slice-4-oracleA-initial.md`, `slice-4-oracleB-initial.md`).

Review follow-up: Added post-admission credential-retention and snapshot-redaction tests without changing reviewed production behavior, so no round was run solely for P2/P3; the final accepted test ticket waited 22 minutes 36 seconds for another worktree's heavy slot and then passed in 13.4 seconds, not a delivery-latency measurement.

### Slice 5
Prove eligible restored, handoff and scheduled roots and ineligible projected children using existing production paths, and reproduce the selected-follow-up-abort gap before choosing a repair; budget used so far: about four hours elapsed, three committed source slices and five scoped worker sessions.

Step 5 — done | rounds 0/2 | open: none | downgraded: none | assumed: temporary-store and stub-provider integration is not live app acceptance; no lineage, question audience or terminal-order changes | deferred: R1 experiment did not reproduce pre-ownership abort because availability changed before the queued start; projected-child lineage proof uses local authorities, while actual remote event dispatch bypasses capture; remote-root classification/coverage remains unresolved; duplicated fixture helper and older fixture test ID retained (B S5-6/7); follow-up repair only after a stable reproduction; settings and live wiring, phone acceptance

Budget used so far: about five hours elapsed including review and shared-slot waits, four completed code/test slices and six scoped worker sessions, reusing the Pair worker for fixes; no real sends, secure-store access or app lifecycle actions.

Slice 5 result: Four production-construction tests added six notification scenarios and passed the 20-test admission suite plus lint and executable discovery after scope/branch assertions were tightened, but the attempted unavailable-provider experiment actually started its follow-up and did not reproduce abandonment, so the next slice resolves that experiment and remote-event authority before live wiring (evidence: `slice-5-fixes-admission-run-1.txt`, `slice-5-fixes-lint.txt`, `slice-5-dev-test-list-full.txt`, `slice-5-r1-experiment-raw.txt`, `slice-5-oracleA-initial.md`, `slice-5-oracleB-initial.md`).

Review follow-up: Both lanes cleared P0/P1, cheap coverage and wording findings were fixed without production changes or a round solely for P2/P3, and the shared data service's hydration path was confirmed to read/decode the session file rather than serve a transcript cache; the test remains a second view model in one process, not live app cold-start acceptance (evidence: `slice-5-parent-restore-authority.txt`).

### Slice 6
Resolve the selected-follow-up-abort experiment with retained fixture dependencies and classify actual remote-event ownership from existing authorities before choosing any repair; budget used so far: about five hours elapsed, four committed code/test slices and six scoped worker sessions.

Step 6 — done | rounds 0/2 | open: none | downgraded: none | assumed: temporary experiments removed; no global preference, lineage, question audience, terminal-order or remote-contract changes; direct tab reservation is a refusal fixture, not real deletion | deferred: notification-only follow-up repair, settings/live wiring and phone acceptance until coverage is clarified

Budget used so far: about five and a half hours elapsed, four committed code/test slices and seven scoped worker sessions, reusing the integration worker for two temporary experiments; no real sends, secure-store access or visible app actions.

Slice 6 result: Strong retention refuted the weak-lifetime hypothesis because the same settings object changed availability, then a fenced reserved-tab fixture proved that a selected follow-up refused before ownership leaves the completed idle root incorrectly suppressed (21 tests, only the deliberate delivery assertion failed; 20 committed tests passed), while source tracing proved remote projections lack reliable completion/question authority, so live wiring waits for the owner to choose where remote notifications must be configured (evidence: `slice-6-r1-test-run-full.txt`, `slice-6-r1-observations.txt`, `slice-6-r1-reserved-fixture.diff`, `slice-6-r1-reserved-test-run-full.txt`, `slice-6-r1-reserved-observations.txt`, `slice-6-remote-authorities.txt`, `slice-6-plan.md`).

Material interpretation requiring owner answer: Notifying only on the executing host preserves trusted local authorities; a remotely observed UI root is not necessarily MCP-controlled, but enabling only its observing client cannot safely cover it from current projections without crossing the remote-contract boundary. Both temporary fixtures were removed and source remains unchanged; this experiment-only slice needs no code review or commit.

Owner question `telegram_remote_notification_configuration` timed out after 328 seconds on 2026-10-10; the owner answered “Configure on the executing Mac” on 2026-10-11, clearing the coverage block without authorizing proxy alerts or remote-contract changes. All seven scoped worker sessions completed before the pause.

### Slice 7
Repair the reproduced selected-follow-up pre-ownership refusal using notification-only outcome observation and existing current-event fences, without changing terminal ordering; budget used so far: about five and a half hours of work including waits, four committed code/test slices and seven scoped worker sessions.

Step 7 — done | rounds 0/2 | open: none | downgraded: none | assumed: notifier remains disconnected; permanent reservation regression proves refusal, not deletion; executing-host-only configuration | deferred: unchanged selected-but-unscheduled and other nil-observation start paths (B S7-2); a remaining queued instruction prevents settled-idle admission by contract; generic suppression detail/pre-filter optimization (B S7-3); settings/live wiring, event-time idle sampling and approved phone acceptance

Budget used so far: about six hours of work including waits, five completed code/test slices and seven scoped worker sessions, reusing the integration worker; no real sends, secure-store access, app lifecycle actions or pushes.

Slice 7 result: An after-start notification observation turned the Slice 6 refusal regression from one expected failure into one original-attempt delivery and passed 21 admission, 139 lifecycle and 23 fallback tests plus lint/guardrails/context checks, with both lanes clearing P0/P1 and no terminal-order changes, so the next slice adds settings and executing-host service wiring against stub HTTP (evidence: `slice-7-parent-final-admission.txt`, `slice-7-test-lifecycle-run-1.txt`, `slice-7-test-codex-fallback-fifo-run-1.txt`, `slice-7-parent-final-lint.txt`, `slice-7-OracleA-initial.md`, `slice-7-OracleB-initial.md`).

Material implementation choices: Keep the callback inside the existing follow-up start task and submit the original immutable capture only after start returns; do not add a capture map or overwrite a tombstone, and retain fail-closed behavior for unchanged unscheduled/replayed starts. Static tracing confirms every provider runner claims ownership and clears the original commit before spawning provider work, closing B S7-1 without new provider fixtures; correct suppression comments but defer the optional queue pre-filter because it is not needed for admission correctness (evidence: `slice-7-provider-start-authority.txt`). Comment-only follow-ups changed no reviewed behavior and the final 21-test admission run and lint were repeated without a round solely for P2/P3.

### Slice 8
Add executing-host settings and app-wide Telegram configuration using the existing admission queue, secure token store and stubbed HTTP validation, with read-only event-time idle sampling and a source-only classification of the remaining S7-2 follow-up paths before live acceptance; budget used so far: about six hours of work including waits, five committed code/test slices and seven scoped worker sessions.

Step 8 — done | rounds 1/2 | open: none | downgraded: none | assumed: all validation uses stub storage/HTTP and no app launch; explicit Send test bypasses automatic enablement and idle filtering but retains configuration/current-service fences and the same FIFO/pacer, not wider automatic event coverage (undo by requiring enablement before Send test); idle uses combined-session input including synthetic events (undo by choosing hardware-source sampling) | deferred: B S8-5 unchanged-value save optimization, B S8-6 hardware-only idle source, B S8-7 generic reader name, B S8-8 external-enable/invalid-chat reload table expansion; fenced ACP late-steering experiment and owner-approved real completion/question phone acceptance

Result: Built executing-Mac settings and guarded startup configuration with secure-token status, shared-queue Send test and event-time idle sampling, passed 13 service, 21 admission, 13 paced, 17 renderer, 90 persistence and one settings-search tests plus lint/build/structural checks with stub HTTP/storage, closed the blocking finding after one re-review by both lanes, and will test the remaining ACP steering settlement window before requesting live acceptance.

Material implementation choices: Show the saved automatic-notification preference separately from delivery readiness, disable runtime delivery immediately on an off/removal action, and explain failed persistence with a direct save-off retry; retain automatic-event diagnostics separately from each manual test record. Keep combined-session idle sampling because the contract says Mac input idle, not physical input only; defer unchanged-value save optimization and a generic idle-reader rename because neither is needed for the requested event contract. Re-review A S8-03/B S8-R1-1 was cheaply fixed by treating an already-saved off preference as successfully off instead of reporting a redundant write failure, and two notice/comment wording issues were corrected; notification admission/delivery behavior is unchanged, the six-row removal table and final 13-test service run cover it, and no round was run solely for new P2/P3 (evidence: `slice-8-parent-final-service-2.txt`, both `slice-8-Oracle*-rereview-1.md`). External-enable and invalid-chat reload table expansion remains deferred under B S8-8. Final budget used is about seven and a half hours including waits, six code/test slices and eight scoped worker sessions. Source tracing closes unchanged eligible-root publication-abandonment/replay paths and confirms remaining generic instructions are not settled idle, but accepted ACP steering can remain outside the currently checked queues until after terminal settlement; that requires a fenced experiment, not a claimed runtime failure (evidence: `slice-8-S7-2-source-probe.txt`).

### Slice 9
Test the ACP late-steering settlement window with a temporary, fenced fake-controller experiment before changing notification behavior, retaining only raw evidence and restoring all temporary source/test edits; budget used so far: about seven and a half hours including waits, six committed code/test slices and eight scoped worker sessions.

Step 9 — done | rounds 0/2 | open: none | downgraded: none | assumed: fake ACP process and stub delivery only, with deterministic gates and no sleeps, real HTTP/storage or visible app lifecycle | deferred: owner-approved real completion/question phone acceptance

Result: Ran one temporary ACP test twice with two fenced schedules through real user submission and a fake ACP process, observed two alerts instead of the expected final-only alert when admission preceded the queued start and mixed earlier/later reply text in the final alert under both schedules (four assertions failed per run), restored every experiment edit, and will repair notification-only settlement and turn-scoped text without changing terminal order or the shared MCP preview (evidence: `slice-9-witnesses-run-2.txt`, `slice-9-test-run-2.txt`, `slice-9-restore-checkpoint.txt`).

Material implementation choices: Treat the post-prompt task-local hold as a controlled delay at the existing cross-actor identity lookup, not a new wire terminal or changed terminal ordering; actual user submissions and pending instruction IDs establish accepted queued work, while a later marker only infers the no-state-change active-flush branch ran. Keep the terminal/publication/gateway authorities unchanged and choose a notification-specific repair rather than permanently dropping the earlier completion solely because an ACP flush exists, which could lose the final alert after a refused start. Source/test files match HEAD and the staged set is empty, so this experiment needs no review or commit; lint, guardrails and live validation did not run, and the context check passed with the existing route-count warning. Final budget used is about eight hours including waits, six committed code/test slices and eight scoped worker sessions.

### Slice 10
Repair notification-only completion settlement and turn-scoped reply capture for accepted late ACP steering, preserving terminal order and shared MCP preview behavior, and retain the smallest fenced regression covering the demonstrated defect; budget used so far: about eight hours including waits, six committed code/test slices and eight scoped worker sessions.

Step 10 — done | rounds 0/2 | open: none | downgraded: none | assumed: fake ACP process and stub delivery only; no terminal-order, lineage, question-audience or gateway changes | deferred: B S10-5 shared ordering-helper extraction, owner-approved real completion/question phone acceptance

Material implementation choices: The source audit rejected sequence-floor-only text selection because the guarded `final_content` handler can overwrite an earlier row without changing its sequence index; record that actual rewrite's row identity for notification provenance and retain the shared transcript/MCP behavior instead of accepting missing text or repairing the unrelated transcript overwrite (evidence: `slice-10-boundary-invariants.txt`, `slice-10-plan-provenance.md`).

Both initial review lanes completed against the same six-file diff and contract, with no P0/P1; the cheap follow-ups route generic after-start observations through the ACP hold, prove ordinary text parity, discard held captures on existing resets, and assert the pre-start hold directly. Keep the text helper private but defer shared ordering extraction because it does not serve a done-when item (evidence: `slice-10-OracleA-initial.md`, `slice-10-OracleB-initial.md`).

Result: Retained the original completion outside admission until ACP handoffs settle and captured attempt-owned reply rows, turning the two-test/four-failure late-steering baseline into a final 307-test/zero-failure combined notification/lifecycle run plus lint/build/guardrails/context checks, with both initial review lanes clearing P0/P1 and cheap follow-ups validated, so the next slice waits for executing-Mac credentials and owner-approved phone acceptance (evidence: `slice-10-test-prefix-red-run-1.txt`, `slice-10-parent-final-test-counts.txt`, `slice-10-fixes-lint.txt`, `slice-10-parent-final-build.txt`, both `slice-10-Oracle*-initial.md`).

Review dispositions: B S10-1 is fixed by the suggested generic observation handoff and a regression with an actual generic refusal plus a fixture-observed ACP start; reverting the fix produced two expected failures before restoration and a final passing run. B S10-2 is closed for the ordinary long-text case by a parity assertion against the live completed resolver, not a claim that all derived/source layouts are identical; B S10-3/S10-4 are fixed by synchronous reset discard and direct held-capture assertions, and the helper is private under S10-5 while shared ordering extraction stays deferred. No round was run solely for these P2/P3 follow-ups; affected validation was repeated on the final restored source. The original red-test source was not retained, so its exact red-to-reviewed test diff is unavailable; the observed four count/text failures are raw evidence, the final regression keeps those desired outcomes and adds refusal/no-successor schedules, and the fallback test was already passing before the fix. No full suite, actual app launch, credential access, real HTTP or phone acceptance ran. Final budget used is about nine hours including waits, seven code/test slices and eight scoped worker sessions, reusing the engineer and Pair sessions.

### Slice 11
Configure and confirm one real completion and one real RepoPrompt `ask_user` notification on the executing Mac only after owner approval and owner-entered credentials; budget used so far: about nine hours including waits, seven committed code/test slices and eight scoped worker sessions.

Step 11 — blocked | rounds 0/2 | open: actual RepoPrompt ask_user phone confirmation and approval for any agent-triggered real sends or visible lifecycle action | downgraded: none | assumed: owner-entered credentials stay in Settings/secure storage; the installed authorized debug signature and keychain marker qualify for persistence, without inspecting runtime environment overrides | deferred: none

Result: After a successful Send test and read-only configuration checks, the owner confirmed receiving a real completion notification from another workspace while the Mac was idle on the pre-update installed build, so completion phone acceptance is owner-confirmed and only the RepoPrompt ask_user phone check remains pending after the owner's planned rebuild/relaunch (evidence: `slice-11-owner-completion-confirmation.txt`, `slice-11-executing-mac-checks.txt`; earlier unanswered approval: `slice-11-approval-result.txt`).

Material implementation choices: Keep the contract active rather than declaring completion or archiving it before phone confirmation; no code, new validation tool or proxy event is needed for this final manual slice. An MCP-controlled root is excluded and cannot substitute for an owner-driven UI root; real automatic acceptance must respect the chosen event-time idle threshold when readable, with zero bypassing that filter.

### Slice 12
Add a persisted configurable idle threshold for automatic notifications, with an explicit always-notify choice and the existing five-minute default, and prove policy-change admission fences before building out the setting; budget used so far: about nine hours including waits, seven committed code/test slices and eight scoped worker sessions.

Step 12 — done | rounds 0/2 | open: none | downgraded: none | assumed: five minutes remains the default, zero means always notify, custom values are nonnegative whole minutes; event-time idle and dropped-not-delayed suppression remain unchanged | deferred: B S12-2 external-reload draft refresh, B S12-5 internal naming/state cleanup, B S12-6 hypothetical setter reentrancy hardening; Slice 11 real ask_user phone confirmation and any visible relaunch

Material implementation choices: Treat the owner's configurable-idle request as replacing the fixed-five-minute requirement without editing the owner-controlled Done when text; record the owner answer below and implement only the setting, persistence and admission behavior needed for it. Reuse the existing automatic generation and add one idle-only source revision to distinguish accepted changes when observation is delayed or a value changes back, leaving the delivery snapshot, pacer and manual Send test unchanged. Preserve optional-field decoding and treat a negative stored threshold as the five-minute default rather than adding whole-document rejection; invalid UI drafts are rejected before any save. Test a queued event against a changed idle policy before completing the UI, and do not read tokens, write real preferences, trigger real sends or relaunch the app during development.

Kill checkpoint result: A temporary removal of the automatic-policy generation and final saved-source fences produced nine failed assertions including four unwanted stub POSTs across five queued-policy schedules, restoring the exact pre-mutation source made the one-test checkpoint pass with zero failures, and the slice continues with settings UI and focused persistence/admission validation (evidence: `slice-12-kill-red.txt`, `slice-12-kill-green.txt`, `slice-12-kill-restore-check.txt`).

Review dispositions: Both lanes cleared P0/P1. Fix A S12-R1/S12-01 by saying Send test queues rather than sends immediately, fix B S12-3 with Return-to-save, remove the tautological B S12-4 assertion while retaining the real Int.max admission case, and rerun lifecycle/FIFO under B S12-7. Defer B S12-2 because the saved label stays accurate and automatic draft replacement could discard an unsaved edit; defer B S12-5 cleanup and B S12-6 because the proposed synchronous reentrancy does not exist in the current observer path. Read-only checks under B S12-1 confirmed the installed persistent-Keychain app is untouched at /Applications/RepoPrompt CE Dev.app and the validation bundle is separate; rebuild the latter with the identical installed signing identity and explicit Keychain policy, without installation or launch. B S12-8 is addressed by marking the older focus answer superseded and consolidating these choices; no round is run solely for P2/P3 follow-ups (evidence: both `slice-12-Oracle*-initial.md`).

Result: Added custom saved whole-minute idle thresholds and Always Notify while preserving the five-minute default, passed the 149-test feature/persistence run and a final 230-test notification/lifecycle/FIFO run after the nine-failure missing-fence checkpoint, cleared both review lanes' P0/P1 and validated lint/build/guardrails/context checks, and will return to Slice 11 for owner-approved relaunch and real completion/question phone confirmation (evidence: `slice-12-parent-final-test-counts.txt`, `slice-12-parent-final-lint.txt`, `slice-12-parent-final-keychain-build.txt`, both `slice-12-Oracle*-initial.md`).

Final validation and budget: The final bundle uses the installed app's unchanged Apple Development identity and authorized persistent-Keychain policy, and read-only signature/marker checks pass for both separate paths; the initial requirement probe used the wrong argument form and was corrected without changing either bundle (evidence: `slice-12-final-bundle-storage-check-2.txt`). No full suite, visual UI validation, real Telegram request, token read, installation or visible lifecycle action was performed; all workers and coordinated jobs completed. The 23 context-checker tests passed, and no review round was run solely for cheap P2/P3 copy/Return-to-save/test-assertion follow-ups. About ten hours including waits have been used, with eight code/test slices and eight scoped worker sessions, reusing the settings engineer.

## Decisions
- Idle threshold: make the automatic-notification idle requirement configurable rather than fixed at five minutes (owner answer 2026-10-12).
- Remote configuration: configure Telegram on the executing Mac, not the observing client (owner answer 2026-10-11); no proxy notification or remote-contract expansion.
- Commit signing: permit unsigned local commits for this contract after the Slice 4 1Password failure; owner will arrange later amendment/re-signing at the desk, with separate history-rewrite approval at that action boundary (owner answer 2026-10-10).
- Review recovery (Slice 2): authorize one additional fresh, bounded OracleB retry after the initial reply and normal retry omitted findings and a complete verdict (owner answer 2026-10-10).
- Orphaned-child questions: never notify.
- Externally MCP-controlled roots: do not notify.
- Coverage: finished turns and RepoPrompt `ask_user` only.
- Focus: prefer sending only when the Mac has been idle ≥5 min if detectable; otherwise always send (fixed threshold superseded by the configurable-idle owner answer 2026-10-12).
- Long replies: numbered parts, up to 3 messages.

## Assumed
- Idle is checked at event time; an event skipped because I'm active is dropped, not re-sent later.
- One send attempt, no auto-retry; plain text only; UI-handoff, Knowledge-root and scheduled-send roots count as roots.
