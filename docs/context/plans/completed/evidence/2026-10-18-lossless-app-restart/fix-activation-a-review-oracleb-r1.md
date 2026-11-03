# Step 9-activation-a re-review, round 1 — OracleB

Scope: read when the task touches the Step 9-activation-a re-review.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB round-1 re-review of prompt-exports/restart-fixes/act-a-delta.diff.

# Re-review, round 1: Step 9-activation-a

I reviewed only the attached delta (`act-a-delta.diff`), the worker report and the two current files. I couldn't read callers outside those files, such as `+RecoveryCheck.swift`, the other `ensureRunAttempt` call sites and how `sourceRunAttemptID` is filled in. Where a finding depends on that code, I say so.

## Summary

The round-1 and 1b fixes do what they say:

- **Run provider recorded:** the run's provider is now saved when its run attempt is first written, under `extras["providerKind"]`. It is never rewritten later, and the codec keeps it intact.
- **Continue and Reconcile refuse on mismatch:** they refuse before any reservation if the recorded provider differs from the session's current one, or if it is missing. A second guard catches cached requests built before a provider switch.
- **Rename:** the registry flag is now `isAnyPairRegistered`. Its consumers are audited.
- **Baseline capture:** Claude dispatch baselines now need Claude's own pairs covered.
- **`coversProvider`:** now needs every family that serves the provider.
- **Check's Stop:**
  - An item whose work hasn't started never starts after Stop.
  - Abandoning an item only releases a `.working` state that item's own Reconcile set.
  - Stopping the only item gives the cancelled heading.

**I found no confirmed P0 or P1.** One item (F1) is a P1 if it can be reached. I can't tell that from the attachments, but the fix is two lines.

## Your round-0 P1s

### P1-1 (provider source): fixed, with one fail-open gap (F1)

- **Recording on run start:** both run-start paths the worker found pass `session.selectedAgent.rawValue`:
  - `AgentRecoveryQueuedInput.swift:293`, used by Codex and by Claude/ACP/headless steering.
  - `AgentProviderHandoff.swift:313`, `commitDispatch` for Claude, ACP and headless.
  - The store writes it only when it creates the attempt (`AgentRecoveryStore.swift:~1207`). This matches "never rewritten", and the test confirms it after a provider switch.
- **Codec:** unknown members are kept as `extras`, and encoding starts from them. The new test checks the record re-encodes to identical bytes. Older app versions also keep the member.
- **Refusal:** it sits after the record read and before any write, reservation or request cache. The three tests through the real `performRecoveryResumeAction` check zero writes, zero reservations, nothing sent and nothing cached.
- **Saved messages and question answers can't be blocked.** The new guard is gated on `kind == .continueWithText || kind == .reconcileOnly` (`+RecoveryActions.swift:~187`). The cached-request guard only compares the target with the current provider, and a freshly built target always matches. So a missing provider can never refuse `sendSaved` or an answer. The rewritten Send-saved test confirms the path dispatches once.
- **"Every real run-start path"** is only partly verified: see F2 and F3.

### P1-2 (`isRegistrationActive` meaning): fixed

- Every renamed consumer either needs only "any pair" or checks its own pair or all pairs further down. I agree with each one in the worker's list.
- `capturesDispatchBaselines(for:)` checks `historyReconciliation`, registration and `coversProvider` for that provider. The VM still pre-filters to `.claudeCode`, and the test covers GLM, Kimi, custom and a Codex-only activation.
- `AgentRuntimeLaunchAuthority.isRegistrationActive(family:provider:)` keeps its name. That's correct, because it is per pair.

### Check Stop changes: no regression found

- **No new Reconcile after Stop:** the item's task and Stop both run on the main actor. The task checks `!wait.isFinished` first. Between that check and `markReconcileStarted()`, `checkOutcome` has no suspension: the catalog lookups and `runtimeExitIsProven` are synchronous.
- **Only Check's own `.working` is cleared:** if `reconcileStarted` is true and the row is `.working`, the window's Reconcile set it. `checkOutcome` already returns early when another action holds `.working`, and the worker confirms the window sets `.working` before its first `await`.
- **Finished-state logic:** `AgentRecoveryCheckOutcome??` behaves correctly. A Stop leaves `.some(nil)`, so `isFinished` is true and `value()` returns `nil`.
- **Cancelled heading:** a Stop always ends as either an abandoned item or "not checked" items. So `cancelRequested || notChecked > 0` can't mislabel a check that finished normally.

## P1

None confirmed.

## P2

**F1 — The run-provider guard lets a Continue/Reconcile through when `sourceRunAttemptID` is nil** (`AgentModeViewModel+RecoveryActions.swift:~187`)

```swift
if kind == .continueWithText || kind == .reconcileOnly, let sourceRunAttemptID { ... }
```

- **Problem:** a nil `sourceRunAttemptID` skips the guard entirely. The only check left is the cached-request guard. For a freshly built request, that guard compares a target built from the current provider with the current provider, so it always passes.
- **Failure scenario:** a run card whose request is built without a run attempt ID gets Continue after a Codex → Claude Code switch. For example, an interrupted turn known only from the transcript, or a recovery-only run with no linked attempt. The continuation is then sent as Claude Code to Claude's conversation. That is the round-0 P1-1 failure, and it contradicts the stated contract that a missing provider is "refused rather than guessed".
- **Severity:** P1 if any such card can reach Continue or Reconcile, otherwise P3. I couldn't check this from the attachments.
- **Fix:** fail closed:

