# Verifier results: 9-live, recovery activation switched on (2026-10-28)

Scope: read when the task touches the results of the 9-live run of lossless-restart recovery with activation switched on.
Authority: Reference
Last-verified: 2026-10-28
Covers: what the external verifier ran on the activation-on candidate build, what passed, what failed, and what still needs a fixture or another kill

## The run

- **Build:** commit `74edea8b` plus the uncommitted `AgentRecoveryActivation.production = .claudeAndCodex`. Provenance `74edea8b`, dirty, built 15:02. App PID 11613; after the one approved kill (15:36:46), PID 15553.
- **Providers:** Claude Code (Haiku, low) and Codex CLI only. V3 skipped (no 9-stop entry point). V9 skipped (the owner uses neither OpenCode nor Oh My Pi).
- **Approvals:** one SIGKILL of the app plus relaunch ("kill round 1", owner, 2026-10-28). No other kill, quit, relaunch or signal. No provider process was signalled.
- **Universal hard fail:** none. Every send was a requested `RPCE_VERIFY_*` prompt and appears once in the provider's history. Claude Code itself adds `tool_result` and `<task-notification>` user entries at resume; those are not RepoPrompt sends.
- **Raw evidence:** `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle13/` (`setup/fixtures.json`, and `results.json`, `notes.md` and screenshots per group), journal key `cycle13`.

## Results

