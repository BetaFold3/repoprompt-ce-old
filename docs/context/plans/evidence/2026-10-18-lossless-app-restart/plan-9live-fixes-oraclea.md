# 9-live fix plan: OracleA

Scope: read when the task touches planning the fixes for the 9-live findings (R1–R7, O42, O43) before the recovery activation switch.
Authority: Reference
Last-verified: 2026-10-28
Covers: OracleA plan-mode answer (chat 9-live-fix-plan-oraclea-34AF06) over the three 9-live diagnosis reports




## 1. Summary

Use small, targeted fixes rather than refactoring recovery. Implement O43 as **proof-backed removal of the execution hold, not invented delivery acceptance**; independently repair Claude history discovery and first-send baselines, persist Codex recovery turn identity, and fix continuation-text retention and Escape handling. Defer early Claude stdout acceptance because O43 removes its immediate necessity. Commit the fixes with production activation off, then verify a candidate whose sole difference is the activation line before the separately reviewed switch.

This plan uses the supplied diagnoses and codemaps; no additional source inspection or validation was performed. References to implementation bodies outside the selection are evidence from those reports, not independently verified here.

## 2. Current-state analysis

### Recovery ownership and data flow

1. **Send admission and durable input**
   - `AgentRecoveryStore` owns recovery records and revision-checked writes.
   - Every provider handoff first obtains durable dispatch evidence.
   - Claude parks written handoffs in `ClaudeAgentModeCoordinator.dispatchHandoffsByTurnID`. Only `noteClaudeTurnCompleted` currently records acceptance.
   - Codex records acceptance from its start/steer RPC receipts.
   - Consequently, an interrupted Claude send can remain `dispatching` even when the provider certainly began processing it. That is conservative, not evidence that nothing was sent.

2. **Startup and execution holds**
   - `AgentRecoveryCoordinator.deriveCrashHolds` includes earlier-launch uncertain intents and interrupted runs.
   - The app-scoped `AgentProcessRegistry` actor discovers process families and publishes restrictions.
   - Check calls `confirmCrashHoldFromRegistryProof`; its current `uncertainIntentIDs.isEmpty` restriction rejects Claude fixtures before process-exit proof can resolve them.
   - Refresh updates process restrictions only. It does not acknowledge crash holds.

3. **Recovery actions**
   - `performRecoveryResumeAction` reserves an action, validates its target, reconciles history, and only then may dispatch a continuation.
   - Claude reconciliation requires the interrupted dispatch’s captured baseline and prefix/identity evidence. All observed baselines were unsupported.
   - Codex reconciliation requires a native turn ID. The consumer reads `AgentTranscriptProviderResponseSpan.providerTurnID`, but production never populates it.
   - These history failures are independent of Claude’s acceptance timing.

4. **Presentation**
   - `AgentRecoveryCatalogProjection` derives app-wide items and action facts; the view model produces banner and sheet props.
   - R4’s unsent-continuation fact is already computed, but `Text(row.error ?? row.detail)` hides it.
   - Continue’s editable text lives in row-local `@State`, which can disappear when the row moves between sections.
   - Runtime rows are already app-scoped. R7 is most likely an ordering/observation problem, not missing discovery ownership.
   - The native View popover’s Escape policy depends on unreliable popover key-window behavior. Its existing local event monitor is the correct extension point.

### Reuse and boundaries

Reuse:

- Existing lifecycle lanes, revision checks, action reservations, crash-hold acknowledgement, and registry proof.
- Existing Claude reader, baseline ledger, prefix fences, and history-only importer.
- Existing Codex observational APIs; do not introduce a rollout reader.
- Existing catalog publication and native popover monitor.

Preserve:

- Process exit does **not** prove delivery or completion.
- Recovered uncertain input never returns automatically to a live queue.
- No history operation invokes old tools or approvals.
- No stale controller callback changes a successor run.
- UI mutations remain on the main actor; registry/store work remains behind existing actor/lifecycle boundaries.
- No process signalling, production activation, or visible lifecycle action is authorized merely by this plan.

## 3. Design

### 3.1 Triage