```swift
if kind == .continueWithText || kind == .reconcileOnly {
    let attempt = sourceRunAttemptID.flatMap { id in runAttempts.first { $0.runAttemptID == id } }
    if let refusal = Self.recoveryRunProviderRefusal(recorded: attempt?.recordedProviderKindRaw, current: session.selectedAgent) {
        return refusal
    }
}
```

**F2 — The `providerKindRaw: String? = nil` default lets new or overlooked first-write paths skip recording without any warning** (`AgentRecoveryCoordinator.swift:~2962`, `AgentRecoveryStore.swift:~1174`)

- **Problem:** the terminal-evidence path (`.keepExisting`), the shutdown path and the delegated-child-link path pass nothing. Any run whose *first* recovery write is one of these gets a card that is permanently refused with "wasn't recorded". That can happen if the dispatch-evidence commit failed and the send continued, or for a run started outside durable input.
- **Impact:** it fails safe, but Continue and Reconcile are refused for cards they should work on.
- **Fix:**
  - Make `providerKindRaw` a required argument at the lane level, so the compiler lists every call site.
  - Pass the session's provider at the terminal and shutdown sites too. It is still written only when the attempt is created there.
  - Use an explicit `nil` only where no session is available.

**F3 — No test records the provider through the real Claude run-start path** (`AgentProviderHandoff.swift:313`)

- **Problem:** the new run-start test only goes through `AgentRecoveryDispatchEvidence.begin` with `.codexExec`. The reconciliation fixtures call `lane.ensureRunAttempt(..., providerKindRaw:)` directly, which skips production.
- **Failure scenario:** if `commitDispatch` stopped passing the provider, every Claude run card would be refused with "wasn't recorded" once the flip happens, and every suite would still pass.
- **Fix:** add a `commitDispatch` run-start test with `.claudeCode` in a new test file. That avoids the lint problem in `AgentProviderHandoffTests.swift`.

**F4 — The provider guard lives in the view model, not the runner**

- **Problem:** the runner's own provider gate still reads `request.target.providerKindRaw`, which is always the current provider. So any path that calls `AgentRecoveryActionRunner.perform` without going through `performRecoveryResumeAction` gets no run-provider check.
- **Likely fine for Check:** the `RecoveryResumeActionReport` parameter suggests Check's Reconcile in `+RecoveryCheck.swift` goes through `performRecoveryResumeAction`, so it is probably guarded. Please confirm.
- **Longer term:** the runner already reads the record in `beginRecoveryAction`. Moving the check there, or into the coordinator, would cover every path.

**F5 — After the flip, pre-existing run cards can only be dismissed**

- **Problem:** every run attempt written before this commit has no `providerKind`. Under `.claudeAndCodex`:
  - Continue and Reconcile are refused on those cards.
  - Check reports them as "could not check".
  - Continue in new conversation is off.
- **Impact:** that matches what you asked for ("refuse missing, legacy runs"). But it is owner-visible at the flip, and Reconcile only imports history, so its refusal is stricter than strictly needed.
- **Fix:** note it in the 9-flip acceptance so it isn't read as a regression during live checks.

## P3

- **Wording:** "Switch back to continue it." also appears on Reconcile refusals, and the `.absent`-record case says "provider wasn't recorded" (`+RecoveryActions.swift:~285–306`). Either could use more accurate text.
- **Debug-only assert:** the composition's consistency check is an `assert` (`AgentRecoveryAppComposition.swift:61`), so it is compiled out of release builds. That's acceptable because the activation isn't configurable, but a `precondition` costs nothing.
- **Misleading name at one site:** `AppRelaunchCoordinator.swift:194` reads `isAnyPairRegistered`, but this site really needs all pairs. It is safe only because of `verifyAllFamiliesStopped` and `safeRestart == false`. Using `registry.qualification.coversAllSupportedPairs` there would say what it means.
- **Long comment line:** one header line in `AgentRecoveryCoordinator+Check.swift:6–8` runs past the file's usual width ("…then reports on its card). It uses only existing machinery…").
- **Timing-based test:** `testCheckStopBeforeTheItemsWorkStartsNeverReconciles…` proves the negative with 20 yields plus a 50 ms sleep. Because everything runs on the main actor, it is reliable enough as-is.

## Recommendations

1. Apply F1's fail-closed change now: it's two lines and removes the only path where P1-1 can still fail open. Then the P1-1 disposition can stand without depending on how `sourceRunAttemptID` is built.
2. Do F2: make `providerKindRaw` required on `AgentRecoverySessionLane.ensureRunAttempt`, and pass the session's provider at the terminal and shutdown sites. The compiler then verifies "every real run-start path" instead of the worker's audit.
3. Add the F3 test through `AgentProviderHandoff.commitDispatch` with `.claudeCode`.
4. Confirm that Check's Reconcile in `+RecoveryCheck.swift` goes through `performRecoveryResumeAction` (F4). If it calls the runner directly, F4 becomes a P1: move the guard into the runner or coordinator.
5. Record F5 in the 9-flip acceptance notes. Defer the P3 items.
6. With F1 applied (or `sourceRunAttemptID` shown to be always set) and your validation rerun, I'd treat both round-0 P1s as closed and the step as ready to commit under the policy.