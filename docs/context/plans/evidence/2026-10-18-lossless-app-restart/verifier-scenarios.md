# Verifier live scenarios for Steps 8 and 9 (draft)

Scope: read when the task touches live verification of the recovery banner popover, Needs Attention changes (O34), Check and resolve, or activated recovery actions (O32).
Authority: Reference
Last-verified: 2026-10-28
Covers: scenarios the external verifier (Pi in Terminal, using rpce-cli-debug and accessibility tools) runs after each step lands; merged from the OracleA and OracleD scenario lists. Draft: accessibility IDs and wording are confirmed per step as the code lands.

## Ground rules for the verifier

- Run against the Dev build named in the step's commit; record the commit hash, app PID and provider (Claude Code or Codex) for each scenario.
- Use only synthetic sessions named `RPCE_VERIFY_<scenario>_<date>`; never touch the owner's real sessions. Record every session ID created.
- Ask the owner for approval immediately before each app kill, relaunch or quit, and before any process signal. A scenario with a "Kill/relaunch" mark cannot start without it.
- Evidence per scenario: screenshots or accessibility dumps of the banner/sheet, the session's recovery record (`~/Library/Application Support/RepoPrompt CE/AgentRecovery/v1/sessions/<id>.json`, read only, never edited), `ps -eo pid,ppid,pgid,comm` before and after for process scenarios, and the provider's own history (Claude JSONL / Codex thread) for send counts.
- Universal hard fail: any message sent to a provider that the steps did not ask for, any second copy of a message, or any lost typed text.
- Afterwards, delete the scenario's synthetic sessions through the UI (with owner approval) and list what was deleted.

## Housekeeping (before the first scenario, owner approval)

H1. Delete the 14 leftover synthetic sessions from the earlier live run through the UI. The main agent holds the list (titles T2–T14, "Restart acceptance M: 600s foreground wait", RPCE_RESTART_ACCEPTANCE_20261025_Z). Pass: they disappear from the sidebar and their Needs Attention items go with them at once, without a relaunch: in every open window the banner and sheet drop their rows and the sidebar badge (`agent.recoveryNeedsAttention.sidebarButton`) stops counting them (F8 re-check).

## Step 8-popover (no kill)

P1. On a row with a View button, open View; with it open, click Edit (or Remove / Restore / Discard…) once. Pass: popover closes and the button acts on the same click. Overlap re-check: with two or three banner rows, open View on the lowest one. Pass: the popover opens above the banner, over the transcript, and covers no row or header button; one click on a button of a row above it closes View and acts.
P2. Open View, click once in the composer. Pass: closes and the composer has focus; typing works at once.
P3. Open View, click a sidebar session or toolbar button once. Pass: closes and that item activates.
P4. Open View, click View again. Pass: closes and stays closed; a third click reopens.
P5. Open View, press Escape right away without clicking inside. Pass: closes on that press, and only the popover closes (in the sheet, the sheet stays open). After Step 9-live-fixes (1), run the 15 manual steps in [fix-9live-esc-worker.md](fix-9live-esc-worker.md), "Manual steps for the live verifier", plus E1 below.
P6. On an edit-proposal row: open View, wait for the comparison line to change from "Comparing with the current file…", close, reopen. Pass: the result appears on the first open and is recomputed on the second, never stuck or stale.
P7. Same as P1 from the Needs Attention sheet. Pass: same as P1, except that the popover opens beside the sheet, over the window behind it, and covers no row or sheet button; one click on any other row's button closes View and acts.
P8. With View open, click a control in another RepoPrompt window once. Pass: the popover closes and that window activates; normal macOS first-click rules apply there (a second click may be needed), and nothing else changes focus.
P9. Cmd-Tab away with View open, come back, click View once. Pass: it had closed; reopens with one click.
P10. Open View, then remove that row while it is open (act on it from the sheet or another window); when a row with a View button appears again, click View once. Pass: the popover went away with the row, and View opens with one click (never looks dead).
P11. Open View inside the Needs Attention sheet, then click the window behind the sheet, outside the popover. Pass: the popover closes; keyboard focus does not land in the composer behind the still-open sheet.

## Step 8-attention (no kill unless marked)