| Finding | Disposition | Reason |
|---|---|---|
| **R1: Claude stays `dispatching`** | O43 behavior blocks activation; early acceptance can be deferred | Check must handle uncertain delivery safely, but stdout acceptance is not required to implement that policy. |
| **Claude history position** | Blocks activation and successful V5/V6 | Neither Reconcile nor Continue can work without an independently valid baseline and history location. |
| **R2: missing Codex turn ID** | Blocks activation and V4/V6/C2 | Production must create the identity consumed by recovery, not merely tests. |
| **R3: apparent running dot** | Defer visual polish | Diagnosis establishes that the captured red dot meant failure/cancellation, not running. |
| **R3: later unexplained `success`** | Blocking investigation; fix if unproven success is confirmed | A restored interrupted tool becoming successful without evidence gives a wrong result. Do not dismiss this as visual polish. |
| **R4: hidden note and lost refused text** | Blocks activation | The unsent message must remain visible and reusable after refusal. |
| **R5: editor disappearing** | Draft retention blocks activation; exact dismissal cause can be deferred after retention works | Unsent typing must survive presentation teardown, regardless of which dismissal mechanism caused it. |
| **R6: Escape** | Small activation blocker | The prescribed popover behavior fails, including unintended sheet dismissal. |
| **V1 refusal notice** | Fix before re-check | The reason exists but is too transient; persistent feedback makes refusal understandable and verifiable. |
| **R7: survivor visibility** | Small ordering fix plus live confirmation | Discovery is already app-scoped; put blocking runtime items first rather than adding another discovery path. |
| **V2 guide mismatch** | Documentation prerequisite | The guide must expect Check to clear a proven stopped hold. |
| **Refresh expectation** | Documentation prerequisite | Keep Refresh read-only; require Check or “It stopped” to acknowledge the remaining hold. |

### 3.2 Step A — Fix Escape without moving keyboard focus

**Goal:** one Escape closes only the View popover in both banner and sheet.

**Scope:** `AgentRecoveryNativePopover.swift` and its decision-table tests.

Change the internal decision interface from:

`decide(isMouseDown:isEscapeKey:isInPopoverWindow:isOnAnchor:)`

to:

`decide(isMouseDown:isEscapeKey:isInPopoverWindow:isInAnchorWindow:isOnAnchor:)`

Behavior:

- Escape in the popover window **or its anchor window**: close and consume.
- Escape in an unrelated window: deliver unchanged.
- Other keys: deliver unchanged.
- Preserve the existing mouse decision table and outside-click pass-through.
- Install the monitor only while the popover is shown; remove it on every close/dismantle path.

Remove `AgentRecoveryNativePopoverKeyFocus`, its protocol seam, deferred `takeKey`, `previousKeyWindow`, and focus restoration. Do not replace them with another focus mechanism.

`Coordinator.shouldConsume` supplies the additional window-identity comparison. Keep deferred binding reporting during SwiftUI dismantling.

**Unit acceptance**

- Anchor-window and popover-window Escape both return `.closeAndConsume`.
- Unrelated-window Escape and non-Escape keys remain `.ignore`.
- Existing mouse cases remain unchanged.
- Remove the four tests asserting the disproven key-focus model.

**Live acceptance:** P5, including sheet survival, selected text, running turn, mention palette, unrelated window, outside-click pass-through, and no-popover behavior.

---

### 3.3 Step B — Preserve continuation text independently of row presentation

**Goal:** fix R4 and prevent R5 from losing text without first redesigning the editor.

#### Durable refused text

Extend the existing action-fact derivation rather than introducing a second scan with different eligibility rules:

- Add optional `unsentContinuationText: String?` to `AgentRecoveryCatalogActionFacts`.
- Derive it from the same unresolved action that makes `hasUnsentContinuation(for:)` true.
- Ignore later textless Reconcile attempts.
- Do not select an older action merely because it has text when a later action has resolved it.

The catalog remains a projection; this field is not persisted separately.

#### In-progress editing

Add view-model-owned, main-actor state keyed by **`AgentRecoveryCardKey`**, not display row ID. Banner prefixes and sheet section changes must not create separate drafts.

Each entry owns:

- Exact text, including deliberate empty text.
- Local edit revision.
- Last submitted revision, if any.

Lifecycle:

- Create on first edit; retain through popover dismissal, sheet dismissal, row reorder, section changes, and tab/workspace navigation while the view model lives.
- Remove on explicit discard, session deletion, or confirmed handoff of that exact submitted revision.
- Never clear newer edits when an older asynchronous submission completes.
- On refusal, retain the draft; the persisted action is the restart fallback.
- Do not add pre-Send disk persistence in this step. This is explicitly in-window lifetime retention, not a new crash-durable editor.

Opening precedence:

1. Existing in-memory draft, including empty text.
2. Durable unresolved continuation text.
3. `recoveryContinueDefaultText`.

The row’s editor reads/writes through callbacks in `AgentRecoveryListActions`; row-local state retains presentation state only. The Send callback still uses the existing recovery action runner and duplicate-click joining.

Use the existing structured action report/outcome to decide whether a submitted draft was handed off. A `nil` error alone is insufficient: reconciliation can succeed without sending because the old turn already finished.

#### Visible unsent notice

Give the row a separate optional continuation-status field rather than appending critical text to a truncated detail string.

Render:

1. Normal detail.
2. Action error, when present.
3. **“The message you typed to continue it was not sent.”**, when applicable.

The critical note must not share the detail’s two-line truncation.

For banner layout, replace the single fixed-height assumption with one shared per-row height calculation used by both rendering and `reservedHeight(for:)`. Preserve the existing maximum visible row count; allocate separate space for error and unsent-note lines. The sheet can use intrinsic height.

**Unit acceptance**

