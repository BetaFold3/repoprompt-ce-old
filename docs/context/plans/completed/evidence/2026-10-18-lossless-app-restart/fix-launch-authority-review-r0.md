# Step 9 shared launch authority: change and round-0 reviews (condensed)

Scope: read when the task touches whether the run-start registration mark and the managed provider launchers resolve the same launch authority (A4 / P2-01), or the release-only `AgentTabSession.runtimeLaunchAuthority`.
Authority: Reference
Last-verified: 2026-10-28
Covers: the main agent's cut-down prerequisite change, its validation, and the OracleA and OracleB round-0 reviews (chats launch-authority-review--6BA227 and launch-authority-review--2293FC), condensed by the main agent

## Change

The deferred activation-b finding (OracleB A4, OracleA P2-01) asked for one shared launch-authority source for the run-start mark and the managed launchers, about 7 launcher construction sites in two modules. The main agent checked these facts first:
- `AgentRuntimeLaunchAuthority.production` (`AgentRuntimeLaunch.swift:85`) reads only `AgentProcessRegistry.production`, a `static let` (`AgentProcessRegistry.swift:83`).
- That registry's `isAnyPairRegistered` and `qualification` are `let`s (`:17-18`), built from `AgentRecoveryActivation.production`, a `static let` constant (`AgentRecoveryActivation.swift:43`).
- No call site in `Sources` passes a `launchAuthority:` argument, so every managed launcher uses the `.production` default.
- The only writer of `AgentTabSession.runtimeLaunchAuthority` is `AgentRunStartProviderRecordingTests.swift:126`.

The owner was offered a choice: a small version, or full threading of the authority. The question timed out, so the main agent went ahead with the recommended small version, recorded under `assumed:`. Outside DEBUG, `AgentTabSession.runtimeLaunchAuthority` is now a computed `.production`. A comment records the invariant and says that full threading is needed if activation ever becomes switchable at runtime.

Validation:
- `make dev-test FILTER=AgentRunStartProviderRecordingTests`: 6 tests, 0 failures.
- `make dev-lint`: clean, after two lint-only reshapes: the comment above `#if` became plain, and the getter body was wrapped.
- No release-configuration build was run (see L2).

## OracleA round 0

No findings. The cut is sound for the constant-only activation switch: every evaluation resolves the same immutable registry and qualification, so threading one captured value is unnecessary. Remote hosts record no mark (`AgentTabSession.swift:2028-2030`).

Recommendations:
- Before closing all of A4, keep evidence that every local launch route of a marked provider is in `supportedPairs`, including fallback routes.
- Include a non-DEBUG build in activation validation.
- Revisit threading if activation becomes runtime-switchable or production code ever injects an authority.

## OracleB round 0

No P0/P1. The facts match the code. The "two stored values agree by convention" half of A4 is closed for release builds, and there is no behavioral regression: the release getter returns the same value the stored default did.

- **L1 (P2), the rest of A4 scenario 2:**
  - **Gap:** the mark checks coverage of every `supportedPairs` family for `AgentRuntimeProvider(agentKind:)` (`AgentRuntimeLaunch.swift:115-126`), while each launch checks its own context pair (`:92-106`).
  - **Failure:** a mixed run, with one registered spawn plus one spawn whose provider variant or family is outside that mapping, could be marked "registry" while one process is unregistered.
  - **Fix:** before 9-flip, add a test that enumerates every `AgentProviderKind` and pins that every pair its managed launchers can build is in `supportedPairs`, with the provider equal to `AgentRuntimeProvider(agentKind:)`. A cheaper alternative is a DEBUG assert in `makeLaunch`.
  - The activation-b worker found no family outside `supportedPairs` that can launch a covered provider (`fix-activation-b-worker.md`, "B A4 scenario 2: no"). That was a code reading, not a test.
- **L2 (P2):** the `#else` branch is compiled only by a release-configuration build, and none was run. Fix: one release build.
- **L3 (P3):** the launcher side still relies on a one-off grep. Optionally give launcher `launchAuthority` parameters the same `#if DEBUG` treatment, or add a lint grep.
- **L4 (P3):** `runStartRegistrationMark` duplicates `AgentRecoveryActivation.coversProvider` over `registry.qualification`. Fix: one shared helper.
- **L5 (P3):** the long rationale is now a plain comment, so Quick Help shows only the one-line doc.

## Disposition (main agent)

- No P0/P1, and no further round.
- L1 and L2 are deferred as gates of 9-flip: the switch commit runs the provider-kind/launch-pair test (or the assert) and one release-configuration build.
- L3–L5 are deferred.
