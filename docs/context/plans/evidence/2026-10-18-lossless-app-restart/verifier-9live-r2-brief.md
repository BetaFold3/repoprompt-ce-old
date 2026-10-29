# 9-live re-check (round 2): verifier brief

Scope: read when the task touches the second live re-check of crash recovery before the activation switch.
Authority: Reference
Last-verified: 2026-10-28
Covers: the verifier's instructions, fixtures and checks for the round-2 live re-check

You are the external verifier for RepoPrompt CE's crash recovery ("lossless app restart"). The owner started you in a terminal. You check the app's behaviour live and report; you do not change code, the plan or the spec. Everything you need is in this brief and in [verifier-scenarios.md](verifier-scenarios.md), which holds the full text of every scenario named here.

## Background

- The first live run (round 1, 2026-10-28) is in [verifier-9live-results.md](verifier-9live-results.md). It had no unrequested or duplicate send, but Claude crash holds couldn't be confirmed, Claude and Codex history matching failed, typed continuation text was lost or hidden, and Esc didn't close the View popover.
- Six fix steps landed since (Step 9-live-fixes):
  1. Esc closes the View popover when pressed in the popover or its anchor window, and only the popover.
  2. The recovery list keeps a Continue draft per row and reopens it; a refused continuation shows "The message you typed to continue it was not sent." before the reason; survivor items come first; a send-refusal notice stays until the next edit, attempt or tab change.
  3. Check (and It stopped) settles a held run's possibly-delivered messages: the row stays "Message may have been delivered", becomes informational with "Its run stopped before the provider confirmed it. It won't be sent again.", and never offers Send saved.
  4. Claude's history location is found (the real CLI's `CLAUDE_CONFIG_DIR`, then a bounded search), so Claude Reconcile and Continue can work for a session with an earlier completed turn.
  5. Codex's native turn ID is saved on the run, so Codex Reconcile and Continue can match the interrupted turn.
  6. Tests pin which providers register, and the guide was updated (this brief).
- Refresh never confirms a crash hold; Check does. It stopped is the manual fallback.

## The build

- **Candidate:** the committed tree the owner names (after Steps 1–6), plus one uncommitted line in `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActivation.swift`: `package static let production: AgentRecoveryActivation = .claudeAndCodex` (committed value: `.off`).
- **Check it before starting (read only):** record `git rev-parse HEAD` and `git diff -- Sources Packages`. The only source change must be that line. Other sessions may have uncommitted docs or test files in this checkout; record them, but if any other `Sources` or `Packages` change appears, stop and report.
- **App:** the owner builds and relaunches the daily debug app. Record its PID and the commit in its `RepoPromptDebugProvenance.json`. The provenance shows "dirty"; that is expected.
- **Effect:** activation is on for the whole app. New Claude Code (standard) and Codex launches are registered, and recovery actions really run. Every other provider launches unregistered and its recovery actions refuse with "Recovery for <provider> isn't qualified yet: …".

## Safety rules

- **Approval per kill.** Ask the owner immediately before every app kill, relaunch, quit and process signal, each time. Earlier approval doesn't count. Never signal a provider process.
- **Application Support is read-only.** Never create, edit, move or delete anything under `~/Library/Application Support/RepoPrompt CE/` by hand. You may read recovery records (`AgentRecovery/v1/sessions/<id>.json`), runtime records (`AgentRecovery/v1/runtimes/<runtimeID>.json`) and saved session files.
- **Synthetic sessions only.** Name every session you create `RPCE_VERIFY_<scenario>_<date>` and record its ID. Never touch the owner's real sessions. Delete synthetic sessions only when the owner asks, through the UI, and list what you deleted.
- **No GUI probes beyond what the owner runs.** Interact only with the debug app the owner launched, and only as the steps say (clicks, keys and accessibility reads in that app). Never launch, relaunch or quit an app yourself, and never start another GUI or window-opening process.
- **Universal hard fail:** any message sent to a provider that a step didn't ask for, any second copy of a message, or any lost typed text. Stop and report at once.
- Use `rpce-cli-debug` if you need the CE CLI; never production `rp-cli`.
- Providers: Claude Code (standard) and Codex CLI only. V3 (Stop) and V9 (unqualified providers) are out of scope.

## Fixture rules

