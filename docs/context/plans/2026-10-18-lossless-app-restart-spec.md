# Lossless app restart and one-click resume — technical spec

Scope: read when the task touches persistence of composer drafts or queued input (follow-ups, Claude/ACP steering, the Codex fallback queue), durable acknowledgement of sends, quit or window-close preservation, the surviving provider-process registry, interrupted-turn state, the recovery list, or Resume after an app restart.
Authority: Reference
Last-verified: 2026-10-18

Status: Phases 1/2, Phase 3 process-registry source, Steps 4a/4b/4c and Phase 5 preservation source are committed and reviewed. The bounded observed Claude subset now includes outbound identity, native-history reconciliation, single-text/Read identity, save/reload comparison, honest unresolved-tool presentation and prospective agreement-proof retention (Step 4d7), without additional raw retention or healing previously cleared proofs. The demonstrated pre-live source findings are closed; full Phase 4 remains blocked on actual app-profile and every-supported-pair qualification in the final isolated live package. Production recovery activation and final live acceptance remain pending (O3/O9/O10).
Step 6-prelive — done | rounds 0/2 | open: none ([validation](evidence/2026-10-18-lossless-app-restart/pre-live-validation-2026-10-24.md)) | downgraded: full-root codemap test failure (`MCPCodeStructureWorktreeTests…ForegroundRecoversOnce`) ignored per O27; pre-existing, fails in clean worktrees at d971983b and 5507c3fa ([Live acceptance results](#live-acceptance-results-2026-10-25)) | assumed: existing dirty-tree tests/package are labeled source and packaging evidence, not clean-HEAD/live acceptance; no unrelated codemap edits | deferred: codemap baseline diagnosis/fix (owner, separately); live cases below
Step 7-F7 — done | rounds 1/2 | open: none; A/B initial review (B P1 R1: unpersisted submit-exit logs) fixed and cleared by A/B re-review 1; 383 focused tests pass ([evidence](evidence/2026-10-18-lossless-app-restart/fix-f7-worker.md)) | downgraded: none | assumed: tab/workspace activation sets `currentTabID` before publishing (audited, no ordering test; view tab-change re-sync is the fallback) | deferred: Tab-tag first-send test until the new ComposerSubmit logs show the reason; workspace-switch ordering test; B R5 other-tab-dependent fields, N3 log correlation, N4 `canSchedule` in no-session snapshot (view gates on target); full test lane and live composer re-checks
Step 7-F1 — done | rounds 1/2 | open: none; A/B initial review had no confirmed P0/P1 (B conditional R2 resolved: replacement retires the lane, registry moved to the coordinator), A/B re-review 1 cleared; 672 focused tests, core 66/66; full lane 54 failures = known codemap failure plus 53 load-only watcher-start failures that pass in isolation ([evidence](evidence/2026-10-18-lossless-app-restart/fix-f1-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-f1-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-f1-review-oracleb.md), [A r1](evidence/2026-10-18-lossless-app-restart/fix-f1-review-oraclea-r1.md), [B r1](evidence/2026-10-18-lossless-app-restart/fix-f1-review-oracleb-r1.md)) | downgraded: none | assumed: only scheduled owners keep no-handoff settlements; non-scheduled settlements cleared (two tests updated deliberately) | deferred: A r1 R4 read-failure liveness (bounded to deferred entries), B R6 scheduled send through the real Claude runner, B N1/N3 failed-status-save test, B P3-a rare registry retention; live acceptance
Step 7-F2 — done | rounds 1/2 | open: none; A/B initial review had no confirmed P0/P1 (B conditional R1 closed: unbound tabs never report unresolved recovery, old predicate restored), A/B re-review 1 cleared, cheap P3s applied; 343 focused tests ([evidence](evidence/2026-10-18-lossless-app-restart/fix-f2-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-f2-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-f2-review-oracleb.md), [A r1](evidence/2026-10-18-lossless-app-restart/fix-f2-review-oraclea-r1.md), [B r1](evidence/2026-10-18-lossless-app-restart/fix-f2-review-oracleb-r1.md)) | downgraded: none | assumed: the recovery gate explains the live observation (reproduced in tests, not observed live); restriction wording "Restart RepoPrompt to check again" | deferred: B r1 P3-4 stub `.stale` outcome, P3-5 empty-blocker filter; no Needs Attention button in the banner; full test lane, rendered banner layout and live check
Step 7-F4 — done | rounds 1/2 | open: none; diagnosis: race supported (concurrent readiness replacing the controller), lazy resume after cancel refuted by test; A/B initial review no P0/P1, A/B re-review 1 cleared, cheap P3s applied; 410 focused tests ([evidence](evidence/2026-10-18-lossless-app-restart/fix-f4-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-f4-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-f4-review-oracleb.md), [A r1](evidence/2026-10-18-lossless-app-restart/fix-f4-review-oraclea-r1.md), [B r1](evidence/2026-10-18-lossless-app-restart/fix-f4-review-oracleb-r1.md)) | downgraded: none | assumed: MCP startup-lease and managed-auth recovered start never begin/end a run attempt (code reading; no lease-enabled test); "still reconnecting" refuses rather than waits | deferred: lease-enabled /compact test; B R7 duplicated availability-reason mapping, R8 second log channel, RR4 retry-test controller identity, RR5 concurrent resumes on one controller (pre-existing); live idle /compact with production tooling and a cancel→/compact re-run to name the K3 trigger
Step 7-F3F6 — done | rounds 0/2 | open: none; A/B initial review no P0/P1; text/log-only P2/P3 fixes applied without a re-review round; 712 focused tests; full lane 45 failures in 12 suites, all passing in isolation except the known codemap failure ([evidence](evidence/2026-10-18-lossless-app-restart/fix-f3f6-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-f3f6-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-f3f6-review-oracleb.md)) | downgraded: none | assumed: a refused scheduled send is final (marked failed), so its text says "not sent", not "paused"; read-only volumes share the neutral access wording; audit scope covered recovery/shutdown/commit-failure user-facing text | deferred: live permission-denied quit check (cycle8.H_shutdownFault re-run, needs owner approval)
Step 7-F5obs — done | rounds 0/2 | open: none; A/B initial review no P0/P1 ([worker](evidence/2026-10-18-lossless-app-restart/fix-f5obs-worker.md), [A](evidence/2026-10-18-lossless-app-restart/fix-f5obs-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-f5obs-review-oracleb.md)); log-text-only P2/P3 follow-ups applied without a re-review round; persisted `LifecycleShutdown` log lines per shutdown phase and per failure dialog (request ID, stage, choice); 80 focused tests | downgraded: none | assumed: "dialog presented" in the log means requested from the presenter, not confirmed visible | deferred: live F5 reproduction with screenshot ~10 s after Quit (needs owner approval); Stage B per-step lines, a stricter composer-wait assertion and test-fixture cleanup (OracleB P3s)
Step 7-minor — done | rounds 1/2 | open: none; item 1 (a Codex bash row killed by quit read `success` after relaunch) fixed: a vanished process settles as `finished` only when the current provider controller owns the execution, otherwise `interrupted` (stored as cancelled, no invented exit code); A initial P1 MINOR-01 (reconnect restores false success) fixed and closed by A/B re-review 1; cheap follow-ups applied without changing reviewed behaviour; 86 focused tests ([worker](evidence/2026-10-18-lossless-app-restart/fix-minor-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-minor-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-minor-review-oracleb.md), re-review [A](evidence/2026-10-18-lossless-app-restart/fix-minor-review-oraclea-r1.md), [B](evidence/2026-10-18-lossless-app-restart/fix-minor-review-oracleb-r1.md)) | downgraded: none | assumed: an unknown outcome after relaunch reads cancelled rather than success | deferred: item 2 (Recovery View popover swallows the next click; SwiftUI popover has no pass-through, needs an AppKit popover wrapper or a UX change, owner choice pending); transport closing during an active run can still settle an owned vanished process as success (A MINOR-05/B R1-02, pre-existing); generation-transition tests (A MINOR-04); full suite and live check not run
Step 8-popover — done | rounds 1/2 | open: none; the View popover is a native AppKit NSPopover that closes on an outside click and lets that click reach its target ([worker](evidence/2026-10-18-lossless-app-restart/fix-popover-worker.md)); A/B review 0 ([A](evidence/2026-10-18-lossless-app-restart/fix-popover-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-popover-review-oracleb.md)) B P1 F1 stale comparison text and B P2 F2 binding left open after removal fixed and cleared by A/B re-review 1 ([A](evidence/2026-10-18-lossless-app-restart/fix-popover-review-oraclea-r1.md), [B](evidence/2026-10-18-lossless-app-restart/fix-popover-review-oracleb-r1.md)); 5 new decision tests and 6 banner tests pass | downgraded: A R1 (one-click activation of other app windows) to P3: B judged first-click activation in another window normal macOS behaviour and the widened rule risked focus behind sheets and panels (B r1 N1), so activation stays limited to the popover's own window | assumed: the deferred binding reset cannot realistically close a just-reopened popover (A r1 R1, B r1 N2) | deferred: live click checks by the verifier ([scenarios P1–P11](evidence/2026-10-18-lossless-app-restart/verifier-scenarios.md)), including Escape right after opening; Edit/Continue popover still SwiftUI; B r1 N3/N4 tidy-ups
Step 8-attention — done | rounds 2/2 | open: 8-attention-1 done: items are classified needs-action or informational at projection time, the composer banner shows only the current session's needs-action rows, counts are needs-action only, the sheet has Needs action and a collapsed Information section ([worker](evidence/2026-10-18-lossless-app-restart/fix-attention1-worker.md)); review 0 ([A](evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oracleb.md)) B checks found two gaps, fixed (a run note under an action's session hold before its reservation; a continuation recorded not-dispatched whose text never became a saved message); re-review 1 ([A r1](evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oraclea-r1.md); the B lane was refused by the app's Oracle concurrency limit) P1 a textless Reconcile cleared an unsent continuation, fixed; final re-review 2 ([A r2](evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oraclea-r2.md), [B r2](evidence/2026-10-18-lossless-app-restart/fix-attention1-review-oracleb-r2.md)) no P0/P1, cheap follow-ups applied (supersession tests, empty text ignored, a row note saying the typed message was not sent); plan: [synthesis](evidence/2026-10-18-lossless-app-restart/attention-activation-synthesis.md), [A](evidence/2026-10-18-lossless-app-restart/attention-activation-plan-oraclea.md), [A part 2](evidence/2026-10-18-lossless-app-restart/attention-activation-plan-oraclea-part2.md), [D](evidence/2026-10-18-lossless-app-restart/attention-activation-plan-oracled.md); 8-attention-2 done: projection-only automatic clearing of informational run notes and sequential bulk Dismiss per sheet section ([worker](evidence/2026-10-18-lossless-app-restart/fix-attention2-worker.md)); review 0 ([A](evidence/2026-10-18-lossless-app-restart/fix-attention2-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-attention2-review-oracleb.md)) no P0/P1, cheap fixes applied (eligible cards frozen at click, hidden rows never captured, one Dismiss-eligibility rule shared with the row, run notes with delegated children or followed only by never-delivered attempts are not cleared, summary names its section and clears when the sheet closes); the extra needs-action card in tests is a missing custom storage folder, a fixture artifact | downgraded: B r2 ATT1-R2-1 (flag flips back if a saved message is deleted) to none: saved messages are never deleted, Remove only marks them withdrawn (AgentRecoveryStore.swift:1152) | assumed: bulk Dismiss covers all workspaces in a section with no per-workspace grouping, and the confirmation names how many cards are in other workspaces (undo: ask for grouping); saved closed-session drafts and an unreadable schedule index count as needs action; run notes are informational unless an action holds the session, an action is unfinished, or its continuation text is unsent; no separate bulk It stopped button, its proven-safe form lives in Check and resolve after activation; other sessions paused by a workspace recovery action get no banner row (their scheduled-send text explains it, as before) | deferred: attempt ordering by array position, the attention class rechecked only before the write, small tidy-ups (see B review F5, F6, F8, F9); age-based expiry; rows moving between sections while an action runs and the new row note, both for the verifier; dismissed rows listed inside Needs action while Show dismissed is on (separate section comes with 8-attention-2); View-menu count
Step 8-verifier-fixes — done | rounds 1/2 | open: none (O39; [verifier results](#steps-89-verifier-scenarios-2026-10-27); [worker](evidence/2026-10-18-lossless-app-restart/fix-verifier-worker.md), review round 0 [A](evidence/2026-10-18-lossless-app-restart/fix-verifier-review-oraclea-r0.md), [B](evidence/2026-10-18-lossless-app-restart/fix-verifier-review-oracleb-r0.md), round 1 [A](evidence/2026-10-18-lossless-app-restart/fix-verifier-review-oraclea-r1.md), [B](evidence/2026-10-18-lossless-app-restart/fix-verifier-review-oracleb-r1.md)): deleting a session takes its Needs Attention rows and badge count away at once in every window, also when the deletion lands during startup; the View popover opens outside the banner or sheet on any side with room, else at its button; the banner and sheet are accessibility containers so the report keeps its own identifier ; the verifier's live re-check passed H1, P1, P7 (also at 1000×700), P11 and the accessibility lookups (2026-10-28, in the verifier section); P5 fixed in source, live check pending: the View popover takes keyboard focus when shown so one Esc closes it, and gives focus back to the window that had it on close, including on app switch ([worker](evidence/2026-10-18-lossless-app-restart/fix-p5-esc-worker.md); review [A](evidence/2026-10-18-lossless-app-restart/fix-p5-esc-review-oraclea-r0.md), [B](evidence/2026-10-18-lossless-app-restart/fix-p5-esc-review-oracleb-r0.md): no P0/P1) | downgraded: none | assumed: deleting a session releases its startup crash hold and session restriction at once, as the next launch already does (a surviving process's restriction stays) | deferred: the deletion observer is not scoped to one data service (VF-7); a bulk Dismiss or Check started before a deletion still lists that session (VF-9); on an outside edge the popover arrow points at the banner or sheet, not the row (VF-R1-5; seen live); after Dismiss of a deleted-to-be session's message row its paused run row was not found in the sheet (verifier observation, unexplained); the popover is measured before its content loads (VF-R1-6); the surviving-process exemption has no test until runtime items carry a session; P5: shortcuts and `NSApp.keyWindow` readers see the popover window while it is open (B P5-R3), key is returned inside a SwiftUI update (P5-R4), the unit tests cover the focus policy, not real event routing (A F1, P5-R5), Cmd-` leaves an open popover that Esc can't close (P5-R7, predates the fix)
Step 9-activation — doing | rounds 2/2 | open: 9-check done: Check and resolve in the Needs Attention sheet, report-only until activation ([worker](evidence/2026-10-18-lossless-app-restart/fix-check-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-check-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-check-review-oracleb.md), [A r1](evidence/2026-10-18-lossless-app-restart/fix-check-review-oraclea-r1.md), [B r1](evidence/2026-10-18-lossless-app-restart/fix-check-review-oracleb-r1.md)); 9-activation-a done: one activation setting drives process registration and recovery actions, production still off; Claude Code and Codex are the registered subset; other providers' recovery actions refuse with a named reason; Continue and Reconcile refuse a run card whose recorded run-start provider differs from the session's or is missing; Check's Stop abandons a stuck item ([scout](evidence/2026-10-18-lossless-app-restart/activation-scout.md), plan [A](evidence/2026-10-18-lossless-app-restart/activation-plan-oraclea.md), [D](evidence/2026-10-18-lossless-app-restart/activation-plan-oracled.md), [worker](evidence/2026-10-18-lossless-app-restart/fix-activation-a-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oracleb.md), [A r1](evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oraclea-r1.md), [B r1](evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oracleb-r1.md), [A r2](evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oraclea-r2.md), [B r2](evidence/2026-10-18-lossless-app-restart/fix-activation-a-review-oracleb-r2.md)); round-2 P2 fix (provider captured once at run start on the run's ownership) applied after the last round and checked by the main agent only; 9-activation-b done (one re-review round): with activation on, Check confirms a crash hold without opening the session when process records prove every process of the held run exited, using a registration mark captured at run start; the card's freshness is checked inside the acknowledgement write; Stop during the write says the result shows on the card ([design](evidence/2026-10-18-lossless-app-restart/activation-b-design-worker.md), plan check [D](evidence/2026-10-18-lossless-app-restart/activation-b-plan-oracled.md), [worker](evidence/2026-10-18-lossless-app-restart/fix-activation-b-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-activation-b-review-oraclea-r0.md), [B](evidence/2026-10-18-lossless-app-restart/fix-activation-b-review-oracleb-r0.md), [A r1](evidence/2026-10-18-lossless-app-restart/fix-activation-b-review-oraclea-r1.md), [B r1](evidence/2026-10-18-lossless-app-restart/fix-activation-b-review-oracleb-r1.md)); shared launch authority done (cut down): outside DEBUG the session's authority is always `.production`, the same fixed value every managed launcher uses, so the run-start mark and the launches can't disagree while activation is a constant; full threading only if activation becomes switchable at runtime ([change and reviews](evidence/2026-10-18-lossless-app-restart/fix-launch-authority-review-r0.md): A and B no P0/P1); 9-live run 2026-10-28 on 74edea8b plus the switch line failed (no unrequested or duplicate send; Codex crash holds confirmed by Check; Claude paths, Codex history matching, continuation text and Esc failed; [brief](evidence/2026-10-18-lossless-app-restart/verifier-9live-brief.md), [results](evidence/2026-10-18-lossless-app-restart/verifier-9live-results.md)); the switch line is reverted and the fixes are Step 9-live-fixes; after them a new 9-live on a candidate that changes only the switch line ([scenarios](evidence/2026-10-18-lossless-app-restart/verifier-scenarios.md)), then a separate reviewed switch, which must first pin the provider-kind to launch-pair mapping in a test (B L1) and pass one release-configuration build (B L2); 9-stop only if a reviewed registry stop entry point exists ([synthesis](evidence/2026-10-18-lossless-app-restart/attention-activation-synthesis.md)) | downgraded: none | assumed: the owner's unanswered choice for the shared launch authority went to the recommended small version (undo: thread one resolved authority through the launcher sites); production stays off until the live checks pass; fresh Claude conversation and safe restart stay off; 9-live proves that an exited record means the process family really exited (complete discovery, marker propagation); Check reconciles only the session open in the calling window, others say to open the session; after activation, Codex Reconcile may start a temporary read-only codex app-server, as the row's Reconcile already does | deferred: run cards written before this build have no recorded provider, so after the switch they can only be dismissed (B F5; note for the switch acceptance); Continue in a new conversation is not provider-guarded (off in this activation); the missing-run-attempt refusal is tested at helper level only (B P3-4); one Check report shared by all windows and cleared by any (B CHK-8); row state and Check report can differ for unconfirmed results (B R1-4); test-only widening of adoptRuntimeRestrictions (B R1-5); A r1 P3s (debug-only composition assert, relaunch site reads any-pair flag, long comment line); leaked unit-test fixture workspaces in Application Support (Step 10, O35); 9-activation-b: no composition-level test that the production registry and coordinator share one store; the commit's revision-conflict retry is untested and effectively unreachable (kept as a defensive branch); a record naming several sessions widens the touched keys, which can only over-refuse (B-R1-04, watch in 9-live); launch-authority P3s: launcher parameters still rely on a grep (L3), duplicated coverage logic (L4), rationale is a plain comment (L5)
Step 9-live-fixes — doing | rounds 0/2 | open: (1) done: Esc in the popover or its anchor window closes the popover, except during an input-method composition; the c3996ab5 key hand-off is removed ([worker](evidence/2026-10-18-lossless-app-restart/fix-9live-esc-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-9live-esc-review-oraclea-r0.md), [B](evidence/2026-10-18-lossless-app-restart/fix-9live-esc-review-oracleb-r0.md): no P0/P1); (2) done (two re-review rounds; the round-2 P1 fixes, in-flight rows skipped and one stored result per composer append, are checked by the main agent only): a Continue draft is kept per row app-wide and reopened; once its card stops offering Continue, unsent typed text moves to the session's message box (only when that box is in a normal state); a refused continuation shows the unsent-text note before the reason; survivor items come first; send-refusal notices stay until the next edit, attempt or tab change ([worker](evidence/2026-10-18-lossless-app-restart/fix-9live-list-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oraclea-r0.md), [B](evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oracleb-r0.md), [A r1](evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oraclea-r1.md), [B r1](evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oracleb-r1.md), [A r2](evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oraclea-r2.md), [B r2](evidence/2026-10-18-lossless-app-restart/fix-9live-list-review-oracleb-r2.md)); (3) done (O43/O46): Check's proof and "It stopped" settle the held run's delivery-uncertain messages to delivery unknown in the same acknowledgement write; Check refuses the whole hold when a message isn't tied to a proven run, "It stopped" settles the ones that qualify and only acknowledges the rest; the row is informational with Edit, Remove and Dismiss, never Send saved; a later hold that is a subset of an acknowledged one stays acknowledged ([worker](evidence/2026-10-18-lossless-app-restart/fix-9live-o43-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-9live-o43-review-oraclea-r0.md), [B](evidence/2026-10-18-lossless-app-restart/fix-9live-o43-review-oracleb-r0.md): no P0/P1); R3 done (O45): a later Claude tool result no longer rewrites a restored interrupted bash row, because the Codex-only bash reconcile now skips Claude-native sessions; the extra empty-arguments backstop was cut after both reviews flagged it for shared Codex and ACP lookups ([diagnosis](evidence/2026-10-18-lossless-app-restart/diag-9live-r3-rewrite-worker.md), [worker](evidence/2026-10-18-lossless-app-restart/fix-9live-r3-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-9live-r3-review-oraclea-r0.md), [B](evidence/2026-10-18-lossless-app-restart/fix-9live-r3-review-oracleb-r0.md)); planned from the 9-live diagnoses ([R1, V1, R7](evidence/2026-10-18-lossless-app-restart/diag-9live-r1-worker.md), [R2–R5](evidence/2026-10-18-lossless-app-restart/diag-9live-r2-r5-worker.md), [R6](evidence/2026-10-18-lossless-app-restart/diag-9live-r6-worker.md)) and the O42 planning round ([A](evidence/2026-10-18-lossless-app-restart/plan-9live-fixes-oraclea.md), [D](evidence/2026-10-18-lossless-app-restart/plan-9live-fixes-oracled.md)), in this order: (1) Esc closes only the View popover, handled in the anchor window while it is shown, replacing the c3996ab5 key hand-off; (2) recovery list: the refusal shows with the unsent-text note, the Continue draft is kept per row and reopened, survivor rows first, the send-refusal reason stays visible while sending is paused; (3) O43 in Check's crash-hold write; (4) O42 Claude history location; (5) the Codex native turn ID saved on the run attempt; (6) switch gates (provider-pair test, release build) and the verifier guide; early Claude acceptance (R1) is cut because nothing depends on it after O43 | downgraded: (2) A r2 R1-02 to P2 (B agrees): when no window has the session open as a Continue result arrives, the typed text is kept in memory only, invisible except as a "Open this session to get it back" row under shown-cleared items, and lost if the app quits | assumed: the downgrade above (undo: a session-keyed pending-text surface) | deferred: (3) by the owner: an acknowledged message the settle skipped (current-launch attempt) can still show as settled (A P2); no Edit-path test for settled messages, no run-card never-handed-off assertion, no mixed-attempt rule tests (B P2-2, P2-4, P3); the next live check adds Edit of a settled Claude message then relaunch (no hold returns, nothing resent); (2) B r2 P3s (neutral wording for joined/prior-action results, drafts on dismissed cards, drafts whose item left the catalog, append during an in-flight submit), B L6, L8, L10 hold-lift half, no test for the held-back-composer gate or the cross-window host; live checks to add in (6): a typed Continue draft then Check history on a finished survivor lands in the message box, Restore with a held-back draft keeps both texts, Open in the no-window case, and the known duplicate after an unrecorded not-sent result and a relaunch; R3 restore-cancelled styling; Esc key-repeat on a held Esc (B ESC-2); the next live check adds focus after Esc and Cmd-C in the popover (B ESC-3, verifier guide in (6)); the remaining cuts are listed in both plan answers
Step 10-fixture-leak — doing | rounds 2/2 | open: 10a done (window-session file; [worker](evidence/2026-10-18-lossless-app-restart/fix-10a-worker.md), review [A](evidence/2026-10-18-lossless-app-restart/fix-10a-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-10a-review-oracleb.md)); 10b tooling done (O41; two re-review rounds): the quarantine script gains classes C (non-empty fixture workspace folders), P (Partitions folders whose files all belong to C folders moved in the same run) and S (windowSessions.json.sb-* leftovers), all moved never deleted, with the restore journal; read-only live dry run selects exactly 19,461 / 926 / 83; apply, restore and a second apply rehearsed on an APFS clone of the store (20,470 moved in 38 s, restore changed nothing) ([classification](evidence/2026-10-18-lossless-app-restart/fix-10b-classification-worker.md), [worker](evidence/2026-10-18-lossless-app-restart/fix-10b-worker.md); reviews [A](evidence/2026-10-18-lossless-app-restart/fix-10b-review-oraclea-r0.md), [B](evidence/2026-10-18-lossless-app-restart/fix-10b-review-oracleb-r0.md), [A r1](evidence/2026-10-18-lossless-app-restart/fix-10b-review-oraclea-r1.md), [B r1](evidence/2026-10-18-lossless-app-restart/fix-10b-review-oracleb-r1.md), [A r2](evidence/2026-10-18-lossless-app-restart/fix-10b-review-oraclea-r2.md), [B r2](evidence/2026-10-18-lossless-app-restart/fix-10b-review-oracleb-r2.md)); 10b done: the owner ran it with the app quit, 20,470 items moved, none skipped, none of 204 checks tripped; nothing of those groups remains and every kept item is unchanged ([live apply](evidence/2026-10-18-lossless-app-restart/fix-10b-live-apply.md)); 10c done: under XCTest in DEBUG builds the default Partitions root is a per-process temporary folder removed on exit, so tests no longer write the live Partitions store ([worker](evidence/2026-10-18-lossless-app-restart/fix-10c-worker.md), review [A](evidence/2026-10-18-lossless-app-restart/fix-10c-review-oraclea.md), [B](evidence/2026-10-18-lossless-app-restart/fix-10c-review-oracleb.md): no P0/P1, the debug-only test guard and a real default-store write test applied); whole-suite check done (2026-10-28, full `make dev-test`): workspace folders (72), Partitions files (2,505) and `sb-` leftovers (0) unchanged; next: the owner deletes the three quarantine folders after a soak period | downgraded: none | assumed: after an interrupted live apply, recovery is to restore that run's journal and apply again (a re-run does not pick up Partitions folders of workspaces the stopped run moved); tests run unhosted (SwiftPM/xctest), so these singletons are created after XCTest loads | deferred: one shared XCTest-isolation helper for the settings, window-session, workspace and partitions stores (B S10a-3, 10c-2); AgentWorkflowStore uses the same unredirected path, no leak observed (10c-3); a save after exit cleanup can leave temp clutter (10c-4); a full test run still writes MCP connection event and kill-signal files to the live store (10c-5); 10b P3s: a restore stop on a changed quarantined Partitions folder names a reference change rather than the folder (B 10b-r2-01), docstring wording (10b-r2-02, 10b-r2-03), home spelled differently (10b-r1-03)
Step 6-live — partial | rounds 0/2 | open: none of F1–F7 (commit IDs as before the 2026-10-26 re-sign, [map](evidence/2026-10-18-lossless-app-restart/resign-2026-10-26.md); fixed in 7d7be9b6, 03b845d1, 4ce78bde, 5363ad2e, 4e7c8bf9, ae111cc7 and re-verified live 2026-10-26 on ae111cc7, see [Live re-verification](#live-re-verification-of-the-fixes-2026-10-26); F1's Claude deferred-start test raced the unawaited run-terminal write under load and now awaits it, no product change ([bisect](evidence/2026-10-18-lossless-app-restart/fix-f1-regression-bisect.md))); production activation of Phase 3/4 actions; 2026-10-25 crash cuts, injected shutdown failure, Codex resume and run-queue admission verified there; whole-app qualification and exact crash/failure controls are prerequisites only for their applicable scenarios ([external-driver handoff](evidence/2026-10-18-lossless-app-restart/live-acceptance-handoff.md)) | completed: 2026-10-25 approved same-candidate normal quit/relaunch preserved two distinct unsent drafts and one managed image, exact IDs/payloads/image bytes plus eventual UI readback, zero synthetic sends; 94/94 focused persistence/shutdown tests | downgraded: disposable account optional for destructive tests (O24); 14.09s quit interval includes owner's dialog-response delay and is not a valid latency sample | assumed: external Terminal Pi, actual accessibility UI checks, unchanged default-off production qualification; Step4c helper policy resolved, live verification pending | deferred: remaining preservation variants/questions/reviews/children/schedules, actual-profile/every-pair qualification, crash/injected failures, workload timing and production activation
Step 4d7 — done | rounds 0/2 | open: none in bounded pre-live source; A/B accepted frozen tree fb60e9de, cheap F1/F2 clarifications validated after review ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d7.md)) | downgraded: none | assumed: exact agreement ends existing revocation ownership, fresh whole-history validation remains authoritative, no healing; already-loaded hydration covered, no demonstrated normal forced-replacement path | deferred: B F3/F4 optional refactor/cosmetics; actual-profile and every-supported-pair qualification in one final isolated live package, production activation and final acceptance
Step 4d6 — done | rounds 0/2 | open: none in bounded presentation source; A/B accepted staged tree0bc4bccb, cheap final corrections validated, 123 focused tests with affected18 rerun ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d6.md)) | downgraded: none | assumed: generic missing/unclassifiable result evidence is neutral even live; explicit classified running unchanged; exact previous run-scoped cancellation preserved separately; no ownership pipeline, recovery bypass or retention change | deferred: B P2-1 visual click/accessibility, P3-2 frozen test names, exact per-call liveness, missing-proof recovery coverage, broader app profile, activation and final live acceptance
Step 4d-no-replay-capture — done | rounds 0/2 | open: none in bounded O21 capture; two successful Read prompts, exact caller/native identity and six stdout/native joins, same-session byte-prefix continuity independently checked ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d-no-replay-capture.md)) | downgraded: none | assumed: observed isolated no-replay CLI profile only; no Swift classifier or app pipeline exercised | deferred: actual app profile, unsupported shapes, invalidated-proof handling, activation and final live acceptance; O21 budget exhausted
Step 4d5 — done | rounds 1/2 | open: none in bounded default-off source; initial A/B and persistence-boundary R1 accepted snapshots1009/1147, cheap corrections1201 validated, 435 focused tests ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d5.md)) | downgraded: none | assumed: O20-modelled Read, no-replay fixture only; import-only whole membership in four current-pipeline forms after unique ledger/native proof; unchanged retention and strict live checks | deferred: invalidated-proof conversation refusal (activation blocker, not ordinary UI tab switching), same-launch mid-chain hydration, unresolved-call presentation, wider tool/context shapes, upgrade golden fixture, optional performance/hardening, installed profile, activation, durability limits and final live acceptance
Step 4d4 — done | rounds 0/2 | open: none in bounded native reader source; checkpoint7c4d3c33 (unsigned O8 option); A/B accepted snapshot2026-10-24/0904, cheap comment/label corrections validated ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d4-worker.md)) | downgraded: none | assumed: exact three-key mode=normal shape only; existing native tool identity/projection; fixtures model observed semantic graph, not raw capture bytes | deferred: P3-04 optional extraction, live tool qualification, unobserved shapes, app profile, activation and final acceptance
Step 4d-tool-capture — done | rounds 0/2 | open: none in bounded O20 evidence capture ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d-tool-resume-capture.md)); three successful Read prompts and exact same-session resume observed and independently checked | downgraded: none | assumed: observed CLI profile only, not app qualification | deferred: thinking/multiblock and other unobserved shapes, no-replay app profile, production activation and final live acceptance; O20 budget exhausted
Step 4d3c — done | rounds 0/2 | open: none in bounded scoped-invalidation source; checkpoint6cf06842 (unsigned O8 option); initial A/B review found no P0/P1, B F1/F2 bounded fixes validated without a P2-only re-review ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d3c.md)) | downgraded: none | assumed: transient producer-owned keys; preserve through hydration/rebind, reset only on clear chat after detach; no new persisted authority | deferred: full A→B→A fixture, F3 cosmetics, same-launch unsupported-output revocation, broader profile, activation, scheduled-save crash window and final live acceptance
Step 4d3b — done | rounds 1/2 | open: none in bounded inactive source; checkpoint f6f205e5 (unsigned O8 option); A/B re-review 1 cleared repair snapshot 2026-10-24/0010 ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d3.md)) | downgraded: none | assumed: core-only evidence, existing ledger proof invalidation and serialized save boundary; default-off injected qualification | deferred: A R3 coverage; B F1/R1-P2-1 collateral invalidation closed by Step4d3c, remaining same-launch/profile activation limits; B R1-P3-1–4 polish/coverage; broader provider shapes, pre-invalidation-commit crash window, production activation and live acceptance (O3)
Step 4d3a — done | rounds 1/2 | open: none in bounded source only; checkpoint60132a4b (unsigned O8 option). The initial A/B review on snapshot 2026-10-23/2226 found one P1 (A R1/B F1), which was repaired on delta 2026-10-23/2241 and closed by A/B re-review 1 with no new P0/P1 ([scope](evidence/2026-10-18-lossless-app-restart/phase4d3.md)) | downgraded: none | assumed: reuse full native projection and existing canonical backing; provider output and user input anchors are order-checked separately (B option (a), keeping the append-at-end contract); no carrier or new persisted marker | deferred: B re-review 1 P3 nil-normalizer fallback and redundant anchor comment, initial B F2/F4/F5, single-text live carrier implementation (Step 4d3b; activation remains off), broader provider qualification, activation and live acceptance (O3)
Step 4d2 — done | rounds 1/2 | open: none in bounded source only; A/B initial review on snapshot2026-10-23/2057, A R1(P1) repaired on delta2026-10-23/2130 and closed by A/B re-review1 with no P0/P1/P2 ([evidence](evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md)); checkpoint bf1fce5a (unsigned O8 fallback) | downgraded: none | assumed: coupled reader and envelope proof before deduplication; exact observed nonrendering graph nodes, not semantic irrelevance | deferred: B P2-01 proofless-cursor requalification, initial P3-04/06/07 and re-review1 P3-1–4, next live single-text carrier step, live/profile qualification, production activation and live acceptance (O3)
Step 4d-capture — done | rounds 0/2 | open: none in bounded authentication diagnosis and one-text capture ([evidence](evidence/2026-10-18-lossless-app-restart/phase4d-claude-capture.md)) | downgraded: none | assumed: O19 child-local removal of inherited CLAUDE_CONFIG_DIR; one real text envelope only; documented safe-mode boundary allows built-in metadata | deferred: broader history/profile qualification, thinking/tools/multiblock/resume, production activation and live acceptance (O3); all4approved prompts consumed
Step 4d1 — done | rounds 0/2 | open: none in bounded outbound source; checkpoint85aecb82 (unsigned O8 fallback), A/B reviewed snapshot2026-10-23/1838 with no P0/P1, cheap P2 fixes validated on repair2026-10-23/1851 ([evidence](evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md)) | downgraded: none | assumed: UUID only on new qualified admission, omit on retry, complete ordered constituents, existing owner save; claim does not prove any bytes were sent | deferred: B P3-1/3/4, all-input-path qualification, owner-approved isolated Claude capture, canonical reconciliation, activation and live acceptance (O3)
Step 4c — done | rounds 1/2 | open: none in bounded source; checkpoint cb15d40f (unsigned O8 fallback), A/B accepted repair snapshot2026-10-23/1820-2 ([evidence](evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md)) | downgraded: none | assumed: owner-delegated explicit uncertain exit, current-request/attempt pre-arm proof, existing serialized helper ownership | deferred: B P3-1 and R1 nonblocking test/wording/ack precision, production activation and live acceptance (O3)
Step 4b — done | rounds 0/2 | open: none in bounded inactive source, checkpoint 8033b458 (unsigned fallback O8); A/B initial reviews accepted snapshot 2026-10-23/1204, cheap proof-label correction validated ([implementation and reviews](evidence/2026-10-18-lossless-app-restart/phase4b-helper-stop.md), [scope and planning](evidence/2026-10-18-lossless-app-restart/pre-live-work.md)) | downgraded: none | assumed: preserve existing explicit manual Retry deadlines; include Phase 5 preservation in remaining source work | deferred: B P2 app-modal loop and remaining coverage, P3 polish; unknown-stop policy, activation and live acceptance (O3)
Step 5a — done | rounds 1/2 | open: none in bounded source, checkpoint76057942 (unsigned O8 fallback); A/B R1 cleared repair snapshot2026-10-23/1514 ([evidence](evidence/2026-10-18-lossless-app-restart/phase5a-edit-reviews.md)) | downgraded: none | assumed: included by O13; historical View/Copy/Discard only, no recovered Apply; decoded-text base and canonical target; worktree reviews isolated in Step 5c | deferred: conservative reset-race uncertainty, worktree comparison/Open/UI fixtures, growth/viewer/naming/source-guard polish, release compile, retention and live acceptance (O3)
Step 5c — done | rounds 1/2 | open: none in bounded source; A/B R1 accepted repair2026-10-23/1656, cheap neutral-wording correction validated, checkpoint ce82ac6d (unsigned O8 fallback) ([evidence](evidence/2026-10-18-lossless-app-restart/phase5c-merge-reviews.md)) | downgraded: none | assumed: same pending-review contract, existing operation/artifact authority, historical View/Copy/Discard only | deferred: remaining initial B P3 and R1 presentation/hardening/coverage, optional polish, orphan retention cleanup and live acceptance (O3)
Step 5b — done | rounds 1/2 | open: none in bounded source, checkpoint 9e508587 (unsigned fallback O8); A/B R1 cleared snapshot 2026-10-23/1327 after identity-receipt retry, cheap wording correction validated ([evidence](evidence/2026-10-18-lossless-app-restart/phase5b-child-links.md)) | downgraded: none | assumed: included by O13; existing local MCP invocation ID and admission-bound parent attempt, not provider-native attribution | deferred: existing-tab/full-submission/Open fixture limits, independent caller retry deduplication, optional polish, retention and live acceptance (O3)
Step 4a — done | rounds 1/2 | open: none; bounded inactive source implemented, validated and cleared by required A/B re-review on snapshot 2026-10-23/0845 (O12: A/B only) ([evidence](evidence/2026-10-18-lossless-app-restart/phase4a-saved-relocation.md)) | downgraded: B P1-1 to P2 test gap, closed and accepted by issuing reviewer | assumed: preserve historical canonical identities with a distinct new execution turn; real covering write before normal dispatch; conservative supported-envelope refusal | deferred: unsupported historical shapes use Edit; B P2-1, frontier fixture P2-A and P3-1/2; actual cold-load/overlapping-writer qualification; all production activation, Claude native identity, automated Restart, optional polish, retention and live acceptance (O3)
Step 4 — blocked | rounds 2/2 | open: broader Claude/profile and activation qualification remain blocked; bounded observed-subset canonical merge/save-reload source is completed by Step4d5; helper-policy source prerequisite is resolved by Step4c and outbound source by Step4d1; Step4d7 closes the demonstrated prospective proof-retention and explicit refusal source findings; broader O15 Claude reconciliation still requires actual supported-profile evidence, while previously cleared proofs remain conservatively ineligible; O19 resolved capture authentication by removing only the child configuration override and observed a real one-text reply, without broader qualification ([evidence](evidence/2026-10-18-lossless-app-restart/phase4-prerequisite-resolution.md)); older saved-message canonical routing source is completed by bounded Step 4a, with activation and live qualification still pending; both final reviews accept O9's inactive partial checkpoint on source tree 5f9151eb ([planning evidence](evidence/2026-10-18-lossless-app-restart/phase4-plan.md), [implementation evidence](evidence/2026-10-18-lossless-app-restart/phase4.md), [O10 source investigations](evidence/2026-10-18-lossless-app-restart/phase4-source-investigations.md)) | downgraded: none | assumed: one coupled source package; bounded Claude history baselines, outbound identity and observed-subset canonical reconciliation with typed refusal; broader profile-local qualification pending; normal dispatch and history-only import; existing bundled helper private mode instead of a new product; production Resume/restart gated on qualified registry/provider behavior | deferred: live qualification; B R2-P2-1–4 and prior P2/P3 in final review evidence; optional polish, retention and live acceptance (O3)
Step 3 — done | rounds 2/2 | open: none; signed checkpoint 559ecd9d, source reviewed on tree c25b94f0; enforcement and live qualification remain pending ([planning evidence](evidence/2026-10-18-lossless-app-restart/phase3-registry-plan.md), [implementation evidence](evidence/2026-10-18-lossless-app-restart/phase3-registry.md)) | downgraded: none | assumed: one coupled worker; production activation off until family discovery is qualified; ACP generic registration included; temporary shell fixtures for CLI runner boundary tests | deferred: activation/live qualification; A P3-R13; B R2-A–D, retirement timeout and EOF-line association (see final review evidence); prior P2/P3; recovered-process signalling, fresh Claude session-ID activation, retention and live acceptance (O3)
Step 2 — done | rounds 2/2 | open: none; signed checkpoint 93af6fb5 ([planning evidence](evidence/2026-10-18-lossless-app-restart/phase2-plan.md), [implementation and reviews](evidence/2026-10-18-lossless-app-restart/phase2.md)) | downgraded: none | assumed: post-cap bounded fix validated without re-review after owner question timed out; immediate question creation writes, non-secret drafts 300 ms debounce/2 s maximum; Dismiss acknowledges cards only | deferred: optional polish/retention and documented P2/P3 limits; unknown-turn provider cleanup; Resume and registry to later phases; UI/live acceptance (O3)
Step 3-platform — done | rounds 1/2 | open: none; implementation, validation and reviews complete ([evidence](evidence/2026-10-18-lossless-app-restart/phase3-platform.md)) | downgraded: none | assumed: independent Platform primitives before registry integration | deferred: production registry, provider integration and live qualification
Step 1b-shutdown — done | rounds 2/2 | open: none; signed checkpoint 57e45120; implementation, required fixes and validation complete ([evidence](evidence/2026-10-18-lossless-app-restart/phase1b-shutdown.md)) | downgraded: none | assumed: sealed window admission; delayed clean acknowledgement is not invalid preservation; bounded post-R2 fixes validated without another review | deferred: optional polish, retired-lane removal retry and live acceptance (O3)
Step 1b-cutover — done | rounds 3/3 (O7) | open: none; signed checkpoint c9138767; final fence fix validated ([evidence](evidence/2026-10-18-lossless-app-restart/phase1b-cutover.md)) | downgraded: retention cost and instruction-wait extra confirmations P2, accepted by issuing reviewer | assumed: bounded final fix validated without a fourth review | deferred: optional polish, record retirement and history-dependent startup/per-commit cost; uncertain wait replies may delay workspace schedules until closed sessions are opened and confirmed; Phase 2 durable dismissal; live acceptance (O3)
Step 1b-recovery — done | rounds 2/2 | open: none; integrated signed checkpoint c9138767 ([evidence](evidence/2026-10-18-lossless-app-restart/phase1b-recovery.md)) | downgraded: none | assumed: final-domain storage/controller activated with the coupled production cutover | deferred: complete quit/window-close preservation; live acceptance (O3)
Step 1b-foundation — done | rounds 2/2 | open: none; integrated signed checkpoint c9138767 ([evidence](evidence/2026-10-18-lossless-app-restart/phase1b-foundation.md)) | downgraded: none | assumed: focused validated fix after review cap (owner question unanswered); durable lifecycle, exclusive creation and permanent UUID tombstones ([scope evidence](evidence/2026-10-18-lossless-app-restart/phase1-scope.md)) | deferred: complete quit/window-close preservation; live acceptance (O3)
Step 1a — done | rounds 2/2 | open: none; committed as ebd686f7 ([evidence](evidence/2026-10-18-lossless-app-restart/phase1a.md)) | downgraded: none | assumed: transcript-only scheduling/draining; embedded lifecycle identity for 1b ([scope evidence](evidence/2026-10-18-lossless-app-restart/phase1-scope.md)) | deferred: complete quit/window-close preservation to the next package; live acceptance (O3)
Step 0 — done | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: live sampling, isolated main-actor timing, quit-time loss observation, real-app crash testing (O3), and minor items in [evidence and reviews](evidence/2026-10-18-lossless-app-restart/phase0.md)
- **How it was drafted:** OracleD and OracleE each wrote an independent plan, and this spec merges them. It includes one review round from each Oracle; every P0, P1, and P2 finding is resolved below. Identity was verified for each send.
- **Evidence:** code reading, plus crash experiments that ran the real provider CLIs under a throwaway parent process. RepoPrompt itself was not killed.
- **Code:** none exists for this feature yet.

