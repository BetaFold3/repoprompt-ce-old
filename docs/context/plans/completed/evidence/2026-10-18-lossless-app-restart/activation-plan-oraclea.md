# Step 9-activation plan consultation — OracleA

Scope: read when the task touches how recovery activation is composed, staged or approved (Step 9-activation).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA plan-mode answer on the scout plan: subset approval, ordering against live evidence, provider refusal, Check Stop, writer basenames.

## Summary

**O32 supports provider-limited recovery, but does not clearly approve unregistered fallback or activation before evidence. Ask one explicit question.** Recommend a single, source-controlled, debug-only acceptance configuration using the real production paths; keep ordinary production defaults off until live qualification. Treat subset activation, composition, and early provider refusals as **9-activation-a**. Keep Check abandonment and crash-hold auto-confirmation separate.

## Current-state analysis

The supplied code establishes this flow:

- `AgentRuntimeQualification.production` is empty. `activatesRegistration` requires all 13 supported family/provider pairs.
- `AgentRuntimeLaunchAuthority.makeLaunch` returns no ownership object while registration is off. Once active, `AgentProcessRegistry.reserveLaunch` rejects uncovered providers rather than permitting an unregistered fallback.
- Registered launches persist a reservation before spawning, establish birth identity before writes, and enforce association/write fences. These safeguards must remain fail-closed.
- `AgentRecoveryActionRunner.perform` checks capability and **global** registration, then obtains the coordinator hold, reserves durably, reconciles where applicable, dispatches through the normal path, and awaits settlement.
- A missing reconciliation performer currently permits continuation fallthrough. That becomes unsafe when the global capability flags turn on for unsupported providers.
- Claude baseline capture is coupled to history qualification plus global registration. Activation therefore changes **ordinary sends**, not merely recovery buttons.

Reuse the registry, runner, coordinator holds, launch ownership, and existing baseline transaction. A targeted change is sufficient; a new recovery framework is not.

The controller, composition, and Check details below rely on the scout: their complete implementations were not supplied.

## Design

### 1. Owner approval and evidence ordering

O32 reasonably establishes **which providers may execute qualified recovery**, but it leaves two materially different interpretations:

1. All launches remain subject to coupled qualification.
2. Only four pairs register; other providers continue ordinary unregistered operation.

The handoff expressly requires separate approval for the second. O36 approves the synthesis’s sequence, but neither decision clearly authorizes treating unobserved process-discovery assumptions as production evidence.

**Exact owner question:**

> O32 names Claude Code and Codex as qualified, but the existing handoff requires separate approval for partial process registration. May we register only standard Claude native/headless and Codex app-server/exec, leave other providers’ ordinary launches unregistered, and show explicit refusals for their recovery actions?
>
> **A — Approve subset, acceptance build first (recommended):** Enable those paths through one debug-only configuration, gather applicable V1–V9 evidence, then change production defaults in a reviewed commit. Fresh conversation, safe restart, and recovered-process Stop remain off.
>
> **B — Approve subset directly in normal builds:** Activate immediately for private use, accepting that ordinary Claude/Codex sends may now be refused by registration or baseline failures; run live acceptance afterward.
>
> **C — Retain coupled activation:** Keep execution off until all 13 pairs qualify; recovery UI may remain visible with explicit unavailable explanations.

Do not record A as an owner Decision until answered. Planning and isolated tests can continue; production activation remains the dependent blocked action.

**Recommend A.** Private-fork reversibility reduces deployment risk, but cannot undo duplicate provider work or incorrectly released ownership.

### 2. One acceptance configuration, not independent switches

Add `AgentRecoveryActivation` in AgentCore’s `Runtime/Recovery` directory as the immutable composition of:

- runtime qualification;
- action qualification;
- the optional app-wide process registry;
- the corresponding launch authority.

Use one custom compile condition, for example `RPCE_RECOVERY_ACCEPTANCE`, effective **only together with `DEBUG`**. No environment variable, defaults key, UI toggle, or runtime switching. This is a reviewed exception to the existing source-only activation policy, not new acceptance tooling.

Profiles:

| Profile | Registration | Recovery execution |
|---|---|---|
| Ordinary build before acceptance | Existing off behavior | Off |
| Debug acceptance build | Four specified pairs | Resume/reconcile on, subject to provider checks |
| Production after accepted evidence | Same verified four-pair profile | Same gates |

Fresh conversation and safe restart remain false in every profile. Supply no `AgentProcessStopActions`.