| Scenario | Result | Evidence and exact UI text |
|---|---|---|
| V1 (Claude survivor) | **Partial: survivor half not shown.** | `RPCE_RUNTIME_ID` is on the `bash -c` parent and on `claude` (`ps eww`), not visible on `sleep` (SIP). The Claude process survived the kill, but its `sleep 590` exited on its own 1 min 46 s after relaunch, before any check. No surviving-process item appeared at any time. After It stopped, a send was accepted once (`RPCE_VERIFY_V1_20261028 after`). Not shown: an item naming provider, PID and worktree; refusal while alive; Let finish; Refresh clearing it. |
| V2 (Codex) | **Pass, with a guide mismatch.** | Shim, `codex` and `sleep` all exited with the app (ps 3 s after the kill); no survivor item. Check then confirmed the hold: "Sending paused · T9 — Resolved: Process records show every process of the interrupted run exited." The guide's "the crash hold remains until It stopped" predates Step 9-activation-b. |
| V4 (Codex Reconcile ×2) | **Partial.** | Run on T14 (F8's turn finished before the kill). Both runs: "The interrupted Codex turn wasn't identified, so its history can't be matched." 0 rows; no new Codex turn or process. See finding R2. |
| V5 (Claude Reconcile ×2) | **Partial.** | Run on T11. Both runs: "No history position was saved before the interrupted run, so its history can't be matched safely. Nothing was imported." No `claude --resume`. See finding R1. |
| V6 (Continue, double-click Send) | **Partial.** | Codex T14 and Claude T11 each: exactly one `continueWithText` action, `notDispatched`, with the typed reasons above; nothing sent; the second click joined. Never a fresh conversation. A real continuation was not reachable (R1, R2). The Claude kill-during-a-tool case needs another kill. |
| V7 (Send saved ×2) | **Not run.** | No fixture: a follow-up sent during a running turn became a live steer on both providers (Claude's interrupted the running Bash). No `queued` intent existed, so no Send saved button. |
| V8 (Send answer as message) | **Not run.** | Codex has no question tool. The Claude question expired (5-min timeout) and had no partial answer, so the row offered View / Restore / Remove saved question / Dismiss only. |
| A8 | **Pass.** | Reconcile from an Information run note: the row left Information while it ran, the banner showed the greyed run row, the row came back afterwards; no text lost. |
| A9 | **Not run.** | Needs a live old process; none existed. Related, from V6: after a refused Continue the row moved to Needs action, but its detail did not end with "The message you typed to continue it was not sent." (R4). |
| C2 | **Partial.** | Report: "Checks process ownership and provider history, and confirms a paused session stopped when process records prove its processes exited. Clearing a restriction or confirming a paused session may let already-authorized scheduled sends run." The first phase was "Refreshing process ownership…" (seen on the second run). "Checked 41 of 41 · 3 resolved · 25 need you · 12 could not check · 1 failed". Not open: "Could not check: Open this session to check its provider history." Saved message and question: "Needs you". Run-attempt counts unchanged. Missing ingredients: no live Claude process, and the Codex run did not finish while closed (it died with the app); with its session open, history matching failed (R2). |
| Crash hold confirmed by Check (9-activation-b) | **Pass for Codex; Claude not shown.** | Codex T9, T14 and F4: confirmed without opening the session ("Resolved: Process records show every process of the interrupted run exited."), `crashHoldAcknowledgement` written, banners gone. Claude T7, whose process had exited: not confirmed, "Needs you: Confirm the previous run stopped (it has a saved message or an older interrupted turn)", because its first message stayed `dispatching` (R1, R3). The clean Claude no-tool case and the live-process case need another kill. B-R1-04: no runtime record named more than one session. |
| P5, steps 1–13 | **Fail (Esc).** | See below. |

### P5 and its neighbours (fix-p5-esc-worker.md, steps 1–13)

The binary contains the P5 fix (`AgentRecoveryNativePopoverKeyFocus`). Esc was sent as a System Events key code 53 after a real click on View.

| Step | Result |
|---|---|
| 1 P5 banner | **Fail.** One Esc, then a second, left the popover open; the next letter went into the composer ("abcd"). |
| 2 P5 sheet | **Fail.** One Esc closed the popover and the Needs Attention sheet together (twice). |
| 3 Esc with no popover | Composer unchanged (pass); sheet half not run separately. |
| 4 Typing while open | Observation: the letter goes into the composer; the popover does not take key; no beep. |
| 5 P1 / P7 | Pass (banner and sheet). |
| 6 P2, 7 P3, 8 P4 | Pass. |
| 9 Selectable text | Text selected and copied, popover stayed (pass); Esc then did not close it (fail). |
| 10 P8 | Pass: File > New Window opened a Welcome window; one click in it closed the popover. |
| 11 P9 | Closed on return and reopened with one click (pass); main window key; Esc right away did not close it (fail). |
| 12 P11 | Pass: closed, sheet kept focus, typing did not reach the composer. |
| 13 P10 | Partial: the row was removed while open (its own Dismiss, by AXPress) and the popover went with it. `log stream` over the step: 0 "Modifying state during view update" / "Publishing changes from within view updates". No Xcode console. The returning-row half was not run. |
| Extra: Esc during a running turn | The turn was not interrupted; the popover also did not close. |

Step 4's observation (the popover never takes key) suggests the fix's key hand-off did not happen on this build; inference, not traced in code.

## Findings for the main agent

- **R1 (confirmed live, cause inferred).** A Claude session's first message whose turn is still running at a kill stays `dispatching` (T7, T11; T4's retry `deliveryUnknown`), while Codex intents reach `providerAccepted`. Effects seen: the "Message may have been delivered" row; Check refuses to confirm the hold ("it has a saved message or an older interrupted turn"); Reconcile and Continue report "No history position was saved…".
- **R2 (confirmed live).** For Codex T9 and T14, with the session open, history matching fails: "The interrupted Codex turn wasn't identified, so its history can't be matched." The rollouts hold one `task_started` and one `turn_aborted`.
- **R3 (confirmed live).** T7's transcript still shows its Bash row with a running dot hours after the tool died.
- **R4 (confirmed live).** After a refused Continue, the row detail lacks "The message you typed to continue it was not sent.", and reopening Continue… shows the default text instead of the typed text.
- **R5 (observed once).** A Continue… editor popover on T11 closed on its own about 40 s after opening, taking the typed text with it; nothing was sent. On T14 it stayed open about 1 min.
- **R6 (confirmed live).** P5: Esc does not close the View popover in the banner, and in the sheet it closes the sheet too.
- **Guide mismatch.** V2's "the crash hold remains until It stopped" no longer holds once Check can confirm a hold.

## Kill round 2 (2026-10-28 17:26)

Owner approved a second SIGKILL. App PID 15553 killed at 17:26:38, relaunched as PID 826. Synthetic Claude sessions: K1 T15 `048632F3-15F0-4976-B556-9332457379C2` (a 9.5-minute Bash loop), K2 T17 `1D281185-1275-4B79-925B-3EFD28EB4928` (a no-tool turn running at the kill), K3 T16 `66827DF5-AD1E-4C26-8056-58B446EA3CBF` (a short Bash tool mid-call). No hard fail: the Claude histories hold each requested prompt once, and the refused A9 text is in no history. Raw evidence: `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle14/k2/`.

| Scenario | Result | Evidence and exact UI text |
|---|---|---|
| V1 survivor item | **Pass.** | Banner in T15: "An agent process is still running · … Claude from an earlier launch of RepoPrompt (1 process found, started as PID 7048). Worktree: /Users/tnguyen/workspace/repoprompt-ce-personal-touch. Conversation: 4c341b46-… Sending to that conversation stays paused…" with Refresh and Let it finish. `RPCE_RUNTIME_ID` on the surviving processes. The item showed only once T15 was open; the sheet list a minute after relaunch had no such row. |
| V1 refusal while alive | **Partial.** | Return and the Send button both refused silently, with no message; the typed text stayed in the composer. |
| V1 Let it finish | **Pass.** | "…stays paused until it exits. You chose to let it finish…" with Refresh. |
| V1 Refresh, sending resumes | **Partial.** | After the loop ended (17:34:04), Refresh cleared the survivor item, but sending stayed paused: "The previous run may still be running" and "Message may have been delivered" remained (R1). After It stopped, one send was accepted and appears once in Claude's history. |
| A9 | **Fail (R4).** | K1 offered no Continue… (only It stopped and Dismiss). On K3, a refused Continue left the row under Needs action with "No history position was saved before the interrupted run, so its history can't be matched safely. Nothing was imported." and no "The message you typed to continue it was not sent." A following Reconcile left it under Needs action (that half passes). Reopening Continue… shows the default text; the typed text is only in the record's action. |
| Live-process Check (C2 part) | **Partial.** | With the K1 process alive: "Checked 44 of 44 · 32 need you · 12 could not check"; "Sending paused · T15 — Needs you: Confirm the previous run stopped (it has a saved message or an older interrupted turn)". The hold was not confirmed, but for the R1 reason; no captured line named the live process. |
| Check confirms a clean Claude hold (K2) | **Fail (R1).** | The turn was running at the kill. Check: "Sending paused · T17 — Needs you: Confirm the previous run stopped (it has a saved message or an older interrupted turn)". |
| V6 Claude kill during a tool (K3) | **Pass (refusal).** | It stopped, then Continue… with edited text and a double-clicked Send: one `continueWithText` action, `notDispatched`, with the typed reason above; nothing sent; no fresh conversation; the second click joined. No real continuation was reachable. |

**R1 confirmed on all three Claude fixtures:** each first message was `dispatching` before the kill, after the relaunch, and at the end. It blocks Check from confirming a Claude hold, keeps sending paused after Refresh, and makes Reconcile and Continue refuse.

**R7 (observed).** The survivor item appears in the session's banner only after the session is opened; the Needs Attention sheet did not list it a minute after relaunch.

## Still to run

- After R1 is fixed (each needs another approved kill): Check confirming a clean Claude hold; V1's "sending resumes after Refresh"; a real Reconcile import and a real Continue on Claude; A9's row detail once R4 is fixed.
- After R2 is fixed: Codex Reconcile and Continue, and C2's "finished Codex run → resolved via history".
- V7 and V8 need fixtures that this build doesn't produce from the composer (a held `queued` follow-up; a question with a partial answer).
- P5 after R6 is fixed.

## Cleanup

Synthetic sessions created, all in workspace `repoprompt-ce-personal-touch`, not yet deleted (owner approval pending). Kill round 2: T15 `048632F3…`, T16 `66827DF5…`, T17 `1D281185…`. Kill round 1: T2 `2F9EF210…`, T3 `4147D169…`, T4 `7EB810F5…`, T5 `268A360D…`, T6 `B8318C5D…`, T7 `3BC977C7…`, T9 `B03D7B42…`, T10 `614B8A17…`, T11 `5FCE22D3…`, T12 `424DCD0B…`, T13 `280AA254…`, T14 `FC416780…`, "Foreground sleep 1500 verification" `EFBE02CD…`, "RepoPrompt CE Session" `4F2FE77B…`. Full IDs: `cycle13/g4-p5/cleanup-list.md`.
