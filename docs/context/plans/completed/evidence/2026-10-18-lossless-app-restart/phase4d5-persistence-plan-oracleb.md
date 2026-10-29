# Step 4d5 — OracleB persistence remedy planning

Scope: read when the task touches Step 4d5 import-only verification of authorized stored Read projections.
Authority: Reference
Last-verified: 2026-10-24

Initial independent consultation and same-lane continuation on the reproduced save/reload and runtime-context blockers. Exact requested/returned OracleB identity verified for both results (continuation inherited its own preset); main read both replies fully. Full review policy included each time. Guidance, not source approval. The original single-image proposal failed actual hydration; main's chosen bounded remedy and rationale are in phase4d5.md.

## Initial response (verbatim)

# Oracle Plan



# Step 4d5: Claude Read rows after save and reload, with option B (compare against the stored projection)

## Summary

I recommend **option B, limited to the exact Read shape and to ledger rows that already have a proof.** It is sound within the existing architecture. Nothing changes in persistence, privacy, the schema or the live owner.

The change is one new pure helper and one decision in the import preflight. The import's canonical payload check would accept a stored copy of a Read call or result when that copy exactly equals what the **real save pipeline plus the real load normalization** produce from the native projected row. That is the authorized persisted form, written here as **E′**. The check accepts it only after the existing checks pass: ledger key, session, envelope digest, ambiguity, tier completeness and order.

What B proves is that the local copy is the policy's lossy projection of a native payload that is already proven, not a raw copy. That is all the stored file ever holds for any tool. Option A is cut because it changes private file-body retention. Option C is cut because it adds a new content authority.

## Current-state analysis

- **Save.** `AgentSessionDataService.sessionPreparedForStorage` (around lines 721–738) runs `AgentTranscriptPolicyPipeline.persistedTranscript(from:)`: compaction, then historical truncation, then `materializePersistentStorageTranscript`. It then clears `stored.items`.
  - `sanitizePersistentStorageActivity` changes Read rows as follows:
    - The tool name is normalized through `normalizeToolIdentity`.
    - Call: `resultJSON` becomes nil and `text` becomes `sanitizedToolCallText`.
    - Result: `resultJSON` and `text` become the `persistedToolResultSummary` JSON.
    - `argsJSON` becomes nil, `summaryOnly` becomes true and `keyPaths` is emptied.
  - The summary is built from the result together with its arguments. Those arguments may come from the builder's paired execution.
- **Load.** `runtimeNormalizedLoadedSession` runs `workingSourceItems(from: stored)`. Next comes the repair: Claude IDs are protected, so the call stays a `.toolCall`. Then `runtimeNormalizedTranscript` or a rebuild, then `runtimeTranscriptOnly`, then the cold-restore sanitize, then `workingSourceItems`.
  - After hydration, both the suffix copies and the turn copies are stored forms.
- **Import.** `AgentProviderHistoryAssociationPreflight.canonicalPayloadRefusal` compares every ledger row of this conversation that maps to a local item. It reads them against `validationRows`, the whole native capture, on **every** import.
  - `comparePayload` returns `.unavailable` in three cases: `!isComplete`, which includes a turn copy with execution `summaryOnly`; dropped arguments; or a summarized result.
  - So once any Read row is saved, every later import of that conversation fails closed. This is the reproduced blocker.
- **Existing proof chain to reuse.** Every Claude `NativeItem` with a `localItemID` and a non-nil `envelopeDigest` was recorded while its canonical copy exactly equalled the native projection:
  - live rows through `holdsClaudeLiveTranscriptRow`;
  - imported rows, which are appended verbatim;
  - already-present rows, which the third loop of `canonicalPayloadRefusal` compares exactly before the planner records them.
- **What protects the rows afterwards.** After insertion, the central mutation backstop, the cold-restore `protectedItemIDs`, and the save and load transforms are the only things that change projected fields. Proof invalidation clears `envelopeDigest`.
- **Assumption to validate:** no pre-4d3a Claude ledger entry with a local item exists in real data. The gate has been OFF throughout, so none is expected.