- Refused custom text reappears after reopen and after store reload.
- Textless Reconcile does not replace it with the default.
- Explicit empty editing does not fall back to the default.
- Row section movement, banner/sheet switching, and dismissal preserve edits.
- An older successful submission cannot clear newer typing.
- Error and unsent note are both represented.
- Two Send invocations still produce one dispatch action.
- Session deletion removes cached drafts.

**Live acceptance:** R4/A9, V6 refusal and success, R5 dismissal/reopen. Retain SwiftUI presentation unless text still disappears after this ownership change.

---

### 3.4 Step C — Implement O43 using the existing acknowledgement

**Goal:** Check clears the execution blocker and actionable uncertainty warning after positive process-exit proof, without manufacturing acceptance.

#### Exact meaning of “clears”

| Concern | After successful Check |
|---|---|
| Intent delivery state | Remains `dispatching` or `deliveryUnknown`; do not write `providerAccepted`, `failed`, or `withdrawn`. |
| Recovery record | Existing `crashHoldAcknowledgement` covers the exact incarnation, reset generation, held run IDs, uncertain intent IDs, and transcript turn IDs. Payloads, attempts, and outcomes remain intact. |
| Execution hold | Released for precisely the acknowledged scope. |
| Default banner / Needs action | The covered uncertainty row no longer demands action. |
| Information section | Retain a row: **“Previous run stopped; message delivery remains unconfirmed.”** Preserve access to the saved payload. |
| Automatic delivery | Never enqueue or resend that intent. Earlier-launch input remains held under existing admission rules. |
| Available recovery | View/copy payload, open the session, and use existing eligible run-level Reconcile/Continue. Any resend/edit path retains explicit uncertainty safeguards. No newly enabled “Send saved” merely because processes exited. |
| Future acknowledgement invalidation | New uncertainty, a changed incarnation/reset generation, or an uncovered attempt requires fresh evaluation. |

Do not automatically age out this informational uncertain-message row. Explicit Dismiss remains available and is still only a presentation acknowledgement.

Apply the same projection semantics to an equivalent acknowledgement produced by “It stopped”; do not create two interpretations of the same stored acknowledgement.

#### Eligibility algorithm

Extend `confirmCrashHoldFromRegistryProof`; remove only the blanket refusal for nonempty `uncertainIntentIDs`.

Before requesting proof, derive the exact eligible scope from the current record:

1. Preserve all existing registration, activation, lifecycle, destination, freshness, and older-turn checks.
2. Require every uncertain intent in the hold to exist in the same incarnation/reset generation.
3. For each such intent, inspect **every attempt that may have handed it off**.
4. Each such attempt must have an unambiguous existing association to a held run covered by the exit query.
5. An affirmatively never-handed-off attempt requires no process proof. A missing, ambiguous, unrelated, or later uncertain attempt refuses the whole confirmation.
6. Use the registry’s existing full-family proof. Root exit alone, elapsed time, disappearance from one process listing, or incomplete inventory is insufficient.
7. Revalidate the held scope after the registry await.
8. Commit the existing acknowledgement through the existing lifecycle transaction.

At the store boundary, verify the scope again against the revision being written. Extend `recordCrashHoldAcknowledgement` with a defaulted optional **proof-confirmation constraint** containing the expected uncertain-intent/attempt membership. Existing manual callers keep their current contract; proof-based callers must supply it.

Use a shared pure eligibility helper for coordinator preflight and store validation. This prevents the write path from accepting a broader scope than the check inspected.

A revision conflict must restart evaluation from a fresh record and fresh proof under the existing bounded retry policy. Never silently expand the acknowledged set.

#### Concurrency and interruption

- Check orchestration and catalog updates remain main-actor operations.
- Registry discovery/proof remains actor-isolated.
- Keep the existing recovery action/session hold through acknowledgement; a new managed writer must not enter during the proof-to-write interval.
- Before implementation, verify that this hold also covers the closed-session write path. Add a race test; do not assume main-actor execution prevents actor reentrancy.
- Stop before committing means no acknowledgement.
- Stop after a successful write does not roll it back; retain the existing “result appears on the card” behavior.
- Storage failure preserves the blocker and displays the existing save-failure result.

#### Why a genuinely delivered message is not lost

The acknowledgement says **execution stopped**, not **delivery failed**. The original input, unknown delivery state, and potential recovered output remain accessible. It neither marks work complete nor makes the payload retryable. An actual `providerAccepted` intent is not converted into uncertain input or withdrawn.

Already-authorized scheduled sends may become eligible when the hold is released; preserve the existing Check warning about this consequence. That is distinct from replaying the acknowledged intent.

**Unit acceptance**

