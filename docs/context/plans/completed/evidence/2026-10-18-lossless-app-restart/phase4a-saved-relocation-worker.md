# Phase 4a O11 — saved-input relocation (worker implementation evidence)

Scope: read when the task touches bounded O11 saved-input relocation implementation and fixture validation.
Authority: Reference
Last-verified: 2026-10-23

Status: implemented; **source frozen** for main's bounded A/B re-review; unstaged and uncommitted. Plan source:
`prompt-exports/oracle-plan-2026-10-22-210809-lossless-restart-for-539d.md` (O11).

## Behaviour

- Send saved places the SAME conclusively unsent saved message A at the execution end, in a distinct
  clean execution turn E (`E.id != A`). A keeps its deterministic user-item ID, payload, provenance
  and original timestamp. When no occurrence survives, A is reconstructed from the intent under
  `createdAt`. When A already is the clean final request and the last working item, it is reused
  unchanged, so preparation is idempotent.
- The historical envelope H keeps:
  - its turn ID and position;
  - its spans and other activities;
  - its terminal state, interruption and recovered outcome.

  Only A's occurrence (request anchor or user activity) is removed. A `conclusionActivityID == A` is
  cleared, and the full-tier caches are re-derived from H's own evidence. There is no Q/X regrouping,
  no A* rekey and no retiering.
- **Shape preflight (no replay).** `hasSupportedWorkingEnvelopes`
  (`AgentTranscriptServices.swift:3052–3058`) runs in `relocatingSavedInput` at `:3137–3139`. That
  is after the consistency checks and before the `.unchanged` reuse/forced-save path and any
  mutation. Every retained **full** turn in the working suffix must pass two checks, or relocation
  returns `.refused(.historicalEnvelopeNotReconcilable)` (`:2566`):
  - It must be import-shaped (`isImportShapedWorkingTurn`, `:2942–2945`): exactly one span, whose
    ID is `deterministicSpanID(turn.id, 0)`.
  - It must carry no user-kind activity other than A.

  This is the only shape `importLegacyItems` emits, so every such turn is either matched by ID or
  explicit, and the positional fallback cannot consume E. No canonical-pipeline replay or graph
  verifier is in production. A refusal leaves the graph, items, persisted bytes and recovery record
  unchanged, and runs no save, receipt or send. The VM shows `recoverySavedHistoryNotMovableText`
  (`AgentModeViewModel+RecoveryActions.swift:411`, mapped at `:461`), and Edit remains available.
- **Hydration authority.** `dispatchRecoverySavedIntent` (`+RecoveryActions.swift:662`) checks
  `stillCurrent()` at `:672`, then `hasTranscriptSaveHydrationAuthority(session)` at `:676`. When the
  session is unloaded, has a pending `persistedLoadTask`, or has an `.unresolved` or `.failed`
  disposition, Send saved returns `recoverySavedNotHydratedText` (`:415`) with no mutation, save or
  start. The check runs at every revalidation point that calls `stillCurrent()`.
- **Closed historical completion metadata.** `preservingExplicitTurnEnvelopes` (`:2994–3046`) treats
  a turn as closed-unchanged (`:3013`) only when all of these match:
  - same request ID;
  - same span IDs and per-span activity IDs;
  - no open span on either side;
  - both `completedAt` non-nil.

  For a closed-unchanged turn it keeps the turn's `lastActivityAt` and `completedAt`, and each span's
  lifecycle, `lastActivityAt` and `completedAt`. It also keeps `terminalState`; for the final turn,
  only when the incoming terminal state is nil, idle or equal. A changed or live E is not frozen: a
  `.running` E reopens. `finalizeTurn` (`:5727–5740`) is unchanged. It already writes
  `terminalState ?? turn.terminalState` (`:5734`) and `completedAt ?? …`, so H's
  .completed/.cancelled/.failed state survives relocation, rebuild, save and reload.
- **Final-only incremental ownership.** `incrementallyUpdatedTranscriptForFinalTurnWithDiagnostics`
  (`:3356`) takes ownership only from `explicitFinalWorkingTurnOwnership` (`:2962–2968`, `:3387`).
  `rebuiltTranscriptPreservingCompactedPrefix` (`:3234`) computes full ownership only in its
  full-rebuild fallback (`:3252`, `:3272`). The incremental branch matches every turn by ID and
  passes an empty set (`:3295`).
- **Ordering:**
  1. Install the placement.
  2. Run one real covering `.written` owner save (`staleWriteCoversCapture`).
  3. Revalidate.
  4. Issue the queue receipt.
  5. Revalidate.
  6. Submit synchronously. The submit reuses the bubble (never appends) only under its own
     still-current `RecoverySavedInputPreparation`.

  `.suppressed`, `.notWritten`, `.resetAcknowledged`, stale, and twice-deferred outcomes never
  qualify. A failure leaves A unsent at the end: the `.reused` cleanup never removes it.