## Design

### 1. Stored round-trip projection helper

Add `AgentTranscriptPolicyPipeline.storageRoundTripItems(_ items: [AgentChatItem]) -> [UUID: AgentChatItem]` in `AgentTranscriptPolicyPipeline.swift`.

- **Kind and visibility:** internal static, pure, synchronous, cannot fail, and has no actor dependency.
- **Steps**, which mirror the real seam:
  1. `AgentTranscriptIO.buildTranscript(from: items, terminalState: nil, nextSequenceIndex: max+1, policy: .canonical)`. The terminal state is nil because real protected Claude rows are never finalized.
  2. `persistedTranscript(from:)`, the exact entry point the save uses.
  3. `AgentTranscriptIO.runtimeNormalizedTranscript`.
  4. `runtimeTranscriptOnly`.
  5. `AgentTranscriptIO.workingSourceItems(from:)`, keyed by ID.
- **Why reuse instead of re-deriving:** this keeps the actual sanitizer as the only authority, with no copy of its Read rules.
- **Deliberately omitted:** the cold-restore delivery sanitize, which only affects user bubbles and intents (assumption; the running-save fixture below checks it).

### 2. Preflight changes in `AgentProviderHistoryImport.swift`

**a. Split `CanonicalPayload.isComplete` into two fields.**

| Field | Meaning |
|---|---|
| `turnComplete` | `retentionTier == .full && !isStructurallyCompacted`. Always true for suffix copies. |
| `executionSummaryOnly` | The turn copy's `toolExecution?.summaryOnly`. False for suffix copies. |

The existing exact path keeps requiring `turnComplete && !executionSummaryOnly`, so its behavior is unchanged.

**b. Build `storedProjections: [UUID: AgentChatItem]` inside `canonicalPayloadRefusal`.** Build it only in the ledger loop and only for **eligible** rows. A row is eligible when all of the following hold:

- `observation.provider == .claude`, and the row is not a user row.
- `native.envelopeDigest != nil` and it equals `validationRows[index].envelopeDigest`. A cleared or invalidated proof, or a changed native entry, is never eligible.
- The native exchange has the exact Read shape, read from `validationRows`:
  - exactly one `.toolCall` row with this `toolInvocationID`, with `toolName == "Read"` (case-sensitive);
  - its `toolArgsJSON` equals `canonicalToolInputJSON` of exactly `{file_path: non-empty String}`;
  - at most one `.toolResult` row with the same invocation ID, `toolName == "Read"`, `toolIsError == nil` and a non-nil string result.

For each eligible exchange, call `storageRoundTripItems([callItem, resultItem?])` once and take the entry for the compared ID. A call with no result projects from `[callItem]` alone.

Rows that are not eligible get no projection. This covers rows from the observation-only third loop, which have no prior proof: a lossy match must never mint a proof.

**c. Change `comparePayload` to `comparePayload(_:expected:storedProjection: AgentChatItem?)`, decided in this order:**

1. The exact path, unchanged (including the turn-copy tool-name exception).
2. If `storedProjection` is non-nil and `payload.turnComplete`, compare against it on the same fields: kind, text, toolName, invocation, args, result and isError. These must be **exactly equal**; the name exception does not apply, because the projection already carries the normalized name. Equal gives `.match`.
3. If `storedProjection` is non-nil and the copy is storage-shaped but unequal, return `.mismatch`. Storage-shaped means the same kind and either:
   - for a call, `toolArgsJSON == nil && toolResultJSON == nil`; or
   - for a result, `AgentTranscriptToolNormalizer.isSummaryOnly(raw: toolResultJSON)`.

   This covers an altered stored summary, or a summary the authorized policy would not produce.
4. Otherwise, fall through to the existing `.unavailable` and `.mismatch` classification.

**d. `holdsCanonicalPayload` passes `storedProjection: nil` and stays exact.** The live owner's prerequisites, duplicate no-ops and `readAgreement` are unchanged. Hydrating in the same launch in the middle of a chain still refuses, as before; this is deferred.

