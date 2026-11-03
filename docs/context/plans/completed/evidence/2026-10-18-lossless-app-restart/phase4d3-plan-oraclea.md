# Step4d3 planning — OracleA

Scope: read when the task touches Step4d3 Claude canonical payload validation or live single-text identity planning.
Authority: Reference
Last-verified: 2026-10-23

Fresh independent planning consultation; returned explicit preset identity verified before synthesis. This is guidance, not implementation review. Main's choices are in [the scoped execution note](phase4d3.md). Full response follows; trailing Markdown whitespace is normalized for repository checks.

# Oracle Plan



## 1. Summary

Step4d3 should add a **default-off, built-in-Claude-only complete-text identity path**, using the existing stream event, transcript owner, and persistence authority. A qualifying complete assistant envelope produces one deterministic canonical row and its existing `NativeItem` proof in the same session save. Generic streaming operations cannot modify identified payloads. Reconciliation compares actual saved payloads—not just IDs—and continues to require every known entry in the full native capture. For semantic disqualification after identified output, **invalidate existing envelope proofs rather than introduce a qualification collection or run marker**. This is pre-live infrastructure only: recovery, registry, Resume, restart activation, and final live acceptance remain off.

`Step4d3 — todo | rounds 0/2 | open: none assessed | downgraded: none | assumed: default-off built-in-only implementation; Step4d2 intended contracts are dependencies, not approved code | deferred: activation, further captures, broader Claude shapes, polish, retention`

## 2. Current-state analysis

### Existing flow and ownership

1. **Provider translation**
   - `ClaudeSDKNDJSONTranslator.parseAssistantMessage(_:)` flattens assistant text blocks into ordinary `"content"` results.
   - `parseStreamEvent(_:)` also maps partial text deltas to `"content"`.
   - Consequently, downstream consumers cannot distinguish a complete native-equivalent assistant envelope from an arbitrary delta.
   - Usage already travels in separate, ordered companions. Its `contentMessageID` is the Anthropic message ID, not the SDK/native entry UUID.

2. **DTO and bridge**
   - `ClaudeProviderStreamResult` is a `Sendable`, `Equatable` provider DTO.
   - `ClaudeCompatibleProviderRuntimeBridge` explicitly copies fields into and out of `AIStreamResult`.
   - This is the correct additive transport seam. Neither usage observations nor `contentMessageID` should be repurposed as transcript identity.

3. **Controller and routing**
   - `ClaudeNativeProcessSessionController` performs accounting work and emits translated results through the existing `.stream(...)` event.
   - An original `"result"` payload—not an arbitrary translated `"message_stop"`—controls turn completion.
   - The supplied probe establishes that routing owns the complete stream event. No additional routing channel is needed.

4. **Canonical transcript mutation**
   - `AgentModeViewModel.applyStreamResult` runs transcript mutations on `MainActor`.
   - Active deltas enter a shared buffer; `applyAssistantDelta` can continue a streaming assistant across user interjections.
   - Background deltas can reopen their stream’s current assistant row.
   - `"final_content"` can replace an assistant’s text without native-envelope proof.
   - These are appropriate legacy behaviors for unidentified rows, but unsafe for rows carrying deterministic native identity.

5. **Existing persistence and recovery authority**
   - `AgentSessionProviderHistoryRecovery.NativeItem` already associates a native row key with a local item and optional complete-envelope digest.
   - Under the intended Step4d2 contract, missing proofs and missing/changed known native entries refuse reconciliation.
   - Import receipts and prefix fences establish native-history acceptance. A live UUID alone establishes neither native presence nor durability.

### Scope decision

Use a **targeted extension**, not a transcript refactor. Reuse:

- The existing DTO, bridge, controller event, and router.
- The reader’s deterministic row-ID and complete-envelope semantic-proof implementation.
- `NativeItem` as the identity/proof ledger.
- The canonical transcript and its existing save owner.
- Existing presentation refresh, background ownership, and reconciliation mechanisms.

**Evidence boundary:** the supplied slices do not include the reader, router implementation, session declaration, or persistence owner. Their contracts are described below, but their exact existing filenames and callable signatures must be resolved by symbol lookup during implementation. Do not treat guessed filenames or unfinished Step4d2 code as approved dependencies.

