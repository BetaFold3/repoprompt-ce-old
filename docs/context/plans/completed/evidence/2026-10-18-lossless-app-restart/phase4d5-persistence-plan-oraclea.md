# Step 4d5 — OracleA persistence remedy planning

Scope: read when the task touches Step 4d5 import-only verification of authorized stored Read projections.
Authority: Reference
Last-verified: 2026-10-24

Initial independent consultation and same-lane continuation on the reproduced save/reload and runtime-context blockers. Exact requested/returned OracleA identity verified for both results (continuation inherited its own preset); main read both replies fully. Full review policy included each time. Guidance, not source approval. The original single-image proposal failed actual hydration; main's chosen bounded remedy and rationale are in phase4d5.md.

## Initial response (verbatim)

# Oracle Plan



## Summary

Choose **B: verify the exact authorized storage projection**, narrowly for reader-validated singleton Claude `Read` rows. Keep raw-payload comparison as the first path; add a separate, ledger-backed comparison for intentionally summarized canonical rows. This preserves existing storage privacy, identities, save ownership, and gates. It changes the recovery contract from “the local raw payload survives” to “the local row equals the authorized persisted representation of the verified native payload.” It does **not** recover discarded file contents. A targeted change is sufficient; neither raw-retention exceptions nor rehydration machinery is necessary.

## Current-state analysis

The supplied evidence establishes a real source defect:

1. Live qualification inserts reader-projected call, result, and answer rows with deterministic IDs and ledger envelope digests.
2. `makePersistedAgentSession` supplies the transcript to the existing serialized save.
3. `AgentSessionDataService.sessionPreparedForStorage` runs `persistedTranscript`, then clears `stored.items`.
4. The pipeline compacts/truncates and sanitizes storage activities. `sanitizePersistentStorageActivity` drops call arguments, replaces result contents, and marks executions `summaryOnly`.
5. Loading reconstructs working items, protects associated calls from finalization, and runs runtime normalization.
6. `canonicalPayloadRefusal` reaches `comparePayload`, which correctly rejects those summaries as unavailable.

Lowercase tool names are secondary. IDs and envelope digests do not restore missing payloads.

Reuse the reader’s projection/digests, canonical ordering and ambiguity checks, storage sanitizer, serialized import transaction, and cursor CAS. **Do not weaken `comparePayload` or `holdsCanonicalPayload`: live-chain prerequisites must continue requiring complete raw payloads.**

The supplied excerpts omit activity construction and portions of normalization. Implementation must inspect those seams and validate the helper described below against actual stored and hydrated activities; no existing round-trip success is assumed.

## Design

### 1. Contract and proof boundary

B is sound for **authorized lossy equivalence**, not proof that raw local contents survived.

A summary is acceptable only when all of these hold:

- Existing baseline, outbound-claim, session, prefix-fence, canonical association, and ordering checks succeed.
- The entire native candidate passed reader validation.
- Its row qualifies for the bounded `Read` subset below.
- Exactly one applicable ledger mapping identifies that native row and deterministic local ID.
- The ledger’s nonnil envelope digest equals the validated row’s digest.
- An unambiguous, full, structurally uncompacted canonical activity exists.
- Its complete tool-storage representation equals the representation produced by the existing sanitizer from that native row.

A missing row, missing proof, arbitrary `summary_only`, or merely matching status is insufficient.

**Fundamental limit:** identical bytes cannot reveal whether someone intentionally persisted a summary or substituted an identical one. B distinguishes missing/corrupt representations by equality, not historical provenance. Likewise, changes discarded by the sanitizer are not recoverable from the summary. Existing native digest and prefix checks remain essential.

### 2. Reader-qualified eligibility

Add transient `storageComparableReadRowKeys: Set<String>` to `AgentProviderHistoryObservation`, defaulting to empty. Populate it only in `ClaudeSessionHistoryReader.observation(_:)`, using the complete `Candidate.validationRows`, never the ledger-filtered suffix.

Eligibility:

- **Call:** singleton entry, ordinal zero, exact name `Read`, input exactly one nonempty string `file_path`, serialized using `canonicalToolInputJSON`.
- **Result:** singleton entry, ordinal zero, string result, absent error flag, uniquely linked to an eligible call by the reader’s native tool-use identity.
- Reconstruct each singleton using `singleToolUseRow` or `singleToolResultRow`; require its identity, payload, and envelope digest to equal the validated row.
- Duplicate or ambiguous associations confer no eligibility.
- A valid call without a result is eligible independently.
- Other tools, multiblock entries, error results, and Codex receive no eligibility.

This is recovery eligibility, **not additional live-profile qualification**. It admits no provider envelope that the native reader already rejects.

### 3. One storage projection implementation

In `AgentToolResultPersistencePolicy.swift`, expose a package/internal synchronous, pure helper conceptually shaped as:

`canonicalStorageProjection(for: AgentChatItem) -> ToolStorageProjection?`

`ToolStorageProjection` is an immutable, nonpersisted value containing:

- The item’s projected kind, text, tool name, invocation ID, arguments, result, and error flag.
- The complete `AgentTranscriptToolExecution` storage value, including `summaryOnly`, status, summary text, key paths, process metadata, and any other serialized execution fields.

Exclude timestamps, sequence indices, streaming state, and grouped presentation caches; identity and streaming are checked separately.

Construct the activity through the existing canonical activity-construction path, then execute **the same identity normalization and persistent-storage activity sanitizer** used by ordinary saves. Extract/reuse those internals rather than recreating summary JSON or adding a second allowlist to the sanitizer.

This helper grants no retention exception. Oracle redaction, `results` omission, budgets, and ordinary tool behavior remain unchanged.

Require the resulting projection to be stable through the existing runtime normalization and repeat sanitation. If stability is not demonstrated, fail closed; do not add a permissive comparison fallback. Fixture tests must establish this prerequisite for the bounded Read shapes.

### 4. Import-only comparison

Extend `canonicalPayloadRefusal`, not its live prerequisite helpers:

1. Attempt existing strict `comparePayload`.
2. If it does not match, consider the bounded storage comparison only with the eligibility and ledger proof above.
3. Generate the expected storage projection.
4. Compare every field in that projection.
5. Preserve existing independent output-order and user-anchor checks.

Extend private canonical indexing to retain a unique backing `AgentTranscriptActivity` for this comparison:

- **Persisted-prefix-only row:** compare the backing activity directly.
- **Suffix plus turn copy:** suffix remains authoritative. Require its projected fields to equal the expected projection **and** its uniquely matching backing activity to equal the complete execution projection.
- **Suffix-only summary:** refuse; it lacks the backing execution evidence required for the call’s summary state.
- Duplicate backing activities, compacted turns, or non-full retention tiers refuse.

This additional backing requirement applies only to the storage path; existing raw comparison semantics remain unchanged.

Use existing refusal cases:

| Condition | Outcome |
|---|---|
| Missing/cleared proof, missing backing, ambiguity, compacted detail | `canonicalPayloadUnavailable` |
| Eligible, fully comparable storage representation differs | `canonicalPayloadMismatch` |
| Native history changed | Existing reader/digest/prefix refusal |
| Complete raw copy matches | Existing behavior |

A deterministic-ID duplicate without a ledger mapping cannot use the storage path. Proof invalidation therefore still blocks summarized recovery, without deleting rows or recreating proofs.

### 5. State, transactions, and lifecycle

All new work is synchronous value transformation inside existing reconciliation. No I/O, tasks, actor crossings, save scheduling, accounting, or producer ownership changes are introduced.

Successful storage comparison authorizes the existing planner only. Rows already ledger-known remain deduplicated; any previously unrecorded user association is committed normally. The existing atomic rows/ledger receipt save precedes cursor CAS. Repeated reconciliation appends no duplicate rows or recovery labels; receipts/cursors may update through the existing protocol.

Refusal leaves transcript, ledger, and cursor unchanged. Existing cancellation and stale-owner protections remain authoritative.

Build indexes once per preflight; storage projection work is linear in compared payload size. Do not introduce cross-request caches.