**What stays unchanged:** ambiguity handling, the turn-only placement rule, separate ordering for outputs and user anchors, `ClaimAssociation`, the planner, existing-ID dedup through `canonicalItemIDs`, fences and cursor CAS.

### 3. Why B is sound, and its limit

The native entry is proven unchanged since insertion, because its digest equals the ledger's. The local copy was exact at insertion. Its only authorized transform is save followed by load. So when the copy equals E′, it is exactly what an untampered save and reload would hold.

Tampering that leaves the summary unchanged cannot be detected. But it also changes nothing that is stored or shown. Any change to the summary refuses.

**Observable behavior after reload:** the Read cards show the summaries the existing policy produces, and the import appends nothing (`rowCount: 0`, with no label row).

## File-by-file impact

| File | Change | Depends on |
|---|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Transcript/AgentTranscriptPolicyPipeline.swift` | Add `storageRoundTripItems`. | — |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift` | Split the `CanonicalPayload` fields, add the eligibility predicate and `storedProjections`, add the `comparePayload` parameter and branch. `holdsCanonicalPayload` passes nil. Update the doc comments for "stored projection" and "Step 4d5". | helper |
| `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift` | Convert the hydration test to the success contract and add the matrix below. | both |
| `docs/.../phase4d5.md`, `phase4d5-worker.md`, and the spec status line | Record the contract and the evidence. | after validation |

**Not changed:** `AgentToolResultPersistencePolicy`, `AgentSessionDataService`, `AgentModeViewModel`, the ledger schema, IDs, Oracle redaction, and the gates.

## Validation contract

The reconciliation tests drive the real `flushSave` and a **fresh** view model and data service over the same storage directory. If the harness lacks this, add a test-only `makeProducerHarness(reloadingFrom:)`.

**Success cases:**

1. **Terminal save, fresh load, import.** The import returns `.imported(.unconfirmed, rowCount: 0)`; the items are unchanged; every live `NativeItem` is unchanged. Keep the assertions that `holds(...)` is false (it stays exact).
2. **Second cycle.** Repeat save, fresh load and import. The outcome is the same and nothing is duplicated, which proves the projection is a fixed point.
3. **Running save (`runState = .running`), then a fresh cold-restore load, then import.** The call is still a `.toolCall`, and the import succeeds.
4. **Imported origin.** The O20 rows are imported (not live), then saved, freshly loaded and re-imported with `rowCount: 0`. They never become owned.
5. **Call only.** The result was never delivered; the chain is saved, loaded and imported, and the call row matches its projection. The overall outcome follows the existing preflight, so record it exactly.

**Refusal cases** (each with items, ledger and cursor unchanged):

6. **Altered stored summary.** Edit the persisted result JSON, for example its `summary_text` or status. Expect `.canonicalPayloadMismatch`.
7. **Changed native Read output** after the save. Record the exact outcome: reader-level, or `.canonicalPayloadMismatch` from the digest guard.
8. **Proof cleared before the save** through the refusal path. Expect `.canonicalPayloadUnavailable`.
9. **Pure unit tests on `canonicalPayloadRefusal`:**
   - an ambiguous duplicate ID in the turns gives unavailable;
   - a turn-only stored copy before the suffix-bearing turns matches;
   - a turn-only copy in or after the suffix-bearing turns gives unavailable;
   - a stored copy in a non-full turn gives unavailable;
   - a non-Read Claude tool (for example `Bash`) after reload still gives unavailable;
   - a Read with arguments other than exactly `{file_path}`, or with `is_error` present, gives unavailable;
   - an observation-only row (no ledger entry) held only in stored form gives unavailable;
   - Codex is unchanged.
10. **Existing suites unchanged:**
    - `AgentModeRunServiceLifecycleTests`, `ClaudeLiveTranscriptQualificationTests`, `ClaudeSessionHistoryReaderTests`;
    - the persistence-policy and `OracleToolResultInspection` test classes (find them with grep);
    - product compile, format check and lint.