## 3. Design

### A. Default-off transport evidence

#### DTO addition

Add an optional companion to both stream DTOs, defaulting to `nil`:

- Provider member: `claudeTranscriptEvidence`
- Core member: the equivalent core-owned type
- Both evidence types are immutable value enums.

Partial interface shape:

```text
ClaudeProviderTranscriptEvidence
  completeTextEnvelope(envelopeJSON: Data)
  envelopeObservation(envelopeJSON: Data)
```

The core equivalent has the same two cases. `Data` holds the complete parsed SDK envelope serialized as JSON; its serialization order is **not** a digest input. Core reuses semantic normalization to construct proofs.

This avoids guessing which stdout fields participate in Step4d2’s complete-envelope proof and avoids moving core recovery policy into the provider package. Evidence is transient transport data, not a new persisted effect log.

Initializer changes are additive:

```text
ClaudeProviderStreamResult.init(existing arguments,
    claudeTranscriptEvidence: …? = nil)

AIStreamResult.init(existing arguments,
    claudeTranscriptEvidence: …? = nil)
```

Update both bridge directions. Existing constructors remain source-compatible.

#### Gate and translator behavior

Add a default-false translator initializer option, enabled only by the existing built-in Claude runtime’s internal development/test gate. Do not expose a setting or enable it for compatible plugins.

**Gate off:**

- Do not generate evidence or metadata-only results.
- Preserve existing result count, ordering, types, fields, and text.
- Do not change outbound CLI bytes, arguments, or tool identifiers.

**Gate on:**

- A top-level `"assistant"` envelope with exactly one nonempty text block is a *candidate*, not yet an accepted identity.
- Preserve its ordered usage companion.
- Attach `.completeTextEnvelope` to its single `"content"` result.
- Do not send that complete text through a second content event.
- Core performs the strict identity and semantic qualification.

For other envelopes:

- Preserve every existing legacy result and its order.
- Attach `.envelopeObservation` once, to the first legacy result.
- If there are no legacy results, emit one metadata-only result with a dedicated internal type, `"claude_transcript_observation"`.
- The view model consumes this internal result without adding a transcript row.

This permits semantic signals that currently translate to nothing to invalidate eligibility without inventing visible assistant output.

#### Classification contract

Introduce one core helper, `ClaudeLiveTranscriptQualification`, sharing the reader’s normalization/projection primitives. Its synchronous classification returns:

- **Qualified complete text:** validated native session ID, native entry ID, API message ID, exact text, deterministic ordinal-0 row ID, and complete-envelope digest.
- **Benign observation:** recognized usage/status/lifecycle information without disqualifying assistant semantics.
- **Disqualified observation:** a closed internal reason:
  - partial output;
  - unsupported assistant shape;
  - non-text output;
  - superseded;
  - aborted;
  - retracted;
  - unsupported semantic marker;
  - unknown semantic envelope;
  - invalid identity.

Qualification requires:

- Built-in Claude gated delivery.
- Main-lane output; no sidechain identity.
- Explicit, valid identity fields; no “latest message” or “latest session” inference.
- Exactly one supported text block, ordinal `0`.
- No unsupported semantic markers.
- Successful conversion through the same semantic representation used by the strict native reader.

Use exact documented/fixture-backed marker recognition, not substring matching. Unrecognized semantic forms fail closed. Reuse recognized benign usage/status forms, but do not classify a whole envelope as benign merely because it contains a familiar status field.

Partial text, thinking, tools, multiblock output, and retraction handling remain **unqualified**, even when synthetic tests exercise their refusal behavior.

### B. Canonical insertion and proof ownership

#### Reuse `NativeItem`; add no live-origin field

Store an accepted live row using:

- The reader’s existing provider/native-session/native-entry/row-kind/ordinal key.
- The reader’s deterministic local row ID for ordinal `0`.
- The reader’s complete-envelope semantic digest.
- The canonical assistant row containing the exact text.

Do not create an `ImportCommit`, advance a recovery cursor, or establish a native prefix fence when inserting live output.

No origin field is needed:

- `NativeItem` means “this canonical row has this claimed native identity and semantic proof.”
- An import receipt/fence means “native history was actually read and committed.”
- The reader must require native presence for **every** ledger entry, regardless of how it entered the ledger.

