# Phase 1b inactive recovery review — OracleA

Scope: read when the task touches lossless restart recovery transaction and lifecycle-gate review evidence.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: `61D024A4-CCFB-4C9C-A614-CC65E0A1864C` (OracleA). Initial independent inspection; test results supplied, not independently run.

The package adds inactive, atomic recovery transactions, opaque revisions, delivery/run evidence, conservative attachment retention, and composer persistence behind the real DataService lifecycle gate. The new gate and tombstone-first cleanup appear correctly ordered within the stated single-writer contract; deferred production hooks are not findings. However, held-draft preservation, restoration races, and unknown-field retention need correction. This is a source review; the reported 28 passing tests and lint were not independently rerun.

## P0 — Must fix

### REC-01 — New-generation input silently deletes the held pre-reset draft

**Source:** `AgentRecoveryStore.swift:329–369` (`commitComposer`); `AgentRecoveryComposerPersistenceController.swift:184–199, 227–230`.

**Scenario:** Persist draft A under generation 0, reset, then restore under generation 1. Restoration correctly returns `.heldForOtherGeneration(A)`, but typing B and flushing replaces A’s only durable slot. Alternatively, submitting B without flushing can consume A: `consumption(for:)` treats the restored durable revision as superseded even though A was never adopted into B.

**Impact:** Previously saved input disappears without explicit resolution. Keeping its image files does not preserve its text, workflow, or attachment associations. The openly reported single-slot limitation is therefore **not sufficient** for the held-input contract.

**Smallest fix:** Refuse ordinary replacement/removal of a composer from another generation until explicitly resolved, and exclude it from automatic submission consumption. A typed conflict that retains pending new input is sufficient for this inactive step; a larger held-draft model is not required immediately.

**Regression test:** Cover reset → held restore → both flush and submission → fresh-store reload, proving A remains recoverable.

## P1 — Should fix

### REC-02 — Typing during restoration leaves the controller permanently behind the composer CAS

**Source:** `AgentRecoveryComposerPersistenceController.swift:207–231`, particularly the early `.superseded` return at line 214.

**Scenario:** A durable composer R0 exists. A fresh controller starts loading it, and the user types R1 while the read is suspended. The load returns `.superseded` before recording R0 as `durableComposerRevision`. Subsequent flushes expect `nil`, but the store contains R0, producing `composerRevisionConflict`. Further edits retain the same incorrect expectation.

**Impact:** Ordinary typing during hydration disables draft persistence for that controller. The existing race test encounters an absent composer, so it does not exercise this failure.

**Smallest fix:** Separate adopting live content from learning the durable CAS baseline. Process the validated read and baseline update inside the serialized operation, even when newer typing prevents live restoration; do not overwrite newer pending content or a later operation’s baseline.

**Regression test:** Seed a nonempty durable composer, pause restoration, type, release, then verify that flush succeeds and reload restores the new text.

### REC-03 — Ordinary composer edits discard supported unknown members

**Source:** `AgentRecoveryComposerPersistenceController.swift:106–115`; `AgentRecoveryStore.swift:350–369`.

**Scenario:** A supported record contains an additive field in `composer.extras`. Restoration decodes it successfully. On the next text edit, `composerDidChange` constructs a new snapshot with default empty extras, and `commitComposer` replaces the old snapshot wholesale. The unknown field disappears even if the caller preserved every field in `snapshot.content`.

**Impact:** The advertised forward-compatible rewrite contract fails on the normal composer-edit path. The existing extras test covers an unrelated intent withdrawal, which merely carries the composer through unchanged.

**Smallest fix:** Preserve existing composer extras when replacing the same-generation logical composer. Preserve nested extras for retained content entities by stable identity as well, while keeping known fields authoritative and respecting explicit removal. Centralizing this merge in the store avoids relying on every producer to reconstruct unknown data.

**Regression test:** Inject unknown composer/content/reference members, restore, edit only text, flush, and verify that all retained entities keep their unknown members.

## Recommendations

- **Request changes** for REC-01 through REC-03 before accepting this package.
- Use fail-closed preservation for the old-generation slot rather than expanding scope into recovery UI.
- Add the targeted tests above and rerun the recovery suite and lint.
- Keep production activation, schedule transfer, shutdown integration, and comprehensive attachment ownership deferred as planned.
