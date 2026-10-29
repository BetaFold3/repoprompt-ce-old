# Step 9-activation plan consultation — OracleD

Scope: read when the task touches how recovery activation is composed, staged or approved (Step 9-activation).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleD plan-mode answer on the scout plan: subset approval, ordering against live evidence, provider refusal, Check Stop, writer basenames.

## Summary

Activation is a design change, not a flag flip, because `AgentRuntimeQualification.activatesRegistration` demands all 13 supported pairs and `reserveLaunch` refuses uncovered pairs outright. The plan: (1) one AgentCore composition value `AgentRecoveryActivation` that owns runtime qualification and action qualification together, with two named values (`.off`, `.claudeAndCodex`) and one `production` constant; (2) subset-registration semantics where an uncovered pair launches unregistered (nil launch) exactly as today and ACP/compatible controllers never join registered retirement; (3) a runner-level refusal for unqualified providers before any reservation; (4) Check's Stop abandons the awaited item without cancelling it. Ordering: land the wiring with `production = .off`, let the verifier flip that one constant on a local candidate for V1–V9, then flip it in a separate one-line commit. That satisfies O32/O36, the handoff's "separate reviewed source decision", and keeps the owner's daily build from inheriting the two unverified failure modes (Codex `.unavailable` scope, writer basenames).

## Current state (what blocks a flag flip)

- `AgentRecoveryActionQualification.production` (runner :44) and `AgentRuntimeQualification.production` (support :60) are two independent statics; `AgentProcessRegistry.production` (:81) bakes the latter in at init (`isRegistrationActive = qualification.activatesRegistration`). `AgentModeViewModel` (:679–690) and `AppRelaunchCoordinator` (:189) pick qualification on their own — the handoff's unmet prerequisite 1.
- `activatesRegistration` (support :78) = all 13 pairs covered. `AgentRuntimeLaunchAuthority.makeLaunch` (:97) returns a launch for *any* pair once active; `reserveLaunch` (:684) then throws `unqualifiedProvider` → the spawn is refused. So a subset without the `makeLaunch` change refuses every ACP/compatible/headless-variant launch.
- Runner gates: `qualification.allows(kind) && registrationActive()` (:167–168), then the reservation. It has no notion of the target's provider; `performers.reconcile == nil` is silently skipped (:182), so Continue/Send saved for GLM/Kimi/ACP dispatch with ownership unproven.
- Baselines: `capturesDispatchBaselines` = `historyReconciliation && registrationActive()`; `captureClaudeDispatchBaseline` (:874) refuses the send on a failed save. Claude runs started before activation have no baseline → Continue/Reconcile refuse with `.associationUnavailable(.baselineUnavailable)`. Correct fail-closed behaviour; a verifier note, not a defect.

## Q1 — Does O32 approve the subset?

O32 approves *which providers are qualified* (Claude Code, Codex). It does not literally approve narrowing *process registration*, which is the thing the handoff (:241) and the `activatesRegistration` comment ("one coupled activation") forbid. The synthesis's "registration turns on in the same commit" is the main agent's interpretation, and the review policy says interpretations are not Decisions. So ask — but the choice is local and reversible (one value in one file), so proceed on the recommendation and record `assumed:` while waiting.

Draft owner question:

> **O37 — Subset process registration.** O32 names Claude Code and Codex as the qualified providers. Process registration is currently all-or-nothing across 13 family/provider pairs, and live-acceptance-handoff.md:241 forbids activating a subset without a separate owner-approved design change. Choices:
> **A)** Treat O32 as that approval: register Claude standard (native + headless) and Codex (app-server + exec) only. The other 9 pairs (compatible GLM/Kimi/custom, headless GLM/Kimi/custom, ACP OpenCode/Cursor/Oh My Pi) launch unregistered exactly as today; their recovery buttons refuse with a named reason; Restart safely stays off because unregistered families can't be proven stopped. *(Recommended — the only option under which V5/V6 can produce evidence.)*
> **B)** Keep all-or-nothing: registration stays off for everyone, action flags turn on nominally but every action refuses with "process tracking is not active". 9-live cannot verify Continue/Reconcile.
> **C)** Register all 13 pairs now, treating `supportsCompleteDiscovery=true` as an unverified input for the 9 pairs (not recommended: a wrong discovery claim can release conversation ownership or refuse launches the app still needs).
> I am proceeding on A as `assumed:`; say B or C to redirect.

