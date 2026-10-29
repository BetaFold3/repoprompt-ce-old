# 9-live re-check (round 4, final): verifier results

Scope: read when the task touches the results of the fourth and final live re-check of crash recovery before the activation switch.
Authority: Reference
Last-verified: 2026-10-29
Covers: what the round-4 verifier ran, the results with exact texts, findings, and the synthetic sessions

## The run

- **Build:** HEAD `e059c451bbc040edffa8d8c10a161408d0d2ebcb` plus the uncommitted `production = .claudeAndCodex` line, the only `Sources`/`Packages` change. Built and launched with `make dev-run`; provenance `e059c451`, dirty, built 14:57:18.
- **App PIDs:**
  - 98218 at the start.
  - Killed with SIGKILL at 15:19:23; relaunched as 79039 at 15:19:32.
  - Normal quit at 15:31:37 (`cleanExit`); relaunched as 82818 at 15:32:28.
- **Approvals (2026-10-29):**
  - The owner quit the previous app (PID 9003, build `f6c87229`) at 14:52 ("I hit the quit/exit button myself. It's fine.").
  - The owner approved the rebuild and launch, the cleanup, and every round-4 kill, relaunch and quit.
  - No provider process was signalled.
- **Universal hard fail:** none. Every send was a requested `RPCE_VERIFY_*` prompt and appears once in Claude's history.
- **Raw evidence:** `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle17/` (`cleanup/`, `run/`, `fixtures.json`), journal key `cycle17`.

**Fixture deviation.** Claude's Bash tool refused the brief's `sleep 90` ("standalone sleeps aren't allowed"). Both turns completed with a failed Bash row and started no process. The verifier then sent one more kill turn per session: `for i in $(seq 1 9); do sleep 10; done`, which needed one Command Approval click each. So each fixture had three user entries before the kill (warm-up, the refused `sleep 90`, then the loop) instead of two. While the loops ran, `ps` showed `bash` loops with `sleep 10` children. Each message was requested; none was duplicated. Future briefs should ask for a loop, not a standalone `sleep`.

## Results

| Step | Result | Exact text and evidence |
|---|---|---|
| Cleanup (round-3 sessions) | **Pass.** | All ten deleted through the UI: K1, K2, K3, K4, K6, X1, X2, X1-failed, "T2" `8C1E3052…` and "T3" `3237CE93…`. Session files and recovery records are gone, tombstones are present, and `list_sessions` no longer lists them. `cleanup_sessions` over the CLI deleted none of them, because it deletes only MCP-started sessions. |
| Kill and relaunch | **Pass.** | Only C1 and C2 were running. Both `bash` loops were alive 3 s after the kill. `claude -p` exited about 20 s later. |
| 1. Processes exited | **Pass.** | No loop or `sleep` was left in `ps` at 15:21:02. |
| 2. Check (clean hold) | **Pass.** | Summary: "Checked 41 of 41 · 2 resolved · 30 need you · 9 could not check". C1 and C2 each: "Sending paused · RPCE_VERIFY_Cx_r4_20261029 — Resolved: Process records show every process of the interrupted run exited." C1: "Interrupted run — Needs you: Continue it or dismiss the note. Claude's history has output RepoPrompt couldn't safely match to this conversation. Nothing was imported, so some of it may not show here; Claude still has it." C2 (not open): "Interrupted run — Could not check: Open this session to check its provider history." Both: "Saved message — Needs you: Send or discard the saved message". |
| 3. V5 tool case (C1), Reconcile twice | **Pass.** | Both times: "Claude's history has output RepoPrompt couldn't safely match to this conversation. Nothing was imported, so some of it may not show here; Claude still has it." This is the same text Check had already set, so the text alone can't tell the two clicks apart. Claude's history kept 3 user entries, the transcript is unchanged, and no `claude --resume` appeared. |
| 4. V6 Claude (C2), Continue with a double-clicked Send | **Pass.** | Continue… appeared only after C2 was opened. The editor was prefilled with "RepoPrompt restarted during the previous turn. Check the current state before repeating any action, then continue."; the verifier replaced it with its message and double-clicked Send at 15:29:01. Claude's history went from 3 to 4 user entries, one copy, same conversation file. The message shows once in the conversation, and Claude replied "OK". |
| 5. Normal send (C1) | **Pass.** | One click at 15:31:02. History went from 3 to 4 user entries; Claude replied "OK". |
| 6. Normal quit and relaunch | **Pass.** | `cleanExit`. After the relaunch, no C1 or C2 row is under Needs action and there are no crash-hold or survivor rows. Only informational rows remain for C1 and C2 under Information, offering View, Edit, Remove and Dismiss: "Message may have been delivered … Its run stopped before the provider confirmed it. It won't be sent again." Claude's history and both recovery records are byte-identical across the relaunch. |

## Findings

- **U1 (observation).** A session's run row offers Continue… and Check provider history only while that session is open. When it isn't open, the row offers Dismiss and Open (seen on C2 before it was opened, and on C1 after switching away). This matches Check's "Open this session to check its provider history." It is probably by design, but the sheet doesn't explain why the buttons are missing.
- **U2 (fixture).** Claude refuses a standalone `sleep N`. Kill fixtures should use a loop of short sleeps.
- No other finding. Round 3's blocker T1 is fixed live: Reconcile now imports nothing with the new text, and Continue sends the typed text exactly once.

## Synthetic sessions

| Session | ID | Claude conversation | Deleted |
|---|---|---|---|
| C1 `RPCE_VERIFY_C1_r4_20261029` | `50FA5943-5FB5-4172-905C-A27EF7033B22` | `181be43f-0bc9-4650-879d-d9227a459218` | No |
| C2 `RPCE_VERIFY_C2_r4_20261029` | `2074D6C5-7244-41FE-AF62-BB986692701A` | `dd21a9a6-4a15-4363-ae73-f39a3e0eef47` | No |

The ten round-3 sessions deleted this round are listed in `cycle17/cleanup/results.json`.