- Claude-shaped uncertain intent with all relevant registered families exited: acknowledgement succeeds; delivery state and payload unchanged.
- Reload reproduces the informational row and released execution hold.
- Live writer, live tool, reserved/unknown runtime, incomplete inventory, and missing registration all refuse.
- Unrelated attempt, missing association, changed reset generation, new attempt during proof, and record revision conflict cannot broaden clearance.
- Accepted input is unchanged.
- Multiple uncertain attempts require coverage of all potentially delivered attempts.
- Save failure and cancellation do not falsely report clearance.
- No queue pump, provider send, or recovery continuation is triggered by confirmation.
- Previously authorized scheduling remains governed by its existing rules.

**Live acceptance:** clean Claude Check, survivor Check refusal, stopped-survivor Check, C2, and removal of the misleading actionable uncertainty warning.

**Refresh remains unchanged.** Correct the guide to: **Refresh updates process status; Check or “It stopped” clears the remaining hold.**

---

### 3.5 Step D — Repair Claude history discovery and first-send baselines

**Goal:** make the existing baseline/reader pipeline work through the rotator wrapper.

#### Recognizing the real Claude process

Do not classify arbitrary numeric executable basenames as Claude, and do not treat every process carrying `CLAUDE_CONFIG_DIR` as the writer.

Extend the existing Claude launch-pair qualification to recognize the native-install executable using:

- Same UID and validated process birth identity.
- The registered runtime marker and/or established wrapper-to-child ancestry under existing discovery rules.
- The configured Claude executable’s resolved target, including the observed native-install path such as `~/.local/share/claude/versions/2.1.302`.
- The supported Claude launch-pair/version qualification.

Normalize executable paths during qualification; compare exact resolved executable identity rather than just basename. A process outside the registered family is not promoted merely because its path resembles a Claude installation.

Read and retain only that verified writer’s `CLAUDE_CONFIG_DIR`. Do not persist its environment or command line.

If verified writers report conflicting homes for the same relevant runtime/conversation, history location is uncertain. Do not silently overwrite the previous home or choose the first result.

Before baseline capture, perform one on-demand registry discovery refresh. This addresses the registration-versus-child-spawn race without polling.

#### Bounded fallback lookup

Keep the exact-session reader. Add lookup before reading, not a second parser.

Known roots are:

1. Registry-recorded Claude homes.
2. `~/.claude`.
3. The known local rotator layout demonstrated by the diagnosis: direct profile directories under `~/.claude-rotator/profiles`.

For each home, inspect only `projects` and its immediate project directories for the exact `<conversationUUID>.jsonl` filename. Do not recursively search the home directory, read authentication/configuration files, or invoke Claude to locate history.

Rules:

- Validate conversation ID as a UUID before constructing paths.
- Canonicalize/deduplicate roots and file identities.
- Reject path escapes and nonregular files.
- A fallback succeeds only when the complete bounded search yields exactly one distinct matching file.
- Zero matches, multiple matches, inaccessible portions, or exceeded bounds produce distinct unavailable reasons; no “first match wins.”
- Validate the selected file using the existing reader’s conversation checks, baseline cursor, and prefix fences. Filename uniqueness alone is not association proof.

Use explicit fixed limits: **256 homes, 16,384 project directories, and a five-second monotonic search budget**. Reaching a limit refuses recovery; it must not accept the partial result. These are operational bounds, not measured performance requirements.

Run enumeration off the main actor, check cancellation between directories, and revalidate the action/session identity before applying the result.

A trusted recorded home can take the direct path. The cross-root search is the fallback when that direct location cannot provide a verified exact history file.

#### First-send baseline

History discovery alone cannot repair “no Claude conversation identity before sending.”

Use the existing `freshSessionID` capability for **new standard-Claude sessions**, after qualifying `--session-id` through the actual rotator launch path:

- Allocate the UUID before launch and associate it with the runtime.
- Never combine `--session-id` with `--resume`.
- Existing conversations continue using `--resume`.
- Capture an empty-history baseline only for this newly allocated conversation, with no earlier handoff and a complete successful lookup proving no matching history exists.
- A missing history file for a resumed conversation is not an empty baseline.
- Persist the baseline and outbound identity through the existing save/receipt path before writing the user message.

Enable the capability only for the qualified standard-Claude pair. This does not enable “Continue in a new conversation” or Safe Restart.

If the required evidence is unavailable, retain the existing explicit unsupported-baseline behavior. Do not backfill historical unsupported baselines from today’s end-of-file position.

**Unit acceptance**

- Version-path writer under the wrapper yields the expected home.
- Numeric tool executable, unrelated Claude process, stale birth identity, wrong UID, and child-set tool environment do not supply writer authority.
- Conflicting homes refuse.
- Direct root, default fallback, rotator-profile fallback, duplicate aliases, multiple files, incomplete enumeration, limits, and cancellation.
- First send records a captured baseline and qualified outbound UUID before handoff.
- Resume never receives `--session-id`.
- Missing resumed history never becomes empty history.
- Baseline write failure prevents the identity-bearing handoff according to the existing admission contract.
- Existing unsupported records stay unsupported.