## Goal

The owner's daily harness is RepoPrompt CE on an always-on Mac Studio. The most common restart is the app itself: a debug rebuild, a crash, or a relaunch to clear sluggishness. When RepoPrompt restarts:
- nothing the user typed, or was told was queued, is lost;
- interrupted work is shown honestly;
- nothing is sent or re-run without a click;
- an interrupted turn resumes with one click once that's safe.

**What it promises:**
- Saved input survives an app restart.
- Interrupted work stays visible.
- RepoPrompt never replays tool calls itself.
- Safely recoverable Claude and Codex work continues with one action.

**What it doesn't promise:**
- Typing from the last moments before a crash.
- Provider output that neither RepoPrompt nor the provider recorded.
- Exactly-once side effects. A resumed model may still choose to repeat an action itself.

## Done when

1. Every message RepoPrompt sends or reports as queued survives an immediate app kill. That covers composer sends, follow-ups, steering, fallback, scheduled sends, and MCP calls. What survives is its text, attachments, origin, order, and a stable ID, together with whether it reached the provider.
2. After a normal quit or Restart safely, each session's latest composer state (text, images, tagged files, workflow) and every queued message are restored exactly. After a crash, at most the last 2 seconds of composer changes are lost. On healthy storage the usual window is about 300 ms.
3. A turn that was running when the app stopped is shown as **interrupted**, with its reason (crash, quit, window close, restart). It is not shown as a user cancel.
4. Relaunch never sends, drains, or resumes anything automatically. Every recovered item waits for a click. Future scheduled sends keep their existing rules (R9).
5. RepoPrompt never starts a second managed writer on a provider conversation while that conversation's previous owner process is alive or unknown. Until the process registry ships (Phase 3), sessions interrupted by a crash require an explicit "the previous run may still be running" confirmation before any send.
6. An eligible Claude or Codex interruption resumes with one click, with no copying the prompt and no re-picking the conversation. If the provider verifiably finished the turn while RepoPrompt was down, that result is imported and shown without starting another turn.
7. Recovery items are stored as data that a future remote UI can render. They stay discoverable when their tab or window is closed.
8. A quit finishes within one 8-second deadline. A failure before teardown cancels the quit and leaves the app fully usable. A failure after teardown offers Retry or Quit anyway, and is recorded so the next launch treats the affected sessions as uncertain.
9. Existing scheduled-send deadline and confirmation rules are unchanged.