- Every Claude kill fixture first runs one short completed turn; the kill turn is the second. The Claude history file `<conversation-id>.jsonl` (under a Claude profile's `projects/*/`) must exist before the kill. A first-message crash is unsupported for Reconcile and Continue by design.
- V1's Bash tool runs `sleep 900` or longer, and V1 is the first thing you run after the relaunch.
- V8: trigger a Claude question, type a partial answer, and kill within its 5-minute timeout.
- V7 and C2's "finished Codex run" part are not reachable live (follow-ups become live steers; the app-owned Codex app-server exits with the app). Record both as "not reachable, accepted on unit coverage". Don't build fixtures for them.

## Plan of the run

### Part 1: no kill

1. **P5 and Esc:** the 15 manual steps in [fix-9live-esc-worker.md](fix-9live-esc-worker.md), "Manual steps for the live verifier" (includes Esc during a running turn and the mention list), then **E1** (step 11's focus and Cmd-C). Send Esc as a real key press (System Events key code 53) after a real click on View.
2. **E7** (Claude history location): a fresh Claude session, three short turns; record `providerHome` after the second send, the refresh count evidence, send latency for each send, and whether the conversation file exists in more than one Claude profile.

### Part 2: fixtures for kill round 1

Create these, each named `RPCE_VERIFY_<id>_<date>`, then ask for approval and have the app killed while the kill turns run:

| ID | Provider | Completed turn first | Kill turn | Used by |
|---|---|---|---|---|
| K1 | Claude | yes | Bash `sleep 900` (or longer) | V1, A9, live-process Check, E2 |
| K2 | Claude | yes | a no-tool reply still streaming | Check confirms a clean Claude hold, E6 |
| K3 | Claude | yes | a short Bash tool mid-call | V5 (Reconcile ×2), E8 |
| K4 | Claude | yes | a Bash tool mid-call | V6 Claude (Continue, double-click Send) |
| K5 | Claude | yes | a pending question with a partial answer typed (within 5 minutes) | V8 |
| X1 | Codex | yes | a long text-only answer (no tools) | V4 and E9 (import) |
| X2 | Codex | yes | a Bash tool (for example `sleep 600`) | V2, E9 (tool-call text) |
| X3 | Codex | yes | any running turn | E10 / V6 Codex |

Before the kill: record `ps -eo pid,ppid,pgid,comm` and `ps eww <pid>` for K1's `claude` and `bash` (the `RPCE_RUNTIME_ID` marker), and read each session's recovery record.

### Part 3: after relaunch (in this order)

1. **V1 on K1, first.** Survivor item (provider, PID, worktree; record whether the sheet lists it before you open the session); a send refused with a notice that stays; Let it finish.
2. **A9 on K1, while its process lives:** Continue… with typed text, refused. Pass: the row is under Needs action and its detail starts with "The message you typed to continue it was not sent."; reopening Continue… shows the typed text, and the draft survives the editor closing on its own; a following Reconcile that doesn't confirm completion leaves the row under Needs action.
3. **Live-process Check:** run Check. Pass: K1's hold is not confirmed and the item names the live process. Record the full report line; Check will confirm other sessions' holds in the same run.
4. **Check confirms a clean Claude hold (K2).** Pass: "Resolved: Process records show every process of the interrupted run exited."; K2's "Message may have been delivered" row is informational with "Its run stopped before the provider confirmed it. It won't be sent again." and offers View, Edit, Remove and Dismiss, never Send saved; a send then goes once.
5. **V2 (X2):** no survivor after Refresh; Check confirms the hold; It stopped only if Check refuses (record the reason).
6. **V4 + E9 (X1, X2), E10 (X3):** Codex Reconcile twice on X1 (rows imported once, then 0); Reconcile on X2 shows "Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported."; Continue once on X3 with a double-clicked Send.
7. **V5 (K3), V6 (K4), V8 (K5):** Claude Reconcile twice (rows once, then 0; watch `ps` for any `claude --resume`: none); Claude Continue with a double-clicked Send (one message in Claude's history, same session ID); Send answer as message on K5 (one new user message, double click sends once).
8. **V1 completion on K1, after `sleep` exits:** Refresh clears the survivor item while sending stays paused; Check then lifts the hold.
9. **E2 on K1:** type in Continue…, close the editor, click Reconcile (Check history). Pass: the text lands in the message box with "This card no longer offers Continue, so the message you typed for it wasn't sent. It's now in the message box." Then send one message on K1: it appears once in Claude's history (V1's last step).
10. **E8 (K3):** read K3's saved session file, send one short turn, read it again: the restored Bash row still reads cancelled.
11. **E3, E4, E5** if their states occur (record "not reached" otherwise).
12. **E6 (K2), step 1:** click Edit on K2's settled row; its text goes to the message box; don't send it.
13. **A8** if not yet covered (section move while Reconcile or Continue runs).

### Part 4: relaunch round 2 (approval first)

- A normal quit and relaunch is enough; ask before it.
- **E6, step 2:** after the relaunch, K2 shows no crash hold for that run, the row doesn't return as needs action, and Claude's history is unchanged.
- **E5:** if a "couldn't be recorded" result happened in Part 3, record whether its text appears both in the message box and as the prefilled Continue text (a known duplicate; it fails only if something is sent twice).
- **R7:** the survivor item, if any, is visible in the sheet without opening the session.

## Evidence

Per scenario: pass or fail, the exact UI text, screenshots or accessibility dumps, the recovery record before and after (read only), `ps` before and after for process scenarios, and the provider's own history (Claude JSONL, Codex rollout) for send counts. Put raw evidence under `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle15/` and give paths.

## Reporting

- Write results to a new file, [verifier-9live-r2-results.md](verifier-9live-r2-results.md), in this directory, with the same header style as this file (title, Scope, Authority: Reference, Last-verified, Covers).
- Include: build commit, PIDs, approvals obtained (time and what), the result table, findings for the main agent, what is still to run, and the list of synthetic sessions created (full IDs), marked deleted or not.
- Send failures back to the main agent. Don't change code, the plan, the spec or [verifier-scenarios.md](verifier-scenarios.md).