- **Joins:** these all resolve A's execution turn to E:
  - the run attempt's own turn;
  - the dispatch's recorded `transcriptTurnID` (recorded only when E ≠ A);
  - the terminal barrier;
  - `AgentRecoveryRunTurnJoin`.

## Restrictions (explicit)

1. **Supported shape is import-shaped only, anywhere in the full working suffix.** Relocation
   refuses any of these:
   - multi-span, span-less or non-deterministic-span full envelopes;
   - full turns carrying a foreign user row in mid-turn.

   Such sessions cannot use Send saved and must use Edit. Multi-span support is not added.
2. **Rows missing from the working items.** A derivable import-shaped turn whose rows are missing
   from the working items can still be positionally substituted by a later rebuild. This is
   pre-existing and is not covered by the shape preflight.
3. **Metadata.**
   - Explicit turns always keep turn `startedAt`, plus each same-ID span's `startedAt`, `runID` and
     `providerTurnID`.
   - Closed-unchanged explicit turns also keep the completion and terminal metadata above.
   - Non-explicit turns still re-derive terminal state and drop span `runID` on a full rebuild
     (pre-existing).
   - A refusal changes nothing.
4. **Compacted H prose.** A compacted H keeps its opaque summary prose (`middleSummaryText` and
   similar), which may still mention A's text. Only `summary.requestText` is cleared.
5. **Finalized-removal behaviour change.** A request-less import-shaped turn left by DataService
   finalized removal is now explicit and kept, not regrouped.
6. **Not covered here.**
   - The pre-O11 binary re-save limitation is documented by main.
   - Production gates remain OFF.
   - O3 live acceptance is pending.

## Validation (all jobs terminal)

