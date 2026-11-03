# Step 9-activation-a re-review, round 2 — OracleB

Scope: read when the task touches the Step 9-activation-a final re-review.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB round-2 re-review of prompt-exports/restart-fixes/act-a-delta2.diff.

# Round-2 re-review: Step 9-activation-a

I found no P0 or P1. F1 is closed, and making `providerKindRaw` a required argument caused no regression on any path you can reach today.

**What round 2 changes:**
- **F1:** the run-provider guard on Continue and Reconcile now fails closed. A nil `sourceRunAttemptID`, an attempt missing from the record, or an absent record all get the "wasn't recorded" refusal before anything is reserved.
- **Required provider argument:** every writer that can create a run attempt must now pass `providerKindRaw`:
  - the store's and lane's `ensureRunAttempt`
  - terminal evidence and its retry
  - shutdown evidence
  - the parent's delegated child link
- **New test:** a Claude run-start test through `commitDispatch`.
- **Stop wording:** Check's pre-start Stop now reads "Stopped before checking this item."

My only real concern is a P2. The terminal, shutdown and delegated-link writers record the session's provider at write time, not at run start. They are only correct while the provider can't change during a run, and I couldn't check that from the attached files.

## F1: closed

- **Guard:** `+RecoveryActions.swift:187-193` sends `kind == .continueWithText || kind == .reconcileOnly` to `recoveryRunProviderRefusal(sourceRunAttemptID:runAttempts:current:)` at `:302-309`.
  - `sourceRunAttemptID.flatMap { … }` gives nil for both a nil ID and an unknown ID.
  - The `recorded:` overload then returns `recoveryRunProviderNotRecordedText`.
- **Absent record:** `.success(.absent)` leaves `runAttempts` empty, so it also refuses. That is the correct fail-closed result.
- **Before any write:** the refusal returns after `readRecord()` and before the prior-action, slot-cache and runner code, so nothing is written.
- **Check:** Check's Reconcile goes through `performRecoveryResumeAction` (`+RecoveryCheck.swift:95`), so it inherits the guard. A legacy card now shows "could not check" with the not-recorded text.
- **Test:** the helper-level test is enough here, because the call site only does the `kind` check and the helper call.

## Required-argument change: checked per path

| Path | Provider recorded | Correct? |
|---|---|---|
| Lane/store `ensureRunAttempt` (`AgentRecoveryCoordinator.swift:2962-2969`, `AgentRecoveryStore.swift:1174`) | The caller's value; the compiler now forces every call site to state one | ✓ |
| Terminal evidence (`AgentRunTerminalCommitBarrier.swift:394`) | `session.selectedAgent` of the lane-owning session, read when the call is made | ✓ if the provider can't change mid-run (see P2-1) |
| Terminal-evidence retry (`AgentRecoveryCoordinator.swift:3073`, `:3085-3087`) | The tuple saved on the first attempt, never re-read at shutdown | ✓ |
| Shutdown (`AgentModeViewModel+Shutdown.swift:345`, used at `AgentRecoveryCoordinator.swift:2654`) | `session.selectedAgent` at shutdown, with `.keepExisting` | ✓ if no mid-run switch (see P2-1) |
| Delegated child link (`AgentModeViewModel+DelegatedChildLinks.swift:300`, `AgentRecoveryStore+DelegatedChildLinks.swift:91`) | `admission.parentSession?.selectedAgent`, applied only to `parentOwnership`. The guard at `:78` ties it to `link.parentRunAttemptID`, and the transaction runs on the parent's lane | ✓ parent's provider, parent's attempt only. A nil `parentSession` gives nil, which fails closed |

Every path still writes the provider only when its write creates the attempt (the store logic is unchanged). An attempt that run start already created keeps its run-start value.

## P2 (consider)