## Q2 — Ordering against the handoff

Chicken-and-egg: V5/V6/V7 evidence needs registration and baselines on, but the handoff wants evidence before production activation. Three options:

| Option | New tooling | Daily build risk | Satisfies handoff "separate reviewed source decision" |
|---|---|---|---|
| Ship `production = .claudeAndCodex` in 9-activation-a | none | refused sends if Codex scope binding or baseline save misbehaves | no (activation precedes evidence) |
| `#if DEBUG` env switch (`RPCE_RECOVERY_ACTIVATION`) | one env read | none | partly; contradicts the deliberate "not overridable by environment or defaults" invariant and the handoff's "changing a test flag is not proof" |
| Land wiring with `production = .off`; verifier flips the constant on a local candidate; separate one-line flip commit after V1–V9 | none | none | yes |

**Recommend the third.** The composition is one `static let`; a candidate with that single line changed is exactly the "candidate revision/dirty inputs" the handoff's evidence format already records. Nothing else differs between candidate and committed code, so the real composition paths are the ones exercised (prerequisite 1). Shipping directly is *acceptable* for a private fork (revert is one line, every failure mode is a loud refusal, not data loss), but it exposes the owner's ordinary Claude/Codex sends to two unknowns that only V1 can settle (see Q3 item 1 and Q4). If the owner prefers direct shipping, it changes only which value `production` holds in step 9-activation-a; the rest of the plan is identical.

## Q3 — Are the scout's proposals safe and minimal?

### 3.1 One composition — `AgentRecoveryActivation` (new, AgentCore)

File: `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActivation.swift`.

```swift
package struct AgentRecoveryActivation: Equatable {
    package var runtime: AgentRuntimeQualification
    package var actions: AgentRecoveryActionQualification

    package static let off = AgentRecoveryActivation(runtime: .init(families: [:]), actions: .init())
    /// O32 (2026-10-26): recovery actions are offered for every provider; Claude Code (standard) and
    /// Codex are the live-qualified ones. A new provider must establish registration, ownership,
    /// history association, dispatch identity and settlement before its actions may execute.
    /// freshClaudeConversation and safeRestart stay off: each needs its own acceptance, and safe
    /// restart cannot prove unregistered families stopped (verifyAllFamiliesStopped).
    package static let claudeAndCodex = AgentRecoveryActivation(
        runtime: .init(families: [
            .claudeNative:   .init(providers: [.claude(.standard)], markerPropagation: true, completeDiscovery: true, writerExecutableBasenames: ["claude"]),
            .claudeHeadless: /* same as above */,
            .codexAppServer: .init(providers: [.codex], markerPropagation: true, completeDiscovery: true, writerExecutableBasenames: ["codex"]),
            .codexExec:      /* same as above */ ]),
        actions: .init(sameConversationResume: true, historyReconciliation: true))
    /// Flipped to .claudeAndCodex by the reviewed source decision after V1–V9 (step 9-flip).
    package static let production: AgentRecoveryActivation = .off

    /// Any family covers this actual provider (used by the runner's provider gate).
    package func coversProvider(_ provider: AgentRuntimeProvider) -> Bool
}
```

Delete `AgentRuntimeQualification.production` and `AgentRecoveryActionQualification.production` so the compiler surfaces every site that chose qualification independently (VM :679–690, relaunch coordinator :189, registry :81, composition :114). `AgentProcessRegistry.production` becomes `AgentProcessRegistry(store:, qualification: AgentRecoveryActivation.production.runtime, system: .live)`. `AgentRecoveryAppComposition.install(into:)` builds the runner from `.production.actions` with `registrationActive: { AgentProcessRegistry.production?.isRegistrationActive ?? false }`.