Update the ledger documentation accordingly. This broadens its producer set without changing its row-key or proof contract.

#### Application order

Handle evidence within the existing ordered `applyStreamResult` path, after delivery ownership validation and before generic text mutation.

For qualified complete text:

1. Flush earlier buffered unidentified text.
2. Compute identity and proof through the shared reader helper.
3. Check both the ledger key and canonical row ID for collisions.
4. Apply one of these outcomes:

| Existing state | Outcome |
|---|---|
| Neither row nor ledger entry exists | Append the deterministic assistant row and matching ledger entry together. |
| Both exist, identities agree, stored proof is valid, and actual canonical payload matches | Idempotent delivery: no second row and no text mutation. |
| Same identity, different payload/proof | Refuse qualification; preserve the identified row and show the incoming text as a separate unidentified row. |
| Only row or only ledger entry exists, or associations disagree | Refuse qualification; do not repair by guessing. Preserve existing data and show incoming text unidentified. |
| Existing entry has no valid proof | Do not regenerate or heal its proof from a live duplicate. |

The complete row is immediately non-streaming. Atomic insertion does not terminate the controller’s turn or discard companions.

Use existing append/replace APIs, revisions, binding updates, dirty tracking, and presentation refresh. For active-run notification provenance, reuse the existing attempt bookkeeping rather than fabricating a `final_content` rewrite.

#### Unsupported output remains visible

Refusing identity is not refusing delivery:

- Preserve normal legacy text/tool/status delivery.
- Never assign deterministic identity to unsupported output.
- For a conflicting complete envelope, append its text as a separate unidentified assistant row.
- Do not merge that fallback into the identified row it conflicts with.

No tool invocation ID changes are permitted.

### C. Protect all identified canonical rows

Define a reusable predicate from the existing ledger:

> A row is protected when a Claude `NativeItem` associates its local ID with native identity, even if its digest is absent or invalid.

Protection therefore covers prior imported rows and remains effective after proof invalidation. It also remains effective when the transport gate is off; disabling evidence collection must not make previously identified payloads mutable.

Apply it at the actual mutation seams:

- `resumableStreamingAssistantIndexAcrossTrailingUserInterjections`
- `applyAssistantDelta`
- `backgroundCurrentAssistantIndex`
- `applyBackgroundAssistantDelta`
- The `"final_content"` replacement branch
- Any additional generic assistant-text mutation found by the required mutation-site search

Protected rows cannot:

- Receive appended generic text.
- Be reopened through a background pointer.
- Have their semantic payload replaced under the same ID.

Streaming flags may be finalized. Terminal drains still flush the generic buffer and end streaming flags.

#### `final_content`

Use the existing ownership-aware target selection, then:

- **Unidentified target:** preserve current behavior.
- **Protected target with exact text equality:** leave its payload unchanged; normal completion/status handling continues.
- **Protected target with different displayable text:** preserve the identified row, invalidate qualification, and append the final text as a separate unidentified row.
- **No eligible target:** preserve legacy append behavior without inventing identity.

Compare exact text, not trimmed, rendered, or normalized text. Displayability checks remain only visibility policy.

No backward search may cross an existing ownership boundary simply to find a protected row to compare.

### D. Durable disqualification without a new marker

#### Chosen mechanism: invalidate existing proofs

For disqualifying evidence after identified output, set `envelopeDigest` to `nil` on the affected native session’s known Claude `NativeItem` entries. Preserve:

- Native keys.
- Local row associations.
- Canonical rows and text.
- Receipts, baselines, and prefix fences.
- Unrelated unknown fields.

Remove any `extras["envelopeDigest"]` value for an invalidated entry so serialization cannot resurrect a proof.

Use conservative native-session scope rather than adding a new run-to-proof collection. This deliberately makes that native conversation ineligible for automated reconciliation; Step4d3 includes no requalification or automatic healing.

If an observation lacks trustworthy session identity, use the existing owned stream/session binding. If no narrower trustworthy binding exists, invalidate the tab’s known Claude proofs rather than guessing an affected entry.

#### Why this is sufficient for the requested gap

Two cases differ:

