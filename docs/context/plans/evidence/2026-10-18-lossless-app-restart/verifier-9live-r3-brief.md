# 9-live re-check (round 3): verifier brief

Scope: read when the task touches the third live re-check of crash recovery before the activation switch.
Authority: Reference
Last-verified: 2026-10-29
Covers: the verifier's instructions, fixtures and checks for the round-3 live re-check

You are the external verifier for RepoPrompt CE's crash recovery ("lossless app restart"). The owner started you in a terminal. You check the app's behaviour live and report; you do not change code, the plan or the spec. This brief changes only what differs from round 2. Everything else, including the safety rules, evidence rules and the full scenario texts, is in [verifier-9live-r2-brief.md](verifier-9live-r2-brief.md) and [verifier-scenarios.md](verifier-scenarios.md). Where this brief and those differ, this brief wins.

## Background

Round 2 ([results](verifier-9live-r2-results.md)) had no hard fail. It found five issues, now fixed or explained:

- **S1 (blocker):** no Claude history position was ever saved, so Claude Reconcile and Continue always refused. Real app Claude histories contain metadata records, `thinking` blocks and a prompt format that the history reader refused. Now:
  - the reader accepts the metadata records seen in real sessions;
  - it skips `thinking` blocks without making rows, both in history and while the turn streams;
  - it matches the prompt the CLI writes;
  - sends through the owner's configured Claude path (the rotator shim) now carry a message ID, so recovery can match the prompt in Claude's history.

  Two record types are still refused on purpose: `deferred_tools_record` and `silent_turn_reminder`. A refusal now names the blocking record type, for example "(attachment deferred_tools_record, line 12)".
- **S2 (not a bug):** Let it finish keeps the item only while the process lives. K1's `sleep` ended at the moment of the click, so the item cleared itself. When the last process exits, the item clears on its own, with no Refresh needed.
- **S3:** Codex Reconcile read only a summary of the turn. It now reads the full turn.
- **S4:** a crash row from an earlier launch now reads "In an earlier launch, RepoPrompt quit unexpectedly during this turn…".
- **S5:** the survivor item now names both PIDs, for example "(1 process found; launcher PID 56334, agent PID 56474)". The agent PID is `claude`'s.

## The build

As in round 2. The committed tree the owner names must include the round-2 fixes (Step 9-live-r2-fixes). On top of it there must be exactly one uncommitted source line, `package static let production: AgentRecoveryActivation = .claudeAndCodex`, in `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActivation.swift`. Record `git rev-parse HEAD`, `git diff -- Sources Packages`, the app PID and the commit in its provenance file.

## Before you start

- **Cleanup:** if the owner asked you to delete the round-2 synthetic sessions, delete them through the UI first and list what you deleted. Those are the nine from round 2 plus T2 (`2F9EF210-BB1A-4B0A-A071-7AACD07CA348`). Otherwise leave them; they don't affect this run. Use only fresh fixtures named `RPCE_VERIFY_<id>_r3_<date>`.
- **Approvals:** ask the owner before every kill, relaunch, quit and process signal, unless the owner has pre-approved them for this run in your terminal. Record the approval either way.

## Fixture timing (new)

Round 2 lost K2–K4 and X1 to timing. In this round:

1. Create all fixtures and run each one's short completed warm-up turn first.
2. Then start every kill turn within about one minute of each other.
3. Kill the app as soon as all kill turns are running.

K1's Bash tool runs `sleep 1800` or longer, so it outlives the checks that need it.

Fixtures are the round-2 table plus one:

| ID | Provider | Kill turn | Used by |
|---|---|---|---|
| K1 | Claude | Bash `sleep 1800` | V1, A9 (optional, passed in round 2), live-process Check, E2, S5 |
| K2 | Claude | a long no-tool reply still streaming (ask for a long essay) | Check confirms a clean Claude hold, then V5 Reconcile ×2, E6 |
| K3 | Claude | a short Bash tool mid-call | V5 tool case, E8 |
| K4 | Claude | a Bash tool mid-call | V6 Claude |
| K5 | Claude | a pending question with a partial answer typed | V8 (optional, passed in round 2) |
| K6 | Claude | a long no-tool reply, killed after part of the answer is visible (start it first so text is showing at the kill) | V5 text case |
| X1 | Codex | a long text-only answer | V4 and E9 import |
| X2 | Codex | a Bash tool (`sleep 600`) | V2, S3 |
| X3 | Codex | any running turn | E10 / V6 Codex (optional, passed in round 2) |