**Unknowns to settle while implementing:**

- **Does `storageRoundTripItems` match the real seam?** It must match on the compared fields, including the result-summary pairing, the terminal state and cold restore. Tests 1–3 are the differential check.
- **Is the projection a fixed point?** Test 2 checks this.

If either check fails, **stop and escalate. Do not loosen the comparison.** Production still fails closed, so no data is lost.

## Risks

- **Divergence from the real seam** gives false refusals. They are fail-closed and visible, not data loss.
- **Sanitizer changes in a later build** make old summaries refuse, also fail-closed. This is acceptable for an inactive, local, reversible contract.
- **Compaction of older turns** makes them non-full, so they are unavailable. This is the existing retention limit and stays deferred.
- **The proof is lossy by design.** Reviewers must judge it as "authorized projection equality after the digest and ledger proof", never as raw equality.

## Implementation order

1. Add the helper, with a unit test that the O20 pair projects to the summarized fields seen in the B F3 diagnostic.
2. Make the preflight changes and the pure tests (item 9). Land these together with step 1 if the compile requires it.
3. Convert the hydration test and add tests 1–8.
4. Run the full validation list, then update the evidence and status files.
5. Get a fresh OracleA/OracleB review of the new persistence-comparison boundary, with the plan, the diff, this contract and the validation results.

## Recommendations

1. **Choose B, limited to the Read shape and to ledger rows with a valid, equal digest, and only for import.**
   - **No owner decision is needed.** B is local, reversible source logic. It persists nothing new, weakens no privacy rule and keeps the gates OFF.
   - **When to ask the owner:** A would need an explicit owner decision, because it stores private file bodies and paths. It would also still be lossy under the 2,048-byte summary cap unless the cap were bypassed.
   - **C is cut** because it makes the native file a new content authority, which is more than this step needs.
2. **Do not widen to other tools in this step.** A generic route is privacy-safe, since it reuses the same sanitizer and stores nothing. But it is unqualified: the Oracle, `ask_user`, `agent_manage` and ACP branches depend on context. The shape limit costs one predicate.
3. **Keep `holdsCanonicalPayload` exact.** Same-launch hydration in the middle of a chain stays a known, fail-closed deferral.
4. **Scoped for source in Step 4d5:** the helper, the preflight branch, the test matrix (items 1–10), the evidence, and a fresh A/B review of this boundary. Classify findings normally: fix P0/P1, and fix P2/P3 only if cheap.
5. **Still pending for the final live stage:**
   - installed no-replay and profile qualification;
   - activation and gate wiring, including the shared O19/Read gate;
   - how an unresolved call is presented;
   - durability and process-ownership limits;
   - same-launch hydration in the middle of a chain;
   - retention and compaction of older turns;
   - broader tool and error shapes;
   - final live acceptance (O3).
6. **Status line** while this work is under way: `assumed: B stored-projection equality is authorized proof only after the ledger digest; projection mirrors the save/load seam (differentially tested)`.

## Continuation after failed runtime-context validation (verbatim)

# Oracle Plan



# Step 4d5: compare Read rows in storage space instead of the round-trip projection

## Summary

**Recommendation:** keep option B, but change what it compares. Stop comparing the in-memory form of a Read row against one modelled round-trip image. Instead, compare the **persisted image**: what the real persistence sanitizer writes for each local copy of the row, against what it writes for the native row.

- **Compare only fields that come from the native row.** Drop fields that depend on local lifecycle, visibility or the load path.
- **Mandatory guard:** the local copy must carry no tool payload. The sanitizer erases raw content, so without this guard a different file body could look equal.
- **What stays unchanged:** the ledger, digest, identity, ambiguity, completeness and order checks; the strict `holdsCanonicalPayload`; persistence; privacy; the gates. Nothing new is persisted.
- **Cut:** a closed set of images, visibility derivation, and raw retention.
- **Owner decision:** none needed. This is local, reversible source logic.
- **Status:** a plan only. I am not claiming any current test passes.