Construct the registry directly inside the composition; make existing production accessors forward to it. Do not create mutually recursive static initializers. Preserve `nil` production storage/registry in XCTest, explicit fixture injection, and all-off test defaults.

This preserves the intent of “9-activation then 9-live”: first wire an executable acceptance candidate, then validate it, then promote its verified configuration. Document that distinction rather than silently overriding the handoff.

### 3. Subset registration and ordinary-send safety

The scout’s subset approach is reasonable with these boundaries:

- Keep `supportedPairs` unchanged: it describes application capability, not current qualification.
- Change aggregate activation to “at least one supported pair covered.”
- Add `isRegistrationActive(family:provider:)` to `AgentRuntimeLaunchAuthority`; it requires both an active registry and exact-pair coverage.
- `makeLaunch(_:)` returns `nil` only for activation-off or an uncovered pair.
- Once a covered launch has ownership, **no registration, storage, inspection, association, or fence failure may fall back to unregistered execution**.
- Keep `reserveLaunch`’s `unqualifiedProvider` rejection as defense against incorrect direct callers.
- Replace global activation checks controlling ACP/compatible retirement and lifecycle behavior with exact-pair checks.
- Continue loading and enforcing existing runtime restrictions regardless of current pair qualification.

Partial coverage cannot prove whole-app quiescence. Besides keeping `safeRestart` off, make `verifyAllFamiliesStopped` refuse a whole-app proof when qualification does not cover all supported pairs.

**Normal-send effects requiring explicit acceptance:**

- Reservation/storage failures, missing operation-owned session context, identity inspection failure, and global runtime-store uncertainty can refuse ordinary sends.
- Claude’s baseline adds a history read and durable save; failed persistence refuses the write.
- Newly activated controllers must not reuse a previously unregistered transport as though registered.
- Empty registry records do not prove that pre-activation processes are absent. Start live acceptance from a verified clean test lifecycle; do not clear existing crash holds merely because no runtime record exists.
- Validate Codex’s owner-captured scope on launch and reuse paths; `.unavailable` must remain a refusal, not become sessionless.

Keep baseline capture coupled to qualified Claude recovery. **Do not introduce an independent “skip baseline but allow Continue” switch.** Preserve the existing distinction: missing history location/identity may be recorded as unsupported and permit an ordinary send; failed required persistence denies it. Unsupported baselines must subsequently refuse continuation, never be reconstructed retroactively.

Measure baseline latency during acceptance. A performance redesign is not part of 9-activation-a.

### 4. Provider refusal before any action reservation

Add an explicit runtime-provider eligibility check to the runner, using the composition’s qualification—not UI visibility or the selected provider alone.

Interface change:

- Before: `perform(_:lane:performers:)`
- After: `perform(_:provider:lane:performers:)`, where `provider` is `AgentRuntimeProvider` captured from the target recovery session and validated against that target before execution.

Update the recovery-action invocation and direct runner tests. Validate the actual call-site inventory during implementation; only excerpts were supplied.

Order the runner’s checks before `beginRecoveryAction`:

1. Capability enabled.
2. Registration active.
3. Target provider recovery-qualified.
4. Required history performer present.
5. Existing coordinator acquisition and durable action flow.

Provider qualification applies to **every recovery dispatch action**, including Send saved and answer-as-input. Require a history performer when the action actually requires reconciliation; do not add a history read to Send saved.

Use an explicit refusal such as:

> Recovery for \<Provider\> isn't qualified yet: RepoPrompt can't verify its process ownership and provider history. Nothing was sent.

Keep action affordances available as O32 requests. Check reports this as `couldNotCheck`; no durable action reservation or synthetic “nothing imported” outcome is created.

Preserve the existing join, prior-action, completion-binding, authorization, and exact-settlement logic.

### 5. Writer basenames

Do not assume `["claude"]` or `["codex"]` is evidence.

If Claude’s executable is `node`:

- Until verified, classify that discovered member as **unknown**, which conservatively retains possible-writer ownership.
- Add `node` as a writer basename only after V1 confirms the actual managed launch chain. Classification must apply to already-discovered runtime members, never all same-user Node processes.
- Keep tool basenames empty; never classify Node as a harmless tool to release ownership.

For the acceptance profile, unverified basenames may remain empty; explicitly label complete-discovery flags as hypotheses. Unknown-as-writer is conservative, but it does **not** establish complete discovery. Production qualification still requires real-path evidence.

### 6. Check’s Stop abandonment

The proposal is safe only as **stop waiting**, not cancellation or process termination:

