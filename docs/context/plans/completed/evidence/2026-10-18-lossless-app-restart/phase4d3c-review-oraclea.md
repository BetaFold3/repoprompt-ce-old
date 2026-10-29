# Step 4d3c initial OracleA review

Scope: read when the task touches scoped Claude live-proof invalidation review findings.
Authority: Reference
Last-verified: 2026-10-24

Snapshot: staged 2026-10-24/0831. Preset identity verified by main. Verbatim response follows, with a terminal newline.

# Oracle Review

## Summary

The change narrows Claude proof invalidation from the entire tab ledger to the exact keys newly inserted by the refused producer. Ownership is recorded alongside canonical row insertion, consumed on refusal, and cleared on persisted-history replacement or chat reset. Imported matches, duplicates, and result agreements acquire no ownership. The supplied changes preserve the existing delivery guards, persistence mechanism, and default-off activation boundary.

## Findings

**No actionable correctness or regression findings in the supplied diff and context.**

- Row insertion, ledger insertion, and ownership recording occur together without suspension.
- Refusal latches the producer and invalidates only its owned Claude keys, including preserved raw proofs. An empty ownership set causes no persistent mutation or save request.
- Merging imports retain ownership; hydration replaces it with the ledger; clear chat discards it. The refused-producer latch remains intact.
- Actual invalidation still marks the session dirty and schedules the existing serialized save. Reader conflict checks continue to reject proofless known entries.
- Tests cover selective invalidation, imported-proof preservation, repeated refusals, conflicting output, reconciliation, and save ordering.

Validation results are **reported evidence supplied with the request**, not independently executed in this text-only review. Hydration reset was reviewed from source; its new ownership behavior lacks a direct fixture.

## Recommendations

- **Accept this source-only step**, with no blocking findings.
- Consider adding a focused hydration regression test verifying that ledger replacement clears ownership, retains refused producers, and prevents a delayed old-producer refusal from invalidating replacement proofs.
- Keep activation and Resume/restart gates off pending the separately required live acceptance. This review does not establish installed-profile qualification.