A1. Clean session open while another session has a saved unsent message. Pass: the clean session shows no recovery banner; the other session shows its banner; the sidebar badge counts needs-action items only.
A2. Kill/relaunch: kill the app mid-turn (Claude). Relaunch, open Needs Attention. Pass: crash hold under Needs action; the run note under Information (collapsed); the badge does not count the run note.
A3. After A2, click It stopped, send a new message normally, reopen the sheet. Pass: the run note is gone from Information; "Show dismissed and cleared" shows it marked as cleared; no new acknowledgement was written to the record for it.
A4. Bulk Dismiss on Information with three notes: click `agent.recoveryNeedsAttention.dismissAll.informational`. Pass: no confirmation; the summary `agent.recoveryNeedsAttention.bulkSummary` reads "Information: Dismissed 3 of 3"; each record has an acknowledgement; saved inputs, questions and crash holds unchanged.
A5. Bulk Dismiss on Needs action when the section also holds a card without Dismiss (a save failure or a surviving process) and at least one card from another workspace: click `agent.recoveryNeedsAttention.dismissAll.needsAction`. Pass: the confirmation title counts only the dismissible cards and says how many are in other workspaces (e.g. "(1 in another workspace)"); its text says Dismiss only hides cards; after `agent.recoveryNeedsAttention.dismissAll.needsAction.confirm` the card without Dismiss is still shown; crash holds still pause sending (the "Sending is paused" row remains). There is no per-workspace bulk button (owner may ask for one).
A6. Start a bulk Dismiss and change one item before it is reached (for example, restore its draft in another window). Pass: that item is reported skipped/changed, never dismissed in its new form.
A7. Sheet sections: open Needs Attention. Pass: header `agent.recoveryNeedsAttention.section.needsAction` reads "Needs action (n)" and the disclosure `agent.recoveryNeedsAttention.section.informational` reads "Information (m)", collapsed (accessibility value `collapsed`); n equals the sidebar badge (`agent.recoveryNeedsAttention.sidebarButton`); turning on Show dismissed does not change n or m.
A8. Section move during an action (after activation): on a run note in Information, start Continue or Reconcile. Pass: the row may move to Needs action while the action runs and back afterwards; no confirmation or typed text is lost, and the composer banner flash is acceptable only while the action runs. Record what happens.
A9. Unsent continuation (after activation, Claude or Codex): type a continuation that is refused before sending (e.g. while the old process may still be running). Pass: the run row is under Needs action and its detail ends with "The message you typed to continue it was not sent."; a following Reconcile that does not confirm completion leaves it under Needs action.
A10. Stop and frozen set: with five or more needs-action cards, start the bulk, then click `agent.recoveryNeedsAttention.bulkCancel` after the first card. Pass: it stops before the next card and the summary says how many were dismissed; a card that was busy (its own Dismiss in progress) when you clicked is reported as skipped (busy) and never dismissed by the bulk, even if its own Dismiss then fails.
A11. Close the sheet after a finished bulk and reopen it. Pass: the old summary is gone. Close the sheet while a bulk is running. Pass: the bulk continues (records keep getting acknowledgements) and its summary is shown on reopening.

## Step 9-check

C1. Before activation: run Check and resolve on existing items. Pass: report says process and provider-history checks are not active; nothing is resolved automatically; no session is opened; no message is sent.
C2. Kill/relaunch, after activation: mixed state (one Claude process still running a long tool, one Codex run that finished while closed, one unsent saved message, one pending question). Open the finished Codex session in a window, then run Check (`agent.recoveryNeedsAttention.check`) from that window. Pass: report (`agent.recoveryNeedsAttention.checkReport`) shows a "Refreshing process ownership…" phase first and warns that clearing a restriction may let already-authorized scheduled sends run; running process → "needs you" (Let it finish or Stop); finished Codex run → resolved via history; run cards of sessions not open in that window → "Open this session to check its provider history."; unsent message → "needs you"; question → "needs you"; nothing sent; run-attempt counts unchanged. The finished-Codex part is **not reachable live**: the app-owned Codex app-server exits with the app, so no Codex run finishes while the app is closed. It is accepted on unit coverage; record it as not reachable.
C3. Click Stop on a running Check part-way. Pass: completed items stay completed; remaining items untouched; the report says cancelled.

