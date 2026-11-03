# 9-live re-check (round 4, final): verifier brief

Scope: read when the task touches the fourth and final live re-check of crash recovery before the activation switch.
Authority: Reference
Last-verified: 2026-10-29
Covers: the verifier's instructions, fixtures and checks for the round-4 live re-check

You are the external verifier for RepoPrompt CE's crash recovery. This is a short, final round. It checks only what round 3 couldn't pass: Claude Reconcile and Continue after a tool-turn kill, and a clean Claude crash hold. Everything else passed in earlier rounds or is accepted on unit tests (list below), so don't re-run it.

The safety rules, evidence rules and approval rules are the same as round 2 ([verifier-9live-r2-brief.md](verifier-9live-r2-brief.md), "Safety rules" and "Evidence"). The universal hard fail still applies:

- any message sent that a step didn't ask for;
- any second copy of a message;
- any lost typed text.

## What changed since round 3

Round 3's blocker was T1 ([results](verifier-9live-r3-results.md)). A Claude turn that ran a tool other than Read could never be matched to Claude's history, so Reconcile refused and Continue was blocked. The cause was not the warm-up turn: live tool rows carry IDs that Claude's history doesn't have.

Now, when the sent message matches Claude's history exactly but the output can't be matched:

- **Reconcile** imports nothing and says one of these:
  - "Claude's history has output RepoPrompt couldn't safely match to this conversation. Nothing was imported, so some of it may not show here; Claude still has it."
  - "RepoPrompt couldn't safely match this conversation's output to Claude's history. Nothing was imported."
- **Continue** goes ahead and sends the typed text once.

The two refusals that used to share one text now differ:

- "A message of yours couldn't be safely matched between this conversation and Claude's history. Nothing was imported or sent."
- "Output shown in this conversation couldn't be safely checked against Claude's history. Nothing was imported or sent."

## The build

The committed tree the owner names must include the T1 fix (Step 9-live-r3-fixes), plus the one uncommitted line `package static let production: AgentRecoveryActivation = .claudeAndCodex` in `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActivation.swift`.

Record `git rev-parse HEAD`, `git diff -- Sources Packages` (that line only), the app PID and the provenance commit.

## Before you start

- **Cleanup:** if the owner asked, delete the round-3 synthetic sessions through the UI first. They're listed in the round-3 results.
- **Approval:** ask the owner before the kill and the relaunch, unless the owner pre-approved them for this run in your terminal.

## Fixtures

Name each `RPCE_VERIFY_<id>_r4_<date>`. Use Claude Code (standard).

1. **Warm-ups:** run one short completed warm-up turn in each fixture.
2. **Kill turns:** start both kill turns within a minute of each other. Each asks Claude to run the Bash command `sleep 90` and then say done.
3. **Kill:** once both Bash rows show as running, kill the app.

| ID | Used by |
|---|---|
| C1 | clean Claude hold (Check), then V5 tool case: Reconcile twice |
| C2 | V6 Claude: Continue with a double-clicked Send |

Before the kill, record `ps -eo pid,ppid,pgid,comm` and read both recovery records (read only).

## After the relaunch, in order

1. **Wait for the processes to exit.** Wait until both `sleep 90` processes have exited (about 2 minutes after the kill; confirm with `ps`).
2. **Check (clean hold).** Run Check.
   - Pass: C1's and C2's holds are confirmed with "Resolved: Process records show every process of the interrupted run exited."
   - Record the full report line.
3. **V5 tool case (C1).** Open C1 and run Reconcile (Check provider history) twice.
   - Pass: both times, one of the two "Nothing was imported" texts above. No row is added or duplicated. Nothing is sent: Claude's history keeps the same user entries, and `ps` shows no `claude --resume` started by Reconcile.
   - Record the exact text.
4. **V6 Claude (C2).** Open C2, click Continue…, type a short message and double-click Send.
   - Pass: the message appears once in the conversation and once in Claude's history, in the same Claude session, and Claude replies.
   - Record the user-entry count in Claude's history before and after.
5. **Normal send (C1).** Send one short message on C1.
   - Pass: it appears once in Claude's history, and Claude replies.
6. **Normal quit and relaunch** (approval as above).
   - Pass: no crash hold returns for C1 or C2.
   - Pass: no row comes back as needing action.
   - Pass: Claude's history is unchanged across the relaunch.

If a refusal appears instead of a pass, record its exact text, take a screenshot, and stop that scenario. Don't retry with variations.

## Accepted without a live run (don't test)

These are covered by unit tests, because this app can't produce their live state on demand:

- V5 text cases: a Claude text answer appears only once it's complete, so there is no partial answer to kill.
- S5: the two-PID survivor text. `claude` exits about 20 s after the kill, so it can't be alive at the relaunch.
- P5 banner steps: these need a synthetic banner row.
- E2 for Claude: Claude Reconcile never confirms completion, so the card keeps offering Continue.
- E3–E5.
- E6 step 1.
- V4/E9 Codex import with a long answer.

## Reporting

Write results to a new file, [verifier-9live-r4-results.md](verifier-9live-r4-results.md), in this directory, in the same header style as earlier rounds, then link it here. Include:

- the build commit, PIDs and approvals;
- the result table with exact texts;
- any finding;
- the synthetic sessions (full IDs), each marked deleted or not.

Send failures back to the main agent.