**Live acceptance:** V5 and real Claude V6 on newly created fixtures, including a supported text-only history shape and the interrupted-tool refusal/continuation behavior.

#### Is early Claude acceptance still needed?

**Not for this activation package.** O43 handles stopped uncertain sends, and history reconciliation depends on baseline/association evidence—not `providerAccepted`.

Early acceptance would improve live delivery reporting, but adds a separate attribution contract:

- Bind an outbound UUID to the exact dispatch evidence, run attempt, conversation, controller instance, and initialization generation **before** writing.
- Accept only a version-qualified stdout event naming that exact UUID.
- With steering, maintain distinct UUID-to-handoff entries; never attribute generic output to the latest pending message.
- Reject events from replaced controllers, previous generations, unknown UUIDs, and ambiguous/batched associations.
- Make duplicate acceptance idempotent and preserve acceptance when later cancellation occurs.
- Verify whether `queued`, `started`, `system/init`, and assistant UUID fields actually acknowledge that individual message; do not treat all four as interchangeable.
- Do not implement the diagnosis’s “single in-flight output” heuristic in this package.

The supplied capture supports investigating this later, not declaring all these event forms acceptance evidence now.

---

### 3.6 Step E — Persist Codex’s recovery target at the authoritative boundary

**Goal:** save the native identity production recovery needs.

#### Which turn to save

Store the **latest authoritative user turn for each run attempt**, paired with its thread ID.

- Initial user start: save its native turn ID.
- Accepted steer into the same turn: idempotent; no new target.
- Accepted steer that changes the authoritative turn: replace the target only after the coordinator’s existing mismatch reconciliation establishes that authority.
- Compaction: never replaces the user-turn recovery target.
- A successor run attempt gets its own target; it does not overwrite the predecessor.
- A resumed active marker alone is insufficient unless the existing coordinator establishes its association with that run attempt.

This matches the current recovery action’s single interrupted-turn target. Do not expand this step into importing every earlier turn in the thread.

#### Durable shape and write path

Add one optional namespaced member to `AgentRecoveryRunAttempt.extras`:

`codexRecoveryTarget = { threadID: String, turnID: String, sequence: UInt64 }`

- Absence means unknown.
- IDs are nonempty native strings.
- Sequence increases for a changed authoritative user-turn binding within that run attempt.
- The entire object is replaced atomically; retain unrelated extras.

Add a revision-checked store operation, conceptually:

`recordCodexRecoveryTarget(binding, expectedRevision, ownership, target) → run receipt`

Route it through the existing recovery lane/controller serialization. Capture ownership and target synchronously when `installAuthoritativeCodexTurnForStart` accepts authority; enqueue the write before publishing later terminal work. Use the same recorder from the accepted-steer mismatch path.

Do not insert a detached disk task with no lifecycle owner, and do not block stream parsing on filesystem I/O. The existing serialized lane must retain and drain the operation. Reject lower sequences; duplicate same-sequence/same-target writes are no-ops; same-sequence/conflicting-target writes fail visibly.

A crash before the receipt can still leave identity missing. Recovery then refuses honestly; it must not guess from rollout order or prompt text.

#### Consumer

`performRecoveryResumeAction` resolves identity in this order:

1. Exact source run attempt’s durable `codexRecoveryTarget`.
2. Existing transcript-span identity for legacy/test data, only when unambiguous and associated with the requested run/turn.
3. Explicit missing-identity refusal.

Validate that the stored thread matches the target conversation. Do not combine a saved turn ID with the session’s newly changed thread.

Do **not** also populate transcript spans in this step; that creates a second authority and extra synchronization without helping the recovery consumer.

#### Tool-bearing interrupted turns

Fix the misleading result now, but do not broaden import support:

- Distinguish **turn absent** from **turn found but items unsupported** in `CodexNativeSessionController.recoveryObservation` and `CodexRecoveryAdapter.historyObservation`.
- For unsupported items, preserve conservative all-or-nothing import and report:  
  **“The interrupted Codex turn was found, but this history contains unsupported items. Nothing was imported; completion is unconfirmed.”**
- Reconcile reports that limitation.
- Continue may follow the existing explicitly unconfirmed path after ownership checks; it must not treat omitted tool items as proof of completion.
- Do not silently drop tool calls and import a deceptively complete subset.

**Unit acceptance**

Drive the real coordinator event/receipt path, persist, reload, then invoke recovery—do not seed `providerTurnID` manually.

Cover initial start, same-turn steer, changed-turn steer, interleaved compaction, successor attempt, stale controller, out-of-order write, storage failure, thread mismatch, and old records.

Adapter tests distinguish missing turn, supported interrupted turn, and found-but-unsupported tool-bearing turn.

**Live acceptance:** V4, Codex V6, C2’s supported terminal-history case, plus an explicit tool-bearing limitation case.

---

### 3.7 Step F — Close the unexplained tool-status rewrite

**Goal:** establish that an interrupted tool cannot become successful merely through restoration, projection, or summary persistence.