## Step 9-activation (Claude Code = C, Codex = X)

V1. Kill/relaunch (C): kill the app during a long Bash tool (`sleep 900` or longer) in a session that already has one completed turn. Before the kill, confirm the child process carries the `RPCE_RUNTIME_ID` marker (`ps eww <pid>`). Relaunch and run V1 first. Pass (Refresh clears the survivor; Check then lifts the hold):
- a surviving-process item names provider, PID and worktree (record whether the Needs Attention sheet lists it before the session is opened; survivor items come first in the list);
- a send to that conversation is refused while it lives: a refusal notice is shown and stays until the next edit, send attempt or tab change, and the typed text stays in the composer;
- Let finish keeps the item with "You chose to let it finish";
- after the process exits, Refresh clears the survivor item; sending stays paused, because Refresh does not confirm the crash hold;
- Check (`agent.recoveryNeedsAttention.check`) then confirms the hold ("Resolved: Process records show every process of the interrupted run exited."); the run's "Message may have been delivered" row, if any, becomes informational with "Its run stopped before the provider confirmed it. It won't be sent again.", and offers no Send saved;
- one send is then accepted and appears once in Claude's history.
V2. Kill/relaunch (X): same as V1. Pass (Check confirms the hold; It stopped is the fallback): if Codex children exit with the app, no survivor item after Refresh; Check confirms the crash hold without opening the session ("Resolved: Process records show every process of the interrupted run exited.") and sending resumes. Use It stopped only if Check does not confirm, and record Check's exact reason.
V3. Stop (C), only if Stop is wired: on a disposable survivor, open Stop, cancel once, then confirm. Pass: cancel signals nothing; confirm signals only the listed PIDs (compare `ps` before/after); final rediscovery decides success.
V4. Kill/relaunch (X): Reconcile twice after It stopped. Pass: first run imports rows and records how the turn ended; second run imports 0 rows; no new Codex turn exists.
V5. Kill/relaunch (C): Reconcile twice; watch `ps` for any `claude --resume`. Pass: rows imported and marked recovered, completion shown as unconfirmed; second run 0 rows; no Claude process started.
V6. Kill/relaunch (X, then C): It stopped → Continue… → edit text → Send; double-click Send. Pass: exactly one continuation and one run attempt; same thread/session ID in the provider's history; the second click joins, it doesn't resend. For C, also kill during a tool call: Continue either works or refuses with a typed reason, never starts a fresh conversation.
V7. Kill/relaunch (X, C): kill while a queued follow-up is saved but unsent. Relaunch → Send saved, click twice. Pass: one dispatch, provider history shows one copy; on refusal it stays unsent. **Not reachable from the composer**: a follow-up during a running turn becomes a live steer on both providers, and the Codex fallback queue can't trigger with an app-owned app-server. Accepted on unit coverage (owner decision D3, like O25); record it as not reachable.
V8. Kill/relaunch (C; Codex has no question tool): kill while a question is pending and a partial answer is typed into it, within the question's 5-minute timeout. Relaunch → Send answer as message. Pass: a new user message is sent; no old question callback fires; double click sends once.
V9. Unqualified provider sanity (OpenCode or Oh My Pi, if the owner uses one): kill/relaunch mid-turn. Pass: actions either work through the same fences or refuse with a visible reason; never a silent send.

## Fixture notes (9-live re-check)

- Every Claude kill fixture runs one short completed turn before the kill turn. A first-message crash has no saved history position, so Claude Reconcile and Continue refuse there by design (first messages stay unsupported); the hold is still confirmed by Check.
- The Claude session's history file (`<conversation-id>.jsonl` under a Claude profile's `projects/*/`) must exist before the kill.
- V1's Bash tool runs `sleep 900` or longer (the earlier `sleep 590` exited 1 min 46 s after relaunch), and V1 is run first after the relaunch.
- V8: type a partial answer into the pending Claude question and kill within its 5-minute timeout.
- V7 and C2's finished-Codex case are not reachable live with an app-owned Codex app-server; they are accepted on unit coverage.
- Codex Reconcile needs two fixtures: one interrupted turn with no tool calls, and one with a tool call.