- Race the reconciliation result against a main-actor stop signal using a one-shot waiter.
- Do not use a structured task group whose scope waits for the stuck child.
- Retain the underlying operation and coordinator hold until actual completion.
- Finish the Check report immediately, mark the current item “check continues,” and count remaining items as unchecked.
- Ignore late completion for the finished report; update the card only after validating its current identity/revision.
- A new action must still join or refuse under the existing hold. Clearing `.working` must not imply that sending is unblocked.
- Handle repeated Stop and simultaneous completion exactly once.

A permanently stuck operation retains its session hold until app exit. That limitation must remain visible.

**Exclude this from 9-activation-a.** It changes asynchronous lifecycle semantics independently of provider activation. Keep recovered-process Stop separate and unwired.

## File-by-file impact

Paths outside the supplied excerpts must be confirmed before editing.

| File | Planned change and dependency |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActivation.swift` — new | Own immutable profiles and shared registry; foundational composition change. |
| `…/Recovery/AgentProcessRegistrySupport.swift` | Subset activation semantics; unchanged supported-pair inventory; corrected qualification comments. |
| `…/Recovery/AgentProcessRegistry.swift` | Forward production registry to composition; preserve reservation guards; reject whole-app stopped proof under partial coverage. |
| `…/Recovery/AgentRuntimeLaunch.swift` | Exact-pair activation API and uncovered-pair `nil` launch; consume shared composition. |
| `…/Recovery/AgentRecoveryActionRunner.swift` | Provider/performer preflight, profile wiring, O32 comment explaining visible actions versus qualified execution. |
| `AgentRecoveryAppComposition.swift` | Inject the same runner and registry through `install(into:)`. |
| `AgentModeViewModel.swift`, `AppRelaunchCoordinator.swift` | Remove independent production choices; retain disabled fallback/test behavior and safe-restart gate. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift` | Pass validated target provider; update baseline comments without changing transaction semantics. |
| `ACPAgentSessionController.swift`, `ClaudeNativeProcessSessionController.swift` | Exact-pair lifecycle/retirement checks; depend on launch-authority API. |
| Existing Recovery/launch/composition tests named in the scout | Update intentional contracts and add subset, refusal, injection, and failure-path coverage. |
| Activation evidence documents, handoff, and owning plan | Record approval scope, candidate-versus-production distinction, evidence status, and deferred steps. Do not edit `review-policy.md`. |

Separate Check-abandonment work touches `AgentRecoveryCoordinator+Check.swift`, `AgentModeViewModel+RecoveryCheck.swift`, and their tests.

## Risks and migration

No persistence schema change is needed. Existing runtime records and restrictions remain authoritative.

Rollback does not erase records or establish that surviving processes exited. Verify that the rollback build still enforces records written by the acceptance candidate. Pre-activation Claude runs without baselines remain explicitly unrecoverable through Continue; do not migrate them into invented association evidence.

## Implementation order

1. **Confirm approval and inspect omitted seams.** Validate controller reuse, runner call sites, composition ownership, and test/build configuration.
2. **Implement 9-activation-a with production off.** Land subset semantics, shared composition, provider refusal, exact-pair lifecycle checks, and acceptance profile atomically.
3. **Validate a’s contract:** exactly four covered pairs; uncovered normal launches remain marker-free/unregistered; covered failures never fall back; all six unqualified provider kinds refuse every recovery execution before reservation; missing required performer cannot dispatch; all consumers share the registry.
4. **Run the scout’s affected suites and repository checks.** Fixture results prove contracts, not live qualification.
5. **Implement remaining separately reviewed steps:** Check abandonment if desired; **9-activation-b** for proof-bound crash-hold auto-confirmation. Preserve the full O36 sequence rather than dropping b.
6. **Run 9-live on the bound debug candidate.** Include process-chain evidence, newly started Claude runs, Codex scope/reuse, refusal UX, ordinary-send failures, and baseline latency. Mark recovered Stop/V3 blocked or skipped explicitly—not passed.
7. **Promote verified defaults in a separate reviewed change.** Rerun affected validation; retain partial status for unresolved required scenarios.

## Recommendations

- Ask the owner explicitly; recommend **subset activation through a debug acceptance build first**.
- Keep **9-activation-a** limited to composition, subset launch semantics, early refusals, and their tests.
- Preserve fail-closed registration and baseline persistence; never silently downgrade a covered launch.
- Treat unknown executables as possible writers until evidenced.
- Keep Check abandonment, crash-hold auto-confirmation, and recovered-process Stop independently scoped.