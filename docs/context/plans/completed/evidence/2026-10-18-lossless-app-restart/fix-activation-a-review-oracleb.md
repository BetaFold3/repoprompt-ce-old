# Step 9-activation-a review, round 0 — OracleB

Scope: read when the task touches the Step 9-activation-a review.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleB round-0 review of prompt-exports/restart-fixes/act-a-r0.diff.

# Review: Step 9-activation-a (`act-a-r0.diff`)

## Summary

The diff adds one `AgentRecoveryActivation` value with two settings, `.off` and `.claudeAndCodex`, and sets `production = .off`. It removes the two separate `.production` qualification statics. The registry, launch authority, app composition, view-model default and relaunch coordinator all now read from the new value. Registration is now active when any supported pair is covered, and each launch checks its own family/provider pair. Under partial coverage, `verifyAllFamiliesStopped` refuses to give a whole-app proof. The runner now refuses unqualified providers before it takes the action hold or reserves anything. Check's Stop now stops waiting on the current item without cancelling it.

I couldn't open files beyond the diff and the attached excerpts. Findings that depend on code outside the diff are marked **PLAUSIBLE (verify)**.

**No P0 findings.**

**Behaviour while `production = .off`:** I traced each production consumer:
- **Registry:** still empty qualification, so `activatesRegistration` is false under both the old and new rules.
- **Launch authority:** still `.activationOff`.
- **Runner:** the first guard still returns `disabledText`.
- **Baselines:** `capturesDispatchBaselines` is still false.
- **Relaunch:** `AppRelaunchCoordinator.production()` is still nil.
- **`install(into:)`:** now overwrites the runner and history registry, but with values equal to the old defaults.

The only change a daily-build user can see is Check's Stop:
- The progress text now reads "Stopping…".
- Each item now runs in its own unstructured task.

Check runs with `checksActive == false` in production, so this is harmless apart from the race in P2-1.

**Claude-compatible and headless mapping:** no finding.
- `claudeCodeGLM`, `kimiCode` and `customClaudeCompatible` map to `.claude(variant)`, which `.claudeAndCodex` doesn't cover. Both `coversProvider` and the runner refuse them, and the tests assert this.
- Headless GLM gets no launch owner from `makeLaunch`.
- `ClaudeNativeProcessSessionController` takes its family from the actual variant: `.standard` maps to `.claudeNative`, everything else to `.claudeCompatible`.

---

## P1

### P1-1 — The runner's provider gate and the window's performers read the provider from different places — PLAUSIBLE (verify)
**Evidence:**
- The gate in `AgentRecoveryActionRunner.swift` `perform` (the new block after `registrationActive()`) reads `request.target.providerKindRaw`, the provider recorded for the source run.
- The window builds its performers in `AgentModeViewModel+RecoveryActions.swift` (`reconcilesProviderHistory = session.selectedAgent == .claudeCode || .codexExec`) from the session's *current* provider. Dispatch goes through the normal send path, which also uses the current provider.

**Failure scenario (under `.claudeAndCodex`):**
1. A Codex run is interrupted.
2. After relaunch, the user switches the session's agent to Claude Code.
3. The user clicks Continue on the old Codex card.
4. The gate passes because Codex is qualified. A reconcile performer exists because the session is now Claude Code. That performer runs Claude history reconciliation against a Codex conversation ID.
5. If it comes back `nothingImported`, the continuation dispatches through Claude.

The reverse case also exists: the target is Claude Code but the session is now GLM, so no performer is built and the user gets "Recovery for **Claude Code** isn't qualified yet". That message is misleading.

**Impact:** the gate could approve a recovery that is actually performed by a different provider, which is the silent-allow case the acceptance criteria rule out. The provider value can't be spoofed: it comes from the stored target. A missing value refuses correctly with "this provider".

**Smallest fix:** in the window, refuse before calling `perform` when `AgentProviderKind(rawValue: target.providerKindRaw) != session.selectedAgent`. Alternatively, have the runner take `provider:` explicitly (as OracleD planned) and require it to equal the target's provider.

**Downgrade to P2** if `reserveRecoveryAction` or the dispatch path already refuses a target whose provider differs from the session's current provider. No refusal at that point would be reached anyway, because the provider gate runs before any reservation.