| Ticket | Command | Result |
|---|---|---|
| 4686a4ad-c5ef-4c83-b574-a02e82f6858f | `make dev-swift-build PRODUCT=RepoPrompt` (pre-tests) | exit 0 |
| 6c192357-6205-41f3-a9e9-476a958c2a51 | `make dev-test FILTER=AgentTranscriptRefreshDiagnosticsTests` | failed at test compile (`await` inside `XCTUnwrap`); fixed |
| fa17ec2b-c678-483d-9f1e-6aba61682817 | same suite | 34 tests, 1 failure (wrong expectation in the test: the conclusion is re-derived, not nil); assertion corrected |
| 60f83276-939e-4000-8f3b-c1f1740e760d | same suite | 34 / 0 failures |
| b6d8441c-63bb-4957-b33e-ee861a7c2b3f | `FILTER=AgentRunTerminalCauseTests` | 16 / 0 |
| 99a3f6b5-00e8-47f6-ad08-885cedd05c9d | `FILTER=AgentRecoveryVMProducerAdmissionTests` | 33 / 0 |
| bdd68376-1e18-4dc2-916f-f16d0e9faa1f | `make dev-test` (full root; unrequested) | **CANCELLED**, not a pass. Before cancellation, its log showed failures in unrelated suites: AgentRunWorktreeStartTests, CursorCLIProviderTests, CursorModelSelectionSurfaceSpikeTests, MCPCodeStructureWorktreeTests. Not triaged. |
| 83133cd1-fee4-46cb-9a05-e16f22d032e1 | `FILTER=AgentTranscriptRefreshDiagnosticsTests` (guard v1) | 35 / 0 |
| 62540f61-5015-4e80-b92e-0e297a9d8d4e | `FILTER=AgentRecoveryVMProducerAdmissionTests` (guard v1) | 34 / 0 |
| 63c4a67d-6a57-42bf-914e-e49b517b8a68 | `FILTER=AgentRunTerminalCauseTests` (guard v1) | 16 / 0 |
| 056a9d9b-e3f5-4c73-a074-f4d5c45f92fb | `FILTER=AgentTranscriptRawInputReuseLifecycleTests` (guard v1) | 13 / 0 |
| a7826898-60a3-440d-b8b0-5ef748346c9f | `FILTER=AgentSourceItemIncrementalCommitTests` (guard v1) | 9 / 0 |
| a72b0df0-5cb7-4dc9-ad0c-bfb698ba4719 | `FILTER=AgentTranscriptRefreshDiagnosticsTests` (guard before `.unchanged`) | 35 / 0 |
| e443a0b2-5b8b-48ba-9268-8f3b35bbebfe | `FILTER=AgentRecoveryVMProducerAdmissionTests` | 34 / 0 |
| 7f28ff5a-58dc-4138-93aa-ea85ef237db3 | `FILTER=AgentRunTerminalCauseTests` | 16 / 0 |
| b2ef75d5-5be8-4aa1-8ada-33374c99620a | `FILTER=AgentTranscriptRawInputReuseLifecycleTests` | 13 / 0 |
| 4923e4ef-b1dd-45a1-8650-1cae770c18fe | `FILTER=AgentSourceItemIncrementalCommitTests` | 9 / 0 |
| d2279b37-5246-4222-9c3d-62f17b243df6 | `make dev-lint` | failed: 5 SwiftFormat findings in changed lines (redundantNilInit, 3× trailingCommas, preferKeyPath); fixed by hand |
| 17bdac65-ccac-47b6-b49a-b682b7d46cec | `make dev-lint` | completed successfully |
| 405cc529-d16f-439e-9706-1da0c3e46642 | `make dev-swift-build PRODUCT=RepoPrompt` (final) | completed successfully |
| 6d2eec90-dbb8-4aaf-a36d-10aba896847b | `FILTER=AgentTranscriptRefreshDiagnosticsTests` (final) | 35 / 0 |
| 11459c85-6a34-4904-8d3c-334055fbbd6d | `FILTER=AgentRecoveryVMProducerAdmissionTests` (round 4) | 34 / 0 |
| f3814f87-f968-4aea-b7be-58e91bbab5fb | `FILTER=AgentTranscriptRefreshDiagnosticsTests` (round 5) | 38 tests, 1 failure (whole-struct equality on an earlier turn whose caches the compactor refreshes); switched to envelope-field assertions |
| 9b237ac5-5ded-4222-b5f4-f4627adb5510 | same suite (round 5) | 38 / 0 |
| 606d2cdc-39cc-4401-843f-e97899faaeeb | same suite (shape preflight) | 38 / 0 |
| c040e3c6-2f37-47fa-8b9a-a588b74b4f15 | `FILTER=AgentRecoveryVMProducerAdmissionTests` | 36 tests, 1 failure (the test's `flushSave` precondition was false on a directly assigned, non-dirty transcript); precondition removed, assertions unchanged |
| a7b9b69f-2f7a-489c-a4af-77b8fc498ac5 | same suite | 36 / 0 |
| a7a72fbf-29ea-449f-ba04-578623079245 | `FILTER=AgentRunTerminalCauseTests` | 16 / 0 |
| f1fd583b-9de3-4ca8-8dba-c333c227f3fd | `FILTER=AgentTranscriptRawInputReuseLifecycleTests` | 13 / 0 |
| 0de56fd1-0e4c-41d9-939f-a69227d09ac4 | `FILTER=AgentSourceItemIncrementalCommitTests` | 9 / 0 |
| 00ff8371-5fc5-4ca1-8f9b-1707e1b23bb8 | `make dev-lint` | failed: wrapArguments/indent, blankLinesBetweenScopes, redundantThrows in changed lines; fixed by hand |
| f35f1a24-05c6-4f26-850a-b552ce51b54a | `make dev-lint` | completed successfully |
| 8ce40fd9-62f1-470a-b41f-09876c1fdc30 | `make dev-swift-build PRODUCT=RepoPrompt` (final) | completed successfully |
| 2839b8de-5e8d-408a-b276-8cd573a4ec48 | `FILTER=AgentTranscriptRefreshDiagnosticsTests` (final source) | 38 / 0 |
| e6587b29-e706-4f4b-878e-8e8038e1e8ba | `FILTER=AgentRecoveryVMProducerAdmissionTests` (final source) | 36 / 0 |

New or extended regression tests:

- `AgentTranscriptRefreshDiagnosticsTests.swift`:
  - `:874`: refusal before mutation. Cases are non-reconcilable shapes, the foreign mid-turn user
    row, and the reuse/forced-save path.
  - `:1054`: the [T,X] retained-envelope refusal.
  - `:1086`: completed, cancelled and failed H metadata through rebuild, JSON round-trip and reload;
    a live E reopens.
  - `:1167`: final-only incremental ownership.
- `AgentRecoveryVMProducerAdmissionTests.swift`:
  - `:1104`: [T,X] VM refusal with an unchanged graph, items, bytes and record, and 0 saves/starts.
  - `:1146`: the four hydration-authority cases.

Logs are in `/tmp/o11/*.log` and under conductor `jobs/<ticket>.log`. No conductor job or background
shell remains active.

The frozen ledger is unchanged. `make dev-format` was not run, and no full-root run was repeated. No
visible app, provider, helper or MCP operation ran.

Changed paths:

- O11 sources:
  - `AgentTranscriptServices.swift`
  - `AgentSessionRestoreSupport.swift`
  - `AgentRecoveryQueuedInput.swift`
  - `AgentProviderHandoff.swift`
  - `AgentRunTerminalCommitBarrier.swift`
  - `AgentTabSession.swift`
  - `AgentModeViewModel.swift`
  - `AgentModeViewModel+Recovery.swift`
  - `AgentModeViewModel+RecoveryActions.swift`
  - `AgentModeViewModel+TranscriptSaveMaxWait.swift`
- Tests: `AgentRecoveryVMProducerAdmissionTests.swift`, `AgentRunTerminalCauseTests.swift`,
  `AgentTranscriptRefreshDiagnosticsTests.swift`.
- This report.

All other dirty files are pre-existing baseline.
