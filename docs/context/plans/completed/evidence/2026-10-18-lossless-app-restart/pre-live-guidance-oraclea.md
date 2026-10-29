# Pre-live acceptance guidance — OracleA

Scope: read when the task touches the externally coordinated lossless restart live-acceptance plan.
Authority: Reference
Last-verified: 2026-10-24

Main requested independent fresh OracleA/OracleB planning together with identical controlled context and verbatim review policy, then continued each lane with the same source-audit corrections. Returned preset UUID/name matched OracleA (61D024A4-CCFB-4C9C-A614-CC65E0A1864C); continuation inherited the same preset. Full replies were read. These are planning opinions, not executed validation or permission to launch.

The follow-up supersedes initial unsupported assumptions. In particular, Step 4c already resolved the helper policy; dirty-tree validation is useful when labeled; whole-app qualification and deterministic crash cuts are not existing CLI capabilities. No source tooling, production activation, clean-worktree rebuild or lifecycle action was adopted now. The owner-facing handoff selects baseline launch approval first, not blanket crash permission. Initial proposals remain below for traceability; trailing Markdown whitespace is normalized.

## Initial guidance

# Oracle Plan



## 1. Summary

Finish the already-running source validation and scratch packaging, then prepare a durable handoff for acceptance coordinated **outside RepoPrompt CE**. Do not launch, stop, relaunch, install over, or crash the app now. The current CE process cannot qualify HEAD, and production recovery remains disabled. Later acceptance must separate **actual provider/discovery evidence**, **live testing of gated recovery paths**, and **production activation**; none substitutes for another. This calls for a bounded acceptance plan, not a new qualification platform or a global-gate refactor.

## 2. Current-state analysis

### Qualification and execution boundaries

- `AgentRuntimeQualification` in `AgentProcessRegistrySupport.swift` is a value type containing family qualifications indexed by `AgentRuntimeFamily`.
  - `qualification(family:provider:)` requires evidence covering the actual provider; missing providers fail closed.
  - `covers(family:provider:)` requires `supportsCompleteDiscovery`.
  - `activatesRegistration` requires coverage of **every** `supportedPairs` entry—13 according to the supplied scout.
  - Registration, marker injection, and enforcement activate together. Qualifying one backend does not activate that backend independently.
  - `allowsFreshSessionID(_:provider:)` additionally requires the separate `freshSessionID` qualification.
  - Production has an empty family dictionary and no environment/default override.

- `AgentRecoveryActionQualification` in `AgentRecoveryActionRunner.swift` is another value type, with four independently represented capabilities:
  - `sameConversationResume`
  - `historyReconciliation`
  - `freshClaudeConversation`
  - `safeRestart`

  All default to false. `allows(_:)` maps the five shown action kinds to the first three capabilities; safe restart has its own capability. The supplied inspection also establishes registration prerequisites and no production recovered-stop signalling.

The relevant acceptance chain is:

**exact provider launch → runtime identity and descendant discovery → durable recovery records → reconciliation/action eligibility → normal dispatch or restart execution → transcript and UI result.**

A fixture can validate a transformation within this chain. It cannot prove real process discovery, installed-app wiring, provider behavior, or crash durability.

### Present evidence limitations

- Reviewed HEAD is `e7ac41e4`; all production recovery gates remain off.
- Full root tests, package tests, and scratch debug packaging are **running**, not yet recorded passes.
- CE PID `8017` predates both the inspected installed bundle and HEAD. The conflicting lane/provenance observations reinforce the mismatch. Neither a successful ping nor inspecting the bundle on disk establishes what that process loaded.
- `rpce-cli-debug` version `1.0.29` can reach the matching `window2`, but this proves connectivity only.
- `make dev-smoke` failed at hardcoded `window1` and attempts a workspace switch. Retrying against the owner’s real window is neither necessary nor safe.
- O3 isolation remains unresolved operationally: a temporary workspace or another same-account app does not isolate the roughly ten hardcoded stores, sockets, or Keychain use.
- Installed/running Claude.app and ChatGPT.app do not establish automation capability, authentication, filesystem access, or restart-independent coordination.

**Reuse:** existing test suites, packaging workflow, CLI, provider launch paths, qualification value types, reconciliation fixtures, and evidence directory. No production API, persistence schema, or runtime ownership changes are proposed now.

## 3. Design

### A. Meaningful work now—and probes to cut