**Deviation from the scout:** do not make the VM's lazy default "all off, for tests". Make the default read `AgentRecoveryActivation.production` too, with `install(into:)` as the override point. Reason: an all-off default plus a late `install` means any dispatch that runs before installation skips its baseline, and that run's Continue then refuses forever. In XCTest `AgentProcessRegistry.production` is nil, so `registrationActive()` is false and the default is inert there anyway.

### 3.2 Subset registration semantics

- `activatesRegistration` → `Self.supportedPairs.contains { covers(...) }`. Update its comment and the "Activation clarification" reference. `allowsFreshSessionID` keeps `activatesRegistration &&` (freshSessionID is false for all four pairs).
- `AgentRuntimeLaunchAuthority.makeLaunch` → nil unless `registry.isRegistrationActive && registry.qualification.covers(family:provider:)`. Keep the `unqualifiedProvider` throw in `reserveLaunch` as defence; it is now unreachable from `makeLaunch`. Update the `covers` doc comment (no longer "refused before its spawn").
- Replace the pair-less `AgentRuntimeLaunchAuthority.isRegistrationActive` with `isRegistrationActive(family:provider:)` and delete the old property so the compiler finds every call site (scout lists ACP :309 and ClaudeNative :1352/:2151; do not trust that list — let the build enumerate). `ClaudeNativeProcessSessionController` serves both `.claudeNative` and `.claudeCompatible` and both headless variants, so the check must take the session's actual `ClaudeCodeRuntimeVariant`, not the controller's family alone.
- Audit every `makeLaunch` call site for a nil-handling path that assumes "nil ⇒ registration globally off" (e.g. skips marker stripping or treats nil as an error). Marker stripping must stay unconditional.

### 3.3 Runner provider refusal

Give the runner the whole activation (`init(activation: AgentRecoveryActivation = .off, registrationActive:)`; `qualification` becomes `activation.actions`) and add a provider argument to `perform`:

```swift
package func perform(_ request:, lane:, performers:, provider: AgentRuntimeProvider?) async -> AgentRecoveryActionResult
// after the two existing guards, before beginRecoveryAction:
guard let provider, activation.runtime.coversProvider(provider), performers.reconcile != nil else {
    return .disabled(Self.unqualifiedProviderText(providerName))   // zero reservations, zero writes
}
```

Text: "Recovery for <Provider> isn't qualified yet: RepoPrompt can't verify its process ownership and provider history. Nothing was sent." `nil` provider (no mapping) refuses too. `.disabled` is the right case (nothing reserved) and Check already maps it to `couldNotCheck` — **verify** that mapping in `AgentRecoveryCoordinator+Check.swift`. `isAvailable(kind)` is unchanged so buttons stay visible per O32. The VM computes the provider with the same session→`AgentRuntimeProvider` mapping the launch context uses — **unknown:** locate it (grep `AgentRuntimeLaunchContext(`); if the mapping lives only in controllers, lift it to a small shared helper rather than duplicating.

### 3.4 Check Stop abandon

Per item in `+Check.swift`: start `let work = Task { @MainActor in await reconcile(item) }`, then `await withCheckedContinuation` resumed exactly once by whichever comes first — a forwarder task awaiting `work.value`, or `requestRecoveryCheckCancel`. Do **not** race with a task group: `Task.value` is not cancellation-responsive and a group would block on the stuck child at scope exit; and never cancel `work` (a cancelled reconcile records `.blocked`, which is a durable, misleading outcome). On Stop: record `.couldNotCheck("Stopped while checking. Its check continues; the card shows the result.")`, count remaining items as not checked, `setCatalogActionState(nil, for: item.id)`. Guarantee the late completion path (`+RecoveryCheck.swift:98`) cannot re-set `.working` after the report cleared it. Safe because the coordinator hold (runner :171–195) persists until the orphaned task ends and a repeat click joins (:233–240).

### 3.5 Normal-send failure modes the plan must cover

