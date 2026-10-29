# Step4d1 initial review — OracleA

Scope: read when the task touches the Claude outbound identity source or its bounded review.
Authority: Reference
Last-verified: 2026-10-23

Snapshot `2026-10-23/1838`; preset `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`; chat `step4d1-outbound-identit-47ACC3`; operation `9BBDC22A-F576-4E0D-917A-4906DEE1EC4A`. Full response follows.

# Oracle Review

## Summary

This change adds an explicit, persisted outbound UUID/text-digest claim to newly captured Claude dispatch baselines and carries the UUID through the existing single write admission into the streamed user frame. Eligibility, constituent validation, retry omission, cancellation, and transport ownership checks remain bounded to this inactive slice; it does not establish delivery or native persistence. No P0/P1 issue is established by the supplied snapshot.

## P2 — Consider

### R1 — Nested claim fields do not preserve unknown members

- **Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift:293–295` decodes `outboundUserMessage` into a synthesized `Codable` type containing only `uuid` and `textSHA256`.
- **Scenario / impact:** A baseline containing an additional field inside `outboundUserMessage` loads successfully, but an ordinary save silently removes that field. The enclosing baseline’s `extras` cannot preserve nested members. This falls short of the history envelope’s stated unknown-member round-trip contract.
- **Smallest fix:** Give `OutboundUserMessage` an `extras` dictionary and dynamic-key encoding/decoding, following the existing baseline pattern. Extend the round-trip test with an unknown field **inside** the claim; its current `futureMember` assertion covers only the enclosing baseline.

## Recommendations

Approve this bounded, production-disabled slice with R1 addressed cheaply or explicitly deferred. Preserve the activation gates and keep native reconciliation and live acceptance pending. The supplied validation results support this review, but were not independently executed here.