1. **Native history removes or changes a known entry.**
   Existing full-capture entry/keyset/digest validation already refuses. No additional marker is necessary.

2. **A stdout-only abort/retraction/unsupported semantic signal arrives, but native history retains the original complete text unchanged.**
   Native equality alone would incorrectly pass. Persisting the known ledger entry with a missing proof forces refusal even though the native text still matches.

This works because the requested gap is **after identified output**: an existing row/ledger association is available to carry the invalidation. A separate run-scoped qualification marker would duplicate that refusal state.

For disqualification before any identified output, maintain a transient monotonic “qualification disabled” latch for the current provider stream. Later envelopes on that stream remain ordinary unidentified output. Reset it only on actual stream replacement/reset, not on an inferred message boundary. After invalidation, persisted proofless entries prevent a replacement stream from silently restoring qualification for that native conversation.

#### Persistence boundary

Canonical insertion plus ledger insertion, and proof invalidation plus any corresponding visible fallback mutation, must each use **one existing-owner session snapshot/save**.

Do not use `commitProviderHistoryImport` to fabricate a live import receipt. Extend the existing session-save owner’s internal callable surface only if necessary to await a row-and-ledger save without import semantics.

Required behavior:

- MainActor applies the coherent in-memory mutation.
- The existing persistence owner serializes snapshots in revision order.
- A committed invalidation must never be overwritten by an older queued snapshot.
- Save failure leaves the session dirty and in-memory eligibility refused; report through existing save-error handling and retain retryability.
- Do not expose successful durable qualification until the corresponding save succeeds.

The durability claim begins at the successful session commit, not at raw stdout receipt. A crash before an event’s first durable save is not covered by a new event journal in this step. Production activation must remain off rather than claiming that stronger guarantee.

### E. Actual canonical payload validation

Extend the existing reconciliation path **before deduplication or overlap acceptance**.

For every relevant known ledger association:

1. Find its native entry in the **full validated capture**, not just the selected suffix.
2. Require the existing exact entry keyset and complete-envelope digest checks.
3. Resolve its canonical local item.
4. Derive the canonical item’s actual semantic payload.
5. Compare that payload with the strict native projection.
6. Only then allow the row to count as already represented.

The comparison must cover persisted complete turns and the recovery suffix, including rows outside the selected import window.

Reuse the reader’s supported semantic representation. Compare every projected semantic field for each supported row kind; exclude presentation-only state such as `isStreaming`. For this step’s live assistant row, the required payload is the assistant kind and exact text, with identity checked separately.

Do **not** substitute:

- Local-ID equality.
- Stored digest equality without reading canonical content.
- Rendered or trimmed text equality.
- Comparison against only the proposed import subset.

Refuse if canonical content is unavailable because of compaction, a missing durable artifact, or a missing row. Do not treat unavailable content as empty or reconstruct it from native history to make validation pass.

Expected cost is linear in the validated native and canonical rows using temporary lookup dictionaries; no persisted index is needed.

### F. Controller, router, and concurrency invariants

Keep unchanged:

- Usage-accounting order and ownership.
- Original-result-based completion.
- Duplicate result accounting behavior.
- Deferred idle completion.
- Run-attempt rerouting.
- Background source ownership.
- Existing `.stream(AIStreamResult)` routing.

Only evidence transport and transcript consumption change.

Translator state remains serialized by its existing controller owner. Transcript and ledger mutations remain MainActor-owned. Persistence remains with the existing save owner. Do not create an independent writer, transcript service, or parallel async event consumer.

If awaiting persistence introduces a suspension, retain existing event ordering and revalidate delivery ownership before any subsequent mutation. A cancellation must not roll back visible canonical output or erase its ledger association.

## 4. File-by-file impact

Paths below are repository-relative.