1. **Codex owner scope** — `CodexAppServerClient` defaults to `.unavailable` (:552). Under registration, any Codex owner operation (user turn, resume, steering, permission change, thread create) that doesn't bind `AgentRuntimeOperationOwner.$session` fails closed → refused send. Grep every `withValue` binding against every `associate(`/`authorizeWrite(` caller before V1; add a unit test under `.claudeAndCodex` for each Codex owner operation if `CodexAppServerRuntimeFenceTests` doesn't already cover it.
2. **Sessionless Claude launches** (model listing, auth, Oracle print) now take a reservation under `.claudeNative`/`.claudeHeadless`. Any such path that relies on `AgentRuntimeOperationOwner.current` (= `.unavailable` when unbound) instead of explicit `.sessionless` is refused. Audit.
3. **Per-send Claude baseline.** Keep it coupled; don't add a gate. A separate gate would re-create "no baseline → Continue refuses" for the qualified provider, defeating O32. The failure mode (save fails → send refused with a message, retry works) is loud, loses nothing, and matches the policy's "fail loudly" bar. Latency is advisory on this host; have the verifier record it, and make an incremental read (seek from the last cursor) a follow-up only if measured latency is objectionable.
4. **Silent send** is closed by 3.3 for unqualified providers. `.sendSaved` on qualified Claude still dispatches without reconcile — by design, fenced.
5. Already-present runtime records / unreadable runtimes directory produce global uncertainty today; not new. The leaked fixture workspaces remain out of scope (Check is catalog-bounded).
6. **Ordinary quit** with registration on: live Claude/Codex processes now register as survivors on quit. That is the designed Stage A/B behaviour, not a regression, but it is a visible change — put it in the verifier notes.

## Q4 — Writer basenames

`writerExecutableBasenames` only affects positive *writer* classification; an unlisted basename is `unknown`, and `unknown` must keep the runtime a possible writer. Only `toolExecutableBasenames` (empty) releases ownership. So a mismatch fails safe: a Claude CLI running as `node` is `unknown` and still blocks. Keep `["claude"]`/`["codex"]`, record that an npm-installed Claude shows as `node` (shebang → `/usr/bin/env node`; the native installer shows as `claude`; Codex is a native binary), and let V1 `ps` evidence add names later. **Verify** in `AgentProcessRegistry` that `unknown` members yield `.possibleWriter` restrictions and that an `unknown` root does not mark discovery incomplete in a way that changes behaviour; add one unit test: family member with basename `node`, writers `["claude"]` → send blocked. Do not pre-add `node` to writers: that would label every marker-bearing node process (including MCP servers) a writer, which is wrong for Stop previews later.

## Q5 — Split and acceptance criteria

**9-activation-a** (this step): everything in Q3 with `production = .off`; O32 comment; stale "everything OFF" comments fixed (runner :20–21, :145–147; support :60; `activatesRegistration` comment); spec status line; handoff :241 reworded to "subset per O37 (assumed A)"; the deliberate contract-test updates listed by the scout (`AgentRecoveryActionTests` :399–410/:479, `AgentRecoveryCoordinatorTests` :2602, `AgentProcessRegistryTests` :100–125/:798–801).

Acceptance (all obtained from XCTest unless marked):
1. `make dev-build`, `make guardrails`, `Scripts/check-agent-context` pass; the named suites pass.
2. Value tests: `.claudeAndCodex.runtime` covers exactly the four pairs and none of the other nine from `supportedPairs`; its `activatesRegistration` is true; `.off`'s is false; `production == .off`; `.claudeAndCodex.actions` allows `continueWithText/sendSaved/questionAnswerAsInput/reconcileOnly` and refuses `continueInNewConversation`; `safeRestart` false.
3. Under `.claudeAndCodex`: covered pair → reservation, `RPCE_RUNTIME_ID`, live record (existing tests re-pointed). Uncovered pair (ACP, compatible, headless GLM) → `makeLaunch` nil, no marker in the child env (inherited marker still stripped), no runtime file, controller does not join retirement.
4. Runner: for each of the six unqualified provider kinds × every action kind, `perform` returns `.disabled(text)` with no `beginRecoveryAction` call and no store write; Check reports `couldNotCheck(text)`.
5. Check Stop: a fixture reconcile that never returns → report finishes, `.working` cleared, a second dispatch into that session is still refused, late completion updates the row.
6. `node`-basename member blocks sends under writers `["claude"]`.
7. `install(into:)` and the VM default both resolve to `AgentRecoveryActivation.production` (no second source).

