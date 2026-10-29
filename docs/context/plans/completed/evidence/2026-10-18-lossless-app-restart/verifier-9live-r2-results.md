# 9-live re-check (round 2): verifier results

Scope: read when the task touches the results of the second live re-check of crash recovery before the activation switch.
Authority: Reference
Last-verified: 2026-10-29
Covers: what the round-2 verifier ran, what passed, what failed, what was not reached, and the synthetic sessions created

## The run

- **Build:** HEAD `1fd160d724dfbb7c99ec64b784beaee2f46421b7` plus the uncommitted `production = .claudeAndCodex` line, the only `Sources`/`Packages` change (checked with `git diff -- Sources Packages`). Other uncommitted files: `.gitignore`, `AGENTS.md`, the codemap test helper and docs.
- **App PIDs:**
  - 71026: the owner relaunched it at 23:18:16. Its provenance is `1fd160d7`, dirty.
  - 69704: after the kill.
  - 1959: after the normal quit and relaunch.
  - Part 1 ran on 71026. The first relaunch had found PID 826 still running the old binary from a staging folder, so the owner relaunched it again.
- **Approvals:**
  - 2026-10-28 ~23:15: clean up the round-1 synthetic sessions.
  - 2026-10-28 ~23:35: pre-approval of the kill and relaunch ("I approve ahead of the time. No need to ask you for the kill&relaunch."). The verifier applied it to one SIGKILL plus relaunch (00:20:49 → 00:21:01) and the Part 4 normal quit plus relaunch (01:04:21 → 01:04:47).
  - No provider process was signalled.
- **Universal hard fail:** none.
  - Every send was a requested `RPCE_VERIFY_*` prompt and appears once in the provider's history.
  - The Claude-injected `tool_result` entries ("[Tool call interrupted…]") at resume are not RepoPrompt sends.
  - The quit and relaunch added only Claude's own `last-prompt`, `mode` and `cost-state` lines to K1's history, no user entry.
- **Raw evidence:** `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle15/`, with folders `cleanup`, `e7`, `p5esc`, `fixtures`, `kill1`, `p3a-k1`, `p3b`, `p3c` and `p4`. Journal key `cycle15`.

**Fixture shortfall.** The fixture group timed out after 60 minutes. Because fixture creation was slow, several kill turns had finished, or never started, before the kill:

| Fixture | Planned kill turn | What happened |
|---|---|---|
| K2 | No-tool reply streaming | Kill turn never sent; warm-up only |
| K3 | Short Bash tool mid-call | Turn finished before the kill |
| K4 | Bash tool mid-call | Turn finished before the kill |
| X1 | Long text-only answer | Kill turn never sent; warm-up only |

Running at the kill were K1, K4, X2 and X3, plus K5's pending question with a typed partial answer, killed within its 5 minutes. The verifier killed the app itself before K5's question expired. K1's `claude` (56474) carried `RPCE_RUNTIME_ID`.

## Results