## Crash contract

The guarantee covers an **app-process crash or kill** while macOS keeps running. A completed atomic file replacement is the commit point.

Out of scope:
- power-loss durability (`F_FULLFSYNC`);
- a database migration, a cloud store, and a background execution daemon.

The owner's Mac runs on battery backup, and app restarts are far more common than power loss.

**Compatibility limit.** Session serialization stays at version 7. That gives decoding compatibility only: an older build ignores the recovery records and their fences, and may resave a session without them. Before downgrading, quit cleanly and resolve recovery items.

## Evidence

### Code (verified 2026-10-18)

| Fact | Where |
|---|---|
| These live only in memory: drafts, queued follow-ups, Claude and ACP steering queues, the Codex fallback queue, pending image and tagged-file attachments, and pending edit reviews | `AgentTabSession.swift:213, 341, 390, 440, 689, 743, 755-756`. `AgentSession.swift` has no field for any of them. The persisted session built at `AgentModeViewModel.swift:14478-14515` omits them. `storeDraftText` (`AgentModeViewModel+DraftsAttachments.swift:28`) writes to memory only. |
| **Bug:** a Codex fallback instruction is reported `durablyQueued` but never saved | `enqueueCodexFallback` (`CodexAgentModeCoordinator.swift:2240-2302`) appends to the in-memory queue and resolves the MCP ack as `.durablyQueued`. It then only schedules a save, and that save doesn't contain the queue. `AgentModeViewModel.swift:16422` maps `.queuedFallback` to `.durablyQueued`, and `CodexSteerAckTracker.swift:40-47` treats it as confirmed. A scheduled send that falls back clears its own pending record on that acceptance. A crash before the queue drains therefore loses the message, with no copy anywhere. |
| Quit and window close discard queued input and don't flush saves | `prepareSessionForWindowClose` (`AgentModeViewModel.swift:3796-3830`) calls `cancelPendingInstruction`, cancels the run, and disposes providers. There is no `flushSaveDetailed` call anywhere in the close or quit path (`AppDelegate.swift:256-277`, `WindowStateManager.swift:953-967`). Saves are 1-second debounced tasks (`AgentModeViewModel.swift:14074-14096`), so the terminal state written at quit is probably lost too. That last point is an inference that Phase 0 validates. |
| Teardown is irreversible once it starts | `beginTermination` runs `signalTermination`, the termination fast path, and `MCPBackgroundModeCoordinator.resetForTermination` synchronously (`AppDelegate.swift:257-264`). `signalTermination` sets `isTerminating` and cancels subscriptions to prevent SwiftUI observation crashes, and nothing resets it (`WindowStateManager.swift:912-922`). `prepareForWindowClose` then sets `hasPreparedForWindowClose`, unregisters observers, detaches the scheduler, and stops coordinators (`AgentModeViewModel.swift:3756-3795`). Window layout is persisted after those signals but before agent shutdown (`AppDelegate.swift:266-276`). |
| The save debounce has no maximum wait | `scheduleSave` cancels and restarts its 1-second timer on every call (`AgentModeViewModel.swift:14092-14096`). Assistant text deltas are buffered for 250 ms (`enqueueAssistantDelta`, `:18923`) and don't call `scheduleSave` directly. There are 112 call sites across 17 files, so whether a busy session can go unsaved for a long time is **unverified**. Existing counters: `save.schedule.replaced` (`:14088`) and `save.session.invoked` (`:14194`). |
| Cold restore can't tell an interruption from a cancel | `AgentSessionRestoreSupport.swift:61-122` turns active run states into `.idle` and open turns into `.cancelled`. |
| Quit already warns about active work | `AppDelegate.swift:161-180`, gated by the warn-before-quit setting. |
| Scheduled sends already model durable intent | `docs/context/agent-scheduled-messages.md`: a `dispatching` attempt is written before handoff; an uncertain restart becomes `needsConfirmation(deliveryUnknown)`; nothing is auto-sent after a closed-app deadline; an unaccepted optimistic item is never marked Sent. |
| Provider processes start in their own process group | `ProcessLauncher.swift:228-267`: `setpgroup 0`, SIGPIPE default, close-on-exec default, stdio pipes. Claude runs as `claude -p --verbose --output-format stream-json --input-format stream-json --permission-prompt-tool stdio [--resume id]` (`ClaudeNativeProcessSessionController.swift:3220-3236`). Codex runs as `codex app-server`. Nothing records spawned processes across launches. |
| Large sessions are expensive to serialize | The transcript-refresh performance spec measured a running session of about 1,500 source items (`2026-10-12-agent-mode-transcript-refresh-performance-spec.md`). |