## File-by-file impact

Paths are repository-relative.

| File | Changes and dependencies |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift` | Add transient eligibility property/default; populate it in the reader extension; enrich private canonical indexing; add import-only storage comparison. Depends on projection helper. Keep strict live helpers unchanged. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Transcript/AgentToolResultPersistencePolicy.swift` | Add immutable comparison projection and pure helper sharing existing normalization/sanitation internals. Ordinary storage output must remain unchanged. |
| `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift` | Replace the successful-chain hydration blocker expectation with genuine fresh-service round trips; retain negative fail-closed coverage. |
| `Tests/RepoPromptTests/AgentMode/Transcript/ClaudeReadStorageProjectionTests.swift` — new | Differential tests against actual persistent/runtime materialization; fixed points; call-only and privacy isolation tests. |
| `docs/context/plans/evidence/2026-10-18-lossless-app-restart/phase4d5.md` | Record the lossy-equivalence contract, evidence, and fresh review results. |
| Same directory, `phase4d5-worker.md` | Supersede the blocker accurately; distinguish old failing-boundary evidence from new validation. |
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` | Update Step 4d5 status and assumptions without declaring full Phase 4 complete. |

No intended changes to `AgentModeViewModel`, `AgentSessionDataService`, pipeline APIs, reader IDs/digests, or persisted schema. Existing observation initializer call sites remain source-compatible through the empty default.

## Risks and migration

- Existing summaries qualify only if they exactly match today’s authorized projection and retain valid proof. No backfill, digest repair, or migration.
- Future sanitizer changes may make older summaries unavailable. Fail closed rather than inventing an unversioned legacy projection.
- Rollback restores conservative refusals; storage contents and schema remain compatible.
- This is a consequential verification-contract change, but reversible local source work. Record it under **assumed**, not as an owner Decision. Raw-retention authorization is unnecessary because retention does not expand.

## Implementation order

1. Add projection helper and differential tests; verify unchanged storage output and fixed points.
2. Add transient eligibility and import comparison together, with refusal tests.
3. Prove terminal save → **new data-service instance** → `loadSessionFromDisk` → reconciliation → save → fresh load → reconciliation. Assert zero appended rows, unchanged IDs/proofs, summarized disk payloads, and no accounting/ownership acquisition.
4. Cover call-only, imported chains, prefix-only rows, suffix/backing disagreement, cleared proofs, changed native bytes, altered stored fields, duplicates, ambiguity, and compaction. Verify Oracle privacy and ordinary tools remain unchanged.
5. Run affected recovery, lifecycle, reader, qualification, and transcript suites plus build/style checks. Obtain fresh independent A/B review of the same snapshot under the supplied policy before checkpointing.

## Recommendations

Proceed with **bounded B**. Cut A because it unnecessarily retains private paths/file bodies; cut C because rehydration adds lifecycle and mutation complexity without solving a required comparison problem. Keep all gates OFF. Source completion requires the real repeated round trip and fresh review; installed/no-replay qualification, unresolved-call presentation, activation, durability limits, and final live acceptance remain pending.

## Continuation after failed runtime-context validation (verbatim)

# Oracle Plan

## Summary

Choose **B with a closed set of current-pipeline representations**. The mistaken assumption was that authorized persistence has one context-independent runtime image—not that exact comparison is unsound. Accept only complete representations generated from the proven native exchange through the existing retained/rebuilt and visible/hidden paths. Never sanitize the actual candidate into acceptance. This is a bounded comparison repair, not a retention change, rehydration system, or source approval.

## Current-state analysis

The supplied code and worker evidence establish:

- `AgentSessionDataService` persists through `persistedTranscript`, clears stored items, then reconstructs working items during load.
- `runtimeNormalizedLoadedSession` either normalizes existing turns or rebuilds them from working items. Runtime materialization subsequently depends on result visibility.
- `storageRoundTripActivities` models only an isolated exchange. It misses the hidden-result representation and rebuilt-call representation found in actual tabs.
- `compareStoredProjection` correctly rejects those differences under its current single-image contract.
- The existing strict `comparePayload` and `holdsCanonicalPayload` remain appropriate for live prerequisites.

**Current validation remains failing:** 50 reconciliation tests, ten failures. Eight are representation mismatches; two are incorrect first-import count expectations.

Reuse the current reader eligibility, native/ledger proofs, backing index, pipeline functions, and import transaction. No change to persistence policy or load behavior is needed.

## Design

### 1. Revised proof contract

Authorize summarized deduplication only after the existing session, baseline, prefix, claim, identity, and ordering checks, with:

1. A reader-qualified singleton `Read` exchange.
2. Exactly one applicable ledger mapping for the compared native row, with the expected deterministic local ID and matching nonnil envelope digest.
3. An unambiguous canonical position and exactly one backing activity in a full, structurally intact turn.
4. A backing activity exactly matching one authorized representation of that same native row.
5. If a suffix copy exists, its complete projected payload exactly matching an authorized representation of that same row.

Backing and suffix may occupy **different authorized presentation states**. They must not disagree on native identity or semantic payload; each must independently match a complete generated representation.

This proves **authorized lossy equivalence**, not which presentation transitions historically occurred. It cannot distinguish tampering that replaces a representation with another byte-identical authorized representation. That limitation is acceptable because neither representation establishes raw-content survival, completion, or live ownership.

### 2. Generate four representations, not a historical catalog

Replace:

`storageRoundTripActivities(_:) → [UUID: AgentTranscriptActivity]`

with an internal synchronous helper conceptually returning:

`storageComparisonActivities(_:) → [UUID: [AgentTranscriptActivity]]`

Use the existing ordered native exchange as input. Generate these four current-code paths:

| Image | Derivation |
|---|---|
| **Loaded** | Existing canonical build → persistent materialization → runtime normalization → runtime materialization. |
| **Loaded-hidden** | Loaded transcript → existing runtime sanitizer with `preservedVisibleToolResultRowIDs: []`. |
| **Rebuilt** | Loaded transcript’s `workingSourceItems` → canonical transcript build → `runtimeTranscriptOnly`. |
| **Rebuilt-hidden** | Rebuilt transcript → existing runtime sanitizer with `preservedVisibleToolResultRowIDs: []`. |

For rebuilding, preserve item identities/order and use the existing canonical builder’s normal defaults, as the current isolated helper does. Do not fabricate load-purpose flags, interruption metadata, or per-row visibility.

These are the two demonstrated representation boundaries crossed with the two result-preservation behaviors. The supplied runtime sanitizer changes hidden results but not calls; rebuilding explains the call metadata difference. Presentation-state membership replaces historical-path inference.

Deduplicate equivalent images. Generate each exchange once per comparison invocation; no persistent or cross-request cache. Reject duplicate IDs or a required row disappearing during generation rather than overwriting dictionary entries.

**Validation gate:** demonstrate that these exact paths cover the actual terminal and running hydration fixtures. If another semantic transformation appears, stop and explain it; do not accumulate more images opportunistically.

### 3. Keep exact fields; change membership, not field filtering

Whole-execution equality is not inherently excessive. **Requiring one execution image was excessive.** Keeping equality against a small generated set is simpler and safer than deciding which fields may be discarded.

For backing activities, retain equality of:

- `itemKind`, `text`;
- the entire `toolExecution`;
- every projected field already checked by `sameProjectedTool`.

For suffix items, retain equality of kind, text, tool name, invocation ID, arguments, result, and error flag.

Continue excluding timestamps, sequence metadata, and presentation caches as the existing comparison does. Canonical relative order remains independently checked.

Consequences:

- Removing `resultJSON.summary_text` is acceptable **only** when the entire resulting representation equals the generated hidden image.
- A rebuilt call’s `summaryOnly == false` and `"Using tool: read"` summary are acceptable **only together with all other rebuilt fields**.
- Arbitrary summary text, changed status/error, injected arguments, key paths, process metadata, invocation, or result content refuse unless the complete representation is itself an authorized image.
- Never form an acceptance rule by independently unioning allowed values for individual fields.
- Never run the actual backing or suffix through storage sanitation before comparison.

Keep fallback limited to strict comparison returning `.unavailable`; a raw `.mismatch` remains a mismatch. Keep `holdsCanonicalPayload` unchanged.

### 4. Proof, duplicates, and mutation behavior

The current `include` function tolerates repeated ledger entries pointing at the same comparison index. Before granting storage fallback, explicitly reject duplicate applicable native keys or competing mappings to the same local ID—even when one carries a valid digest. Do not let ledger order select the usable proof.

Preserve:

- Missing/cleared proof, missing/duplicate backing, compacted backing: unavailable.
- Comparable backing or suffix outside the authorized set: mismatch.
- Changed native bytes: existing prefix/digest refusal.
- Prefix-only canonical rows: require backing membership.
- Suffix-only summaries: unavailable.
- Reordered canonical outputs: mismatch.
- Call-only exchange: generate the same four paths without inventing a result.

All work remains synchronous inside existing preflight. Refusal changes no rows, ledger, or cursor. Successful reconciliation uses the existing atomic rows/ledger save and subsequent cursor CAS; it grants no producer ownership or accounting.

## File-by-file impact

Paths below are relative to `Sources/RepoPromptAgentCore/AgentMode/Runtime/`.

| File | Required change |
|---|---|
| `Transcript/AgentTranscriptPolicyPipeline.swift` | Replace the single-image helper with the four-path generator. Reuse existing pipeline/sanitizer entry points; no policy change. |
| `Recovery/AgentProviderHistoryImport.swift` | Replace `Compared.stored` and `storedReadProjection` with bounded image collections. Change exact single-image comparison to complete-image membership, independently for backing and suffix. Add unique-ledger-proof enforcement. Keep eligibility, strict helpers, ordering, and planner unchanged. |
| `Transcript/AgentToolResultPersistencePolicy.swift` | **No intended edit.** Its existing runtime sanitizer generates hidden images. |
| `AgentSessionDataService.swift` | **No production edit.** Existing load branches remain the behavior being tested. |

Also modify:

- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift`: round trips, image membership, proof ambiguity, and count assertions.
- `docs/context/plans/evidence/2026-10-18-lossless-app-restart/phase4d5-worker.md`: replace the stopped-contract account with the revised contract and actual results.
- Existing `phase4d5.md` evidence and Step 4d5 plan status: record the reversible assumption, remaining blocker, and review disposition.