| File or existing declaration seam | Change and dependency |
|---|---|
| `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeProviderStreamResult.swift` | Add optional evidence and its immutable enum. Preserve default initialization and existing usage/content-ID semantics. |
| `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKNDJSONTranslator.swift` | Add default-off evidence option; attach complete candidates and ordered observations; generate metadata-only observations only with the gate on. Preserve legacy flattening for unsupported delivery. |
| `Sources/RepoPromptAgentCore/AI/Providers/AIProviderFactory.swift` | Add equivalent optional evidence to `AIStreamResult`; leave existing call sites compatible. |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/ClaudeCompatibleProviderRuntimeBridge.swift` | Copy evidence in both directions, including every enum case. |
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift` | Wire the built-in-only gate at translator creation/reset. Preserve accounting/emission/completion order. Do not add full evidence payloads to stream-result diagnostic summaries. |
| **New:** `Sources/RepoPromptAgentCore/AgentMode/History/ClaudeLiveTranscriptQualification.swift` | Core classifier and qualified-candidate value; compose the reader’s shared normalization, deterministic ID, and semantic proof helpers. No persistence ownership. |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | Document live ledger production; add lookup/invalidation operations that preserve keys and clear proofs safely. No new serialized field. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Consume evidence before generic mutation; atomically insert row plus ledger; handle duplicates/conflicts; protect generic delta, background, and final-content paths. |
| **Existing file declaring `AgentTabSession` — not supplied** | Add only transient stream qualification state if the current stream owner has no suitable state slot; clear it on actual source replacement. No second row store or persisted collection. |
| **Existing strict Claude history reader/projection file — not supplied** | Expose/reuse the deterministic ordinal-0 ID and complete semantic-envelope projection for live candidates; no algorithm fork. Depends on the finalized Step4d2 contract. |
| **Existing reconciliation/canonical overlap validator file — not supplied** | Add actual canonical payload validation across full known history and suffix before deduplication. |
| **Existing session save-owner file, including `AgentSessionDataService` — not supplied** | Ensure coherent row/ledger snapshots and ordered durable invalidation; add an internal awaited non-import save operation only if absent. |

The existing router needs **no production change** if the probe’s whole-event forwarding contract holds. Its tests must prove that evidence survives active/background delivery unchanged.

### Tests

Use the existing suites; proposed new files are only needed where no suitable suite exists.

| Suite/location | Small meaningful coverage |
|---|---|
| Provider translator tests under `Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests/` | Gate-off result equality; one complete text with ordered usage; partial/multiblock fallback remains visible; ignored semantic signal gets a gate-on observation. |
| Existing bridge/router tests under `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/` | Bidirectional evidence round-trip; unchanged active/background ownership and event order. |
| Existing `ClaudeNativeBackgroundTranscriptTests` | Identified background row cannot reopen; another source cannot modify it; conflicting final text remains visible separately; identical final text is harmless. |
| Existing transcript tests | Active buffering across user interjections cannot append to a protected live or imported row; duplicate identity/payload is idempotent; conflicting identity/payload preserves original output. |
| Existing reconciliation suite | Full-turn canonical text tamper refuses despite correct ID; suffix match succeeds only after full-known-entry validation; native absence refuses; unavailable compacted payload refuses. |
| Existing persistence/recovery tests | Row and proof round-trip together; invalidation survives reload; unknown fields survive; stale saves cannot restore a cleared proof. |
| Existing reconciliation suite: stdout-only disqualification | Keep native capture unchanged, persist proof invalidation after retraction/partial-output evidence, reload, and require refusal. |

All new unsupported-shape fixtures are synthetic refusal tests, not live qualification evidence.

## 5. Risks and migration

- **No session version bump or new persisted collection.** Existing optional `envelopeDigest` encoding carries both valid proof and unavailable-proof refusal.
- Older data with missing proofs remains unproved; never backfill it from live output.
- Preserve unknown fields except the deliberately invalidated `envelopeDigest` value.
- Older builds may ignore the new protection policy and mutate these rows. Gate-off development must therefore not imply safe rollback interoperability after experimental live insertion.
- Step4d2 is an integration prerequisite, not an editable dependency of this task. If its final helper or persistence contract differs, adapt Step4d3 to the accepted contract; do not quietly repair Step4d2 here.

## 6. Implementation order

