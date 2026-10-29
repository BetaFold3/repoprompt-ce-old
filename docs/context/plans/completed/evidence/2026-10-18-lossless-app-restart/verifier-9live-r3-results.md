# 9-live re-check (round 3): verifier results

Scope: read when the task touches the results of the third live re-check of crash recovery before the activation switch.
Authority: Reference
Last-verified: 2026-10-29
Covers: what the round-3 verifier ran, what passed, what failed, what was not reached, and the synthetic sessions created

## The run

- **Build:** HEAD `f6c87229` plus the uncommitted `production = .claudeAndCodex` line, the only `Sources`/`Packages` change. App PID 3007 came from the owner's relaunch job at 09:27:36, with provenance `f6c87229`, dirty.
- **App PIDs:** 3007 to start. After the SIGKILL at 09:55:55, PID 25483 (relaunched about 09:56:03). After the normal quit (10:44:02, `cleanExit`, `shutdown_ended outcome=completed`), PID 9003.
- **Approvals:** on 2026-10-29 the owner approved the cleanup of the round-2 sessions and every kill, quit and relaunch of this round ("I approve"). No provider process was signalled.
- **Universal hard fail:** none.
  - Every send was a requested `RPCE_VERIFY_*` prompt and appears once in the provider's history.
  - Claude itself writes the "[Tool call interrupted…]" `tool_result` and "No response requested." entries at resume; RepoPrompt didn't send them.
  - Twice a misplaced click put synthetic text into a composer (`RPCE_VERIFY` into X2's, and the verifier's own "while alive" draft). Both were cleared on purpose and nothing was sent.
- **Raw evidence:** `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle16/`, in `cleanup`, `fixtures`, `kill`, `after-a`, `after-b` and `p5-quit`. Journal key `cycle16`.

**Fixtures.** All seven warm-ups completed (Claude Sonnet low, Codex GPT-6 Sol low). All kill turns were sent between 09:52:12 and 09:53:42. Three were lost to the providers, not to timing:

| Fixture | Kill turn | State at the kill |
|---|---|---|
| K1 | Bash loop `200 × sleep 10`, used instead of `sleep 1800` | Running |
| K3 | Bash loop | Running |
| K4 | Bash loop | Running |
| X2 | Codex `sleep 600` | Running |
| X1 | Long text answer | Codex refused the long filler ask and finished at once |
| K6 | Long text answer | Finished at 09:54:44; the app showed no partial text before the whole essay appeared |
| K2 | Long text answer | Still "Thinking" at 09:55:44 per the screenshot, but its record shows the turn completed before the kill (09:55:55) |

So this build can't produce the V5 text cases (Claude text doesn't stream visibly) or V4/E9 import with a filler prompt. The supervisor chose to kill without extra sends.

## Results

| Scenario | Result | Evidence and exact UI text |
|---|---|---|
| Cleanup (round 2 sessions) | **Pass.** | All ten deleted through the UI after `get_log` identity checks. Session files and recovery records are gone and tombstones are present. The badge went 35→30 at once, without a relaunch. Process-registry runtime records naming the deleted IDs remain; they were not touched. |
| R7: sheet first | **Pass.** | Before any session was opened, the sheet listed K1's survivor item: "Claude from an earlier launch of RepoPrompt (2 processes found, started as PID 15850)…". |
| S5: both PIDs | **Partial.** | The item names only launcher PID 15850. `claude` (15940) and the launcher had both exited by about 09:56:17, leaving only `bash` 83203, so no agent PID was left to name. The two-PID wording can't be judged from this run. |
| Live-process Check | **Pass.** | Run at 09:58:47: "Checked 49 of 49 · 37 need you · 12 could not check". K1's hold was not confirmed and the item names the live process. K3, K4 and X2 were also not confirmed. K2, K6 and X1 had no holds, because their runs completed. |
| V1 on K1 | **Pass.** | The send was refused with a notice that stayed: "The previous run in this session may still have been working when RepoPrompt closed. Confirm it stopped from the recovery banner before sending. Your draft is kept." Let it finish: "You chose to let it finish; RepoPrompt keeps watching it." K1's history kept 2 user entries. |
| V1 completion and E2 on K1 | **Partial.** | The loop exited at 10:26:03 and the survivor item cleared itself about 25 s later (S2 confirmed). Reconcile refused with T1's text, so E2's premise wasn't met: the typed text stayed in the Continue draft instead of moving to the message box. One "after" send appears once in Claude's history. |
| Identity check (K2 kill turn) | **Pass.** | The saved `outboundUserMessage.uuid` is `29249156-1CC6-41D7-989F-AEA97572B8A0`. Claude's history file has the prompt entry's `uuid` as `29249156-1cc6-41d7-989f-aea97572b8a0`: the same ID, different case. No raw protocol log exists. The warm-up's baseline is unsupported by design, because no conversation existed before the first send. |
| K2 clean hold | **Not reached.** | K2's kill turn completed before the kill, so there was no hold and no settled row. |
| V5 text cases (K6, K2) | **Not reached.** | Both kill turns completed before the kill. |
| V5 tool case (K3) | **Safe refusal (T1).** | It stopped, then Check provider history twice: "The pre-send history position was saved, but this build cannot safely match Claude's history to messages already in this conversation. Nothing was imported." Nothing sent, no `claude --resume`, Claude's history unchanged at 34 lines and 2 user entries. Afterwards the row offered only Dismiss and Open. |
| V6 Claude (K4) | **Refused (T1).** | Continue with edited text and a double-clicked Send: "The message you typed to continue it was not sent. The pre-send history position was saved, but this build cannot safely match Claude's history to messages already in this conversation. Nothing was imported." The draft was kept, nothing was sent, and the history is unchanged. |
| V2 (X2) | **Pass.** | No survivor item. It stopped was used; Check wasn't re-run, to avoid acting on about 35 of the owner's items. |
| S3 (X2) | **Pass.** | Reconcile twice, both times: "Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported." The rollout is unchanged. |
| V4 + E9 (X1) | **Not reached.** | X1's kill turn was refused by the model and completed. |
| E8 (K3) | **Pass.** | The restored Bash row reads `bash • failed` before and after a new turn, never `success`. The E8 prompt appears once in Claude's history. |
| E3, E4, E5 | **Not reached.** | — |
| S4 | **Pass.** | Right after the kill, rows read "RepoPrompt quit unexpectedly while this session was working…". After the next launch, K4's row reads "In an earlier launch, RepoPrompt quit unexpectedly during this turn. The saved conversation stops where it was interrupted. The message you typed to continue it was not sent." |
| E6 step 1 | **Not reached.** | There was no settled K2 row. |
| E6 step 2 (K2, normal quit and relaunch) | **Pass, trivially.** | K2's record is unchanged (rev `8CAF563F`); no K2 row and no crash hold; Claude's history is unchanged at 39 lines and 2 user entries. K2 had nothing to settle. |
| P5 / Esc (sheet) | **Pass.** | Steps 2, 3, 4, 10 (P4), 11 (E1), 13 (P9) and 15 (P11) pass in the sheet. Esc closes only the popover, and a second Esc closes the sheet. Typing with the popover open doesn't reach the composer. Cmd-C copies the popover's text ("RPCE_VERIFY_P5_r3_20261029 draft"). One Esc during a running turn didn't interrupt it. Step 7 partial: sheet controls act on the first click and close the popover. |
| P5 / Esc (banner) | **Not run.** | Steps 1, 4, 5, 6, 8, 9, 12 and 14 need a synthetic banner row with View. Opening a session restores a saved draft into the composer, which removes the row, and the owner's rows were off limits. |
| V7, V3, V9, C2 "finished Codex run", K5/V8, X3/E10 | **Out of scope, or passed in round 2** (V8, E10). | — |