| Work | Treatment now | Evidence classification |
|---|---|---|
| Already-running unfiltered root suite | Collect completion, exit status, failures, and exact tested snapshot | Source/test evidence |
| Core and provider package suites | Collect independently; retain package-specific results | Source/test evidence |
| Scratch debug packaging | Finish without installation or app execution; record artifact location, digest, embedded revision/lane and packaging result | Packaging evidence |
| Failure triage | Separate regressions, environmental failures, and known unrelated failures; use targeted reruns only when they answer a specific question | Source/test evidence |
| Existing Claude identity captures and fixture/reconciliation results | Index their exact scope and link retained evidence; do not repeat successful captures without a missing claim | Isolated CLI or fixture evidence |
| Acceptance preparation | Identify exact supported pairs, actual launch profiles, candidate artifact, existing test injection seams, scenario prerequisites and evidence locations from available source/artifacts | Preparation |
| Existing live CE ping | Retain the existing result; no repeated ping loop needed | Connectivity only |

For every suite and package result, record whether the checkout was clean or dirty and which changes were included. A HEAD identifier alone does not describe a dirty build. Preserve unrelated owner changes; if they affected the candidate, label that candidate accordingly rather than claiming clean-HEAD validation.

**Cut these probes:**

- Retrying or retargeting `make dev-smoke` against the owner’s workspace.
- Testing recovery actions in the stale live process.
- Repeating fake-controller, reconciliation, or temporary-workspace tests as though they close live acceptance.
- Broad provider/account enumeration or credential/configuration inspection.
- New same-account “isolated” app instances.
- Repeating successful CLI captures merely to accumulate evidence.
- Installing the scratch bundle while the old app remains running.
- Beginning another full suite unchanged after a successful run.

New isolated provider CLI experiments are justified only by a specific unanswered prerequisite and an applicable approval. Earlier tightly bounded capture approvals must not be treated as reusable authorization for fresh processes, spending, or different restrictions. Such experiments still would not qualify the app integration.

### B. Minimal outside-CE coordinator and human bootstrap

**Recommended driver:** an already-installed CLI agent in a normal Terminal/tmux session, launched independently of CE, in the disposable macOS account used for acceptance. It must not be a CE tool child or depend on a CE-hosted task, socket, or transcript to retain its plan.

Use Claude CLI, Codex CLI, or Pi according to whichever the owner can authenticate and operate there. Do not assume authentication transfers to the disposable account.

Claude.app or ChatGPT.app are alternatives **only after** confirming that the selected app can access the handoff and execute the required local operations. Their presence alone is insufficient. Codex.app is not an available option from the supplied inventory.

#### Human-only bootstrap and approvals

Keep the later owner interaction to one bootstrap checklist:

1. **Approve visible lifecycle acceptance** in a disposable macOS account, including test launches, deliberate crashes, quit/relaunch, bounded provider usage, and the intended isolation boundary. Default: leave the owner’s original-account CE and data untouched.
2. Create or sign into that account, place the candidate and handoff there, and authenticate the required provider profiles through normal provider flows.
3. Start the external coordinator and grant any OS-required access. UI automation permission is optional unless that driver actually supports it; otherwise reserve a short manual UI checklist.
4. Authorize the exact candidate and scenario batch. State whether the batch includes a qualification-only build; this is not permission to activate production gates.

No credentials, tokens, or copied live Keychain databases belong in the handoff.

A usable disposable account does not automatically prove isolation. Before any destructive case, the coordinator must confirm that app data, workspaces, sockets, helper targeting, and provider histories resolve to disposable-account resources. Shared absolute paths are a stop condition.

#### Restart-resilient ownership and evidence

The coordinator owns sequencing; workers may perform bounded tasks but must not independently trigger lifecycle actions. Only the main coordinator starts workers or requests OracleA/B review.

Keep the handoff and results in ordinary files outside CE application support and temporary directories. The coordinator must retain, before each lifecycle action:

- Run/scenario ID and exact planned operation.
- Candidate revision, dirty-state description, executable/bundle digest and lane.
- Target account, app PID/start time/executable path, and relevant helper/provider identities.
- Expected result, allowed scope, and evidence paths.

Update each scenario through `not run → prepared → running → passed/failed/blocked`. If the driver itself disappears during a scenario, treat the persisted `running` state as **interrupted/unknown**. Observe existing app/provider/helper state before retrying; never repeat a send, answer, or restart automatically.

After every launch, rebind evidence to the newly running executable and candidate. A PID, app name, CLI version, or on-disk bundle alone is insufficient.