### P1-2 — `AgentProcessRegistry.isRegistrationActive` changed meaning without a rename, and its consumers weren't audited — PLAUSIBLE (verify before 9-live)
**Evidence:**
- `AgentProcessRegistrySupport.swift` `activatesRegistration` changed from "all pairs covered" to "any pair covered".
- The launch authority's pair-less property was deleted, so the compiler found its callers. The **registry's** own `isRegistrationActive` kept its name, so the compiler can't find callers that now mean something different.

Consumers visible in this diff:
- `AgentRecoveryActionRunner.capturesDispatchBaselines` (`historyReconciliation && registrationActive()`).
- `makeActionRunner`'s `registrationActive: { registry?.isRegistrationActive == true }`.
- `AgentRuntimeLaunchAuthority.production`.

The lifecycle-shutdown and quit paths (Stage A/B survivors) presumably read it too.

**Failure scenario (under `.claudeAndCodex`):**
- If the Claude dispatch path checks `capturesDispatchBaselines` without checking the runtime variant, an ordinary GLM or Kimi send would read history and save a baseline. That send would be refused if the save fails, even though the provider is unqualified and unregistered.
- If quit or shutdown code treats "registration active" as "every live controller is registered", it could misclassify unregistered ACP or compatible processes.

The worker's audits covered Codex scope binding and sessionless Claude launches. They didn't cover these consumers. The quit-policy and lifecycle suites ran only under off or fixture qualification.

**Smallest fix:** grep every `.isRegistrationActive` and `registrationActive()` consumer and confirm each one either needs only "some pair is covered" or checks its own pair. Give baseline capture an explicit `.claude(.standard)` check, or document that it already has one. Optionally rename the registry property to `isAnyPairRegistered` so the compiler lists the call sites.

---

## P2

### P2-1 — Stop has a race window that can start a new Reconcile after Stop and clear a `.working` state Check didn't set
**Evidence:** `AgentRecoveryCoordinator+Check.swift`. `waitForCheckOutcome` queues `Task { … checkOutcome(…) }` and then suspends on `wait.value()`. The abandon branch in `checkCatalogItems` clears `.working` for any item in that state.

**Scenario:** Stop arrives on the main actor after the per-item task is queued but before it runs. Then:
- `finish(nil)` wins. The item is reported as "Its check continues" and Check finishes.
- The queued task runs anyway. `checkOutcome` calls `reconcile(item)`, which starts a *new* Reconcile, with a hold, a reservation and history writes, after the user pressed Stop.
- In the same window, if another window's action had set the item to `.working`, the abandon path clears that row's state even though Check never owned it. If `checkOutcome` had run, it would have returned "Another action on this item is in progress."

**Fix:**
- Give `AgentRecoveryCheckItemWait` an `isFinished` property. In the task, check it (or `recoveryCheck?.cancelRequested`) before calling `checkOutcome`.
- Record on the wait whether `reconcile` actually started, and only clear `.working` when it did.

### P2-2 — The plan's late-completion guard isn't visibly implemented
OracleD §3.4 asked for a guarantee that the window's late-completion path (`+RecoveryCheck.swift:98`) "cannot re-set `.working` after the report cleared it". The `+RecoveryCheck` hunk only adds `self.` and a comment.

If `reconcileRecoveryCheckItem` sets `.working` after its first `await`, a Stop during that await clears nothing. The row then shows `.working` until the hung Reconcile ends. That is arguably accurate, but it doesn't match the acceptance text "`.working` cleared".

**Fix:** confirm where `.working` is set, then either guard it or record that the current behaviour was intended.

### P2-3 — `coversProvider` accepts coverage from any one family
**Evidence:** `AgentRecoveryActivation.swift` `coversProvider` passes if *any* supported family covers the provider. That is correct for `.claudeAndCodex`, which covers both families for each provider.

**Latent risk:** a future value that qualified only `.codexExec`, or only `.claudeHeadless` for GLM, would pass the runner gate. Meanwhile the provider's Agent Mode runs (app-server or compatible native) would launch unregistered, so recovery would act without process ownership.

