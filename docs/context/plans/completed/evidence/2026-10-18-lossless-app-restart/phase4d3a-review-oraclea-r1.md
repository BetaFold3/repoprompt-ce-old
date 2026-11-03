# Step 4d3a re-review 1: OracleA (verbatim)

Scope: read when the task touches the Step 4d3a OracleA re-review 1 of the option (a) order repair and the turn-copy tool-name comparison.
Authority: Reference
Last-verified: 2026-10-23

Raw OracleA response to main's Step 4d3a re-review 1 (repair delta 2241), saved verbatim below the rule from `prompt-exports/oracle-review-2026-10-23-224359-step4d3a-re-review1-e3f7.md`. Main verified the preset identity. The initial review is [phase4d3a-review-oraclea.md](phase4d3a-review-oraclea.md); the repairs and completion are in [phase4d3a-worker.md](phase4d3a-worker.md#initial-review-repairs).

---

# Oracle Review

The delta fixes replay rejection by checking provider-output order and user-anchor order independently, preserving the existing append-only import contract. It also accepts the existing tool-name normalization for persisted turn copies while retaining exact suffix comparisons. Payload, availability, ambiguity, identity, and association checks remain intact.

## Disposition

**R1 — Closed.** I accept the revised fix rather than my earlier blocking suggestion: rejecting valid steered imports would unnecessarily restrict the existing workflow. The expanded real-view-model regression covers initial import, unchanged replay, lost-cursor replay, and subsequent append-only growth; negative tests retain output and constituent-order rejection.

**No new findings in the scoped delta.** The tool-name adjustment is consistent with the supplied transcript-builder implementation and includes positive and negative coverage.

Review was static, using the supplied diff and context. Validation results are reported by main, not independently rerun. This acceptance does not establish live-provider qualification; production gates remain off.