### C. Ordering provider qualification and gated acceptance

#### Stage 1 — Baseline app/profile acceptance

After approval, launch the exact production-gates-off candidate in the disposable account.

For each of the **actual 13 `supportedPairs`**, record the provider/backend, runtime family, launch configuration, relevant executable versions, and whether a real authenticated launch is available. Use source names rather than inventing profile aliases.

Confirm normal app/provider operation first. A successful standard Claude run does not qualify compatible backends, headless variants, ACP backends, or either Codex family.

**Output:** baseline live app/profile evidence—not recovery qualification.

#### Stage 2 — Establish actual discovery evidence

Test the real launch/discovery path for each pair, including marker propagation through the shims and provider tools and representative descendant lifetimes.

Qualification must be based on observed behavior of the actual profile. Do not fill missing provider entries with copied evidence, and do not mark complete discovery merely to permit launching the test.

**Output:** per-pair discovery evidence, with missing or failed pairs explicitly unqualified. Test fresh-session-ID behavior separately; complete discovery does not imply it.

#### Stage 3 — Exercise gated recovery paths

There is a genuine bootstrap issue: production gates are off, but their protected paths need live acceptance before activation.

A **bounded isolated qualification composition is necessary only if the existing harness cannot run the real app paths with explicit non-production dependencies**. CLI-only captures and fake controllers cannot replace it, but there is no justification yet to build a new harness.

Validate the existing initializer/composition call sites before deciding:

- Reuse an existing non-production injection seam if it supports the real app, stores, provider processes, registry/discovery and action runner.
- Do not change either `.production` constant, add an environment/default activation switch, or weaken the coupled all-pairs rule.
- Keep intended test coverage separate from observed qualification. A test-enabling setting is not proof that its premise passed.
- Supply real, evidence-backed discovery qualification before treating gated-action results as eligible for production qualification.
- Enable only the action capability under test in the isolated composition. Keep safe restart off until its own approved cases.

If the only available way to exercise discovery itself is to assert an unproven `supportsCompleteDiscovery`, that is an unmet testability prerequisite—not a reason to fabricate evidence. Stop and propose the smallest separately approved qualification-only composition change. Its scope is real-path invocation in the isolated build, not a second runtime architecture.

The supplied excerpts do not show the composition root or injection signatures. Therefore **no such source change is authorized or specified by this plan**. Validate those call sites first; if a change is needed, name its actual files and review its behavior with OracleA/B before implementation.

The all-pairs activation constraint remains significant: if one required backend cannot be qualified, record useful partial evidence, but do not claim the registry/action acceptance chain or production activation is complete.

#### Stage 4 — Production activation is a separate decision

Passing an isolated qualification build does not enable the normal build. Any later production-gate change is a reviewed source change backed by the recorded coverage and owner approval, followed by validation of the resulting production-composed candidate.

**Current stop point:** finish non-lifecycle work and persist the handoff. No current authorization covers Stage 1’s visible launch, much less crash/restart or activation.

### D. Mandatory recorded scenario matrix

All rows below are currently **not live-passed for HEAD**. Existing fixture evidence may be linked in a separate column.

| Scenario group | Mandatory cases | Required observation |
|---|---|---|
| Candidate and isolation | Exact app/build binding; disposable stores/socket paths; helper targeting | Every later result identifies the actual candidate and cannot affect owner data |
| Provider/discovery coverage | Every supported pair; both shims; markers reaching provider tools; foreground/background descendants | Actual per-pair evidence; no borrowed backend qualification |
| Claude lifecycle | Foreground tool then new tool; background child; unanswered stdio permission; RepoPrompt MCP call; startup hooks; resume with dangling `tool_use` | Process identities, surviving activity, truthful interruption/reconciliation, no unintended stop or duplicate execution |
| Codex lifecycle | Command in progress, then `thread/resume` | Correct thread/turn linkage and no duplicate command |
| Explicit recovery/UI | Continue; Edit first; Send saved; Answer as input; history-only reconciliation; fresh conversation after failed Claude resume | Correct dispatch count and destination; preserved IDs/chronology; failures remain recoverable |
| Older saved input | Move/reconstruct the same unsent message at current end; inject send failure | Same ID and saved chronology; failure leaves it unsent at the new position |
| Intent/delivery crash cuts | Before commit; after commit before acknowledgement; after acknowledgement before drain; just after direct Send; scheduled-send transfer | Respectively no success acknowledgement; one recoverable intent; full payload; held or `deliveryUnknown`; no duplicate |
| Runtime crash cuts | Mid-stream; quit Stage A; quit Stage B; reserved record before identity | Interruption and measured staleness; Stage A remains usable; Stage B uncertain next launch; unresolved ownership stays unresolved |
| Shutdown failures | Stage A failure → Cancel → interact → quit again; Stage B failure → Retry flush | Continued usability and preserved pending data; correct retry state |
| Survivor/helper policy | Default Let finish/watch; explicit stop behavior; armed-helper stop and restart interactions | Only intended processes affected; helper behavior matches the approved policy |
| Safe restart and multi-session quit | Restart safely; Cmd-Q with several sessions | Durable recovery and correct relaunch; record latency and click counts |
| Busy/performance | Unresolved interruption blocks scheduler; intent-commit latency; typing responsiveness; transcript maximum wait | Correct busy behavior; measurements with method and conditions |