## Current-state analysis

The disk form is a fixed point (tickets 2a3e75de and 0263627f). The tab's in-memory forms vary in two ways:

- **Visibility.** The answer that follows the result hides it, and `runtimeTranscriptOnly` then drops `summary_text`.
- **Load path.** A running cold restore rebuilds the call from items: `summaryOnly=false` and `summaryText="Using tool: read"`.

Each in-memory form is a presentation that is re-derived from disk, and the next save collapses it back. The re-saved sessions equalled the projection, so the persistence sanitizer maps the hidden form back to the stored one.

The current `compareStoredProjection` checks whole-`toolExecution` and projected-field equality against one runtime image. That bakes visibility and load path into the contract, and that is where all 8 mismatches come from. Its isolated fixture (`storedView` with no answer row) is why the pure matrix passed.

**The `rowCount` 4/2 versus 3/1 is the label row.** `plan` inserts the recovered-label system row at index 0 when anything is appended, and `ImportCommit.rowCount = appended.count`. So the counts are 3 rows + 1 label and 1 row + 1 label. User rows have `item == nil` and are never appended. The test expectation is wrong; the product behavior is correct.

## Design

### Contract: persisted-field equality

For an **eligible** row, the canonical copy is accepted when the persisted image of every local copy that could be saved equals the native persisted image on the compared fields listed below.

- **Eligible** means unchanged from today: the row is in `storageComparableReadItemIDs`, it has a ledger entry, and that entry's digest is non-nil and equals the validation row's digest.
- This branch runs only after `comparePayload` returns `.unavailable`.

**Why this is not loosening:**

- Equality is exact on every persisted field the native row determines.
- The only extra variation it accepts is variation the persistence sanitizer itself erases, which can never reach disk.
- Claude-associated projected item fields are already pinned by the central backstop.
- Raw-content masking is blocked by the payload-free guard below.

**Fields compared after the image is computed:**

| Row | Compared (all must be equal) | Dropped, with reason |
|---|---|---|
| Call | `kind`, `toolInvocationID`, `toolName` (item and execution), item `text`, item and execution args (both nil), result (nil), `toolIsError` (nil), execution `summaryOnly` | Execution `status` and `summaryText`. A native Read call carries no status; it is local run lifecycle, and the running rebuild changes it. |
| Result | `kind`, `toolInvocationID`, `toolName`, item `text` and `toolResultJSON`, `toolIsError` (item and execution), execution `status`, `summaryOnly`, `summaryText`, `resultJSON`, `argsJSON`, `processID`, `exitCode` | — |
| Both | — | `keyPaths` (storage empties them), timestamps, `sequenceIndex`, `isStreaming`, grouped-history caches, the pre-image presentation forms, and any other execution field |

Whole-execution equality is unnecessary rigor. It compares presentation state the native row never determined.

### Decision order inside the storage branch

1. **No native image** (proof cleared, digest differs, no ledger entry, or not eligible): `.unavailable`.
2. **Payload-free guard** on the authoritative copy picked by `canonicalPayloads`, checked before the image:
   - `toolArgsJSON == nil`;
   - for a call, `toolResultJSON == nil`;
   - for a result, `AgentTranscriptToolNormalizer.isSummaryOnly(raw: toolResultJSON)`.

   Otherwise `.mismatch`: a copy that carries any payload is decided only by the exact path.
3. **Stored origin is required.** Index the turn activities of `sanitizeTranscriptForPersistence(canonical.transcript)` by ID, computed lazily once per check.
   - The row's ID must occur exactly once (otherwise `.unavailable`).
   - Its turn must be `.full` and not structurally compacted (otherwise `.unavailable`).
   - Its persisted fields must equal the native image's (otherwise `.mismatch`).

   A summary-form copy can only come from persistence, so a summarized row with no stored turn is not an authorized projection.
