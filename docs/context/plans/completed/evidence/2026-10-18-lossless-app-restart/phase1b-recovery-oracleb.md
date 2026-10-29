# Phase 1b inactive recovery review — OracleB

Scope: read when the task touches lossless restart recovery transaction and lifecycle-gate review evidence.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` (OracleB). Initial independent inspection; test results supplied, not independently run.

# Phase 1b inactive recovery transactions and Core lifecycle gate: initial review

## Summary

This package adds the recovery record schema and codec. The codec keeps unknown fields, rejects records that don't re-encode exactly, and preserves future or corrupt records byte-for-byte. It also adds the `AgentRecoveryStore` actor, the composer persistence controller (300 ms debounce, 2 s absolute maximum), and the DataService pieces: the recovery gate/transaction, authoritative discovery, and cleanup after the tombstone.

The store's delivery state machine is internally consistent:
- Every transition the store can write passes the codec's invariant check, including late acceptance with a newer attempt open, failed → accepted, and withdrawn → accepted.
- Receipts are reissued only after revalidation.
- `staleTarget` blocks both live-queue and explicit dispatch; `previousInstance` is derived and only an explicit action can claim it.
- Run evidence is keyed by the existing `AgentRunOwnership.attemptID`.

The DataService gate checks the stamp, tombstone, file, incarnation and generation under the session gate before the body runs, and holds the gate across the body. Discovery rereads each record under its gate and never reports a tombstoned, legacy, other-workspace or unreadable session as `eligible`.

There is one real gap: a draft saved before a reset is not protected. That draft is also exactly the known limitation you asked about. The remaining findings are smaller.

## Answer on the known limitation (old-generation composer slot)

**Not sufficient.** It is wider than reported. The store does more than let the next current-generation composer write replace the held draft. The controller also treats the held draft's revision as an older draft the user moved past. So an unrelated **submission** under the new generation deletes the held draft too, in the same replacement. The store must not let either path remove an older-generation composer unless the user explicitly resolves it. See F-1.

---

## P1

### F-1: A held older-generation composer is silently destroyed by the next composer write or by any submission

**Sources:**
- `AgentRecoveryComposerPersistenceController.swift`:
  - `loadRestorableComposer`, `.supported` branch (~L212–217): `durableComposerRevision = record.composer?.revision` runs **before** the generation check that returns `.heldForOtherGeneration`.
  - `consumption(for:)` (~L176–185): any durable revision this controller did not issue is added to `supersededRevisions`.
- `AgentRecoveryStore.swift`:
  - `commitComposer`: the composer CAS (compare-and-swap) checks only the revision. It never compares `current.composer.transcriptResetGeneration` with the binding's generation.
  - `insertIntent`: `consumption.consumableRevisions.contains(stored.revision)` also ignores the stored composer's generation.

**Scenario A (write):**
1. The user types draft D at generation 0, and it becomes durable.
2. A reset commits (gen 1), then the app quits or crashes before any gen-1 composer write.
3. On relaunch, the gen-1 controller restores and gets `.heldForOtherGeneration(D)`, while `durableComposerRevision = D.revision`.
4. The user types one character in the new composer. `commitComposer(expectedComposerRevision: D.revision, snapshot: gen1)` passes the CAS and replaces D.

**Scenario B (submit, worse):**
- Same setup, but the user sends a new message instead of typing.
- `consumption(for:)` includes D's revision as "superseded", so `insertIntent` removes D in the same replacement.
- D was never adopted or edited. Removing the stored composer here is guaranteed every time this path runs.

**Impact:** Durable typed input is lost without any explicit user action. That breaks the spec's first promise ("nothing the user typed … is lost") and the reset rule that pre-reset input is held and never retargeted. It is also the store-level API that the producer cutover will build on, so it should be fixed now.

**Smallest fix (three small parts):**
1. **Store, `insertIntent`:** consume only if `stored.transcriptResetGeneration == binding.transcriptResetGeneration`. This is one condition.
2. **Controller:** on `.heldForOtherGeneration`, keep the held revision in a separate `heldComposerRevision`. Do not assign it to `durableComposerRevision`, so `consumption(for:)` can't see it.
3. **Store, `commitComposer`:** when the stored composer's generation is lower than the binding's, don't replace it implicitly. Two options:
   - **(a) Preferred:** move it to a `heldComposers: [AgentRecoveryComposerSnapshot]` member that is preserved on rewrite. Add an explicit `discardHeldComposer(revision:)` and a `carryForward` flag. The live reset-rebind path uses `carryForward`, so it doesn't create a spurious held copy of text that is still in the live composer. Schema v1 has never been written in production, so adding a member now costs nothing.
   - **(b) Minimal:** reject with a new `heldComposerUnresolved` error unless the caller passes an explicit discard or carry-forward. The cost is that new-generation drafts can't be saved until the held draft is resolved.

   I recommend (a).

**Tests to add:** held-then-type, and held-then-submit. In both, the held draft must survive.

---

## P2

### F-2: A `.superseded` restore leaves the controller blind to the stored composer, so every composer write fails until the first send

**Source:** `loadRestorableComposer` returns `.superseded` before updating `durableComposerRevision`. `withConflictRetry` retries only record `revisionConflict`; `composerRevisionConflict` is terminal.

**Scenario:**
1. A controller is built with the default `durableComposerRevision: nil` while the store holds draft rX.
2. The user types during the restore read, which can wait behind the session gate during hydration. The restore returns `.superseded`.
3. Every debounce or flush write fails with `composerRevisionConflict(expected: nil, actual: rX)`. `lastWriteFailure` stays set.
4. New typing is never saved until a submission happens to adopt `receipt.composerRevision`.

A crash in that window loses more than the 2 s bound allows.

**Smallest fix:** in the `.superseded` path, still apply the incarnation and generation checks, and set `durableComposerRevision` from the record that was read. The newer typing is meant to replace rX. With F-1 applied, a held draft still won't be adopted. The alternative is to require that `durableComposerRevision` be passed at construction, but that pushes the burden onto the producer.

### F-3: `importManagedImage(sessionID:attachment:)` copies the file again even when it is already in this session's managed storage

**Source:** `AgentRecoveryStore.importManagedImage(sessionID:attachment:)`, `.localFile` branch. It always calls `AgentAttachmentStore.importImageFile` and gets a new UUID filename each time.

**Scenario:**
- A restored composer's attachment resolves (via `attachment(for:)`) to a path inside `attachments/<sessionID>/`.
- The producer then builds the content for each `composerDidChange` through this API, so every keystroke snapshot copies the image again.
- Rewrites never delete files and garbage collection is deferred, so disk use grows without bound.

**Smallest fix:** if the standardized source path's parent is `managedAttachmentDirectoryURL(sessionID:)` and the name passes `isSafeManagedFileName`, return `.managedFile(fileName:)` with no copy.

### F-4: Test coverage misses the failure paths above

The existing 28 tests cover generation fencing only through `heldForOtherGeneration` plus a stale-gate rejection. None of them does a new-generation write or submission after a held restore, a write after `.superseded`, or a re-import of an already-managed attachment. Add one test for each with F-1 to F-3.

---

## P3

### F-5: `issuedRevisions` grows by one per keystroke until the next submission

**Source:** `composerDidChange` appends to it. It is trimmed only in `performSubmission`, and `consumption(for:)` does a linear `firstIndex` over it.

**Fix:** after a successful `writePending`, drop the entries before the committed revision. That revision stays in the array, so `consumption(for:)` behaves the same.

### F-6: Run evidence doesn't check that the ownership belongs to the binding's session

**Source:** `ensureRunAttempt` and `recordRunTerminal` never compare `ownership.binding.persistentSessionID` with `binding.sessionID`.

**Fix:** a one-line guard returning `runAttemptConflict` when they differ.

### F-7: A failed composer write is never retried while the user is idle

This is documented and deliberate ("must not spin"). Still, one transient failure with no further typing leaves the draft only in memory.

**Fix:** if wanted, arm a single backoff retry (for example 2 s) per failed snapshot.

### F-8: The store doesn't require the gate for imports and direct calls

**Source:** `importManagedImage` runs outside the gate by design. A direct store call made with a stale binding after deletion finds `writableRecord == nil` and can create a fresh record.

**Impact:** discovery still reports such records as `.tombstoned`, so they are never actionable. The leftover is orphan storage until the session is deleted again.

**Fix:** document at the API that the body is not reentrant. A body that calls a gated DataService method for the same session deadlocks. Optionally, have `removeDataForDeletedSession` callers and imports check the tombstone.

---

## Acceptance checklist

| Criterion | Status |
|---|---|
| Exact plan path and delivery states | ✓ |
| Immutable input, stable intent and user-item IDs | ✓ |
| Opaque CAS | ✓ (the record CAS is effectively always satisfied inside the gate; the composer CAS carries the protection) |
| Atomic composer → intent removal that preserves newer typing | ✓ within one generation; ✗ across generations (F-1) |
| Explicit `staleTarget`, derived `previousInstance`, no implicit retarget | ✓ |
| Evidence-qualified fallback, acceptance precedence, late evidence | ✓ |
| Strong queue and dispatch receipts | ✓ |
| Terminal and shutdown evidence keyed by the existing run attempt | ✓ (F-6 minor) |
| Supported unknown fields kept; future or corrupt records preserved and never written | ✓ |
| Conservative attachment references | ✓ (F-3 duplication) |
| Real DataService gate serializes reset and delete against commits | ✓ |
| Discovery never exposes tombstoned or unknown sessions as actionable | ✓ |
| Composer 300 ms / 2 s absolute bounds and error fences | ✓ |
| Composer restore fences | ✗ F-1, F-2 |

## Recommendations

1. **Fix F-1 before this step is committed.** Apply the generation condition in `insertIntent`, keep the held revision separate in the controller, and make `commitComposer` preserve an older-generation composer (I recommend the `heldComposers` member plus explicit discard and carry-forward). Add the two held-draft tests.
2. Apply F-2 and F-3 in the same delta. Each is a few lines and comes with a test (F-4).
3. Defer F-5 to F-8, or do them in the same pass if trivial (F-5 and F-6 are one-liners).
4. Re-run the recovery filter (Store, Controller, Integration) and `make dev-lint`. Then re-review only the composer/consumption delta.
5. The things you listed as deferred (sends, queues, schedule transfer, startup barrier, terminal producers, UI and quit, live and schedule attachment ownership, GC) are consistent with the inactive scope. I am not raising any of them as findings.