| Scenario | Result | Evidence and exact UI text |
|---|---|---|
| Cleanup (round 1 sessions) | **Partial.** | 16 of 17 deleted: session file gone, tombstone present, gone from `list_sessions`. T2 `2F9EF210-BB1A-4B0A-A071-7AACD07CA348` remains; its delete did not complete. |
| P5 / Esc, 15 steps + E1 | **Mostly not run.** | Step 2 passed: the first Esc closed the View popover and left the sheet open; the second Esc closed the sheet. Step 3 partial. Steps 1 and 4–15 and E1 have no evidence (the group timed out). |
| E7 | **Pass.** | `providerHome` after the second send: `~/.claude-rotator/profiles/38b72e00…`. The conversation file exists in that one profile only (checked `~/.claude`, `~/.claude-2nd` and the rotator profiles). Send latency to the first assistant text: 7.45 s, then 3.40 s, then 3.00 s; it doesn't grow after the third send. A fourth refresh can't be observed (no log line). |
| V1 survivor item (K1) | **Pass, except Let it finish.** | Listed first in the sheet before K1 was opened, which settles R7: "An agent process is still running · This workspace — Claude from an earlier launch of RepoPrompt (1 process found, started as PID 56334). Worktree: /Users/tnguyen/workspace/repoprompt-ce-personal-touch. Conversation: 1b92920a-…. Sending to that conversation stays paused until it exits. Nothing is stopped automatically." The PID shown is the node shim's, not `claude`'s. A send was refused with a lasting notice, and the draft was kept: "The previous run in this session may still have been working when RepoPrompt closed. Confirm it stopped from the recovery banner before sending. Your draft is kept." **Let it finish removed the item** (badge 34→33). No "You chose to let it finish" text was found, so this check isn't verified (S2). |
| A9 (K1) | **Pass, but after the process exited.** | "The message you typed to continue it was not sent. No history position was saved before the interrupted run, so its history can't be matched safely. Nothing was imported." Reopening Continue… shows the typed text. The editor stayed open 60 s untouched, and the draft survived an outside-click close. A following Reconcile left the row under Needs action. Nothing sent. |
| Live-process Check | **Not reachable this round.** | K1's `claude` had exited by 00:21:56 and its loop by about 00:24:20, before Check (00:30). Check then resolved K1's hold: "Resolved: Process records show every process of the interrupted run exited." Report: "Checked 45 of 45 · 4 resolved · 30 need you · 11 could not check". |
| Check confirms a clean Claude hold (K2) | **Not reached** (K2 had no kill turn). | Substitute K5, whose hold Check confirmed: its "Message may have been delivered" row reads "Its run stopped before the provider confirmed it. It won't be sent again." In the session it offers View, Edit, Remove and Dismiss; in the sheet View, Open and Dismiss; never Send saved. One later send went once. |
| V2 (X2) | **Pass.** | No survivor item. Check: "Resolved: Process records show every process of the interrupted run exited." It stopped wasn't needed. |
| V4 + E9 import (X1) | **Not reached.** | X1 had no kill turn. |
| E9 tool call (X2) | **Fail (S3).** | Expected "Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported." Got "The provider has no new history for this conversation." X2's run attempt carries `providerTurnID 01a1837c-a8a3-7c03-a0bb-7697909a0ab6`; the rollout has 2 `task_started` and 1 `turn_aborted`, both unchanged. No new turn started. |
| E10 / V6 Codex (X3) | **Pass.** | Continue once with edited text; Send was double-clicked. Result: one message, the same rollout file, `task_started` 2→3, one user message, one new intent and run attempt. |
| V5 (K3), V6 Claude (K4) | **Not reached.** | Their turns finished before the kill. |
| V8 (K5) | **Pass.** | Send answer as message was double-clicked: Claude history user entries went 2→3, one copy, same `sessionId`; a reply arrived. |
| V1 completion | **Partial.** | The process had exited before Refresh could be tried; Check lifted the hold. The kill-turn message settled as `deliveryUnknown`: "Process records show every process of this run exited before the provider confirmed the message." |
| E2 (K1) | **Partial; final step passes.** | Its premise (a card whose turn completes in history) wasn't met, because K1 has no history position (S1). The text stayed on the card, and no "This card no longer offers Continue…" appeared. The final send "RPCE_VERIFY_V1_20261029 after: reply OK" appears once in Claude's history; the reply was "OK.". |
| E8 | **Not reached.** | K3's Bash finished before the kill. Observation: K1's kill-cancelled Bash row stays `failed` after a new turn, not rewritten to `success`. |
| E3, E4, E5 | **Not reached.** | — |
| E6 step 1 (K1) | **Pass.** | The settled row was informational with View, Edit, Remove and Dismiss. Edit moved the text to the composer: the intent became `withdrawn`, the row disappeared, and nothing was sent. |
| E6 step 2 (K1, after the normal quit and relaunch) | **Pass, with a wording finding (S4).** | No crash hold returned. The edited row did not come back. The composer still holds the text, unsent. Claude history has no new user entry. K1's "Turn interrupted" row still reads "RepoPrompt quit unexpectedly during this turn…", but this time RepoPrompt quit normally. The row refers to the earlier killed run, so the wording is defensible but confusing. |
| A8 | **Partial.** | During Reconcile (X2) and Continue (X3) the rows stayed in Information. A refused Continue moved K1's row to Needs action, and it stayed there. No "moves back" case was seen. |
| R7 | **Pass** (from Part 3). | The survivor was listed in the sheet before the session was opened. After the relaunch no survivor existed. |
| V3, V9, V7, C2 "finished Codex run" | **Out of scope / not reachable, accepted on unit coverage** per the brief. | — |

## Findings for the main agent

- **S1 (confirmed live).** A Claude kill turn after a completed warm-up turn still has no saved history position.
  - K1's dispatch for the kill turn (run attempt `FC40B345…`, intent `85E1C582…`) has no baseline field in the recovery record.
  - Because of that, Reconcile and Continue on Claude refuse with "No history position was saved before the interrupted run…".
  - Fix 4 (finding the history location) worked, per E7's `providerHome`, but no position was recorded at dispatch.
  - This blocked V5/V6 Claude, a real Claude continuation, and E2's premise.
- **S2 (observed).** Let it finish removed the survivor item instead of keeping it with "You chose to let it finish". The item may have moved somewhere the verifier didn't look, so this is not fully verified.
- **S3 (confirmed live).** Codex Reconcile on a turn interrupted during a tool call (X2) says "The provider has no new history for this conversation." The saved `providerTurnID` didn't lead to the expected "found, but couldn't be imported" wording.
- **S4 (wording).** After a normal quit, an older killed run's row still reads "RepoPrompt quit unexpectedly during this turn…". That is accurate for the killed run but reads as if the normal quit was unexpected.
- **S5 (observation).** The survivor item names the node shim's PID (56334), not `claude`'s (56474).

## Still to run

Each of these needs another kill. Build fixtures faster: create them with short warm-up turns, start every kill turn within a minute of each other, and kill immediately.

- Live-process Check: a survivor still alive when Check runs. Run Check within a minute of the relaunch, or use a loop over 20 minutes.
- The clean Claude hold (K2).
- V4/E9 import (X1).
- V5 and V6 Claude (K3, K4), after S1.
- E2 and E8.
- The P5/Esc steps 1 and 4–15 plus E1. These need no kill.

## Synthetic sessions

All are in workspace `repoprompt-ce-personal-touch` and none are deleted yet. They need the owner's approval.

| Session | ID |
|---|---|
| K1 | `15ED5106-192E-4E89-B684-69B02C67F959` |
| K2 | `8C15B73B-CBD7-41EA-B02B-109AB45E5846` |
| K3 | `80B1D855-BC1F-4ADC-B953-7E17370A688D` |
| K4 | `3D53A3E7-B337-426B-967B-BA733147702D` |
| K5 | `0B37357F-985E-4D6D-AAEA-265EF3477D29` |
| X1 | `EAD95F6A-2788-4624-99C4-5A59EFA78167` |
| X2 | `8F93931E-D018-49C1-8854-10E753F2EFB6` |
| X3 | `B86B1961-CB9F-4574-8B3F-F8548512438C` |
| E7 | `14863B15-4B6C-49EA-81D9-AAAC8F74AF63` |
| Round-1 leftover T2 | `2F9EF210-BB1A-4B0A-A071-7AACD07CA348` |

The 16 round-1 sessions deleted in this round are listed in `cycle15/cleanup/results.json`.