No schema, migration, privacy-policy, or gate changes.

## Implementation order

1. **Land generator and matcher changes atomically**, with pure tests. Verify complete-image matching and reject mixed-field combinations that match no image.
2. Resolve import counts from the supplied planner: it prepends one recovered system label before calculating `rowCount`. Therefore expect **4 for the chain and 2 for call-only**, not 3/1. Assert exactly one deterministic recovered label and respectively three/one native output items. The claimed user entry is ledger-only, not the extra appended row.
3. Run terminal and running save → fresh-service load → actual tab hydration → reconciliation twice. Ensure the freshly constructed service supplies the hydration under test, rather than merely inspecting disk alongside a reused loader. Verify zero repeated appends, unchanged proofs, no ownership/accounting, and summarized disk contents.
4. Cover prefix-only and suffix/backing views; call-only and later native result arrival; changed native bytes; cleared/duplicate proofs; altered summaries; missing, duplicated, compacted, and reordered rows. Retain ordinary-tool and Oracle privacy regression checks.
5. Rerun affected reconciliation, lifecycle, reader, qualification, persistence/privacy suites and build/style checks. Main obtains fresh independent A/B review of the same snapshot under the supplied policy before checkpointing.

## Recommendations

Proceed with the **four current-pipeline images**, recorded under `assumed:`, not an owner Decision. Cut visibility plumbing, storage-space normalization, raw-retention exceptions, and historical shim catalogs. Keep gates OFF. Source completion requires passing real repeated hydration tests and fresh review; installed/live/no-replay acceptance and activation remain pending.