### Crash experiments (2026-10-18)

A throwaway Python parent launched each process exactly as `ProcessLauncher` does, then was killed with `kill -9` mid-turn. The real CLIs ran through the owner's shims, the same chain RepoPrompt uses:
- a Node `claude-rotator` shim that launches the real `claude`;
- a Node `codex-auth-switcher` shim that launches `codex`.

The environment matched RepoPrompt's. In particular, `CLAUDE_CONFIG_DIR` must be unset, or the shim skips its login.

| Case | Result after the parent died |
|---|---|
| A silent shell command | Kept running (reparented to launchd) and finished |
| A command printing to stdout | Died on its next write (broken pipe) |
| A provider-like process with a background child | The writer died; the child survived and finished |
| A process blocked on stdin | Saw end-of-input and kept going |
| **Claude 2.1.302** | **Kept working.** It finished the running 20-second foreground command. 19 s after the kill it ran a **new** command (`touch m2`), wrote its final answer, and exited. Its session JSONL recorded every step. In another run it waited for a backgrounded task, made another model request, answered, and exited. |
| **Codex 0.162 app-server** | **Stopped cleanly.** It exited within 3 s and stopped its running command, so neither marker file was created. Its rollout recorded `turn_aborted` with reason `interrupted`, plus a note telling the model the turn was cut off. |

Both providers ran their tool commands in a **process group separate from their own**: Claude was in group 40019 and its tool shell in group 40328. Signalling the provider's group doesn't reach its tools.

Claude's session JSONL was found at `~/.claude/projects/<cwd>/<sessionID>.jsonl`, even though the shim selects a profile under `~/.claude-rotator/profiles/`. The JSONL root is therefore not simply the selected profile directory (R6).

**Not yet tested:**
- Claude with an unanswered stdio permission request.
- Claude calling a RepoPrompt MCP tool when RepoPrompt dies. That server lives inside the app, so the call would fail.
- Claude startup hooks.
- ACP and Oh My Pi providers.
- A real kill of the RepoPrompt app (see O3).

## Decisions

Where a decision chose between the two plans, it records why the alternative lost.

### R1. Where state lives: one small recovery record per session, next to the transcript

| Data | Authority |
|---|---|
| Transcript and existing session settings, plus a new optional turn-level `interruption` record (R5) | The existing `AgentSession` JSON, serialization version 7, unchanged |
| Pending schedules | The existing `AgentScheduledSendPersist` record |
| Composer snapshot; every sent or queued message ("intent") and its dispatch evidence; run-attempt records; pending-question snapshots; recovery decisions | **New** per-session recovery record, `…/RepoPrompt CE/AgentRecovery/v1/sessions/<sessionID>.json` |
| Provider process ownership | **New** runtime records, `…/AgentRecovery/v1/runtimes/<runtimeID>.json` |
| Launch instance and clean-exit mark | **New** `…/AgentRecovery/v1/launch-state.json` |
| File checkpoints | The checkpoint spec's private store |

- Paths come from the app's existing Application Support resolver; there is no new hard-coded root.
- One app-scoped `AgentRecoveryStore` actor is the only writer. It does atomic replacement, revision checks, idempotency, and tombstones.
  - Revision checks use an opaque revision token, as `scheduledSend.updatedAt` does.
  - It takes and returns immutable `Sendable` values, never `AgentTabSession` or controllers.
- **Why a separate record** (OracleE's choice over OracleD's new session-JSON fields):
  1. An acknowledgement shouldn't wait on re-serializing a large transcript on the main actor.
  2. Composer state changes on every keystroke.
  3. The record must stay writable during teardown, independently of view-model debounce tasks.

  OracleD's atomicity concern is handled two ways: the reconciliation rules in R1a, and the receipt transfer in R9. The scheduled-send clear still needs a session save, so that route keeps the transcript-write cost.
- **Schema and corruption handling.** `schemaVersion: 1`, using the typed-or-unreadable pattern from scheduled sends.
  - An unknown version keeps the original file, which is never executed or overwritten.
  - Unknown members are preserved.
  - A corrupt file is kept and shown as "recovery status unknown".
  - A missing record for a legacy idle session means "nothing pending". A missing record that a summary or runtime record refers to is an error, not an empty queue.
- **Contents.**
  - `composer`: one `composerRevision` covering text, managed image references, tagged-file references, workflow, and `interviewFirst`.
  - `intents`: every message (R2).
  - `attempts`: run-attempt identity, dispatch and terminal evidence, and a shutdown or close reason when known.
  - `questions`: pending `ask_user`, user-input, and elicitation snapshots, each with any partial answer.
  - `recoveryDecisions`.
- **Ownership and lifecycle.**
  - Each record stores the session's existing durable incarnation (its reset/delete generation) in canonical serialized form. Implementation first locates that authority in `AgentSessionDataService`; no new counter is invented.
  - Reset keeps unsent intents as held "from the previous conversation" input and never retargets them.
  - Delete writes a tombstone before cleanup; late writes then fail the generation or tombstone check.
  - A record is deleted once it holds no unresolved items, which keeps the launch scan small.
- **A durable session stub exists before the first intent.** A new session's first send writes its normal session file first, so a recovery record never points at a session that exists only in memory.
- **Attachments.** Images must already be in managed storage before a message is acknowledged. The attachment cleanup's reference set grows to cover composer snapshots, intents, and held items.
- **Metadata index.** Schema goes from 7 to 8 and adds a bounded recovery hint: state, reason, unsent count, and whether a draft exists. It is a discovery hint only; recovery discovery scans its own records.

### R1a. Reconciling the two files after a crash

The recovery record can be newer than the session JSON, or exist before any saved turn.