### P2-1: Post-start writers record the provider at write time, not at run start
- **Where:** `AgentRunTerminalCommitBarrier.swift:394`, `AgentModeViewModel+Shutdown.swift:345`, `AgentModeViewModel+DelegatedChildLinks.swift:300`.
- **What's wrong:** before this round, these writers passed nil. An attempt they created was therefore refused as "not recorded". Now they record the session's provider at the moment they write. That only matches the run-start provider if the provider can't change while the run is active.
- **Failure scenario:**
  1. A run starts on Codex, and its run-start dispatch write fails or happens before the lane is claimed. No attempt exists yet.
  2. The session's provider changes to Claude Code while the run is still active.
  3. The terminal or shutdown write creates the attempt and records `claudeCode`.
  4. After relaunch, Continue on that card passes the guard and runs as Claude Code against the old Codex run. That is the round-0 P1-1 scenario, coming back through a narrower path.
- **Likelihood:** it needs both a missing run-start record and a provider switch during an active run. If the UI or view model already blocks switching mid-run, this can't happen. If it allows it, raise this to P1.
- **Fix, smallest first:**
  - Confirm that `selectedAgent` can't change while `runState.isActive` and cite the file:line in the status line. No code change is needed then.
  - Or capture the provider once in `session.beginRunAttempt(source:)`, for example on `AgentRunOwnership`. Every writer would then read `ownership.providerKindRaw`, and all paths would record the run-start provider by construction.
  - Or go back to passing nil from the terminal and shutdown paths, which restores the fail-safe refusal.

### P2-2: No test covers the three new production providers
- **Where:** only nil is passed at the changed call sites, in every test in the delta.
- **What's wrong:** a regression that passed nil again, or passed the child's provider instead of the parent's, would stay green.
  - Terminal evidence (barrier) and shutdown would just fall back to the "not recorded" refusal.
  - The delegated-child-link case is worse: it would record the wrong provider on the parent's attempt.
- **Fix:** one test per path where that write creates the attempt, asserting `recordedProviderKindRaw` equals the owning (or parent) session's provider. For the delegated link, give the child a different provider from the parent.

## P3 (improvement)

- **P3-1: Doc comments merged by mistake (`+RecoveryActions.swift:296-301`).** The new overload was inserted under the old doc comment, so two doc blocks now sit on `recoveryRunProviderRefusal(sourceRunAttemptID:…)`, and `recoveryRunProviderRefusal(recorded:current:)` at `:311` has none. Move the first three lines down to `:311`.
- **P3-2: Refusal wording is about Continue only.**
  - `recoveryRunProviderNotRecordedText` says "can't be continued safely. Nothing was sent."
  - The mismatch text says "Switch back to continue it."
  - Both are also shown for Reconcile and in Check results, where nothing is being sent or continued. A neutral wording would fit all three, for example: "This card's provider wasn't recorded, so RepoPrompt can't act on it safely. Nothing was changed."
- **P3-3: The new run-start test may not prove the session's provider is read.** `AgentRunStartProviderRecordingTests` sets `.claudeCode`. If `boundTabSession()` already defaults to Claude Code, the test can't tell "reads `session.selectedAgent`" apart from a hardcoded value. Assert the fixture's default first, or add a second case with a different provider (for example Claude-compatible) that goes through the same `commitDispatch`.
- **P3-4: The nil/unknown-ID path is only tested at helper level.** This is acceptable as reasoned. Note it in the status line so nobody reads it as a real-path test of a legacy card.

## Recommendations

1. **Commit gate:** no P0 or P1 is open, so once you've rerun validation the step can be committed under the policy.
2. **Resolve P2-1 before activation goes on.** The cheapest option is a one-line confirmation that `selectedAgent` can't change while a run is active. If it can, capture the provider on `AgentRunOwnership` at `beginRunAttempt`. Record the choice under `assumed:` or `deferred:`.
3. **Defer P2-2 and the P3s** unless they're cheap now. P3-1 and P3-2 are text-only edits.
4. **Owner note:** failing closed means every interrupted run created before this build can no longer be continued or reconciled. That includes Reconcile, which only imports history. It's consistent with what you accepted in round 1b, but list it in the release or activation notes, together with the open round-1b question on whether Continue in new conversation should also be guarded.