4. **Suffix copy.** If the row is in the suffix, build an image from the suffix copies of the same exchange: same invocation ID, `.toolCall` first, then `.toolResult`.
   - The kind counts must match the native exchange (otherwise `.unavailable`).
   - The persisted fields must equal the native image's (otherwise `.mismatch`).
   - This covers whichever copy the save writes: the rebuilt items or the turn.
5. Otherwise `.match`. The existing order check then runs unchanged.

### Images (one helper, one sanitizer)

- **Native:** `persistedImages(of: [call, result?])` builds the canonical transcript (sequenced as today), then calls `AgentToolResultPersistencePolicy.sanitizeTranscriptForPersistence`, and indexes the activities by ID. The exchange is the one `storedReadProjection` already selects.
- **Local suffix:** the same function over the suffix exchange copies.
- **Local turn:** the same sanitizer over `canonical.transcript`.
- **Deliberately omitted:** compaction, truncation and load normalization. These are not part of the persisted contract, and leaving them out keeps both sides on one function.
- **Load-bearing assumption:** the sanitizer alone equals the real save on the compared fields. The disk differential test below checks this.

### Distinguishing the cases

| Case | Outcome |
|---|---|
| Intentional storage projection | Payload-free, has a stored origin, and the persisted fields are equal → match |
| Altered stored summary, status or `is_error` | Fields unequal → `.mismatch` |
| Different raw local output | Guard or exact path → `.mismatch` |
| Missing or duplicated backing, or compacted turn | `.unavailable` |
| Call only | Native exchange is `[call]` → call rules only |
| Proof invalidated | No image → `.unavailable` |
| Turn-only copy before the suffix-bearing turns | Allowed through step 3 |
| Turn-only copy in or after the suffix-bearing turns | `.unavailable` (existing ambiguity rule) |

### Cut, with reasons

- **Closed set of images:** it catalogs the load paths and grows with each one.
- **Visibility derivation:** it still fails the running rebuild unless load context is added as a new authority.
- **Raw retention (option A):** it changes private body retention and needs the owner.
- **Option C:** larger than needed.

## File-by-file impact

1. **`AgentTranscriptPolicyPipeline.swift`**
   - Replace `storageRoundTripActivities` (~21 lines) with `persistedImages(of items:) -> [UUID: AgentTranscriptActivity]`: build, sanitize for persistence, index.
   - Update the doc comment: storage space, import comparison only.
2. **`AgentProviderHistoryImport.swift`** (~141 lines in the current region)
   - Delete `StorageBackings`, `storageBackings(_:)` and the body of `compareStoredProjection`.
   - Rename `Compared.stored` to `nativeImage`.
   - `storedReadProjection` now calls `persistedImages`.
   - Add a private `persistedFields(_ activity:, kind:)` that returns a small `Equatable` struct holding the field list per kind.
   - Add a lazy sanitized-turn index with ambiguity and completeness flags, and the new `compareStoredImage` implementing steps 1–5.
   - **Unchanged:** `comparePayload`, `holdsCanonicalPayload`, the reader's `storageComparableReadItemIDs`, observation plumbing, ledger handling, order checks.
   - **Doc comment:** "persisted-field equality after the ledger digest proof; never a raw proof".
3. **`AgentRecoveryReconciliationTests.swift`** — see the test section below.
4. **`phase4d5-worker.md` and `phase4d5.md`**
   - Record the contract, the field table and the label-row explanation.
   - Mark the round-trip `storageRoundTripActivities` remedy as superseded.

## Tests

### Pure matrix (`canonicalPayloadRefusal`)

- **Fixture fix:** rebuild the real contexts, not isolation.
  - Terminal: `storedView([call, result, answer])`, so the answer naturally hides the result.
  - Running rebuild: `rebuiltTranscriptPreservingCompactedPrefix` over the stored transcript's working items, with terminal state `.running`.
  - Call only.
- **Accept:** suffix plus backing, prefix only, call only, and a raw exact copy (unchanged path).
- **Refuse with `.mismatch`:**
  - an altered result `status`;
  - `is_error` set to true;
  - an altered `summaryText` together with the JSON `summary_text`, on the turn and on the suffix;
  - a call turned into a result;
  - a changed invocation ID;
  - a Bash name on a stored copy;
  - a different raw output with arguments nil.
