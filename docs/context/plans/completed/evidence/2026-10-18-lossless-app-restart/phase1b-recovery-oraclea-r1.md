# Recovery transactions — OracleA re-review 1

Scope: read when the task touches lossless restart recovery transaction and lifecycle-gate review evidence.
Authority: Reference
Last-verified: 2026-10-21

Verified preset: OracleA. Source review; no live validation.

The delta addresses held-draft preservation (REC-01) and unknown-member retention during ordinary edits (REC-03), and fixes REC-02’s restore-then-flush case by learning the baseline inside serialization. Managed-image reuse and foreign-session ownership checks also look appropriate. One related restoration/submission race remains. This is a source-only review; the reported 34 passing tests and lint were not independently rerun.

## P1 — Should fix

### REC-02a — Submitting during restoration captures consumption before learning the durable baseline

**Evidence:** `AgentRecoveryComposerPersistenceController.swift:151–155, 190–201` (`submitQueued`, `consumption(for:)`); the same ordering exists in `submitDirect`.

**Failure scenario:**
1. Durable composer R0 exists. A fresh controller starts restoration and pauses inside the gate.
2. The user types R1 and submits before restoration finishes.
3. Submission computes its consumption set immediately, while `durableComposerRevision` is still `nil`; the set contains R1 but not R0.
4. Restoration completes and learns R0 inside the serialized operation.
5. The queued submission then commits using its already-captured consumption set. The store preserves R0, while `performSubmission` clears pending R1.

**Impact:** After a successful send, relaunch restores the obsolete R0 draft. The new baseline fix makes a subsequent **flush** work, but a submission queued behind that same restore still fails to consume the superseded composer.

**Smallest fix:** Preserve the call-time revision cutoff that protects newer typing, but incorporate the baseline learned by a preceding restore when constructing the effective consumption set inside serialization. Only include a baseline established to predate the submitted edit—not an arbitrary newer durable revision.

**Regression test:** Seed R0, pause restoration, type and enqueue submission of R1 **before releasing the restore**, then complete both operations. Verify through a fresh store that the intent contains R1 and R0 is no longer stored as the composer. Cover queued and direct submission.

## Recommendations

- **Request changes** for REC-02a; REC-01 and REC-03 are addressed.
- Add the restore/submission ordering test and rerun affected validation.
- Keep explicit held-input resolution and production integration deferred as planned.
