# Step 4d6 worker evidence: scout STOP, then revised A implementation

Scope: read when the task touches the Step 4d6 historical tool-call presentation scout, its missing-ownership seam, or the revised A neutral-display and cancel-eligibility change.
Authority: Reference
Last-verified: 2026-10-24

This report is chronological. The scout STOP below comes first and is kept as written. The revised A implementation that main chose afterwards is in [Revised A implementation](#revised-a-implementation-after-mains-decision).

Base: source HEAD `9b4ab670`, docs capture commit `4cc4909a`. The brief is `phase4d6.md` together with `prompt-exports/oracle-plan-2026-10-24-133643-step4d6-refusal-boun-a8a6.md`.

There are **no source or test edits**. Nothing was staged or committed, and there were no provider or app actions.

The scout found that the exact item-owning execution context is not available in the render pipeline. Per the brief, the work stopped here before any edits. It needs main's decision.

## Verified context (read-only anchors)

### The render path is live, not dead

Every visible call row renders through one chain:
- `AgentModeView.transcriptRowView` (`AgentModeView.swift:3113-3220`) is used by:
  - plain blocks (`:3069-3076`);
  - flattened grouped history (`:3451-3468`);
  - expanded grouped history (`:3479-3497`).
- `transcriptRowView` builds `AgentMessageBubble`.
- `AgentMessageBubble.swift:291-302` holds the sole production `ToolCardRouter.callView` call. The exceptions are `context_builder`, ask_user and hidden tools.
- `ToolCardRouter.callView` (`ToolCardRouter.swift:120-145`) builds `ToolCallCard` (`:980-1043`), which calls `ToolCallCardStateResolver.status(for:)` (`:967-978`).

`ToolCallCardStateResolver.status(for:)` is also called directly by the remote, projector and grouped-export tests:
- `RemoteAgentSessionTests`
- `RemoteAgentClientFixesTests`
- `RemoteTranscriptProjectorTests`
- `AgentTranscriptGroupedHistorySpawnExportTests`

### Pairing

- In the core builder, rows are `activity.toItem()` (`AgentTranscriptServices.swift:8960-8981`).
- A call and its result that share a `stableExecutionID` are emitted in one `standaloneTool` block (`:8842`). This is the existing exact pairing.
- `toItem()` (`AgentTranscriptModels.swift:167-190`) drops `toolExecution.status`.
- An unresolved call row carries no result fields. A paired result is a separate row, which in a cluster or grouped history can be flattened among other blocks' rows.
- No per-row paired-result status reaches the card.

### Cancel eligibility is session-wide

`showRunScopedToolCancel` (`AgentModeView.swift:3086-3101`) requires all of:
- `runInteractionSnapshot.runState == .running`;
- an `activeRunID`;
- a block that is not archived and is `.full`;
- `sequenceIndex > latestUserSequenceIndex`.

This is session activity plus a sequence heuristic. Per the brief it is not execution identity.

### No exact live ownership reaches the view

- `AgentTranscriptRenderBlock` (`AgentTranscriptModels.swift:1036-1050`) has `turnID` but no turn or execution state.
- `AgentTranscriptPresentationSnapshot` (`:1148-1166`) and its metadata (`:1116-1125`) carry no turn or execution state.
- `dynamicSummaryLockTargetTurnID` (`AgentModeViewModel.swift:10436-10447`) is derived from session `runState.isActive` plus the last turn.

### The turn's terminal state is not exact ownership

- The builder (`AgentTranscriptServices.swift:3784-3805`) closes the prior turn for **every** request user item, including a mid-run steer: `isCompleted: true, terminalState: nil`.
- Only the trailing turn takes the session's terminal state (`:3834-3838`).
- So after a steer, a call in the start turn that is still executing sits in a closed turn. Using the turn's state would hide its live spinner, and would also not tie a call to its run.

### Execution status carries no liveness

`AgentTranscriptToolNormalizer.status(for:)` (`AgentTranscriptServices.swift:1839`) derives a call's status from its own row fields. A call without a result is `pending`, whether it is live, interrupted (protected cold restore, Step 4d5) or dangling.

### The exact join exists only in recovery

- The exact run-attempt-to-turn join is `AgentRecoveryRunAttempt.transcriptTurnID` (`AgentRecoveryModels.swift:588`) plus `AgentRecoveryRunTurnJoin` (`AgentSessionRestoreSupport.swift:32`). The join matches steer turns through intent attempts by user item ID.
- Both are durable recovery-store authority, used at cold restore.
- `AgentTabSession` (`beginRunAttempt`, `:1973`) keeps no turn mapping for the active attempt.

## Smallest missing seam (for main's decision)

Two derived, in-memory presentation inputs would let the resolver, card and callers change atomically with explicit parameters:

1. **Live execution-owned turns.** The set of transcript turn IDs owned by the active, nonterminal run attempt: its start turn, plus the turns of user items it dispatched as steers. This is the same join as `AgentRecoveryRunTurnJoin`, but held live by the session. It would be computed in the view model's presentation metadata, beside the existing per-item precedent `activeContextBuilderCallItemID`, and passed explicitly through `transcriptRowView` → `AgentMessageBubble` → `callView` → `ToolCallCard`.
2. **Paired result status per call row.** Taken from the builder's existing `stableExecutionID` grouping, either exposed on the block or derived during projection. Matching `toolInvocationID` in the view would be a new pairing algorithm, which the brief excludes.

Both are model and pipeline expansions: a new live session mapping and new presentation metadata. Under the brief this is a STOP, not a worker decision.

The weaker substitutes are rejected as not honest:
- session-wide `showRunScopedToolCancel` makes an old call spin while a new run is active;
- turn `terminalState` hides a live call's spinner after a steer.

## Initial scout validation (historical)

At the initial STOP, no tests, build or style checks were run, because no source changed. The recovery refusal regressions (the uncovered missing-proof cases) were not started; they belong in the same step, after main's decision. The frozen ledger is untouched, and unrelated dirt is preserved.

## Revised A implementation (after main's decision)

Main honored the STOP and validated the scout. Both Oracle lanes chose to cut the unsupported per-call liveness instead of adding new state. The brief is `phase4d6.md` (current contract) together with `prompt-exports/oracle-plan-2026-10-24-134626-step4d6-refusal-boun-4f65.md`. Both were read before the edits. Oracle B's partial-fallback and precheck guidance was not selected.

The edits are unstaged and uncommitted. There were no provider or app actions, no dev-build, package or run, and activation stays OFF.

### Product change (`Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ToolCardRouter.swift`)

- **Display status.** `ToolCallCardStateResolver.status(for:)` keeps its signature. A call with no attached result evidence (`toolResultJSON == nil && toolIsError == nil`) is now `.neutral` instead of `.running`. Attached evidence is resolved by the existing `ToolResultStatusResolver` with `fallback: .neutral` instead of `.running`. Explicitly classified success, warning, failure and running results are unchanged. Explicit running can only come from a `summary_only` render summary with status `running`, because status words `pending` and `running` already mapped to `.neutral`.
- **Cancel eligibility is decoupled.** The new pure helper `allowsRunScopedCancel(for:)` reproduces the pre-4d6 set exactly: missing evidence → true; otherwise the existing resolver with the old `fallback: .running` must return `.running`. The new helper `showsRunScopedCancel(for:showRunScopedToolCancel:hasCancelAction:)` adds the same unchanged gates (run scope, a non-nil action, and `MCPIntegrationHelper.isRepoPromptToolNameAfterNormalization`). `ToolCallCard.showsCancelButton` now calls that helper, not `status == .running`.
- **Unchanged.** The timestamp suppression (`showsTimestamp: !showsCancelButton`) and the cancel closure (`cancelActiveToolsAction`) are unchanged. The callers, `AgentMessageBubble`, `transcriptRowView`, pairing, blocks and pipeline are unchanged. So are the reader predicate, recovery, import and the ledger.
- **Button text.** The shared `ToolCardCancelButton` showed only "Cancel", with no tooltip or accessibility label, while its action is run-scoped (`cancelActiveToolsForRun`). The fix is local to the `ToolCallCard` call site: `.hoverTooltip` and `.accessibilityLabel` both read "Cancel active tools for this run". It uses `.hoverTooltip` because lint forbids `.help`, which required `import RepoPromptUI`. The shared button and its `ContextBuilderToolCards` uses are untouched.
- **Comment.** The comment on the empty card body now reads "Tool call cards don't show args by default".

### Test changes

The ledger is per-method, so no existing methods were renamed. The pinned names that now read as stale have comments.

- `RemoteTranscriptProjectorTests`:
  - `testToolCallWithoutToolResultRemainsRunning` expects `.neutral` and asserts cancel eligibility is still true.
  - `testUnknownToolResultJSONFallsBackToRunning` expects `.neutral` and asserts cancel eligibility is still true.
  - The settled test keeps its `NotEqual .running` assertion and adds an exact `.success`.
- `RemoteAgentSessionTests`:
  - The unresolved `runningTool` expects `.neutral` and stays cancel-eligible.
  - Both settled tools keep `NotEqual .running` and add an exact `.success`, with cancel no longer eligible.
  - The `.failure` assertions are unchanged.
- `AgentTranscriptGroupedHistorySpawnExportTests`:
  - The result-less remote call expects `.neutral` (it also asserts there is no result and that cancel is still eligible).
  - The hostile-name settled call adds an exact `.success`.
- `RemoteAgentClientFixesTests`: the `.failure` assertions are unchanged, and the suite was run only as a regression check.

Three new truth-table methods were added to the existing `RemoteTranscriptProjectorTests` suite. No new framework or suite was added.

- **`testToolCallCardDisplayStatusTruthTable`** covers the display status for each input:

  | Input | Display status |
  |---|---|
  | Missing evidence | neutral |
  | `{"status":"unknown"}` | neutral |
  | Non-JSON text | neutral |
  | `{"status":"running"}` | neutral |
  | success | success |
  | `toolIsError` false only | success |
  | warning | warning |
  | failed | failure |
  | `toolIsError` true only | failure |
  | Explicit running render summary | running |

- **`testToolCallCardRunScopedCancelKeepsPreStep4d6Eligibility`** runs the same inputs. For each one it checks two things: the old-set oracle (the resolver with `fallback: .running`, as it was before 4d6), and `allowsRunScopedCancel`, which must match that oracle. The result is true for missing evidence, unknown, non-JSON and explicit running. It is false for the status word `running` (which was already neutral before 4d6), success, warning and failure.
- **`testToolCallCardRunScopedCancelRequiresRunScopeActionAndRepoPromptTool`** checks the button gates:
  - shown for a server-prefixed RepoPrompt tool (the prefix is built from `MCPIntegrationHelper.repoPromptMCPServerName`) and for plain `read_file`;
  - hidden when the run scope is false;
  - hidden when there is no action;
  - hidden for a foreign tool, `Bash`;
  - hidden for a settled call;
  - also asserts that the unresolved call displays `.neutral`.

The existing recovery refusal tests are cited, not extended. Recovery is out of scope for this contract.

### Tickets

| Check | Ticket | Result |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` | `faad2806-6e44-4c98-b682-d83bccc52793` | passed |
| `make dev-test FILTER=RemoteTranscriptProjectorTests` (first run) | `47cd7e67-df41-40f6-8f5e-c412155e8017` | 1 failure: a test-fixture mistake. The prefix was hardcoded as `mcp__RepoPrompt__`, but CE's server name differs. Fixed by building the prefix from `repoPromptMCPServerName`. |
| `make dev-test FILTER=RemoteTranscriptProjectorTests` (rerun) | `70390946-7131-4f95-81cb-cf7a2d6ae7db` | 18 tests, 0 failures |
| `make dev-test FILTER=RemoteAgentSessionTests` | `3a625320-9adb-46a8-be38-a5fdafa30d87` | 67 tests, 0 failures |
| `make dev-test FILTER=RemoteAgentClientFixesTests` | `06149e78-bf5d-4ecf-9e5a-d84afc930882` | 29 tests, 0 failures |
| `make dev-test FILTER=AgentTranscriptGroupedHistorySpawnExportTests` | `98e16d5c-7a05-4e2b-82c6-6dfb6ec344ad` | 9 tests, 0 failures |
| `make dev-lint` (first run) | `51725c77-020e-4ae7-8701-6f57283154e2` | failed `no_swiftui_help_modifier`; fixed by switching to `.hoverTooltip` |
| `make dev-lint` (final) | `8c844d57-b8f3-49b6-89f7-071f97066c95` | passed |
| `make dev-format-check` (final) | `ec11fdf1-6787-46fd-a382-7ae640d209e9` | 0/2177 files require formatting |
| `git diff --check` | — | clean |
| `Scripts/check-agent-context` | — | passed, 1 pre-existing `route-count` warning on `AGENTS.md` |

The product build ran before the projector-test fixture fix, which touched a test only. The focused suites compiled the product again.

### Limitations and not run

- Missing or unclassifiable attached evidence no longer infers per-call execution. Explicitly classified `.running` render summaries still display running, unchanged; this step does not requalify their freshness. The session-level run indicator shows run activity, and separate result cards own their outcomes.
- The cancel shortcut keeps the old run-scoped eligibility, including the existing latest-user sequence gate. No new exact invocation-ownership check is added, and this report does not establish that an arbitrary older call passes that gate. The action cancels the run's active tools, and the new label says so; eligibility is not per-call liveness evidence.
- There is no missing-proof recovery work. Import, reader and ledger are unchanged.
- Not run: the full test suite, dev-build, package or run, visual or app acceptance of the tooltip, and provider prompts.
- `make dev-format` was not run. The frozen ledger is untouched, and unrelated dirt is preserved.

## Cheap final fix (after initial reviews)

Main read and verified both initial reviews; neither found a P0 or P1. The input was `prompt-exports/oracle-review-2026-10-24-140143-step4d6-initial-b-23-ed1b.md`. Main had already staged the four initial files and froze them. This repair touches only two files, and its edits are left unstaged on top of the staged snapshot. Nothing was staged or committed.

- **B P3-1** (`ToolCardRouter.swift`, `showsRunScopedCancel`): the order is now `showRunScopedToolCancel && hasCancelAction && allowsRunScopedCancel(for:) && isRepoPromptToolNameAfterNormalization`. The two boolean gates now short-circuit before the result JSON is parsed. The logic is the same pure conjunction, so the eligible set is unchanged.
- **B P3-3** (`RemoteTranscriptProjectorTests.swift`): both truth tables gain the row `{"type":"command_execution","exitCode":-1}`, a negative exit code with no timing hint. Its display is `.neutral`, from an explicit `.neutral` returned by `commandExecutionOverride`, and its cancel eligibility is `false`. This pins that an explicit `.neutral` blocks cancel while a fallback `.neutral` allows it.
- **B P3-4** (`RemoteTranscriptProjectorTests.swift`): a comment now says the `oldEligibility` comparison restates the pre-4d6 formula and is not an independent oracle; the hardcoded `allowed` column is what pins the behavior. The assertion message changed from "old-set oracle" to "pre-4d6 formula". The earlier description in this report that calls it an "old-set oracle" should be read with this correction.
- **Not done, by direction:**
  - B P3-2 (renaming tests): frozen, because the ledger pins test names.
  - B P2-1 (the shared button and tooltip): main will inspect it. A live click is deferred because no app action is authorized.
  - No additional review.

| Check | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=RemoteTranscriptProjectorTests` | `e1c2e0b8-d191-4e59-9b96-042f72a104cf` | 18 tests, 0 failures; this test build also compiled the reordered product helper |
| `make dev-format-check` | `304d3e2b-9f48-4fd5-a071-bc601659e071` | 0/2177 files require formatting |
| `make dev-lint` | `bd35727b-3e7f-4a5e-855a-c9bc19c1b8c8` | passed |
| `git diff --check` | — | clean |

No separate product build was run; the focused test build compiled the changed product file. Not run: the other three focused suites (their files are unchanged in this repair), the full suite, and any app or provider actions.