- **Refuse with `.unavailable`:**
  - no backing, a duplicated backing, a condensed turn;
  - a cleared proof, a changed digest, no ledger entry;
  - the unsupported shapes (existing list).
- **Keep:** strict `holds` stays false.

### Round trip (keep both, fix the expectations)

- **Imported test, first import.** Assert `rowCount: callOnly ? 2 : 4`. Also assert the exact appended composition so the expectation is tighter, not weaker:
  - the first appended row is `.system` with `recoveredLabel` and the deterministic label ID;
  - the rest are exactly the ledger local IDs of c1, r1 and a1 (or c1 alone), in order.
- **Before writing it, confirm the label rule** by grepping an existing passing non-zero `rowCount` import assertion. If the label is not counted there, stop and report.
- **New disk differential check.** In every cycle, for each tool row, the persisted fields of the freshly stored activity (`freshlyStored`) must equal those of the native image.

### Real refusals (fresh load, then import; items, ledger and cursor unchanged)

- Edit the stored file's result `status`, and separately its `summaryText` together with `summary_text`: `.canonicalPayloadMismatch`.
- Clear the proof before the save: `.canonicalPayloadUnavailable`.
- Change the native Read output after the save: record the exact outcome.

### Unchanged suites

Lifecycle, qualification, reader, persistence-policy and Oracle-inspection suites; build, format check and lint.

## Risks

- **The sanitizer alone diverges from the real save**, or the running rebuild changes result status. The result is a false refusal, which is fail-closed. **Stop gate:** report the field; never exclude it ad hoc.
- **An altered disk summary is accepted** because the sanitizer regenerates it. **Stop gate:** report it; do not ship.
- **In-memory-only presentation edits the sanitizer erases are accepted.** This is intended; they never persist, and the backstop pins the item fields.

## Implementation order

1. Helper replacement plus the preflight rewrite, landed together so it compiles.
2. Pure matrix on the real-context fixtures.
3. Round-trip expectation and differential fixes, plus the real refusal tests.
4. Full validation list, then the evidence docs.
5. Fresh OracleA/OracleB review of this boundary.

## Recommendations

1. **Adopt persisted-field equality.** The contract is: the real persistence sanitizer maps every local copy that could be saved to the native row's persisted fields. It keeps the existing ledger, digest, identity, ambiguity, completeness and order checks, plus two new guards: no tool payload in the copy, and a stored-turn origin. This is the smallest contract that holds for terminal saves, re-saves and running cold restores, because each in-memory form collapses to the disk fixed point.
2. **Cut** the round-trip helper, the whole-execution comparison, the closed image set and visibility derivation. Do not pursue raw retention: it would need an owner decision on private body retention, and B makes it unnecessary.
3. **Compare** only fields the native row determines: identity, name, text, payload absence, and the result's summary, status, error and process fields. **Drop** a call's status and `summaryText`, `keyPaths`, timing, and the pre-image presentation forms.
4. **The `rowCount` failures are the label row.** Fix the expectation to 4 and 2 and assert the exact appended composition. This is a tighter assertion, not a weaker one.
5. **Hard stop gates for the worker:**
   - native image ≠ disk on the compared fields;
   - any real context's image ≠ native image;
   - an altered disk summary is accepted.

   On any of these, report. Do not loosen the comparison.
6. **No owner decision needed.** Record `assumed: B persisted-field equality after ledger digest; sanitizer-only image matches save (disk-differential tested)`.
7. **Scoped for source:** the helper, the preflight branch, the tests above, the evidence docs, and the fresh A/B review.
8. **Pending for the live stage:**
   - activation and gates;
   - installed no-replay;
   - how an unresolved call is presented;
   - same-launch hydration in the middle of a chain (strict `holds`);
   - retention of compacted turns;
   - other tools and error shapes;
   - O3 acceptance.