## Identity check on K2's kill turn (new, IDs only)

For K2's kill turn (the second send), compare IDs only after the relaunch and record the result. Do the same for its warm-up turn if it was claimed:

- the dispatch's saved `outboundUserMessage.uuid`, from `providerHistoryRecovery.dispatchBaselines` in the saved session file;
- the native prompt entry's `uuid` in Claude's `<conversation-id>.jsonl`;
- if a raw protocol log exists, the `uuid` on the outbound stdin frame.

Pass: all of them are equal.

If the saved dispatch has no `outboundUserMessage`, or the IDs differ, record it as a finding. Claude Reconcile and Continue will then refuse, safely. Never copy message text into the report.

## After the relaunch (in this order)

1. **Sheet first (R7, S5):** before opening any session, record whether the survivor item for K1 is listed. Record its exact text; it must include the agent PID, which is `claude`'s PID from your `ps` before the kill.
2. **Live-process Check:** run Check while K1 lives.
   - Pass: K1's hold is not confirmed and the item names the live process.
   - Record the full report line, including the other sessions Check confirms.
3. **V1 on K1:** a send is refused with a notice that stays. Then click Let it finish and read the item's text immediately: it must say "You chose to let it finish".
4. **K2 clean hold:** Check confirmed it in step 2 ("Resolved: Process records show every process of the interrupted run exited.").
   - K2's "Message may have been delivered" row is informational, with "Its run stopped before the provider confirmed it. It won't be sent again.".
   - It offers View, Edit, Remove and Dismiss, never Send saved.
5. **V5 text cases (K6, K2):** Claude Reconcile twice on each.
   - Pass: the visible part of the answer is not duplicated, the rest of the answer, if Claude finished writing it, appears once, and the second Reconcile adds nothing.
   - No `claude --resume` and no send appear in `ps` or in Claude's history.
   - If Reconcile refuses, record the exact text. A refusal now names its reason; one naming `deferred_tools_record` or `silent_turn_reminder` is an expected safe refusal, so record the type and move on.
6. **V5 tool case (K3):** Claude Reconcile twice. A safe refusal is expected, because only Read tools qualify for import. Record the exact text. Pass: no row is duplicated and nothing is sent.
7. **V6 Claude (K4):** Continue with a double-clicked Send. Pass: one message in Claude's history, in the same session. If it is refused, record the text.
8. **V2 and S3 (X2):**
   - V2: no survivor after Refresh, and Check confirmed the hold.
   - S3: first Reconcile. Pass: either rows are imported once, or the row says "Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported."
   - A first click may also finish with no visible text. That is a known zero-row case, so record it.
   - Then a second Reconcile. Pass: no new rows. Fail: "The provider has no new history for this conversation." on the first click.
9. **V4 and E9 (X1):** Codex Reconcile twice. Pass: rows are imported once, then nothing.
10. **E2 on K1, after `sleep` exits:** the survivor item clears by itself. Then type in Continue…, close the editor, and click Reconcile (Check history).
    - Pass: the text lands in the message box with "This card no longer offers Continue, so the message you typed for it wasn't sent. It's now in the message box."
    - Then send one message on K1. It must appear once in Claude's history.
11. **E8 (K3):** read K3's saved session file, send one short turn, then read the file again. Pass: the restored Bash row still reads cancelled.
12. **E3, E4, E5** if their states occur; otherwise record "not reached".
13. **P5 and Esc**, which need no kill and can run any time: steps 1 and 4–15 of [fix-9live-esc-worker.md](fix-9live-esc-worker.md), "Manual steps for the live verifier", then **E1**.

## Normal quit and relaunch (approval as above)

- **E6 step 2 (K2):** no crash hold returns for that run, the row doesn't return as needing action, and Claude's history is unchanged.
- **S4:** K-rows from the crash now read "In an earlier launch, RepoPrompt quit unexpectedly during this turn…".
- **R7:** a survivor item, if any, is visible in the sheet without opening a session.

## Reporting

Write results to a new file, `verifier-9live-r3-results.md`, in this directory (then link it here), with the same header style and contents as round 2. Include the identity check result, every refusal text, and the list of synthetic sessions (full IDs), each marked deleted or not. Send failures back to the main agent.