1. **Resolve the dependency seams read-only.** Locate reader identity/proof helpers, canonical overlap validation, session state, save ordering, and existing tests. Confirm Step4d2’s accepted contract before depending on its implementation.
2. **Strengthen reconciliation payload checks.** Add full-turn/suffix canonical comparison and refusal tests independently of live carriers.
3. **Add DTO evidence and bridge round-trip tests atomically.** Defaults remain `nil`; no runtime activation.
4. **Add gated translation and core classification.** Verify gate-off result equality and unsupported-output preservation.
5. **Land canonical insertion, ledger persistence, and mutation protection together.** These must be atomic: no identified row may become available before all generic write paths protect it.
6. **Add durable proof invalidation and reload tests.** Verify unchanged native history cannot bypass a persisted semantic disqualification.
7. **Run existing targeted translator, router, background transcript, and reconciliation suites.** Record fixture-based evidence accurately; perform no new model turn, capture, app harness, or activation.

## Recommendations

Proceed with **`NativeItem` reuse, actual canonical payload comparison, and durable proof invalidation—without a new qualification marker**. Keep the gate and all production activation off. Defer richer Claude output, requalification, retention, and live acceptance to separately authorized work.


## Controller-only scope reduction

Returned inherited preset identity verified, operation `4A57544A-EE78-42BE-804B-A76E40AC8739`. Planning only; full response follows.

# Oracle Plan

## 1. Smallest safe enrichment seam and ordering

**Accept the scope cut.** Enrich `AIStreamResult` inside `ClaudeNativeProcessSessionController`, after core translation and before stream emission. The controller already has both inputs needed: the original envelope and the bridge-converted results. Moving evidence through the provider package would add transport changes without adding information.

**Current flow:** raw payload → serialization/core translator at 2434–2440 → package-to-core bridge → controller accounting and filtering → existing `.stream(AIStreamResult)` → router → canonical owner. Keep that flow, adding evidence only after the bridge.

Step4d2 `bf1fce5a` supplies the proof contract. Step4d3a supplies canonical full-projection comparison and imported-row mutation protection; it remains an unreviewed prerequisite.

### Core-only companion

Add one optional, immutable, `Sendable`/`Equatable` companion to `AIStreamResult`, default `nil`:

- Trusted producer launch token, using the existing token type.
- Evidence variant:
  - **Complete envelope:** immutable raw-envelope JSON bytes.
  - **Successful-result observation:** raw envelope, requiring owner-side final-text comparison.
  - **Disqualified:** a closed reason identifying the refusal.

Reuse Step4d2’s semantic projection/digest implementation; JSON serialization order is not proof. Keep evidence transient and exclude raw envelopes from logging summaries.

The successful-result variant is necessary because `result.result` can conflict with canonical text independently of the assistant envelope. Treating every successful result as benign would leave that gap open.

### Processing order

For each raw payload:

1. Preserve original-payload completion detection and existing accounting order.
2. Translate exactly once.
3. When the captured launch gate and eligibility both permit it, classify the **raw payload regardless of translated-array length or eventual suppression**.
4. Update the producer qualification latch immediately if classification disqualifies.
5. Use the existing result loop unchanged for accounting, provider-ID recording, logging, state/progress handling, and suppression.
6. Attach evidence exactly once:
   - Complete-envelope evidence goes on the unique surviving content result representing that complete text.
   - Disqualification/result-check evidence goes on the first surviving stream result.
   - If none survives, emit one metadata-only **core** result through `.stream(...)`, after loop processing and before original-result completion handling.
7. Execute the existing original-result FIFO/completion logic unchanged.

A complete-envelope candidate is eligible only when translation yields one matching, whole-text content result. Zero, multiple, or mismatching content results disqualify; preserve whatever legacy results exist rather than manufacturing another copy of the text.

The metadata-only result has a dedicated internal type consumed without creating a transcript row. It must not enter translation, accounting, provider-ID recording, or completion logic.

**Gate off:** no companion, metadata-only result, changed result ordering, or changed CLI bytes. Plugin/wrapper paths never enter enrichment.

At the canonical owner, process evidence **before the attached result’s generic mutation**. Qualified complete text is inserted atomically rather than also entering the generic buffer. Unsupported output follows existing visible delivery; conflicting text remains visible separately without replacing protected text.

## 2. Minimum producer-scoped ownership

### Controller-owned state

Capture these at actual producer installation, alongside `activeStdoutLaunchToken`:

- Existing launch token.
- Immutable qualification-enabled flag: injected default-off flag **and** `outboundUserMessageIdentityEligible`.
- A monotonic qualification state: `eligible` or `disqualified(reason)`.