## Findings for the main agent

- **T1 (confirmed live; cause is an inference).** Claude Reconcile and Continue still refuse, now after a history position was saved, with "…cannot safely match Claude's history to messages already in this conversation." The code maps this text to `nativeUserAssociationUnavailable` or `canonicalOutputAssociationUnavailable`.
  - **Inference:** the warm-up turn the brief requires has no saved baseline ("unsupported by design" for the first send), so its messages can't be associated. That blocks every later kill turn in the same conversation.
  - If so, the round-3 fixture rule (a completed first turn before the kill turn) makes Claude Reconcile and Continue unreachable.
  - Not traced in code.
  - Affects K1, K3 and K4.
- **T2 (confirmed live).** The S1 refusal text "names the blocking record type" never appeared. The T1 refusal names no record type, so it isn't clear how often `deferred_tools_record` or `silent_turn_reminder` would matter.
- **T3 (observed).** After K3's refusal, the row lost Continue… and Check provider history, leaving Dismiss and Open. That may be by design after a terminal refusal.
- **T4 (fixture limit).** In this app, a Claude text answer appears all at once after "Thinking", so a "part of the answer visible at the kill" fixture can't be made from the composer. Codex refuses filler asks. A V5 text case needs a different prompt, for example a genuinely long Codex answer, or accepting unit coverage.
- **T5 (fixture limit).** S5's two-PID wording needs `claude` still alive after the relaunch. The CLI exited about 20 s after the kill even though its Bash child lived on.

## Still to run

- Claude Reconcile and Continue (V5, V6, E2), after T1 is resolved, plus the K2 clean hold and E6 step 1. This needs another kill.
- V4/E9 import and a V5 text case, if fixtures can be made (T4).
- S5 with a live `claude`.
- P5 banner steps 1, 4–6, 8, 9, 12 and 14. These need no kill, only a synthetic banner row with View.

## Synthetic sessions

All are in workspace `repoprompt-ce-personal-touch`. None are deleted.

| Session | ID |
|---|---|
| K1 | `0AED4A8E-5730-4502-BF55-3652E89610BA` |
| K2 | `4BB73911-2B53-463A-9775-642DAE1CCA36` |
| K3 | `258136C1-AACD-4AA9-91DB-D8EFAD83F8D0` |
| K4 | `2B40196C-A73D-4ABB-8492-9FFC39977B98` |
| K6 | `86AAE542-FBFA-429C-A312-720638F9BAAE` |
| X1 | `4385F77E-58AA-4655-9B0C-704AA2E10DDA` |
| X2 | `F2841A1D-B505-43A4-B520-9A1A15B5EB5F` |
| X1, failed first try (model not found) | `03DF6763-8FC3-493B-8744-8C3B9BB32E92` |
| P5 draft, "T2" | `8C1E3052-03DA-488F-8BAE-20A32EBB76FE` |
| P5b, "T3" | `3237CE93-D293-4648-8852-8F2C04CE638F` |

The ten round-2 sessions deleted this round are listed in `cycle16/cleanup/`.