**Fix:** require every supported family that serves the provider to be covered, or gate on the family the target run actually used.

### P2-4 — The composition takes `activation` and `processRegistry` as separate parameters
**Evidence:** `AgentRecoveryAppComposition.init`. A caller can pass `activation: .claudeAndCodex` with a registry built from a different qualification. Launch authority and controllers always read `AgentProcessRegistry.production`, whatever activation was injected. In production both come from `.production`, so this only affects tests. Still, the "one activation" property isn't enforced.

**Fix:** add `assert(processRegistry.map { $0.qualification == activation.runtime } ?? true)` in the init, or build the registry from the activation.

### P2-5 — Misleading refusal when a qualified provider has no history performer
When the provider is qualified but `performers.reconcile == nil`, the runner reports "Recovery for Claude Code isn't qualified yet…". That's false: the real cause is the window not supplying a performer, usually the P1-1 mismatch.

**Fix:** use a separate text such as "Provider history isn't available for this session. Nothing was sent."

### P2-6 — Some test assertions are weaker than they read
No existing assertion was weakened. Every contract change I saw matches the plan's intended semantics:
- subset `activatesRegistration`
- `allowsFreshSessionID` following its own pair
- `.unqualifiedProvider` for direct callers
- abandoned-item reporting
- `calls.reconcile` going from 1 to 2, with the reconcile-first assertion added

Some of the new assertions check less than they appear to:
- `testUnqualifiedProvidersRefuseEveryChoiceBeforeAnyReservation`: `XCTAssertFalse(isCoveredByRecoveryAction)` runs after `perform` returns, when any hold would already have been released, so it can't fail. The revision and empty-actions checks do carry the "zero writes" claim.
- `testCheckStopHaltsBeforeTheNextItem…`: a single `Task.yield()` before the "late result never reaches the report" check. That property holds by construction, since the loop has already returned, so the test proves little.
- `testCompositionAndViewModelDefaultReadTheOneProductionActivation`: while `production == .off`, it can't tell a hard-coded `.off` default from a read of `.production`. This is inherent until the flip; note it for 9-flip.
- `testQualifiedProviderWithoutAHistoryPerformer…`: `XCTAssertNotEqual(sent, .disabled(expected))` for Send saved would also pass on any other refusal. Prefer asserting the specific expected result.

### P2-7 — `ClaudeNativeProcessSessionController` works out the launch family in two places
**Evidence:** `registersLaunches` comes from `runtimeFamily(config.runtimeVariant)` at init, while the launch around line 1290 builds its context from its own local `family` and `provider`. `makeLaunch` now checks the pair itself, so the `if registersLaunches` gate does nothing except skip gathering context. If the two derivations ever differ, `joinsRetirementBeforeSuccessor` and actual registration would disagree.

**Fix:** have the launch site use `Self.runtimeFamily(config.runtimeVariant)` and `.claude(config.runtimeVariant)` too, or compute the family once.

---

## Recommendations

1. **Before committing:** close P1-1, or downgrade it with evidence that the store or dispatch already refuses provider-mismatched targets. The cheapest fix is an equality check between `target.providerKindRaw` and `session.selectedAgent` before `perform`.
2. **Before 9-live:** do the P1-2 audit of every `registry.isRegistrationActive` and `registrationActive()` consumer, especially Claude baseline capture for compatible variants and the quit/shutdown survivor logic. Record the result next to the D 3.5 audits.
3. **Fix P2-1 now:** it's a few lines (an `isFinished` check before `checkOutcome`, and only clearing `.working` that Check set). Also confirm P2-2.
4. P2-3 to P2-7 can be fixed cheaply now or listed as deferred. P2-3 should be fixed before any activation value covers a provider in only one of its families.
5. The other acceptance items hold as written:
   - a covered launch never falls back to unregistered
   - `reserveLaunch` still throws `unqualifiedProvider`
   - marker stripping is unconditional
   - the stopped proof is refused and launches aren't sealed under partial coverage
   - the refusal text matches exactly
   - an unknown `node` basename keeps blocking sends

   All of these come from fixtures, not live runs. 9-live still has to provide the live evidence.