This is the one source change whose exact mutation point is not identified by the supplied evidence. Do not invent a cause or apply a global “cancelled always wins” rule.

Use a bounded regression trace through:

- `AgentSessionRestoreSupport.sanitizeColdRestoredActivity`
- Transcript-to-chat-item conversion in `AgentTranscriptServices.swift`
- `AgentToolResultPersistencePolicy.derivedStatusWord` and summary-only encoding
- Subsequent Claude run finalization and session save/reload

Fixture: an interrupted Claude Bash activity matching T7’s persisted shape. Cold-restore it, execute a mocked later unrelated turn through normal production mutation paths, save, reload, and compare the original execution ID’s status at each boundary.

Required invariant:

> Restoration, summary reduction, and unrelated later runs preserve cancellation/interruption; only authoritative evidence for that same execution may refine its outcome.

If the reducer loses cancellation or defaults it to success, fix that reducer. If a later-run finalizer mutates historical executions, restrict it to the run/execution it owns. Do not suppress legitimate same-execution provider evidence globally.

**Acceptance:** exact execution remains interrupted through the sequence, with no invented exit code or success result.

If the anomaly cannot be reproduced or explained, keep it open at the activation decision. A broader investigation or an explicit owner deferral is required; the diagnosis is not closure.

---

### 3.8 Step G — Persistent refusal and runtime ordering

**V1 notice**

Keep `shouldClearInput: false`. Extend the recovery-blocked composer completion path so it carries a persistent-notice presentation classification instead of using the ordinary three-second steering notice.

- Persist until the next submission replaces it, the relevant blocker clears, or the session changes.
- Show the full reason; no two-line truncation.
- Re-evaluate on the existing recovery/catalog notifications.
- Return and Send use the same completion path.
- Do not add an independent polling timer or disable sending solely from a stale UI snapshot; admission remains authoritative.

**R7 ordering**

Stable-partition catalog presentation so:

1. Global ownership uncertainty and surviving-runtime restrictions appear first.
2. All other rows retain their current relative order.

Preserve IDs, counts, session filtering, and action semantics. This is presentation ordering, not another registry subscription.

**Unit acceptance:** persistent refusal survives beyond the old timeout and clears on blocker removal; composer text remains unchanged; runtime items appear without hydration and ordering does not change membership/counts.

**Live acceptance:** V1 refusal captured after more than three seconds; survivor visible at the top of Needs Attention before opening its session.

## 4. File-by-file impact

Paths below are relative to the repository. For files named only in diagnoses, locate the existing file by its exact basename before editing; their full paths were not supplied.

| File | Change and dependency |
|---|---|
| `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNativePopover.swift` | Step A event-policy argument; remove key-focus machinery. Independent. |
| `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryListBanner.swift` | Step B separate error/unsent-note rendering, shared banner height calculation, callback-backed editor text. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift` | Step B draft precedence and callback wiring; Step C acknowledged uncertainty wording; Step G display ordering integration if needed. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift` | Step B outcome-aware draft clearing; Step D refreshed Claude lookup; Step E durable Codex identity lookup. Existing dispatch safeguards stay. |
| `AgentModeViewModel.swift` | Declare main-actor continuation draft storage if Swift extensions cannot own it; initialize/clean up with existing session lifecycle. |
| Files declaring `AgentRecoveryListRowProps` and `AgentRecoveryListActions` | Add continuation status and draft callbacks; update all constructors/call sites. Exact locations require symbol lookup. |
| `AgentRecoveryActionModels.swift` | Expose the unresolved continuation action/text using the existing `hasUnsentContinuation` predicate. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift` | New text fact; acknowledgement-aware informational projection; prevent automatic hiding of acknowledged uncertain payloads; runtime-first ordering. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCoordinator+CrashHoldProof.swift` | Step C exact attempt coverage, registry proof, post-await revalidation, constrained acknowledgement. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore.swift` | Step C transaction constraint; Step E atomic target recording through existing revision/ownership checks. |
| Recovery lane/controller and model declaration files | Forward the constrained acknowledgement and Codex target operation; add typed access to the extras member and shared O43 eligibility helper. Locate existing owners; do not bypass them with direct view-model store writes. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProcessRegistry.swift` | Step D writer classification/home discovery; retain current conservative lifetime proof. |
| `AgentProcessRegistrySupport.swift` | Qualified resolved executable identity support; no generic numeric-basename rule. |
| New `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/ClaudeRecoveryHistoryLocator.swift` | Stateless bounded locator using injected filesystem/root inputs for tests; no parser or persistent cache. |
| `ClaudeNativeProcessSessionController.swift` | Validate/reuse existing preallocation path; change only if necessary to expose the preallocated identity before baseline capture. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActivation.swift` | Qualified standard-Claude preallocation capability; **production activation line changes only in the final flip**. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | Step E capture/enqueue authoritative user-turn target from accepted start and steer-mismatch paths. |
| `CodexNativeSessionController.swift`, `CodexRecoveryAdapter.swift` | Distinguish unsupported history items from absent turn; update all exhaustive result switches. |
| `AgentSessionRestoreSupport.swift`, `AgentTranscriptServices.swift`, `AgentToolResultPersistencePolicy.swift` | Step F regression trace; modify only the proven faulty transformation/finalizer. |
| `AgentInputBar.swift`, `AgentComposerUIModels.swift`, `AgentModeViewModel+Recovery.swift` | Step G typed persistent recovery-refusal presentation and existing admission mapping. |
| Existing focused tests under `Tests/RepoPromptTests/AgentMode/Recovery`, `Codex`, `Transcript`, and `UI` | Extend production-path coverage above. Add dedicated locator and continuation-draft tests where no existing suite owns the seam. |
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` | Add small-step status lines, O43 semantics, qualification limits, and corrected P5 status. Do not add assumptions as owner Decisions. |
| `docs/context/plans/evidence/2026-10-18-lossless-app-restart/verifier-scenarios.md` | Correct Check/Refresh expectations and fixture setup. |
| `…/verifier-9live-brief.md` | Replace failed-candidate instructions with the new frozen-candidate re-check. |
| New evidence files in the same evidence directory | Preserve source validation, reviews, approvals, and new live results separately from historical results. |
| `Scripts/source_layout_guardrails.sh` | Register new routed evidence/source files only where existing guardrails require it. |
| `docs/context/review-policy.md` | **No edits.** Apply it verbatim. |

