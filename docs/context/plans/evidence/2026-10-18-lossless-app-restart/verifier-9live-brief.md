# Verifier brief: 9-live, recovery activation switched on (2026-10-28)

Scope: read when the task touches the 9-live run of lossless-restart recovery with activation switched on, or its results.
Authority: Reference
Last-verified: 2026-10-28
Covers: what the external verifier runs on the activation-on candidate build, and where results go

## The build

- **Candidate:** commit `74edea8b` plus one uncommitted line, `AgentRecoveryActivation.production = .claudeAndCodex` in `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActivation.swift`. The main agent checked that it compiles (`make dev-build`).
- **App:** the owner rebuilds and relaunches the daily debug app. Record its PID and its `RepoPromptDebugProvenance.json` commit. The provenance shows the build as dirty, and that is expected: the uncommitted line is the activation switch. Other sessions also have uncommitted files in this checkout; those are also expected.
- **Effect:** activation is on for the whole app, not only for test sessions. New Claude Code and Codex launches are registered, and recovery actions really run.

## Ground rules

Follow "Ground rules for the verifier" in [verifier-scenarios.md](verifier-scenarios.md). In particular:
- Use synthetic `RPCE_VERIFY_<scenario>_<date>` sessions only.
- Ask the owner for approval immediately before every app kill, relaunch, quit or process signal.
- Read recovery records and never edit them.
- The universal hard fail applies: any unrequested or duplicate send, or any lost typed text.
- The verifier does not change code.

## What to run

1. **Activation checks: V1, V2 and V4–V9** from verifier-scenarios.md, section "Step 9-activation".
   - Skip V3: no reviewed registry Stop entry point exists yet (9-stop).
   - Run V9 only if the owner uses OpenCode or Oh My Pi.
   - For V1, first confirm that the child process carries `RPCE_RUNTIME_ID` (`ps eww <pid>`).
2. **Checks that need activation:** A8, A9 and C2 from the same file.
3. **Crash-hold confirmation by Check (Step 9-activation-b):**
   - Kill the app (approval first) during a Claude turn that has no long-running tool. Relaunch.
   - Make sure the turn's processes are gone (`ps`), then run Check and resolve.
   - Pass: the crash hold is confirmed without opening the session, and sending resumes.
   - Repeat with a process still alive, for example a long Bash tool. Pass: Check does not confirm the hold, and the item names the live process.
   - Note any session whose record names several sessions; it may refuse more often than needed (review note B-R1-04).
4. **P5 and its neighbours (Esc on the View popover):** steps 1–13 under "Manual steps for the external verifier" in [fix-p5-esc-worker.md](fix-p5-esc-worker.md).
   - Also check that one Esc does not interrupt a running agent turn.
   - For P10, check that the Xcode console shows no SwiftUI "modifying state during view update" warnings, if a console is available.

## Reporting

- **Where results go:** write them to a new file, [verifier-9live-results.md](verifier-9live-results.md), with the same header style as this file.
- **Per scenario:** pass or fail, evidence paths, session IDs, approvals obtained, and any unexpected UI text.
- **Cleanup:** delete the synthetic sessions through the UI, with the owner's approval, and list them.
- **Failures:** send them back to the main agent. The verifier does not change code, and does not change the plan file.