**9-live**: verifier builds a candidate with the one-line flip, records it as a dirty input, runs V1–V9 (V3 skipped: no Stop entry point). Notes for the verifier: V5/V6 only on runs started under the candidate; watch Codex launch refusals (Q3.5-1) and Claude send latency; capture `ps` basenames for Q4.
**9-flip**: `production = .claudeAndCodex`, docs status; needs no re-review beyond the diff read.
**9-activation-b**: crash-hold auto-confirm when the registry proves every process exited (new write behaviour, own review).
**Follow-ups**: Stop entry point (9-stop), Codex start/associate deadlines, show-vs-hide refusing buttons, incremental baseline read if latency warrants.

## File-by-file impact

| File | Change |
|---|---|
| `Recovery/AgentRecoveryActivation.swift` (new) | struct, `.off`, `.claudeAndCodex`, `production`, `coversProvider` |
| `Recovery/AgentProcessRegistrySupport.swift` | remove `AgentRuntimeQualification.production`; `activatesRegistration` = any pair; comment updates on `activatesRegistration`, `covers`, header |
| `Recovery/AgentProcessRegistry.swift` | `.production` reads `AgentRecoveryActivation.production.runtime` |
| `Recovery/AgentRuntimeLaunch.swift` | `makeLaunch` requires `covers`; replace `isRegistrationActive` with `isRegistrationActive(family:provider:)`; comment on `activationOff` |
| `Recovery/AgentRecoveryActionRunner.swift` | remove `.production`; init takes `AgentRecoveryActivation`; `perform(provider:)` gate + text; fix stale comments |
| `AgentRecoveryAppComposition.swift` | builds runner/registry from the one value |
| `ACPAgentSessionController.swift`, `ClaudeNativeProcessSessionController.swift` (+ any site the compiler surfaces) | per-pair check with actual variant |
| `AppRelaunchCoordinator.swift` | reads `.production.actions.safeRestart` |
| `AgentModeViewModel.swift`, `+RecoveryActions.swift`, `+RecoveryCheck.swift` | default from composition; pass provider to `perform`; late-completion guard |
| `AgentRecoveryCoordinator+Check.swift` | Stop abandon per 3.4 |
| Tests listed in Q5; docs: spec status line, handoff :241, evidence notes | |

## Implementation order

1. `AgentRecoveryActivation` + delete the two `.production` statics; fix every compile site (registry, authority, composition, VM, relaunch coordinator). Compilable, tests still green (value is `.off`).
2. Subset semantics (`activatesRegistration`, `makeLaunch`, per-pair authority check) with the registry/launch contract tests updated — land atomically with step 1's authority change.
3. Runner provider gate + VM provider mapping + Check `couldNotCheck` mapping + tests.
4. Check Stop abandon + test.
5. `node`-basename test; Codex owner-binding audit/test; sessionless-launch audit.
6. Comments, docs, status line; owner question O37 recorded as `assumed: A`.

## Recommendations

1. **Ask O37 (draft above) but proceed on A as `assumed:`** — the choice is one local value; O32 implies A but does not state it, and the handoff explicitly requires the approval.
2. **Land 9-activation-a with `production = .off`; verifier flips the one constant on a local candidate for 9-live; 9-flip commits it afterwards.** No new tooling, no debug switch, daily build untouched, handoff ordering honoured. If the owner prefers direct shipping, only the value in step 1 changes.
3. **Adopt the scout's four proposals with three amendments:** VM default reads the composition (not all-off); delete the pair-less `isRegistrationActive` so the compiler enumerates call sites; implement Stop abandon with a once-resumed continuation, never task-group cancellation.
4. **Keep the Claude baseline coupled and ungated**; measure latency in 9-live; incremental read is a follow-up only if needed.
5. **Writers `["claude"]`/`["codex"]` are a safe default** because unlisted basenames stay `unknown` and still block — confirm that invariant with one test, and let V1 `ps` evidence extend the list.
6. **Before 9-live, close the two real normal-send risks in unit tests:** every Codex owner operation binds its session scope under registration, and sessionless Claude launches use explicit `.sessionless`.