Only actual producer installation at 1359–1362 creates a fresh eligible state. Clearing the producer clears its state. Do **not** reset qualification on:

- `resetEventsStreamForNewRun`;
- system/init;
- turn completion or another prompt;
- router changes;
- active/background transitions.

Check the payload callback’s producer token against the installed producer before changing this state. A stale producer must neither disqualify its replacement nor acquire the replacement’s token.

After disqualification, every subsequent raw payload carries the sticky disqualification instead of a new positive claim, once per payload using the attachment/fallback rules above. This lets a replacement consumer learn the refusal without a new replay channel.

### Canonical-owner enforcement

The existing routed delivery ownership identifies the destination. The companion’s launch token identifies provenance; it is **not** authorization to write whichever tab is currently active. Background delivery uses its existing source/session ownership.

For accepted text:

- Reuse the deterministic ordinal-0 reader ID.
- Mutate canonical row and `NativeItem` together on MainActor.
- Mark the existing session dirty.
- Create no import receipt, cursor advancement, or durability claim.

For disqualification after identified output:

- Preserve row associations and canonical content.
- Clear typed `envelopeDigest` **and** raw `extras["envelopeDigest"]` for the affected native conversation.
- Never restore those proofs from later live delivery.
- If trustworthy conversation scoping is unavailable, conservatively invalidate the owned session’s Claude proofs, not another session selected from untrusted payload fields.

A proofless known entry blocks new live qualification for that conversation, including after producer replacement. This makes owner-detected conflicts sticky without adding another persisted marker or controller feedback channel.

Repeated identity plus matching proof **and actual canonical payload** is idempotent. Conflicting identity/payload refuses, invalidates qualification, and preserves incoming output as unidentified text. A proofless entry cannot be “healed” by a matching duplicate.

### Successful-result observations

Before applying legacy `final_content`, compare `result.result` against the uniquely associated identified assistant for that **owned turn**:

- Exact equality: no payload mutation; ordinary completion continues.
- Different text: invalidate proofs; preserve the identified row and display differing output separately.
- Missing/ambiguous association: refuse qualification; do not search backward across turn/source boundaries.

This check runs even when translation produces no forwarded final-content result. The transient lookup can use existing turn ownership plus the ledger; it must not become another transcript store. If the existing ownership context cannot establish that association, refusal—not heuristic matching—is the bounded behavior.

## 3. Explicit benign classification and implementation seams

Use a narrow allowlist, not “all non-assistant events” or “all system events.”

| Raw event | Bounded treatment |
|---|---|
| `command_lifecycle` | Benign only for the supplied key shape—`command_uuid`, `session_id`, `state`, `type`, `uuid`—with valid identifiers and `queued`, `started`, or `completed`. It does not finalize or reset qualification. |
| `system` / `init` | Benign only for the recognized initialization schema. Other system subtypes, compaction markers, or unrecognized semantic additions disqualify. |
| Replayed `user` | Benign only when associated with the existing outbound caller/native-user claim and matching supported replay content. No inferred “latest user” association. |
| `rate_limit_event` | Benign only for the validated informational rate-limit schema; preserve legacy status handling. |
| Single-text `assistant` | Positive candidate only through the strict shared projection: valid identities, supported main-lane envelope, exactly one supported text block, and no unsupported markers. |
| Successful `result` | Conditional observation, not unconditional benign status: require the supported success shape and exact owner-side final-text agreement. |
| Everything else | Disqualify unless explicitly supported above. |

Known supersedes, retraction, abort, compaction, partial/`stream_event` output, tool or thinking blocks, multiblock assistant output, invalid identities, and unknown semantic shapes all disqualify. Preserve their existing legacy delivery; refusal must not discard otherwise displayable model output.

**Consequential evidence limit:** event counts establish neither the complete init/rate-limit/result schemas nor their permitted nested fields. Validate those allowlist branches against the already-authorized offline O19 artifact or existing sanitized fixtures. Do not request another capture or infer permissive schemas from counts. Until validated, an unrecognized shape refuses.

### Files/seams changed