## Step 9-live-fixes additions (round-2 re-check)

The round-2 run order, fixtures and safety rules are in [verifier-9live-r2-brief.md](verifier-9live-r2-brief.md).

E1. P5 step 11 (selectable text): open View, drag to select text inside, press Cmd-C, then Esc. Pass: the popover closes on one Esc. Then type one letter: it lands in the composer (banner case) or focus stays in the sheet (sheet case). Record whether Cmd-C copied the popover's text or the composer's selection; a Cmd-C failure is a separate finding (it predates the fix), not a P5 failure.
E2. Continue draft on a finished survivor: on the run card of a survivor whose turn finished in the provider's history (V1's session after its process exits and Check lifts the hold), type text in Continue…, close the editor without sending, then click Reconcile (Check history), which finds the turn completed. Pass: the typed text lands in the session's message box, with "This card no longer offers Continue, so the message you typed for it wasn't sent. It's now in the message box." Nothing is sent.
E3. Restore with a held-back draft: with a Continue text held back because the session has an unresolved saved draft ("Your message wasn't sent. Resolve this session's saved draft first; your message is kept and then moves to the message box."), click Restore on the saved draft. Pass: the message box holds both texts, the restored draft first, then the Continue text after a blank line; nothing is lost or sent.
E4. Open with no window: when a Continue result arrives while no window has its session open, the row (listed under "Show dismissed and cleared") reads "Your message wasn't sent. Open this session to get it back in the message box." Click Open. Record whether the text arrives in the message box or the "Resolve this session's saved draft first" message appears instead (a known caveat: the opened session may not be ready yet). The text lives only in memory, so a quit loses it (known, deferred). Record "not reached" if no fixture produces it.
E5. Known duplicate: after a Continue whose not-sent result couldn't be recorded ("Nothing was sent, but that couldn't be recorded. Your message is now in the message box.") and a relaunch, the text may show both in the message box and as the card's prefilled Continue text. This is a known duplicate of text, not a send; it fails only if anything is sent twice. Record "not reached" if no fixture produces it.
E6. Edit of a settled Claude message, then relaunch (approval first): after Check or It stopped settles a Claude "Message may have been delivered" row, click Edit (its text moves to the message box; don't send it). Relaunch. Pass: no crash hold returns for that run, the row doesn't come back as needs action, and nothing is resent (Claude's history unchanged).
E7. Claude history location (no kill): in a fresh Claude session, send three short turns. After the second send, read the runtime record (`AgentRecovery/v1/runtimes/<runtimeID>.json`, read only) and record its `providerHome`. Record:
- whether a fourth registry refresh happened for that runtime (at most three are allowed; there is no log line, so infer it from `providerHome` being set and from send latency not growing after the third send, or record "not observable");
- send latency with activation on (Return to the first transcript activity), for each of the three sends;
- whether the conversation file `<conversation-id>.jsonl` exists in more than one Claude profile (`ls` the `projects/*/` directories of `~/.claude` and each rotator profile, read only). If it does, Claude Reconcile and Continue refuse with "Claude history for this conversation exists in more than one location"; that is expected (deferred), not a failure.
E8. R3 watch: in a session whose Bash row was cancelled by a kill and restore, read the saved session file (read only) before and after the next turn in that session. Pass: the restored row still reads cancelled after the turn, not `success`.
E9. Codex Reconcile (after It stopped or Check): on an interrupted Codex turn with no tool calls, Reconcile imports its rows once, and a second Reconcile imports 0 rows; on an interrupted turn with a tool call, Reconcile imports nothing and says "Codex's record of the interrupted turn contains tool calls that can't be imported; nothing was imported." (record the exact text). No new Codex turn starts in either case.
E10. Codex Continue once: on the interrupted Codex session, Continue… → edit the text → Send, double-clicking Send. Pass: exactly one continuation and one run attempt; the same thread ID in Codex's history, with one copy of the text; the second click joins.

## Reporting

For each scenario: pass/fail, evidence paths, session IDs, approvals obtained, and any unexpected UI text. Failures go back to the main agent; the verifier does not change code.