`ClaudeAgentModeCoordinator.noteClaudeTurnCompleted` and its acceptance contract remain unchanged in this package.

## 5. Risks and migration

- **O43 changes presentation and admission, not delivery history.** Existing acknowledgements receive the same scoped projection. Test old manual acknowledgements as well as new Check acknowledgements.
- **Codex target is additive.** Old records decode with no target and retain conservative refusal. Verify that existing extras decoding/re-encoding preserves the nested member before landing. Older binaries may ignore it; rollback must never interpret absence as permission to guess.
- **Claude baselines are prospective.** Old unsupported baselines remain unsupported. New fixtures are mandatory; this package does not repair historical attribution.
- **Continuation cache is not a persistence schema.** Submitted/refused text remains in existing actions; edits not yet submitted survive presentation changes only while their owning view model lives.
- **Actor ordering is a correctness requirement.** Validate lane serialization and lifecycle draining for Codex target writes and O43 acknowledgements. Detached best-effort writes are not an acceptable substitute.

## 6. Implementation order and live acceptance

### Source sequence

1. **Land Step A:** Escape policy and tests.
2. **Land Step B atomically:** action-text derivation, catalog props, view-model draft ownership, callbacks, and row layout.
3. **Land Step C atomically:** O43 eligibility, store constraint, acknowledgement projection, tests, and guide semantics.
4. **Land Step D’s locator and registry changes:** independently testable without enabling preallocation.
5. **Qualify first-send preallocation through the real shim**, then land the qualified capability and baseline integration together. Until qualified, Claude successful recovery remains blocked.
6. **Land Step E atomically:** Codex producer, serialized durable write, consumer, and adapter distinction.
7. **Complete Step F’s bounded trace and fix.** Do this before freezing the candidate.
8. **Land Step G and the revised verifier instructions.**
9. **Run affected validation and required reviews for each step.** Follow the supplied policy: independent A/B implementation reviews, at most two re-review rounds, preserve findings and dispositions, no replacement reviewer when a lane fails.
10. **Commit all fixes with activation off.** Run guardrails/pre-commit checks; stage only step-owned hunks. Source completion is not live acceptance.
11. **Run the 9-flip gates:** provider-kind→launch-pair test and a release-configuration build of the activation-on candidate.
12. **Live re-check the frozen candidate**, then review and commit the activation switch if blockers are closed.

The launch-pair test must assert that standard Claude and Codex register, other provider/pair combinations remain unregistered and recovery-refused, and run-start registration marking agrees with actual launcher authority.

### Candidate integrity

The re-check candidate must differ from its committed tree **only** in:

`AgentRecoveryActivation.production = .claudeAndCodex`

Record commit, exact diff, binary provenance, and release-build result. Coordinate unrelated dirty work rather than hiding it with a weaker provenance statement. Record live evidence outside the candidate source tree until the run completes.

Any behavior-changing fix after the run requires a new candidate and affected live re-check; documentation-only reporting does not.

### Required live matrix