Record recovery records, transcript/message IDs, process identities, marker evidence and UI click counts where applicable. Timing on this shared host is advisory; an unsound measurement method is not.

Do not claim “UI acceptance” from CLI outcomes alone. Use verified external UI automation or the short owner-operated checklist.

## 4. File-by-file impact

Only documentation is proposed for this step; this response does not itself persist files.

| File | Planned change | Dependency |
|---|---|---|
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` | Add/update the acceptance-step status line and link the handoff. State that source validation may finish while actual app qualification, lifecycle acceptance and production activation remain blocked. Keep assumptions separate from owner Decisions. | Final worker results |
| `docs/context/plans/evidence/2026-10-24-acceptance-handoff.md` — new | Store the compact run manifest, existing evidence links, provider coverage checklist, scenario matrix, external-driver bootstrap, stop conditions and next operation. Reference logs rather than embedding them. | Existing artifacts and source inventory |

No changes to `AgentProcessRegistrySupport.swift` or `AgentRecoveryActionRunner.swift`. Their gates remain unchanged.

Documentation/status updates need no Oracle review under the supplied policy. If a later qualification-only composition requires behavioral changes, only the main coordinator requests OracleA/B review, attaching the review policy **verbatim**, and saves both lanes’ findings in the evidence directory.

## 5. Risks and boundaries

- **Unavailable profiles can block coupled activation.** The realistic response is partial evidence with activation still blocked—not narrowing the production matrix opportunistically.
- **The test injection seam may not reach real app wiring.** Validate it before promising lifecycle automation; fixture-only injection is insufficient.
- **Isolation may fail through shared paths or helper targeting.** Account separation must be verified before crashes or signalling.
- **External-driver capability/authentication is unverified.** CLI-in-Terminal minimizes dependencies, but owner bootstrap is still necessary.
- **Current provenance cannot be repaired by observation alone.** Actual HEAD qualification requires a later approved launch of a known artifact.
- **Armed-helper-stop behavior remains safety-critical.** Do not exercise it until the intended policy and target ownership are explicit.

No data migration or production rollback is introduced by this documentation-only step.

## 6. Implementation order

1. Collect the running suites and scratch packaging results without changing source or installing the app.
2. Triage concrete failures; rerun only affected validation where justified.
3. Assemble the handoff and evidence links; record all unrun live cases as blocked, not failed or passed.
4. Validate existing composition seams from source and record whether later real-path qualification can reuse them.
5. Stop at the visible lifecycle boundary. Offer the disposable-account external-CLI bootstrap as the recommended approval package.
6. After approval, establish isolation and exact candidate binding; run baseline provider profiles, then discovery qualification.
7. Exercise gated paths only with the approved isolated composition and satisfied prerequisites; record crash, shutdown, helper and UI results.
8. Consider production activation separately, with required review and final candidate validation.

## Recommendations

- **Now:** finish source/package/packaging validation and persist one usable handoff. Cut stale-process and mutating smoke probes.
- **Later:** use an independent CLI coordinator in a disposable macOS account, with one owner bootstrap and explicit lifecycle approval.
- **Keep production gates off.** Reuse existing qualification injection only if it reaches real paths; otherwise stop for a narrowly scoped proposal.
- Report the outcome as **non-lifecycle validation completed, live acceptance blocked pending approval**, not feature complete.

## Follow-up after source audit (controlling guidance)

# Oracle Plan

## Summary

**Yes—the revised stopping boundary is honest and sufficient for the current request.** Finish and record the existing dirty-tree validation and isolated packaging, persist the external-coordinator handoff, and stop before launch. There is no unavoidable reason to add source tooling now: it would serve later, currently unauthorized acceptance, not improve the validity of today’s results.

## Current-state analysis

The new audit closes the earlier uncertainty: **component injection does not provide whole-app qualification**.

- `AgentRecoveryAppComposition:44` accepts a registry, but not action qualification.
- The VM at line 677 uses `.production` and the registry singleton.
- `AgentRuntimeLaunch:85` independently reads production registry state.
- `WindowStateManager:233` defaults to `AppRelaunchCoordinator.production`.
- Store `FileOperations` and lifecycle `Environment` injection are XCTest seams, not externally controllable installed-app boundaries.

Consequently, neither existing fixtures nor the packaged candidate establish that gated UI or deterministic crash-cut scenarios can be exercised.

Isolation is better established at the UID boundary, but **shared build/bundle destinations remain unsafe**: per-UID conductor locks do not coordinate cross-account writes. The global CLI symlink also cannot be treated as an account-independent entrypoint.

The armed-helper policy is **resolved**, not awaiting another owner decision: Step4c `cb15d40f`, `phase4-prerequisite-resolution.md`, and coordinator lines 888–905 establish the restricted current-attempt prearm witness and Stage B safe-restart “Exit — may reopen” behavior. What remains is live verification.

## Design

### Finish now

Collect the running suites and packaging results, recording:

- Exact dirty inputs, commands, exit statuses and artifact identity.
- Any uncertainty about inputs changing during execution.
- Separate labels for **source tests**, **fixture evidence**, and **packaging evidence**.

Do not call these clean-HEAD acceptance. Do not create a clean worktree merely for ceremony, retry the mutating smoke script, or use the stale process to qualify current code.

### Smallest next authorization package

Present one compact choice **when the owner is ready to cross the boundary**:

> **Recommended:** bootstrap one disposable macOS account with normal provider login and an independent Terminal coordinator, then authorize launch of the identified candidate for bounded baseline app/provider acceptance. Use account-local bundle/build destinations and explicitly resolved `rpce-cli-debug`; do not use the global CLI link. Leave the owner’s running CE untouched.
> **Alternative:** leave live acceptance pending.

This is not blanket crash/restart authorization. Before any later destructive batch, the coordinator must obtain explicit just-in-time approval identifying the candidate, affected processes, scenarios and stop conditions. Do not bundle presently untestable gated scenarios into a promise.

The coordinator may use an already available CLI. Computer use is optional and must first be verified; otherwise retain a short manual UI checklist. No assumed app automation or authentication.

### Durable handoff and later prerequisite

Persist one compact handoff outside CE-owned storage containing:

- Completed evidence links and outstanding scenario IDs.
- Candidate digest/revision/dirty-input identity and account-local paths.
- Target UID, PID, start time, executable identity and relevant helper identity, including bundled `repoprompt-mcp`.
- Last completed operation, next permitted operation and approval scope.

After disconnect, reobserve identities and state before continuing; never blindly repeat a send, stop or restart. CE-hosted workers cannot own this continuity.

Later gated/crash acceptance has an **explicit unmet testability prerequisite**: separately review the smallest isolated candidate composition and deterministic boundary controls needed by the selected scenarios. No new platform or global-gate redesign is justified.

**Testing a hypothesis is legitimate:** an isolated candidate may deliberately enable the behavior under investigation, with assumptions clearly recorded. Those settings are experimental inputs—not observed qualification. Setting `supportsCompleteDiscovery=true` cannot prove discovery, satisfy missing pair coverage, or justify production activation. Normal-build production gates remain off.

## File-by-file impact

- **Existing acceptance plan:** update status and cite completed evidence; mark live acceptance blocked on approval and testability prerequisites.
- **One handoff file in the existing evidence directory:** record the external-terminal procedure and manifest above.
- **Production and test source:** no changes now.
- **`phase4-prerequisite-resolution.md`:** reference the resolved policy; do not reopen it.

## Implementation order

1. Collect and accurately label existing validation results.
2. Persist the compact handoff and blocked scenario status.
3. Stop before launch.
4. On approval, bootstrap externally and run only supported baseline cases.
5. Address narrowly scoped testability prerequisites before requesting the corresponding lifecycle batch.

## Recommendations

Accept this stopping boundary. Continue evidence collection and handoff preparation only; offer the single bootstrap/baseline package next. Report **live acceptance pending**, not feature complete, and prefer deferral over unsafe same-account crashes.