- **Join keys.** Session incarnation, intent ID, the deterministic user-item ID carried by the intent, run-attempt ID, and transcript turn.
- **An intent without acceptance evidence** shows its user bubble as "not sent", using the deterministic item ID; it is never shown as Sent. *Send* reuses that item ID, so it never appends a second bubble. This is the scheduled-send rule.
- **An intent with acceptance evidence but no saved bubble** gets its bubble restored from the intent.
- **An attempt with terminal evidence while the saved transcript still shows the turn open** displays as "completed; transcript tail may be missing", not "interrupted". In Phase 4, the provider-history import fills the tail.
- **An attempt that exists only in the recovery record** (a crash before the first transcript save) is still discoverable and gets an interrupted card.
- **Cold restore prefers per-attempt evidence** (an attempt's recorded quit or close reason) over the global launch mark. A missing clean mark proves only an unclean exit, not its cause.

### R2. Durable acknowledgement for every send

- **Rule.** Every provider handoff, direct or queued, first commits the message as an intent together with a `dispatching` attempt, in one record write. RepoPrompt may report a message as **queued** only after its intent is committed, and as **accepted** only on affirmative provider acceptance.
  - This covers first prompts and direct follow-ups as well as queues, so a crash just after Send never loses the message.
  - A crash during `dispatching` becomes `deliveryUnknown`.
- **Intent delivery states.**

  | State | Meaning |
  |---|---|
  | `queued` | Saved; no handoff has begun |
  | `dispatching` | Handoff may have happened |
  | `providerAccepted` | The provider acknowledged it (not "completed") |
  | `deliveryUnknown` | Sending again might duplicate it |
  | `failed` | Verified rejection or pre-handoff failure; the payload is kept |
  | `withdrawn` | The user removed it explicitly |

- **Holds.** A hold blocks automatic draining without changing delivery state. Hold reasons are `staleTarget`, `missingAttachment`, and `previousInstance`. The last is **derived** by comparing the record's app-instance ID with the current launch, never written at relaunch, so a crash before that write can't leave an unheld queue.
- **Outcomes by boundary.**
  - The intent commit fails: the caller gets `.failed`, the optimistic row is removed, and the composer is restored.
  - The intent commits, but the target run ends during the suspension: the caller gets `.stale`, not "queued". The committed intent stays as held input under the same ID.
  - Handoff may have happened, but recording acceptance fails: the payload is kept as `deliveryUnknown`. RepoPrompt doesn't claim rejection and doesn't restore a retryable draft.
- **Codex fix** (OracleE's design).
  - `enqueueCodexFallback` becomes `async`. It reserves the queue ID so concurrent callers join one operation, then commits the intent and revalidates the session and target after the suspension. Only then does it project the entry into the live queue and resolve the MCP acknowledgement.
  - `NativeSendOutcome.queuedFallback` and `CodexSteerAckTracker.TerminalState.durablyQueued` carry the store-issued receipt. Neither acknowledgement producer can then report success without persistence evidence. Both producers land together.
  - `CodexFallbackQueueEntry` is not made `Codable`, because its controller identities mean nothing after a restart. Its `id` becomes the intent ID.
- **Other queues.**
  - `pendingInstructions: [String]` becomes identifiable values carrying intent IDs, and the Claude and ACP steering projections get the same association.
  - Every site that reports "queued" or "instruction delivered" must hold a receipt first. Inventorying those sites is Phase 0 work.
  - On lifecycle shutdown, the "preserve" disposition still fails any waiting MCP `instructionContinuation`, because a continuation can't survive a restart.
- **After a restart.** Recovered intents become **held recovered input** and never return to live queues, because their run and controller targets no longer exist. For MCP callers, "durably queued" therefore means the message survives a restart as a visible item that needs one click. That is the same rule as closed-app scheduled sends.
- **Composer writes.**
  - Any change to text, images, tagged files, or workflow advances `composerRevision`.
  - Writes are coalesced with a 300 ms debounce and a **2-second maximum delay** from the first unsaved change. They also happen on tab switch and at shutdown.
  - A write failure is shown in the composer. There is no permanent Saving/Saved indicator.
  - On send, the composer clears optimistically, as it does today. The intent commit also records the composer snapshot's removal. On commit failure the composer is restored, keeping any typing that happened meanwhile.

### R3. Transcript saves get a maximum wait

- **Keep the 1-second debounce, and add a 10-second maximum delay.** The clock starts at the canonical transcript mutation point: the session's dirty mark or a source-items revision change, not only `scheduleSave` callers. It resets only when a save commits.
- **Drain buffered assistant text before cleanup.** It is applied before any destructive cleanup and before every final snapshot, so teardown never discards text still in the 250 ms buffer.
- **Send-path state goes to the small recovery record.** Run-attempt start, dispatch, and terminal evidence are written there, not through forced whole-session saves.
- **Phase 0 measurements:**
  - whether a busy session goes unsaved, using `save.schedule.replaced`, `save.session.invoked`, and a new `save.session.written` counter that records successful saves, on a long text-only stream;
  - the main-actor cost of serializing a large session, since a 10-second maximum delay re-serializes it periodically.

  The maximum wait ships either way; its interval is tuned from the measured cost.

### R4. Quit, window close, and Restart safely

Quit uses one absolute 8-second deadline covering all windows, with sessions handled concurrently. It runs in two stages, separated by a point of no return.

**Stage A — reversible.** Any failure here cancels the quit and leaves the app fully usable.
1. Persist window layout before any agent shutdown, as today (`AppDelegate.swift:266-270`).
2. Freeze admission synchronously, before the first `await`. That covers manual starts, the scheduler, queue pumps, and MCP starts.
3. Commit composer snapshots, held queues, question snapshots, and each active attempt's shutdown reason to the recovery records. Mark the launch state as "shutdown in progress".
4. Flush every dirty, fully hydrated session. A session whose load never finished is skipped, so a partial in-memory state never overwrites its file; implementation names the existing load and save-commit guard that enforces this.

If any step fails or times out, admission unfreezes and the user sees the affected sessions with Retry and Cancel quit. Nothing irreversible has happened yet.

**Point of no return.** Only now do `signalTermination`, the termination fast path, the background-mode reset, and `prepareForWindowClose` run. Those steps currently run first in `beginTermination` (`AppDelegate.swift:262-264`); they move after Stage A.

Moving `signalTermination` later means Stage A runs while SwiftUI observation is still live. That is the normal running state, so it should be safe, but implementation must confirm that no Stage A step triggers the shutdown-time observation crashes the flag guards against. If one does, add a separate, reversible "quit pending" flag for Stage A rather than setting `isTerminating` early.

**Stage B — teardown.**
1. Stop runtimes with the existing teardown, using the *preserve* disposition (R2).
2. Flush sessions dirtied by the terminal commits.
3. On success, mark the launch state clean and exit. If a flush fails or the deadline passes, offer only Retry flush or Quit anyway. The launch state stays unclean, so the next launch treats those sessions as uncertain. Cancel quit is not offered here, because the view models are already torn down.

- **Non-cooperative tasks.** The deadline must not hang on one. Such tasks are owned explicitly, and late results fail ownership checks.
- **Unanswered quit.** At logout, macOS kills an app that doesn't answer the quit request, and 8 seconds is inside that allowance.

**Window close** uses the same two stages for that window only. Preserve-versus-withdraw lives inside `prepareSessionForWindowClose`, which window close and quit share, not in `AppDelegate`. A window close records its reason on that window's attempts and **never** marks the launch clean; only app termination does that.

**Preserve versus withdraw.** `cancelPendingInstruction`, the steering cleanups, and the fallback cleanups get an explicit disposition:
- *preserve* on lifecycle shutdown;
- *withdraw* only when the user explicitly cancels the item.

**Quit confirmation.** The wording changes from "will terminate" to "will be interrupted; you can resume after relaunch". Unsent items and drafts are listed for information only.

**Restart safely** (Phase 4) is a menu command that runs the same pipeline with reason `safeRestart`.
- A short-lived helper then waits for the old process to exit and opens the bundle. The helper does no agent work.
- It fails visibly unless state is committed and every managed process is verifiably stopped.
- Deferred to Phase 5 as an experiment: OracleD's option to detach Claude instead of stopping it. The orphan would lose RepoPrompt's MCP tools and its permission channel.

### R5. Honest interruption

`AgentTranscriptTurn` gains an optional `interruption` record:

| Field | Values |
|---|---|
| `reason` | `appCrash`, `appQuit`, `windowClose`, `safeRestart`, `providerProcessLost`, `unknown` |
| Times | `observedAt` and `lastConfirmedActivityAt` |
| Identity | `runAttemptID` and the provider conversation identity |
| Optional context | a pending-question summary and a runtime reference |
| `resolution` | `importedCompleted`, `resumed`, `dismissed` |

`terminalState` stays `.cancelled`, so every existing switch and v7 reader keeps working. Both Oracles rejected adding an `.interrupted` case to `AgentSessionRunState`: it would ripple through every exhaustive switch and through the index and sidebar projections.

**When it is written:**
- On cold restore, before open spans are sanitized. The reason comes from per-attempt evidence first (R1a), then from the launch state.
- From the runner's existing provider-loss path, with `providerProcessLost`.

Phase 1 records shutdown reasons only in the recovery record's attempts. Phase 2 projects them into this turn-level record.

**Display:**
- The sanitizer's inferred `completedAt` is never presented as a real provider completion.
- The UI distinguishes six states: interrupted; provider still running; ready to resume; completed while RepoPrompt was closed; cancelled by you; status unknown.
- An action interrupted mid-way (decision `continueRequested` with no outcome) shows "Resume was interrupted; status unknown". Resume is offered again but never retried automatically.

### R6. Surviving-process registry

**Owner.** `AgentProcessRegistry`, an app-scoped AgentCore actor. OS inspection lives in a new Platform helper, `ProcessInspection.swift`, which wraps `proc_pidinfo`, `proc_pidpath`, `sysctl(KERN_PROCARGS2)`, and `getpgid`, and imports no session types.

**Runtime record.** It describes a process lifetime, not a turn, and holds:
- runtime ID and owning app-instance ID;
- provider kind and provider home (below);
- root PID, process group, and birth identity;
- the observed shim-to-CLI chain;
- the sessions, run attempts, and native conversation IDs it serves. A Codex app-server can serve several threads; whether today's controller shares one isn't claimed;
- worktree bindings and permission mode;
- observed descendants;
- state: `reserved`, `live`, `exited`, `stopped`, `detachedAtQuit`, or `unknown`.

Full environments and command lines are never persisted.

**Process identity** is the combination of boot session, PID, start time (seconds and microseconds), and UID. Executable path and process group are supporting evidence. Any mismatch means `exited`. A changed boot session proves the process is gone.

**Marker.** `ProcessLauncher` gains an optional environment marker, `RPCE_RUNTIME_ID=<runtimeID>`, inherited by the shim, the CLI, and its tools. The name avoids `KEY`, `TOKEN`, and `SECRET`, which Codex's default `shell_environment_policy` strips from tool environments. Propagation through both shims, Claude's Bash tool, and Codex's sandboxed commands is a live validation gate.

**Registration order.** This replaces both original proposals. OracleE showed that the "never given work" rationale fails, because Claude can run startup hooks before its first message.
1. Commit a small `reserved` record (runtime ID, session, marker) **before spawn**.
2. Spawn.
3. Fill in the birth identity and mark the record `live` before the first user message.

If the reservation write fails, the run aborts visibly; RepoPrompt never sends work to an unregistered process. A crash between spawn and step 3 leaves a `reserved` record. Discovery then finds the process by its marker and keeps ownership unresolved. A suspended launch isn't needed.

**Provider home.** RepoPrompt can't pass `CLAUDE_CONFIG_DIR` through the rotator shim, so it learns the home in two ways:
- at registration and at discovery, by reading the real `claude` descendant's `CLAUDE_CONFIG_DIR` through `KERN_PROCARGS2`. Only that one value is kept;
- for history import, by finding `<sessionID>.jsonl` across the known Claude config roots, including `~/.claude/projects`. Session IDs are UUIDs, so the match is unambiguous.

**Claude session IDs are preallocated in Phase 3** with `--session-id`, gated on a compatibility check of 2.1.302 through the shim. They are never combined with `--resume`. The runtime record then has the conversation ID before any output arrives. Until then, a live runtime bound to a session blocks Resume on that session even if its conversation ID is unknown.

**Discovery** runs at launch, before Stop, before Resume, and when an exit event fires.
- It takes one same-UID process inventory, follows parent links from registered roots, and matches the marker. That also finds tools reparented to launchd and tools in separate process groups.
- No continuous polling. OracleE proposed polling once per second, but the owner's CPU and main-thread budget matter.
- `kqueue` `NOTE_EXIT` watches **every** identified live writer, launcher, and blocking tool, not just the root, and each exit triggers rediscovery. A Refresh action covers missed events.
- Denied or incomplete inspection means `unknown`, never `exited`.

**Launch-time UI.** Processes left by the previous instance appear as recovery items. Each shows provider, session, worktree, elapsed time, permission mode, and its discovered descendants. The actions are:
- **Let finish** (default): record the choice and keep watching.
- **Stop**: show the processes about to be signalled. Revalidate identity immediately before each signal, then send SIGTERM to every verified process group. Wait 3 seconds and escalate to SIGKILL. Finally, run a fresh family discovery to verify.

Processes are never signalled by name. `EPERM` or an identity mismatch leaves the item unresolved. Nothing is killed automatically (O1).

**Two-writer rule.** RepoPrompt refuses another managed writer for a conversation while any of its recorded writers or launcher shims is alive, reserved, or unverifiable. The conversation key is provider kind, provider home, and native conversation ID.
- **Tool-only survivors** (for example, a dev server Claude started) are not conversation writers. They don't block same-conversation Resume, but they keep the worktree busy for automatic work and set the checkpoint spec's `unresolvedPriorExecution` flag. Resuming while one is alive needs a confirmation that lists it.
- **Unverifiable ownership** disables same-conversation Resume. The card offers Stop. "Continue in a new conversation" (the existing handoff) is also offered, but it needs Stop or an explicit confirmation, because a live orphan could still edit the same worktree. There is no force override.

**Remote-host sessions** have no local process. Composer snapshots and intents apply to them; the registry and Resume don't.

### R7. One-click Resume

`AgentRecoveryCoordinator` (main actor) runs each Resume as one reserved action, keyed by recovery-item ID, expected revision, and action ID. Repeated clicks join the same action.

1. Persist the decision. Then validate session ownership, provider identity, worktree binding, and the R6 fences.
2. Reconcile the provider's own history (below). Persist imported transcript rows before advancing the history cursor; a crash between the two causes only a harmless re-import.
3. If verified terminal evidence shows the interrupted turn finished, display the result and stop without sending anything.
4. If the original message was never handed off, the action becomes **Send saved message**, which sends the saved payload under its existing item ID.
5. Otherwise:
   - create one continuation intent and a new run attempt;
   - obtain the shared pre-dispatch permit, which includes the checkpoint spec's fresh start capture;
   - dispatch once through the normal start path.

   The continuation text is shown in the card and can be edited. Default: "RepoPrompt restarted during the previous turn. Check the current state before repeating any action, then continue."

Other held follow-ups stay visible and are **not** bundled into the continuation (OracleE). OracleD proposed joining them, but silent bundling changes what they mean.

**Claude:**
- **History import.** A read-only adapter reads only the exact session JSONL, located as in R6. It parses complete lines only and deduplicates by native message, tool-use, and parent IDs. It stores the file identity and the byte offset of the last complete line, and rescans after a replacement or truncation. Rows are imported through a history-only path that cannot invoke tools, approvals, or old continuations, and they are labelled "recovered".
- **Completion test.** The test is stricter than "the last message ended its turn". A Stop hook can continue after an assistant response, and accepted steering separates a response from the attempt. A turn therefore counts as finished only with version-validated terminal evidence bound to the interrupted request. Without it, the card says "Last answer recovered; completion unconfirmed" and keeps Continue.
- **Continuing.** Start a new process with the existing `--resume <id>`, recreating current MCP endpoints and permission routing.
- **Open behavior.** How `--resume` treats a dangling `tool_use` must be tested live. If it refuses, fall back to "Continue in a new conversation".

**Codex:**
- Reuse the existing thread and turn reconciliation in the Codex controller; don't write a parallel reader.
- Read with the observational APIs. Once ownership is safe and the user has clicked, run `thread/resume` and then a new `turn/start`.
- Record the native `turn_aborted interrupted` evidence on the turn. Codex has already told the model about the interruption, so the continuation text is optional.
- Pin the adapter to the tested app-server schema.

**ACP and Oh My Pi.** Input and interruption data are preserved from Phase 1. Recovery stays context-only (the existing handoff) until each provider's transport-loss, history, and resume behavior has been tested live.

### R8. The recovery list is data

**Catalog.** `AgentRecoveryCatalog` is app-scoped, like the scheduled-send coordinator. It derives items from:
- recovery records;
- runtime records;
- the metadata-index hint, for sessions that aren't hydrated;
- scheduled sends in `needsConfirmation`.

Each item records its kind, session, workspace, reason, available actions, and blockers.

| Item kind | Introduced |
|---|---|
| Interrupted turn | — |
| Surviving process | — |
| Saved unsent input | — |
| Unanswered question | — |
| Scheduled send needing confirmation | — |
| Pending edit review | Phase 5 |

Decisions (`pending`, `continueRequested(actionID)`, `dismissed`, `resolved`) are stored in the session's recovery record.

**Startup order (Phase 1).** At launch, recovery discovery runs **before** the scheduler evaluates and before any queue pump starts.

**Rendering.** The Mac UI renders from the catalog: a per-session banner, plus a "Needs attention" sheet modelled on the Scheduled Messages sheet. A future remote UI reads the same catalog.

**Dismiss** acknowledges the card only. It never:
- discards saved input;
- answers a question;
- stops a process;
- confirms an overdue schedule;
- releases an unknown owner.

Removing saved input is a separate, explicit action, which first offers to move the text into the composer.

### R9. Interactions with other features

**Scheduled sends.** Ownership transfers by receipt (OracleE):
1. Commit the existing `dispatching` attempt with its deterministic item ID.
2. If delivery falls back, commit an intent that carries the schedule, attempt, and item IDs.
3. Commit the schedule receipt and clear its pending record.
4. Release attachment ownership only once the intent holds the attachments.

A crash after step 2 is repaired by matching the receipt. Because the startup barrier ships in the same phase, the repair runs before the scheduler could surface a second confirmation.

- **Receipts.** Historical receipts gain an acceptance kind: `providerAccepted`, `savedInQueue`, or `legacyUnknown`.
- **Busy aggregation** adds unresolved interruptions, unresolved processes, and Resume reservations. `runAlongsideOtherSessions` cannot bypass them.
- **Never auto-confirmed.** Dismiss and Resume never confirm an overdue schedule.
- **Future schedules unchanged.** A schedule whose deadline is still in the future keeps its documented behavior once these gates pass.

**Pending questions.** The question text, its options, and any partial answer are saved; continuations are not. After a restart the old request is historical and its transport has expired. The user's typed answer becomes the Resume or Send text, and any fresh request needs fresh routing.

**Pending edit reviews** (Phase 5):
- The proposal is persisted before it is shown, and `applicationStarted` is committed before applying.
- After a crash, current file fingerprints are revalidated and nothing is reapplied automatically.
- Approving after a restart can't return a tool result to the dead provider, and the card says so.

**MCP callers and `agent_run` children** (Phase 5):
- Persist the parent session and attempt, the tool-call identity, and the child session before child dispatch. A parent's recovery then finds its child instead of replaying `agent_run`.
- Old RPC continuations and permission scopes expire at restart.
- A stable client operation ID is deferred. Until then, the contract explicitly excludes deduplication across an MCP caller's own new retry: persisted intent IDs recover that intent, but they don't give exactly-once behavior across separately submitted requests.

**Turn checkpoints** (`2026-10-18-turn-worktree-checkpoints-spec.md`). This spec supplies only:
- the shared run-attempt ID;
- opaque checkpoint outcome references in the recovery record;
- the `unresolvedPriorExecution` flag from the registry;
- pinning of unresolved interrupted turns;
- the interrupted-turn card that hosts the checkpoint section.

The shared pre-dispatch gate runs this spec's ownership check before the checkpoint's 2-second capture. File review is never a prerequisite for Resume, Resume never restores files, and a missing checkpoint never blocks an otherwise safe Resume.

## Live acceptance results (2026-10-25)

Scope: Claude Code and Codex CLI only, on the daily debug app `/Applications/RepoPrompt CE Dev.app` built from `d971983b`, with synthetic `RPCE_RESTART_ACCEPTANCE_…` sessions only. Production recovery qualification stayed unchanged (default off). The owner approved normal quits, deliberate `SIGKILL`s, and a temporary permission fault. Full step-by-step evidence is in the [live-acceptance handoff](evidence/2026-10-18-lossless-app-restart/live-acceptance-handoff.md); raw records are in the local journal `.agent-artifacts/lossless-restart-ordinary-acceptance/lifecycle.json` (keys `cycle2`–`cycle9`).

### Verified

| Area | Result | Evidence |
|---|---|---|
| Normal quit | Drafts, images and queued records preserved; no resend | 8/8 records after quit; four active sessions (Claude, Codex, OpenCode, Cursor) quit in 1.12 s (one advisory sample) |
| Quit during a live turn | Claude intent `dispatching` → `deliveryUnknown`; Codex intent stays `providerAccepted`, run attempt `terminal{appQuit, cancelled}` | Banners "previous run may still be running" and "Message may have been delivered" |
| Exact crash cuts (lldb breakpoint, then `SIGKILL`) | Every cut below: payload kept, nothing resent, no provider process started after relaunch | Debug signing has no hardened runtime, so `lldb` attaches without a prompt |
| — queued written, before receipt | intent `queued`, composer consumed; card "Saved message, not sent" | `AgentRecoveryStore.swift:747` |
| — run attempt recorded, before dispatch | intent `queued`, open run attempt; crash hold plus "Run interrupted before it was saved" | `AgentRecoveryQueuedInput.swift:252` |
| — dispatching written, before handoff | intent `dispatching`, one attempt; "Message may have been delivered" (conservative: the provider never saw it) | `AgentRecoveryStore.swift:870` (line 868 is before the durable `rewrite`) |
| — quit Stage A after the unclean mark | `launch-state` `shutdownInProgress`; relaunch treats it as unclean; draft restored exactly | `AgentLifecycleShutdownCoordinator.swift:584` |
| — quit Stage B before the clean mark | same as Stage A | `AgentLifecycleShutdownCoordinator.swift:776` |
| Timing-based kills mid-turn (Claude and Codex) | records frozen, no resend; Codex children die with the app; Claude shim, CLI and tool survive as orphans and finish on their own | `cycle8.E_crash` |
| Injected shutdown failure (`chmod 555` on `AgentRecovery/v1/sessions` only) | Quit blocked with "RepoPrompt couldn't save everything before quitting … Nothing was stopped or closed" and Cancel / Retry; app stays usable; after permissions are restored, Retry flushes all pending text and quits | `cycle8.H_shutdownFault` |
| Scheduled send across a quit | `needsConfirmation` / `missedWhileClosed`; nothing dispatched | banner "Scheduled for 14:28 · app was closed; confirmation required" |
| Recovery card actions | It stopped, Dismiss, View, Edit, Remove write only their own decision; none sends | Edit restored exact text and withdrew the intent |
| Codex resume after a restart (MCP steer and composer) | same thread; reply "QUEUED; lighthouses." needs both earlier turns; no re-execution | `cycle9.L` |
| Queued behind a running command (Codex, MCP) | "Queued to start", durable `queued` intent, drained exactly once | `cycle9.K` |
| Codex `queuedFallback` | accepted on unit-test evidence (owner, O25): `CodexFallbackFIFOTests`, `AgentModeRunServiceLifecycleTests`, `AgentRecoveryQueuedInputTests`, 213 + 10 tests, 0 failures | its only reliable live trigger (`resumedThreadActive`) cannot occur: the Codex app-server is a child of the app and dies with it |
| Full-root codemap failure | pre-existing, not caused by this work | `MCPCodeStructureWorktreeTests…ForegroundRecoversOnce` fails at line 1805 in clean worktrees at `d971983b` and `5507c3fa` |

### Live re-verification of the fixes (2026-10-26)

Built and installed from `ae111cc7` (`make dev-run`, provenance commit `ae111cc7`; `dirty` only from unrelated local docs and the codemap helper), on the daily debug app, with synthetic `RPCE_RESTART_ACCEPTANCE_20261026_…` sessions, Claude Code and Codex CLI only. Production recovery qualification stayed default off. Raw records: `cycle10` in the local journal.

| Finding | Live result | Evidence |
|---|---|---|
| F7 | **PASS.** The exact trigger, a first send in a new session with a Tab-accepted `@` file suggestion, sent once on both Claude and Codex, with the tag attached. Switching between a Claude and a Codex tab kept each composer's own model, showed no foreign MCP chip, and a send from each tab was accepted once. | intents `2E8A55A1`, `66E6D7EF` `providerAccepted`; `taggedFileAttachments` = the spec path; replies `TWELVE` / `THIRTEEN` |
| F1 | **PASS.** A 15-minute follow-up in an idle, composer-created Claude session fired on time without a restart and was delivered once. The earlier turns were untouched: no error row, not marked failed. | scheduled intent `7CF30842` `providerAccepted`, no `withdrawnAt`; run attempt `ordinary/completed`; reply `FIRED`; schedule cleared |
| F2 | **PASS (feedback; the gate is unchanged by design).** Send now on a new-session schedule, both while running and after a quit as `missedWhileClosed`, now explains itself: "Will send after 13 interrupted sessions in this workspace are resolved: choose It stopped (not Dismiss) in Needs Attention…". Nothing dispatched. | schedule `needsConfirmation` / `missedWhileClosed`, `runAlongsideOtherSessions` true, 0 turns |
| F3 | **PASS.** The header reads "Nothing interrupted in this session. 64 items elsewhere need attention." With local rows it reads "3 saved or interrupted items in this session need your attention. 66 items elsewhere need attention." | screenshots during the run |
| F4 | **PASS.** Idle `/compact`; a compaction cancelled with Stop (`userCancel` after 25 ms); then `/compact` again. Each answered "Requested Codex context compaction." and never "Start a Codex conversation". The thread kept its context (follow-up answered `Harbors`). | run attempts in the Codex session `F0C20642…` |
| F5 | **PASS (not reproduced).** A normal quit during a running Codex foreground command exited about 2 s after Quit and killed the command. The run attempt has `shutdown{appQuit}` and `terminal{appQuit, cancelled}`; `launch-state` was `cleanExit`. The new `LifecycleShutdown` log shows the whole request (confirmation answered, Stage A steps, teardown, Stage B, `shutdown_ended outcome=completed`) in 0.8 s. | unified log, request `BFD1674D…` |
| F6 | **PASS.** With the sessions directory made read-only and a pending draft, the quit dialog reads: "the message box could not be saved (RepoPrompt can't access its data folder; check that folder's permissions and that its disk is writable). Nothing was stopped or closed…", with no Swift or `NSError` text. After permissions were restored, Retry saved the exact text and quit cleanly. The dialog and the choice are in the `LifecycleShutdown` log. | `shutdown_dialog_presented` / `shutdown_dialog_choice` |
| Regression | **PASS.** The dispatching crash cut (lldb at `AgentRecoveryStore.swift:872`, after `beginDispatch`'s durable rewrite, then `SIGKILL`) on the fixed build: `dispatching` intent and attempt kept; after relaunch no resend and no provider process; crash hold, "Run interrupted before it was saved" and "Message may have been delivered" shown. | Claude session `2A0336BA…` |

Not re-run on the fixed build: the other crash cuts, timing kills, the four-provider quit, and the Codex queue scenarios. The minor observations below remain as recorded.

### Steps 8/9 verifier scenarios (2026-10-27)

Run on the daily debug app built by the owner from `a8796ec0` (contains Step 8-popover, Step 8-attention, the bulk Dismiss, Check and resolve, and Step 9-activation-a; recovery activation off), Claude Code only, scenario IDs from [verifier-scenarios.md](evidence/2026-10-18-lossless-app-restart/verifier-scenarios.md). Raw records: `cycle11` in the local journal and `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle11/<group>/`. No unrequested, duplicate or lost message in any scenario.

| Scenario | Result |
|---|---|
| H1 | **Partial.** All 14 leftover synthetic sessions deleted through the sidebar; each lost its session file and recovery record and gained a tombstone. Their 12 Needs Attention rows (5 Needs action, 7 Information) stayed visible, and the 5 still counted in the badge, until the next app launch, when all 12 were gone. See finding F8. |
| P1–P4, P7, P9, P11 | **Pass.** One click on another row's action closes View and acts; the composer, a sidebar row and the window behind a sheet each take one click; View toggles; app switch closes it. |
| P5 | **Fail (known open question).** Esc, pressed twice with View open and nothing clicked, does not close the popover. |
| P6, P8, P10 | **Not run.** No edit-proposal row; File > New Window opened no second window. |
| A1, A7 | **Pass.** No banner in a clean session; Information collapsed by default and excluded from the badge; Show dismissed changes no counts. |
| A2, A3 | **Pass.** SIGKILL during a Claude turn (PID 6669 → 14622): crash hold under Needs action, "RepoPrompt quit unexpectedly" under collapsed Information, badge excludes it. It stopped removed the hold and recorded `crashHoldAcknowledgement`; the next message was delivered once. The message dispatching at the kill (`D1FF8952`) was not re-sent and still shows "may have been delivered". A Claude `<task-notification>` user entry in the provider history came from Claude Code's own background-shell notice, not from RepoPrompt. |
| A4–A6, A10, A11 | **Not run.** Every section held owner items, so no bulk Dismiss was attempted. |
| C1 | **Pass.** "Process and provider-history checks are not active. Items are reported as they are; nothing was changed." then "Checked 29 of 29 · 21 need you · 8 could not check". All 54 recovery records byte-identical before and after; sessions, counts and provider processes unchanged. |
| C3 | **Pass (timing-dependent).** "Cancelled: checked 3 of 29, 26 not checked · 3 need you"; records unchanged. Check finishes in about 0.5–4 s, so cancelling needs a fast click on **Stop** (the guide says Cancel). |
| V1–V9, A8, A9, C2 | **Not runnable** until activation (`AgentRecoveryActivation.production = .off`). |

Observations, not scenario failures: the View popover covers the buttons of the rows above it and swallows clicks there; the Check report has no `agent.recoveryNeedsAttention.checkReport` accessibility identifier (it inherits `…sheet`).

**F8 (confirmed, minor).** Deleting a session leaves its Needs Attention rows in the open app until the next launch, and Needs-action rows keep counting in the badge. Expected (H1): they go with the session. The record file is deleted and a tombstone written on delete; that the in-memory projection is simply not refreshed then is an inference, not traced in code.

**Re-check after the verifier fixes (2026-10-28).** Rebuilt from `8263d7da` (contains `ed540912`; activation off), app PID 92285, no messages sent. Raw records: `cycle12` in the local journal and `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle12/recheck/`.

| Scenario | Result |
|---|---|
| H1 / F8 | **Pass.** Deleted the verifier sessions T2 `E1857698…`, T3 `AB664854…` and T4 `D52D8872…` (decision O40). Each lost its session file and recovery record and gained a tombstone; its rows left the banner and sheet at once and the badge dropped by its Needs-action count (T4 22→21, T2 21→20, T3 0 rows left), without a relaunch. |
| P1 | **Pass.** View on the lowest of two banner rows opens above the banner over the transcript and covers no row or header button; one click on Dismiss of the row above closed View and acted. |
| P7 | **Pass**, also with the window at 1000×700: the popover opens beside the sheet, fully on screen, covering no row or sheet button; one click on another row's Open closed View and acted. |
| P11 | **Pass.** Clicking the window behind closed View; focus stayed on the sheet. |
| C1 and accessibility | **Pass.** The report is found as `agent.recoveryNeedsAttention.checkReport` ("Checked 30 of 30 · 22 need you · 8 could not check"); the banner as `agent.recoveryList.banner` with child IDs `status`, `needsAttention`, `view`, `dismiss` and `detail`. |

Observations, not failures: after Dismiss of T2's message row, its run row read "Sending is paused … Confirm it stopped to send again." and the verifier did not find it in the sheet, although deleting T2 still dropped the badge by one; the banner popover's arrow points near the banner's left side, not at View; at 1000×700 the popover extends past the window's right edge.

### Findings for the implementer

Fixed and re-verified live on 2026-10-26 (see above); the diagnosis below is kept as the record. Diagnosed 2026-10-26 at `d971983b` from code, the on-disk records of the affected sessions, Claude's own session log and the acceptance journal (`.agent-artifacts/lossless-restart-ordinary-acceptance/lifecycle.json`). OracleA and OracleD reviewed the diagnosis and the fix guidance independently (identity verified; a diagnosis review, not a phase review round). Line numbers refer to `d971983b`. Labels: **confirmed** (code, or code plus recorded data), **inference** (fits the evidence, not proven), **open** (unknown).

**Fix order:** F7, then F1, each with its regression tests, plus the observability items under "Cross-cutting". Then F2 feedback, F4, and F3/F6 wording. F5 first needs one live observation.

**Safety fences that every fix keeps:**
- the composer submit-target checks (`AgentInputBar.swift:543-549`, `renderedSubmitTarget`) and submission tokens;
- the recovery admission gates, including the new-session gate that "Run alongside" does not bypass;
- the durable-intent transition rules (`AgentRecoveryStore.swift:930-960`): a withdrawn intent is never dispatched;
- "Sent" only on affirmative provider acceptance;
- the single 8-second quit deadline followed by a user choice.

#### F7 — Submit disabled or "This composer changed…" because another tab's state overwrites the composer (high)

- *Observed:*
  - Owner, 2026-10-25: a first send with a Tab-accepted file tag in a new Codex session was refused with "This composer changed before the message could be sent. Please try again." Afterwards Submit was barely ever clickable. Changing the reasoning effort and changing it back re-enabled Submit, but only for a while.
  - Journal (`queuedScenario`, 10:35–11:10): Return or Send did nothing in sessions E, G, J, K and T3, sometimes showing the same message. In T3, a session never touched by MCP, the composer showed an orange MCP chip, a locked model and a disabled Send button. A relaunch cleared it temporarily (`cycle2.uiReadbackT4`). `cycle9.J2` and `K` hit the same thing.
- *Cause (confirmed, code):*
  1. Every recovery-record write publishes a commit with no change filter, including the composer snapshots written while typing (`AgentRecoveryStore.swift:2156`).
  2. The coordinator adopts it, invalidates the catalog and posts a coalesced `.agentRecoveryCatalogDidChange` (`AgentRecoveryCoordinator.swift:529-559`, `:719-747`). `composerStateDidChange` also posts `.agentRecoveryComposerStateDidChange` (`:819-827`).
  3. The view model's observer (`AgentModeViewModel+Recovery.swift:641-646`) calls `refreshRecoveryListUI`, which loops over `sessions.keys` and calls `syncComposerUIState(tabID:)` for each tab (`AgentModeViewModel+RecoveryList.swift:1053-1056`).
  4. Each call writes `makeComposerProps(tabID:)` into the one shared `AgentComposerUIStore` (`AgentModeViewModel+ComposerUI.swift:192-195`; the store has a single `props`, `AgentComposerUIStore.swift:7`). The last dictionary key wins, and Swift's per-launch hash seeding makes that order differ between launches.
  5. When the winner isn't the visible tab, `renderedSubmitTarget` is nil (`AgentInputBar.swift:543-549`): the button is disabled, and Return shows the stale message from `view_nil_target` (`:2422-2424`).
  6. The MCP chip and model lock read the props without a tab check (`AgentInputBar.swift:613-618`, `:994`; built from the explicit tab at `AgentModeViewModel+ComposerUI.swift:74-75`). That is why T3 showed another tab's MCP state.
  7. The effort `didSet` republishes the current tab (`AgentModeViewModel.swift:381-386`), which explains the workaround until the next write.
- *Also:* `makeComposerProps` for a non-current tab is a mix of states. Some fields come from that tab (submit target, schedule, MCP lock, selected agent); others come from the visible session or view model (run state, busy flags, pending attachments, reasoning effort, auto-edit). Publishing it was never a valid state.
- *Open:* the exact rejection reason for the owner's Tab-tag send was not logged. Tag acceptance attaches synchronously (`TextFieldMentionHelpers.swift:331-340`, `AgentModeViewModel+DraftsAttachments.swift:195-220`), so the earlier "late tag resolution" lead is unsupported. `sendMessage()` has silent exits before the logged one: the provider-unavailable notice (`AgentInputBar.swift:2411-2418`, which can read another tab's `canSendWithCurrentProvider`) and the empty-draft guard (`:2420`). A separate first-send race, where draft persistence binds a session after the rendered target was captured, is plausible but untested.
- *Fix:*
  - Enforce ownership in `syncComposerUIState(tabID:)`, the shared publication boundary used by about 67 call sites. When an explicit `tabID` is not `currentTabID`, skip the store update but still call `notifyScheduledSendBusyStateMayHaveChanged(tabIDs: [tabID])`. Otherwise publish `makeComposerProps()` for the current tab.
  - Make `refreshRecoveryListUI` publish the current tab once and send busy notifications for the other tabs explicitly. Don't drop scheduler notifications by accident: the observer comment saying "no scheduler churn" is already inaccurate.
  - Optionally add a DEBUG assertion in `AgentComposerUIStore.update` that published props belong to the current tab.
- *Audit before landing:*
  - `currentTabID` is computed from `promptManager.activeComposeTabID` (`AgentModeViewModel.swift:1307-1314`). Find any tab-activation or first-send path that publishes the new tab before that value switches, for example `createAndActivateSessionTab` and the first-send destination sync near `AgentModeViewModel.swift:15530`. With the new guard such a path would leave stale props, so make it publish after the switch.
  - Check direct `ui.composer.update` calls and other shared UI stores fed by `syncAllActiveUIState(tabID:)` for the same pattern.
- *Do not change:* the submit-target checks (they turned this into a safe failure instead of a send to the wrong tab), the commit publisher (scheduled-send evidence consumers need every commit), or store equality (another tab's props are legitimately unequal).
- *Tests:*
  - With tabs A (current) and B open, `refreshRecoveryListUI()` and a posted catalog-change notification leave `props.currentTabID`, `submitTarget`, `isCurrentTabMCPControlled` and `areModelControlsDisabled` as A's; Send stays enabled.
  - `syncComposerUIState(tabID: B)` leaves the props unchanged and still notifies B's scheduler busy state.
  - Run across tab-order permutations.
  - Switch tabs while a notification is queued.
  - Cover the no-current-tab and tab-removal cases.
  - Keep separate coverage for the Tab-tag first send.
- *Afterwards:* re-run the live composer checks. Per-keystroke refresh cost (one refresh per write, plus a second for composer-state changes) is a separate, optional performance follow-up; any filtering belongs in `adoptRecordCommit`, never in the store.

#### F1 — A scheduled follow-up is withdrawn before its runner dispatches it, and the previous turn is marked failed (high; Claude confirmed, ACP likely)

- *Observed:* an idle Claude session (`86798767-FE57-4D15-9AD9-AB11A469EE3F`, `cycle9.I_followup`) ran a 15-minute follow-up with no restart.
  - The schedule went `failed` with "The agent runtime changed before the scheduled message could be sent." and the banner read "Delivery unconfirmed".
  - The previous completed turn (S3, reply `READY`) was rewritten `terminalState: failed` with the error "This message was not sent because its delivery could not be recorded. It stays saved."
- *Recorded sequence (confirmed, on-disk recovery record):*
  - t0: intent `496A71F4` saved `queued`.
  - t0+118 ms: intent `withdrawn`.
  - t0+289 ms: run attempt `8196222E` recorded, 171 ms after the withdrawal. It reuses the previous `processRunID`, which is intended; the run attempt is new.
  - t0+420 ms: terminal `ordinary/failed`.
  - There is no delivery-attempt row for the intent. Claude's session log (`897e3ec2-ab7a-4ef7-8d93-7cc700c5f534.jsonl`) contains S3 and never S4, so nothing was delivered.
- *Cause (confirmed, code):*
  1. For non-Codex providers the run service defers the durable dispatch commit to the runner (`AgentModeRunService.swift` ~650-700, "adopted plan §5").
  2. The Claude runner spawns `session.agentTask` and returns (`ClaudeIntegratedAgentModeRunner.swift:63-113`). The commit happens later in that task, after `lease.acquire()` and tool-tracking setup (`ClaudeAgentModeCoordinator.swift:2014`). So `startAgentRun` returns `nil` while the intent is still `queued` with no attempt.
  3. `finishMandatoryScheduledDispatch` reads the record, finds `intentNeverDispatched` (`AgentScheduledSendRecovery.swift:206-211`), and treats a `nil` outcome as non-delivery (`AgentModeViewModel+ScheduledSend.swift:3170-3176`). It then removes the bubble, withdraws the intent and marks the schedule failed, using the nil-fallback text (`:2881-2896`).
  4. The runner's later `beginDispatch` on the withdrawn intent throws `invalidTransition` (`AgentRecoveryStore.swift:939-953`; the intent is still present with state `withdrawn`). That maps to the `.commitFailed` text (`AgentRecoveryCoordinator.swift:292-293`), and the run finalizes `failed`.
  5. The terminal barrier attributes the failure to `session.items.last(where: .user)` (`AgentRunTerminalCommitBarrier.swift:248-250`). The scheduled bubble was already removed, so that is the previous turn.
- *Same exposure (confirmed, code):* ACP providers (OpenCode, Cursor, Oh My Pi) also commit inside a spawned run task (`ACPIntegratedAgentModeRunner.swift:317-325`, commit at `:1729`). Headless is unaudited.
- *Why tests missed it:* the injected starter in `AgentScheduledSendNonCodexMandatoryTests.swift:15-25` writes dispatch evidence before returning `nil`, which production doesn't do. Only the "already dispatching" branch is covered.
- *Also:*
  - `nil` is ambiguous. Some non-Codex exits before any runner exists also return `nil` (comment at `AgentModeRunService.swift` ~576-582; the workspace failure at ~658).
  - The view model's staged-input path already treats "inactive run" as not proving non-handoff (`stagedInputStartDisposition`, `AgentModeViewModel.swift` ~19058). The scheduled finisher is the odd one out.
  - The error text "…delivery could not be recorded…" has three sources: `.commitFailed`, and literal strings in the Claude runner (`:154`) and the ACP runner (`:1719`) `attachRunAttempt` branches.
- *Fix (authority: the run-start and handoff boundary, not provider-specific scheduler heuristics):*
  1. Make `nil` from `AgentModeRunService.startRun` mean only "a runner owns this input and owes a settlement". Every pre-runner exit returns an explicit `.failed` or `.stale` for every provider. Codex semantics are unchanged.
  2. In `finishMandatoryScheduledDispatch`, never infer non-delivery from `nil` or from a record read. Hold with `.awaitingProviderEvidence`, keeping the schedule, payload, intent and bubble.
     - Resolve the hold only on the handoff's own settlement. Committed evidence leads to the existing transfer and acceptance logic. A proven no-handoff (`noteNoHandoff`) on the still-queued intent is the only case that may withdraw, remove the bubble and mark failed, using the handoff's message.
     - Verify that a deferred, uncommitted durable handoff's `noteNoHandoff` and `settleRunInputScope` actually wake the scheduled hold, for example via `.agentRecoveryDeliveryEvidenceDidSettle` (`AgentModeViewModel+Recovery.swift:649`). If not, that is the one new hook.
     - A dispatch commit is not acceptance and not Sent. A timeout never proves non-handoff.
  3. Bind terminal attribution to the run attempt's own input (the attempt's `userItemID` and execution turn, keeping the relocated-input mapping) instead of `items.last(.user)`. If that target is absent, never fall back to failing an earlier turn. This also covers a newer queued input being appended.
  4. Give the three identical "could not be recorded" texts distinguishable diagnostics.
- *Do not change:* `beginDispatch`'s refusal of withdrawn intents, `intentNeverDispatched`, `withdraw` semantics, dispatch-before-provider ordering, intentional `processRunID` reuse, the Codex path, or the existing `deliveryUnknown` hold branch (`AgentModeViewModel+ScheduledSend.swift:3138-3149`).
- *Tests:*
  - A production-shaped starter returns `nil` first and commits evidence after a delay. Expect a hold, the intent kept, a transfer only after acceptance, and the previous turn unchanged.
  - The starter returns `nil` and then reports no-handoff. Expect `.failedBeforeHandoff`, with only the scheduled bubble removed.
  - Every pre-runner exit in the run service returns non-nil for Claude and ACP.
  - The real Claude runner with a delayed fake `lease.acquire()`.
  - The same for ACP.
  - Cancellation, tab replacement or shutdown during preparation.
  - Terminal attribution with a relocated input and with a newer queued user item.

#### F2 — "Send now" on an overdue new-session schedule silently does nothing (medium)

- *Observed (`cycle6.sched`):* in `needsConfirmation` / `missedWhileClosed` with `isNewSessionStart`, both menu items left the record unchanged for over a minute. "Run alongside other sessions" only set `runAlongsideOtherSessions`. There was no intent, attempt or process.
- *Cause (confirmed, code; live blocker inference):*
  - `confirmAndSendNow` returns `Void`, records consent and calls `evaluate()` (`AgentScheduledSendCoordinator.swift:995-1027`).
  - `evaluate()` silently skips new-session starts while any host reports `hasUnresolvedRecoverySession`, including when Run alongside is set (`:1729-1739`; revalidated at `:1345-1356`). This is by design (comments at `:409-410`, `:1345-1346`).
  - The gate clears for a crash hold only through explicit **It stopped** for that exact hold, and for restrictions only through schedule-transfer resolution or the next launch's inspection (`AgentRecoveryCoordinator.swift:1448-1471`). Dismiss does not clear it.
  - The workspace held many crash holds from the deliberate kill tests.
- *Open alternative:* `confirmAndSendNow` also returns early, silently, when a pending confirmation obligation exists (`:1002`), when startup admission is closed, when a transfer hold exists, or when no candidate matches. Check which applied before choosing the message.
- *Fix:*
  - Keep the gate.
  - Have the scheduler expose a per-schedule disposition (rejected, consent recorded but blocked with a reason, or progressing), derived from the same predicates admission uses.
  - Have `confirmAndSendNow` return or emit a refusal reason.
  - Show it in the schedule banner, for example "Will send after N interrupted sessions in this workspace are resolved (It stopped, not Dismiss) → Needs Attention…".
  - Keep revision-scoped consent.
- *Tests:*
  - A crash hold, a session restriction and a workspace restriction each produce visible blocked feedback.
  - Run alongside stays blocked.
  - Dismiss doesn't clear the gate; It stopped does, and the valid consent then dispatches once.
  - Every early return of `confirmAndSendNow` is covered.

#### F4 — `/compact`: a misleading "Start a Codex conversation" after a cancelled compaction (medium; thread loss refuted)

- *Observed (`cycle9.K`, session `531B9358-98FE-4770-B972-E061B16250B0`):* the first `/compact` printed "Requested Codex context compaction." and a run attempt (`DE6F5490…`) ended `userCancel`. The second `/compact` answered "Start a Codex conversation before using /compact." A later normal message resumed the same thread with its context (`cycle9.L`). A composer message typed during compaction did not submit.
- *Confirmed (code):*
  - "Requested…" means the `thread/compact/start` request returned, not that compaction finished (`CodexAgentModeCoordinator.swift:1664-1670`).
  - Cancellation detaches the controller and marks reconnect, but keeps `codexConversationID` and `codexRolloutPath` (`:10238-10260`). No thread is lost.
  - The same message has two sources: the availability check with no thread metadata (`:1587-1589`), and the post-readiness check where the controller is nil or `!hasActiveThread` after `ensureCodexNativeSession` (`:1659-1662`). The second `/compact` passed availability, so it came from the post-readiness check.
  - Return calls `sendMessage` and never cancels. The mouse Send button becomes Stop while a run is active (`AgentModeViewModel+ComposerUI.swift:17-25`, `AgentInputBar.swift:1032-1047`).
- *Inference:*
  - The `userCancel` was a click on Stop; the journal records the automation clicking Stop by mistake once before (`queuedScenario.errorLog`).
  - The 2 ms interval is not the compaction duration: a worker reported that the run-attempt record is created at terminal time (`AgentRecoveryCoordinator.swift` ~2957-2981, `AgentRecoveryStore.swift` ~1191-1200). Not spot-checked.
  - The second error was recorded 182 ms after the MCP-sent message K3 arrived, and K3 started a run on the same session about 1 s later. So two reconnects probably raced.
- *Open alternative (OracleD):* after a cancel-detach, `ensureCodexNativeSession` may never re-establish an active thread until a normal turn runs. That would make `/compact` fail deterministically after any cancel. A cancel → `/compact` unit test separates the two explanations. Also open: which guard swallowed the typed message (F7, or a silent latch or empty-draft exit).
- *Fix:*
  - Separate "couldn't reconnect / reconnect in progress" from "no conversation" in the `/compact` message and diagnostics.
  - If the race or lazy resume is confirmed, coordinate readiness at the session/controller authority, and recheck session identity, run state and eligibility after suspension, so compaction never overlaps a newly admitted turn.
  - No sleeps or blind RPC retries. Keep the reconnect metadata retention and the cancellation fences.
- *Tests:*
  - A persisted thread with a detached controller and a delayed reconnect.
  - Cancel → `/compact`.
  - A concurrent MCP submission with `/compact`.
  - Controller replacement during readiness.

#### F5 — Quit during a running Codex turn not finished after 30 s (medium; narrowed, not diagnosed)

- *Observed (`cycle9.M`):* a terminate request plus a click on the sheet's Quit did not end the app in 30 s. Tooling then killed it, and recovery correctly classified that as `appCrash` with no resend.
- *Confirmed (on-disk):*
  - A successful quit writes Stage A `runAttempts[].shutdown{appQuit}` and Stage B `terminal{appQuit, cancelled}` about 110 ms apart. Examples: sessions `A5291E56…` (Codex) and `6A56F9A3…` (Claude). The four-session quit including an active Codex turn exited in 1.12 s (`cycle7`).
  - The F5 run attempt `3F894870-E449-4FED-B5D7-5D8745C896D9` has **neither**. This session's Stage A evidence and teardown never happened. Teardown did not stall, though a stall elsewhere isn't excluded: Stage A can also skip a session with no live lane (`AgentModeViewModel+Shutdown.swift:310`).
- *Remaining explanations:*
  - The Quit click wasn't accepted: later terminate requests only return `.terminateLater` (`AppQuitPolicy.swift:53-55`).
  - Stage A stalled. After the 8-second deadline the app presents "RepoPrompt couldn't save everything before quitting" [Retry][Cancel] and waits for the user indefinitely, which is spec-consistent (`AgentLifecycleShutdownCoordinator.swift:832-866`; dialogs `WindowStatesManager+LifecycleShutdown.swift:145-176`).
  - A lead for the stall: Stage A awaits a pending composer preparation with no bound (`AgentModeViewModel+Shutdown.swift:304-309`).
  - Main-actor starvation or an obscured sheet are also possible.
- *Next:*
  - Screenshot the window about 10 s after clicking Quit.
  - Add a persisted log line whenever a quit-failure dialog is presented, plus request-ID phase timestamps, so this is diagnosable after the fact.
  - Tests: a permanently suspended preparation and a stalled teardown each present the right dialog at the single deadline; repeated quit requests don't extend it; a late completion can't complete an expired request.
- *Do not change:* the deadline or the intentional wait for the user's choice.

#### F3 — The banner header contradicts its button (low, wording)

- *Observed:* "0 saved or interrupted items need your attention." beside "Needs Attention (64)…".
- *Cause (confirmed, code):*
  - The header counts this session's rows (`AgentRecoveryListBanner.swift:87-92`).
  - The button counts every undismissed catalog item not shown here, including other workspaces (`AgentModeViewModel+RecoveryList.swift:52-55`).
  - `isEmpty` deliberately keeps the banner for the button alone (`AgentComposerUIModels.swift:393-397`).
  - Not caused by F7: the banner is hidden when the props belong to another tab (`AgentInputBar.swift:571`).
- *Fix:*
  - When there are no rows but other items exist, use neutral text, for example "Nothing interrupted in this session. N items elsewhere need attention." Keep both counts distinct when both exist.
  - Don't change catalog scope, dismissal or visibility.
- *Tests:* header text for zero-local/nonzero-other, one, many and empty, plus the dismissed crash-hold indicator.

#### F6 — The quit-failure dialog shows raw Swift error text (low, presentation)

- *Observed (`cycle8.H_shutdownFault`):* "…the message box could not be saved (store(AgentRecoveryStoreError.storageFailure(… Code=513 … mktemp … Permission denied …)))".
- *Cause (confirmed, code; matches the live text):*
  - `shutdownPreparationFailureText` interpolates the failure for `composerNotPersisted` and `evidenceNotPersisted` (`AgentModeViewModel+Shutdown.swift:380-383`).
  - That failure is the store's `String(describing: error)` (`AgentRecoveryStore.swift:2152-2154`).
- *Fix:*
  - Map typed failures to plain, actionable text at the presentation boundary: permission denied, disk full, other. Where only an opaque string exists, use a generic message rather than parsing it.
  - Keep the raw detail in redacted logs.
  - Audit other raw interpolations, such as the run-service commit-failure message (`AgentModeRunService.swift` ~650-700).
  - Keep the failure classification and the quit-blocking behavior.
- *Tests:* permission, disk-full and unknown failures produce text with no enum or `Domain=` syntax and no draft content.

#### Cross-cutting observability (cheap; land with F7/F1)

- Log a reason on every early return of `AgentInputBar.sendMessage()` and the composer submit path, not only on `view_nil_target`. This closes the F7 Tab-tag and F4 typed-message gaps.
- Persist a line, with request ID and stage, whenever a quit-failure dialog is presented (F5).
- Give the three "delivery could not be recorded" sources distinct diagnostics (F1).

#### Minor observations

- A Codex bash row can still read `success` after its command was cancelled by quit.
- The View popover swallows the next press on its row while open.
- MCP-created sessions cannot schedule (`canScheduleSend` requires no MCP control). This is by design.

### Deliberately gated, not a defect

- **Orphaned provider processes:** live, a crash leaves the Claude shim, CLI and tool running unmanaged; the app shows only the crash hold ("It stopped" / Dismiss).
- **Recovery row actions:** Continue, Send saved and the other row actions are hidden by `AgentRecoveryActionQualification.production`.
- **What exists:** Phase 3 (discovery, Let finish, Stop, two-writer rule) and Phase 4 (Resume) source is committed and reviewed but inactive by design (O9, O14).
- **What enabling them takes:** this is the remaining Step 4 qualification (actual app profile, every supported provider pair) and an explicit owner activation decision, not a bug fix.

### Not verified

- The exact rejection reason for the owner's Tab-tag first send (F7), which dialog the F5 quit was showing, why the F4 reconnect failed, and which guard swallowed the F4 typed message.
- Exact intent/ack boundaries for scheduled-send transfer steps.
- The `reserved`-record crash cut.
- A storage fault during an active run.
- Quit-latency and intent-commit performance targets.

## Owner decisions

Decision O3 (2026-10-20): Defer real-app crash testing; proceed with instrumentation and code validation, leaving live acceptance pending.
Decision O6 (2026-10-21): Use the configured 1Password signer for reviewed local checkpoints; no unsigned signing bypass is authorized.
Decision O7 (2026-10-21): Authorize one additional independent OracleA/OracleB re-review of Phase 1b input integration after the remaining fixes, beyond the normal two re-review rounds.
Decision O8 (2026-10-22): Retry signing now; unsigned local commits are authorized if signing remains unavailable, then continue implementation. This supersedes O6's prohibition on an unsigned fallback.
Decision O9 (2026-10-22): Preserve the architecture and checkpoint the reviewed inactive partial Phase 4 source; keep the older-message requirement and full Phase 4 explicitly blocked, and do not enable features.
Decision O10 (2026-10-22): Persist the OracleD/OracleE guidance and proceed with the recommended bounded source-only investigations of older saved-input canonical ownership and Claude native identity; keep automated Restart, activation, polish, retention and live acceptance deferred.
Decision O11 (2026-10-22): Implement moving or reconstructing the same unsent message at the conversation's current end, preserving its ID and saved chronology; if sending fails, leave it unsent at that new position.
Decision O12 (2026-10-23): Use OracleA and OracleB for reviews; never use OracleC unless the owner explicitly asks.
Decision O13 (2026-10-23): Continue until all work is finished before the final live verification.
Decision O14 (2026-10-23): Accept the recommendation to keep full Phase 4 blocked pending authoritative Claude history-identity evidence and resolution of the armed-helper-stop policy, with recovery activation off and live acceptance pending; use OracleA and OracleB for guidance when uncertain.
Decision O15 (2026-10-23): Proceed now to resolve the remaining Claude history-identity and armed-helper-stop prerequisites, using delegated judgement and OracleA/OracleB guidance.
Decision O16 (2026-10-23): Approve the isolated Claude session capture described in the question: configured authentication, a few trivial prompts in a temporary directory with tools disabled, reading only its new test-session history and retaining sanitized evidence; no recovery activation or app lifecycle action.
Decision O17 (2026-10-23): Select “Use my normal CLI (Recommended)” for the capture authentication prerequisite; no custom command or credentials were supplied.
Decision O18 (2026-10-23): Confirm `/Users/tnguyen/.local/bin/claude` works manually and request a dedicated worker to diagnose why the capture differs and how to correct it.
Decision O19 (2026-10-23): Approve one additional isolated prompt with only `CLAUDE_CONFIG_DIR` removed from the child's environment, using the same CLI, safe-mode/tools-disabled flags, 120-second deadline and $0.50 cap; no login changes or credential inspection.
Decision O20 (2026-10-24): Approve up to three trivial prompts across at most two Claude processes using `/Users/tnguyen/.local/bin/claude`, removing `CLAUDE_CONFIG_DIR` only in those children, in a fresh private temporary workspace with a synthetic read-only fixture; safe/restricted mode, built-in Read only where supported, no MCP or permission bypass, 120 seconds and configured $0.25 budget per process ($0.50 total), inspect only the new test-session histories; managed-policy hooks are not independently ruled out; stop if the CLI cannot support the restrictions; no credential/config inspection, global changes, app launch or recovery activation.

Decision O21 (2026-10-24): Approve the bounded no-replay capture: at most two Read-only prompts across two Claude processes, second resuming the first session, using `/Users/tnguyen/.local/bin/claude` without `--replay-user-messages`; fresh private temporary workspace and synthetic files, child-only removal of `CLAUDE_CONFIG_DIR`, safe/restricted mode, Read only, no MCP or permission bypass, 120 seconds and configured $0.25 per process ($0.50 total); stop on failure, no retry, credential/config inspection, global changes, app lifecycle or recovery activation; managed-policy hooks are not independently ruled out. This qualifies isolated CLI behavior only, not full app acceptance.

Decision O22 (2026-10-24): Approve continuing the work until the remaining blockers are resolved (owner: “then go on continue until all resolved. I approve.”).
Decision O23 (2026-10-24): Run the remaining validation up to the part requiring app stop/relaunch, and draft a low-manual-effort plan for those lifecycle steps using available external apps/agents or the debug CLI; no immediate app stop/relaunch is requested.
Decision O25 (2026-10-25): Accept Codex `queuedFallback` as passed on its unit-test coverage, since its live trigger cannot occur with an app-owned Codex app-server. Record the live-acceptance findings and evidence in this spec; the owner implements the fixes.
Decision O24 (2026-10-24): Proceed without a disposable-account requirement. Use the existing daily app for ordinary quit/relaunch durability acceptance, coordinated by Pi already running in Terminal. Diagnose the outstanding test failure, prepare synthetic drafts/queued messages/sessions and verify exact restoration. Deliberate crashes and injected storage failures remain separate and unverified until a proportionate method is chosen; recovery-action qualification remains a distinct limitation. Fresh approval is still required immediately before each visible lifecycle action.
Decision O26 (2026-10-26): Keep the live re-verification results in this spec.
Decision O27 (2026-10-26): Ignore the pre-existing full-root codemap test failure for this plan; the owner will address that test separately.
Decision O28 (2026-10-26): Recovery activation only needs Claude Code and Codex for now.
Decision O29 (2026-10-26): Re-sign the unsigned local commits now that the owner is present to approve signing.
Decision O30 (2026-10-26): Re-sign all unpushed local commits from deb4ae53 onward.
Decision O31 (2026-10-26): Fix the recovery View popover with option A, a native popover that lets outside clicks through.
Decision O32 (2026-10-26): Aim to switch the recovery actions on for all providers; the owner mostly uses Claude Code and Codex, so those are the qualified ones, and the decision is noted in code so a later provider addition knows what to qualify.
Decision O33 (2026-10-26): Delete the synthetic live-test sessions to clear their Needs Attention items.
Decision O34 (2026-10-26): Show the recovery banner only when the current session needs action, add bulk actions to Needs Attention, and separate items that need action from informational ones, guided by OracleA and OracleD.
Decision O35 (2026-10-26): Leaked unit-test workspaces in Application Support: first a small separate task that stops the tests writing there, then a dry-run list of what would be deleted for owner approval before anything is removed.
Decision O36 (2026-10-26): Proceed with the recommended Step 8-attention and 9-activation sequence as written in the synthesis (attention-activation-synthesis.md); the external verifier (Pi) runs verifier-scenarios.md.
Decision O37 (2026-10-26): Choice A: when recovery is switched on, only Claude Code (standard) and Codex register their processes; other providers launch unregistered as today and their recovery actions refuse with a named reason.
Decision O38 (2026-10-26): Step 10 is split: the other session in this working tree finishes and commits its workspace-storage test isolation; this plan fixes only the test window-session file leak (WindowSessionStore), then produces the dry-run deletion list once both are in.
Decision O39 (2026-10-27): Fix the cycle-11 verifier findings now as one small step (Step 8-verifier-fixes): F8 (a deleted session's Needs Attention rows and badge count stay until the next launch), the View popover covering and swallowing clicks on the rows above it, and the missing Check report accessibility identifier; the guide's Cancel becomes Stop.
Decision O40 (2026-10-27): The verifier deletes its three leftover synthetic sessions T2 (E1857698…), T3 (AB664854…) and T4 (D52D8872…) through the sidebar; the three other T-named sessions in NewGeneric are not the verifier's and stay.
Decision O41 (2026-10-28): Step 10b removes only the clearly-fixture leftovers: the 19,461 high-confidence fixture workspace folders, the 926 Partitions files of fixture workspaces and the 83 windowSessions.json.sb-* files, moved (never deleted) into a dated quarantine folder with a restore list by the extended quarantine script while the app is quit; the indexed benchmark/live-script and dotfiles workspaces stay, the less certain groups stay, and globalSettings is left alone.
Decision O42 (2026-10-28): After 9-live, plan the fixes with an OracleA/OracleD planning round over the three 9-live diagnosis reports before implementing; Claude's history location is learned from the `CLAUDE_CONFIG_DIR` of the real Claude process the wrapper starts, with the spec's search of known Claude roots built as the fallback.
Decision O43 (2026-10-28): Check clears a "may have been delivered" (delivery-uncertain) message of a held run once process records prove every process of that run exited.
Decision O44 (2026-10-28): A crash during a conversation's first Claude message keeps Reconcile and Continue refused for now (no `--session-id` preallocation); such crashes are rare and a normal composer send resumes the conversation.
Decision O45 (2026-10-28): The unexplained R3 rewrite of a cancelled tool row to `success` gets one bounded read-only investigation, with a fix only if it proves a wrong status; if not found, it is watched in the next live check; activation is not blocked otherwise.
Decision O46 (2026-10-28): O43 is OracleD's version: the proof (and "It stopped") moves the run's uncertain messages to delivery unknown in the same write that lifts the hold; the row becomes informational with View, Edit, Remove and Dismiss, never a resend; the message text is kept.
Decision O47 (2026-10-28): V7 (Send saved) is accepted on test evidence; no live fixture tooling is built for it.

Each has a recommended default; none blocks Phase 1.

- **O1 — Surviving processes at launch.** Default: *Let finish* and keep watching, with no automatic stop. A dev-rebuild restart shouldn't destroy a Claude turn that is still finishing.
- **O2 — What a Resume click does.** Default: send immediately, with the continuation text visible and editable in the card. A secondary *Edit first* action puts it in the composer instead.
- **O3 — How to test against a real app kill.** About ten stores hard-code `Application Support/RepoPrompt CE`, so a second instance would share live data. The options:
  - (a) a DEBUG-only Application Support root override honored by every store, which needs an audit of those stores, the MCP socket paths, and the Keychain service;
  - (b) a disposable macOS test account, which needs no code but does need the provider CLIs, shims, and logins set up there.

  These are isolation options for deliberate crash/fault tests only. Per O24, neither is required for ordinary quit/relaunch acceptance on the daily app. Choose a proportionate isolation method separately if destructive tests are later authorized.
- **O4 — Composer durability.** Default: a 300 ms write debounce with a 2-second maximum delay, and no Saving/Saved indicator.
- **O5 — What "durably queued" means to MCP callers.** Default: the item survives a restart as held input that needs one click. It is never auto-sent.

## Phasing

0. **Measure and prepare** (no behavior change):
   - Add the save counters and measure starvation and serialization cost (R3).
   - Locate the session-incarnation authority (R1).
   - Inventory every queued/delivered acknowledgement site and every provider handoff route.
   - Check whether any controller spawns `claude --resume` eagerly when a session hydrates. If one does, a relaunch could start a second writer next to a surviving orphan before Phase 3, so that path joins Phase 1's crash hold.
   - Settle O3.
1. **Stop losing what's typed and queued.** This splits into two independently shippable parts:
   - **1a (small):**
     - the 10-second transcript maximum wait, with buffered text drained before cleanup;
     - flushing dirty, fully hydrated sessions before teardown, with a second pass after terminal commits;
     - window-close preservation inside `prepareSessionForWindowClose`.
   - **1b:**
     - the recovery store and records, and the durable session stub;
     - composer persistence;
     - intents for **every** send route;
     - the Codex fix with receipt-gated acknowledgements, landed together;
     - the scheduled-send receipt transfer **with** the startup barrier;
     - preserve-versus-withdraw;
     - the two-stage quit with its point of no return;
     - the R1a reconciliation rules;
     - held recovered input with *View* / *Edit* / *Remove*;
     - a **crash hold**: in a session whose last attempt was open at an unclean exit, every send route (composer, MCP, scheduled) requires a confirmation that "the previous run may still be running" until Phase 3 replaces it with the registry.
2. **Honest interruption:** launch state, the turn `interruption` record, the recovery catalog and banner, index schema 8, and question snapshots. No Resume yet.
3. **Process registry:**
   - the pre-spawn reservation, marker, and birth identity;
   - Claude `--session-id` preallocation;
   - discovery, exit watching, Let finish, and Stop;
   - the two-writer rule, which replaces the crash hold;
   - live gates for marker propagation and startup hooks.
4. **One-click Resume:** Claude history import, Codex reconciliation, the Resume action and dispatch permit, the checkpoint card seam, and Restart safely.
5. **Later:**
   - pending edit-review persistence;
   - `agent_run` parent/child linkage;
   - ACP and Oh My Pi qualification;
   - the Claude detach-on-restart experiment;
   - durability hardening, shared with the checkpoint spec's Phase 3.

## Validation

### Unit tests

New suites go under `Tests/RepoPromptTests/AgentMode/Recovery/`. They cover:
- record round-trips, including unknown versions, unknown members, and corrupt files;
- revision conflicts, tombstones, and reset retargeting;
- the R1a joins: unaccepted intent with a saved bubble; accepted intent with no bubble; terminal evidence against an open turn; an attempt that exists only in the recovery record;
- acknowledgement outcomes at each boundary: commit failure, stale target after the commit, and bookkeeping failure after handoff;
- a concurrent same-ID enqueue producing one intent;
- the composer maximum delay and the transcript maximum wait under a fake clock;
- cold restore writing the per-attempt reason, without touching turns the user cancelled;
- registry classification with faked inspection: a reused PID with a different start time, a descendant found by marker, a `reserved` record without a process, and denied inspection classified as unknown;
- two-writer refusal, and tool-only survivors not blocking;
- the catalog snapshot matching rendered rows;
- the scheduler treating a session with an unresolved interruption as busy.

### Crash cuts

These need O3. Kill RepoPrompt at each point and check the result:

| Kill point | Expected after relaunch |
|---|---|
| Before an intent commit | No success acknowledgement was sent |
| After the intent commit, before the acknowledgement | One recoverable intent |
| After the acknowledgement, before the queue drains | The full payload survives |
| Just after a direct Send | The message is held, or `deliveryUnknown` |
| Between scheduled-send transfer steps | No duplicate |
| Mid-stream | Interruption recorded; transcript staleness within the measured maximum wait |
| During quit Stage A, then during Stage B | Stage A: the app stays usable. Stage B: the next launch treats the sessions as uncertain |
| After a `reserved` record, before identity is filled | Ownership unresolved |

### Shutdown-failure tests

- A Stage A failure followed by Cancel quit, more interaction, and another quit.
- A Stage B failure followed by Retry flush.

### Live acceptance

First exercise ordinary preservation on the daily app with an external Terminal coordinator (O24): bind a current candidate, prepare synthetic composer/attachment/queued-input state through normal app paths, obtain fresh approval for normal quit/relaunch, and verify exact restoration with no automatic resend. A bootstrap from an older running build does not prove the candidate's pre-quit behavior. Keep recovery activation off; UI-only checks need actual UI interaction.

The advanced provider/crash qualification cases below remain separate. Use the real shims; for destructive cases choose and verify an O3 isolation option before obtaining fresh scenario-specific approval:
- a Claude foreground tool followed by a new tool;
- Claude with a background child;
- Claude with an unanswered stdio permission request (this decides O1's advice);
- Claude mid-call to a RepoPrompt MCP tool;
- Claude startup hooks;
- `claude --resume` with a dangling `tool_use`;
- a Codex command in progress, then `thread/resume`;
- marker propagation through both shims and both providers' tools;
- Cmd-Q with several running sessions, recording quit latency.

Record process identities, recovery records, transcript IDs, marker files, and click counts. The throwaway-parent experiments above are design evidence only; they must not be cited as passing these tests.

### Performance

On the owner's Mac:
- intent commit latency p95 ≤ 50 ms;
- composer writes never block typing;
- a quit with 5 active sessions finishes in ≤ 8 s.

## Owning seams

**New in AgentCore:**
- `AgentMode/Models/AgentRecoveryModels.swift`;
- under `AgentMode/Runtime/Recovery/`: `AgentRecoveryStore.swift`, `AgentRecoveryCoordinator.swift`, `AgentProcessRegistry.swift`, and `AgentProviderRecoveryAdapter.swift`;
- `AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift`;
- `AgentMode/Runtime/Codex/CodexRecoveryAdapter.swift`, a facade over the existing reconciliation.

**New in Platform:** `Infrastructure/Process/ProcessInspection.swift`. `ProcessLauncher.swift` also gains the optional environment marker and returns the birth identity.

**Changed in AgentCore:**
- `Runtime/Session/AgentTabSession.swift`: identifiable queue values with intent IDs, held recovered input, `composerRevision`;
- `Runtime/Codex/CodexAgentModeCoordinator.swift` and `CodexSteerAckTracker.swift`: async enqueue and receipts;
- `ClaudeNativeProcessSessionController.swift`: reservation, registration, `--session-id`;
- `Runtime/AgentSession.swift`: the turn `interruption` record;
- `AgentSessionRestoreSupport.swift`: the recovery context, with per-attempt reasons recorded before sanitizing;
- `AgentSessionMetadataIndex.swift`: schema 8;
- `Runtime/Scheduling/AgentScheduledSendCoordinator.swift`: the startup barrier and busy inputs.

**App:**
- `AgentModeViewModel.swift`: send and composer integration, preserve-versus-withdraw inside `prepareSessionForWindowClose`, the flush before teardown, the maximum wait, delta draining;
- `AgentModeViewModel+ScheduledSend.swift`: the receipt transfer;
- new `AgentModeViewModel+Recovery.swift`;
- `AppDelegate.swift` and `WindowStateManager.swift`: the two-stage, bounded shutdown;
- `WindowCloseCoordinator` and the quit confirmation wording;
- new recovery banner, Needs-attention sheet, and `AppRelaunchCoordinator.swift`.

**Docs:** when this lands, update `docs/context/agent-scheduled-messages.md` for queued-versus-accepted semantics and the recovery admission contract.

## Review record

**Round 1, 2026-10-18 (OracleD and OracleE, identity verified).**
- *P0 fixed: cancelling quit after teardown.* Both Oracles found that a failure after teardown could not safely cancel the quit. Fixed with R4's two stages and point of no return.
- *P1s resolved:*
  - durable intents for direct sends (R2);
  - composer coverage and its maximum delay (R2, O4);
  - two-file reconciliation (R1a);
  - the scheduler barrier moved into Phase 1 alongside the receipt transfer;
  - an admission hold for crash-interrupted sessions in Phase 1;
  - how the provider home is learned (R6);
  - window close never marking the launch clean (R4);
  - outcomes by boundary (R2);
  - a pre-spawn reservation replacing both registration proposals (R6);
  - a stricter Claude completion test (R7);
  - the transcript maximum-wait hook and delta draining (R3).
- *P2s resolved:*
  - window-layout order;
  - optimistic composer clear;
  - tool-only survivors;
  - stale target after a commit;
  - skipping partially hydrated sessions;
  - remote-host scope;
  - `--session-id` moved to Phase 3;
  - Phase 1 versus Phase 2 interruption data;
  - the window-close seam;
  - the eager `--resume` check;
  - exit watching for every member.
- *P3 corrections applied:* line references fixed, the existing save counter cited, the `previousInstance` hold made derived, and record lifecycle, registration failure, and the Stop preview specified.
- *Rejected alternatives the reviewers accepted as sound:* no continuous polling; no bundling of follow-ups into Resume; detach deferred; no Saving/Saved indicator; the interruption record kept in session JSON.
