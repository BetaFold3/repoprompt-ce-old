# Step 4d4 initial OracleA review

Scope: read when the task touches the exact native mode reader review.
Authority: Reference
Last-verified: 2026-10-24

Snapshot: staged 2026-10-24/0904. Main verified the returned preset identity. Response follows verbatim, with a terminal newline.

# Oracle Review

The change narrowly accepts the capture-observed `{type:"mode", mode:"normal", sessionId:expected}` record as nonprojected metadata and adds four sanitized Read/resume tests. It leaves tool association, identity derivation, envelope digests, prefix fences, ledger handling, and activation unchanged.

## Findings

No actionable findings in the supplied staged diff.

- `parseModeRecord` enforces the exact key/value contract. Graph identity keys—including null values—refuse; extra keys, invalid sessions, and invalid modes use existing typed refusals.
- `mode` remains outside `operationalTypes`, avoiding broader acceptance.
- Accepted records still participate in raw-byte prefix proofs but produce no graph node, row, or caller anchor.
- Fixtures cover tool/result identities and pairing, resumed cursor imports, replay deduplication, strict mode rejection, and invalid tool associations. Their claims remain bounded to synthetic reader tests, not live app qualification.

Review was static against the supplied diff, full files, and capture evidence. Reported test/build/style results were not independently rerun.

## Recommendations

Approve this snapshot for the bounded reader-only step. Keep activation off and broader recovery acceptance pending; no additional capture or scope expansion is warranted by this review.