| Area | Required evidence |
|---|---|
| **V1 survivor** | Runtime shown before opening session; named process/worktree; Return and Send visibly refused; draft preserved; Let finish; Refresh removes runtime restriction after exit; Check clears the remaining hold without replay. |
| **O43 clean Claude** | Kill while the provider is processing a no-long-tool turn; after complete family exit, Check succeeds without hydration; intent state/payload unchanged; informational access retained; zero sends caused by Check. |
| **V2** | Codex exited-family confirmation matches the corrected guide. |
| **V4/V5** | Reconcile twice on new supported fixtures; expected import/deduplication, no user-message send, no Claude resume merely for reading. |
| **V6** | Actual same-conversation continuation for both providers; double-click joins; one new message; refused path preserves exact text and visible note. |
| **Codex tools** | Found-but-unsupported wording, no partial import presented as complete, explicit Continue remains safely gated. |
| **R3** | Interrupted Claude tool remains interrupted after a later unrelated run and save/reload. |
| **R4/R5/A9** | Custom editor text survives dismissal, section movement, refusal, reopening, and a later textless Reconcile. |
| **C2** | Live process refuses for the relevant process reason; stopped uncertain Claude hold clears; supported terminal Codex history resolves when reachable. |
| **P5 and neighbors** | Escape closes only View, not the sheet or running turn; existing click behavior preserved. |
| **Universal checks** | No unrequested send, duplicate send, fresh-conversation substitution, or lost text. Compare exact synthetic prompts against provider histories. |

### Fixture changes

- **V1:** use a synthetic finite Bash loop with enough remaining lifetime after relaunch—approximately 15 minutes, not a turn nearly finished before the kill. Confirm the real Claude writer and marker before requesting the kill. Use a separate clean no-tool fixture for O43.
- **Claude/Codex history:** create fresh sessions after the fixes. T7/T9/T14 and similar old records cannot prove prospective baseline/identity production.
- **V7:** stop trying ordinary follow-ups that become live steering. O25 already accepts the unreachable live Codex fallback trigger on unit coverage. Cover Send saved end-to-end with an isolated store/lane fixture that creates a genuine queued receipt; never edit daily recovery JSON. Label this fixture evidence, not live acceptance.
- **V8:** use an existing supported Claude question with a non-secret partial answer, and perform the approved lifecycle action before its timeout. If no supported live question path is reachable, use production question-snapshot/controller integration tests and leave live qualification explicitly pending rather than fabricating a record.
- **C2 terminal Codex case:** use a supported completed turn whose app-side recovery record remains interrupted only through an existing controlled test seam. If the real app-owned process always dies before finishing, report that branch as fixture-tested, not demonstrated live.

Every kill, quit, relaunch, or process signal requires fresh owner approval immediately beforehand. Do not assume prior cycle approvals cover this run.

## 7. Remaining owner decisions

O42 and O43 are settled. The following are distinct remaining choices:

| Decision | Choices | Recommendation |
|---|---|---|
| First-send `--session-id` qualification | Qualify the actual shim and enable the existing standard-Claude capability; or keep first-send recovery unsupported and delay activation | **Qualify it.** This is the smallest way to give first sends a defensible baseline. Fresh approval is needed for live prompts/lifecycle actions. |
| V7’s unreachable live setup | Accept production-path fixture evidence under O25; or build a new debug forcing mechanism | **Accept fixture evidence; cut new tooling.** |
| V8/C2 branches that remain unreachable live | Accept explicitly bounded integration evidence; or delay the switch until an actual fixture is available | **Attempt existing live paths once, then present the precise remaining gap.** Do not silently waive it. |
| R3 rewrite remains unexplained | Keep activation blocked for a bounded follow-up; or explicitly accept the residual wrong-status risk | **Keep it blocked until explained or corrected.** |
| Broader reader qualification fails | Keep activation off; or explicitly narrow the advertised/accepted recovery capability | **Keep it off until the owner accepts a clearly named limitation.** Do not loosen identity checks to make the scenario pass. |

Unanswered reversible design assumptions belong in `assumed:` status fields. Approvals and unresolved blocking findings remain blocked only for their dependent actions.

## 8. Cuts

Defer:

- Early Claude stdout acceptance and non-UUID attribution heuristics.
- A new Codex rollout reader or full tool-history import.
- Retrofitting old unsupported Claude baselines or guessing old Codex turn IDs.
- Replacing Continue’s SwiftUI popover before ownership-based retention is validated.
- A custom `NSPanel`, keyboard-focus framework, or global Escape handler.
- General process polling, arbitrary filesystem search, or credential/config inspection.
- A new live-fixture injection system for V7.
- Neutral/orange interrupted-tool styling and command-subtitle retention.
- Safe Restart, new-conversation continuation, additional providers, registry Stop, and retention cleanup.
- Broad coordinator refactoring.

## Recommendations

1. Fix **Escape and continuation retention first**; they are cheap and independent.
2. Implement **O43 as scoped acknowledgement**, preserving delivery uncertainty and payloads.
3. Treat **Claude baselines and Codex native identity as separate recovery prerequisites**, not consequences of R1.
4. Defer early Claude acceptance; resolve the unexplained success rewrite before activation.
5. Commit the switch only after the **single-line candidate**, required release/test gates, and explicitly scoped live acceptance pass.