| File/seam | Step4d3b change |
|---|---|
| Existing `AIStreamResult` declaration in `AIProviderFactory.swift` | Optional core-only evidence, default `nil`; existing initializer calls remain compatible. |
| `ClaudeNativeProcessSessionController.swift` | Default-off injected configuration; launch-owned latch; raw classification; evidence attachment and metadata fallback. Preserve existing completion/accounting branches. |
| Core-only `ClaudeLiveTranscriptQualification.swift` | Small classifier composing Step4d2 projection/proof helpers; explicit benign/disqualifying cases. No persistence or routing ownership. |
| `AgentModeViewModel.swift` | Consume evidence before mutation; qualified row-plus-ledger insertion; result comparison; proof invalidation and dirty marking. Reuse Step4d3a guards/comparison. |
| `AgentSessionProviderHistoryRecovery.swift` | Existing-ledger lookup/invalidation helper if absent; clear typed and raw digest without rebuilding away unknown fields. |
| Existing controller/router/transcript/reconciliation test files | Focused tests below. |

**Unchanged:** package DTO, package translator, root translator adapter, bridge, router production implementation, persistence schema, save owner, registry, Resume, restart activation.

Implementation order: add default-`nil` core transport and classifier; add owner consumption/proof handling; then wire gated controller enrichment. Controller wiring and its owner handling must land together before any test enables enrichment.

## 4. Scheduled persistence boundary and smallest tests

**Retain the existing scheduled-save boundary. No new save barrier is required for this explicitly pre-live step.**

The supplied save behavior supports this limited contract:

- MainActor immediately applies coherent row-plus-ledger insertion or proof invalidation and marks dirty.
- In-memory qualification is refused immediately after invalidation.
- `makePersistedAgentSession` snapshots canonical rows and ledger together.
- An older snapshot may commit **before** the invalidation snapshot; the existing mutation check requests a fresh save.
- Serialized writes prevent an older VM snapshot from subsequently overwriting an already committed invalidation.
- Save failure leaves dirty state and in-memory refusal intact, using existing retry/error behavior.

**Explicit crash window:** termination before the first invalidation snapshot commits can leave previously valid proofs on disk. Native history might retain the unchanged text and omit the stdout-only disqualifying signal; reload could then lack evidence of refusal. Proof clearing does not solve that pre-commit window. Accept it only as this step’s stated boundary, with production activation off and no claim of immediate crash-safe revocation.

No terminal-only save: interrupted output must use ordinary ongoing dirty/save scheduling. No persisted member or migration is added; transient evidence defaults absent and unrelated unknown fields survive.

### Required tests only

1. **Controller gate-off and eligibility:** identical legacy results/order/accounting/completion; no enrichment for plugin/wrapper or ineligible launches.
2. **Attachment/suppression:** one complete-text carrier with unchanged usage companions; empty arrays and fully suppressed disqualifying payloads yield exactly one metadata event; original result completion occurs once.
3. **Producer lifecycle:** disqualification survives later turns and consumer reset; new actual launch resets only controller state; stale-producer callbacks cannot affect the replacement.
4. **Classification table:** observed benign shapes pass their explicit schemas; each listed semantic-disqualification category refuses while retaining legacy output.
5. **Router/background transcript:** evidence reaches the owning background session unchanged; duplicate delivery is idempotent; later deltas/final text cannot alter protected rows; conflicting final output stays visible separately.
6. **Persistence/reconciliation:** row and proof share a snapshot; clearing both digest representations survives reload and preserves unknown fields; unchanged native history still refuses after committed invalidation; later live delivery cannot restore proof.
7. **Scheduled-save ordering:** an older queued snapshot triggers a fresh snapshot after mutation and cannot overwrite committed invalidation. Use the existing persistence test facilities—no new harness.

Reuse Step4d3a’s full-history canonical comparison, missing-native-entry, and compacted-content refusal tests rather than duplicating them. All new fixtures are synthetic/offline evidence, not broader live qualification.

## Recommendations

Accept controller-boundary enrichment and cut all provider-package/bridge changes. Use a producer-scoped monotonic latch, existing `NativeItem` proof invalidation, and the existing scheduled save boundary with its explicit pre-commit crash window. Keep every production activation gate off; Step4d3a acceptance remains a prerequisite.
