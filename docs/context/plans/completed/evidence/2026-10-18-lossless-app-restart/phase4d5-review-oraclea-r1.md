# Step 4d5 — OracleA R1 persistence-boundary review

Scope: read when the task touches Step 4d5 stored-projection verification and cold-restore preservation review.
Authority: Reference
Last-verified: 2026-10-24

Fresh independent review on frozen delta2026-10-24/1147 (+1004/−60), full source2026-10-24/1147-2 (17 files +2903/−159). Both lanes received identical explicit source slices, full delta, contract, validation and verbatim policy; no other lane's findings. Exact explicit preset identity verified and full reply read. New consequential persistence verification boundary, not a P2-only review round. No P0/P1.

## Verbatim response

# Oracle Review

The delta adds an import-only comparison for summarized singleton Claude Read exchanges, deriving up to four permitted representations from the existing save/load pipeline. It also preserves associated tool payloads during cold restore, fixes Read-answer duplicate detection across persisted turns, and preserves arguments on unidentified result rows. The new tests exercise actual hydration and repeated saves without changing storage policy or activating production evidence.

## Findings

No substantiated P0, P1, or P2 findings in the supplied delta.

### Boundary assessment

The bounded four-form contract is sound within the stated scope:

- **Authority remains the existing proof:** fallback requires reader qualification, a unique applicable ledger key/local-item mapping, and a matching envelope digest.
- **Comparison remains restrictive:** only strict `.unavailable` results reach fallback; strict mismatches are not rescued. The backing must be unique, full, and structurally intact.
- **Whole representations are checked:** backing execution and projected fields must match a generated image; suffix fields independently match a whole image. The actual candidate is never sanitized into acceptance.
- **Live qualification stays exact:** stored-form acceptance does not extend `holdsCanonicalPayload`, acquire ownership, or introduce duplicate accounting.
- **Cold-restore protection is narrowly placed:** it bypasses synthetic tool cancellation after streaming ends, while retaining turn interruption, terminal-state handling, span closure, and cancellation of ordinary tools.
- **Persistence authority is unchanged:** no new retained raw payload, schema, receipt, cursor, or commit mechanism appears in this delta.

The four forms are a bounded acceptance set—not evidence that every future pipeline transformation or wider tool shape will remain compatible. Refusing representations outside that set is consistent with the contract.

## Recommendations

- Accept this delta for the **default-off scope**, without treating it as production qualification.
- Keep no-replay/profile capture, live acceptance, and unresolved-call presentation explicitly pending; do not widen accepted forms to bypass those checks.
- Preserve the real round-trip and tampering tests when storage or normalization policies change.

This assessment is static, based on the supplied diff and excerpts. The reported validation results were not independently executed or inspected.
