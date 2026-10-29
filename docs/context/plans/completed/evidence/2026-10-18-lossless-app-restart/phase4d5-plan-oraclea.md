# Step 4d5 — OracleA planning

Scope: read when the task touches Step 4d5 bounded Claude Read live-envelope planning.
Authority: Reference
Last-verified: 2026-10-24

Fresh independent planning from HEAD 7c4d3c33. Requested and returned preset identity verified as OracleA; main read the full reply. Same selected source, sanitized O20 evidence, question and verbatim review policy sent to both lanes together. This is planning, not source approval or live qualification.

## Verbatim response

# Oracle Plan



## 1. Summary

**Proceed with an inactive, single-Read source path, conditional on inspecting the remaining shape details in the already-approved O20 captures.** O20 establishes the necessary identity joins and ordered tool exchange; it does **not** qualify the app’s no-replay invocation profile. Extend the existing classifier, reader projection, and canonical owner rather than changing the package translator or introducing persisted authority. Keep activation OFF, preserve the single-text path, and treat mutation protection and accounting parity as part of this step—not follow-up polish.

## 2. Current-state analysis

The supplied code has three relevant boundaries:

1. **Native controller:** `sendUserMessage` records outbound identity after a successful write, without suspension between write and tracking. `handleStreamPayload` translates and then classifies the same serialized payload before suppression. Producer qualification is launch-local and sticky across consumer resets.
2. **Identity projection:** `ClaudeSessionHistoryReader.project` derives deterministic row IDs, invocation IDs, and semantic envelope digests. Calls and results are **distinct rows**; tool-result users are not prompt anchors. Native graph validation remains independent of live classification.
3. **Canonical owner:** `applyStreamResult` handles evidence before generic mutation. Accepted text inserts its row, ledger entry, and producer-owned key together on the main actor. Refusal invalidates only that producer’s newly inserted proofs.

Two blockers prevent simply accepting tool envelopes:

- `ClaudeSDKNDJSONTranslator.resolveInvocationID` generates random pairing IDs, while history derives deterministic IDs.
- The generic owner’s `tool_result` branch replaces a call row with a result, contradicting the reader’s two-row projection. Its name fallback could also mutate a previously identified call after qualification fails.

Reuse the existing carrier, ledger, scoped invalidation, save scheduling, and reader algorithms. This is a **targeted extension**, not a translator or transcript architecture refactor.

## 3. Design

### A. Evidence boundary and acceptance scope

Before implementation, inspect only the already-approved capture records to establish:

- Complete key sets and value types for tool-call assistant, tool-result user, and final assistant envelopes and nested messages.
- Presence/type of `wire_tool_inputs`, `tool_result_meta`, `tool_use_result`, timestamps, message IDs, replay flags, and attribution fields on each record.
- Nested metadata discriminators needed to recognize those containers without interpreting their private contents.

Record sanitized shapes only. Do not retain paths, file contents, request payloads, credentials, or real identifiers. The selected summary does not provide enough detail to invent these allowlists.

If those bytes cannot be inspected under existing access authorization, **postpone the affected classifier branches rather than guessing permissive shapes**.

Accepted behavior is limited to:

- One identified outbound string prompt.
- Exactly one main-thread, single-block `Read` call, with input containing only a nonempty string `file_path`.
- Exactly one matching, string-content tool result, with `is_error` absent.
- Exactly one nonempty single-text final assistant.
- An agreeing success result.
- Existing recognized lifecycle/init/rate-limit records interspersed.

No additional tools, thinking, multiblock, parallelism, denials, sidechains, compaction, or abnormal-exit recovery.

### B. Reader-derived row evidence

In `ClaudeSessionHistoryReader.swift`, add synchronous, package-scoped projection helpers:

- `singleReadToolCallRow(session, entry, toolUseID, filePath) -> Row?`
- `singleReadToolResultRow(session, entry, toolUseID, text) -> Row?`

Both construct the existing semantic `Entry`/`Block` representation and delegate to `project`/`envelopeDigest`. Supply the known `Read` association when projecting a result. Do not duplicate hashing, JSON serialization, or UUID derivation.

In `ClaudeLiveTranscriptQualification.swift`:

- Preserve `.completeText` and existing single-text behavior.
- Add `.completeReadRow(...)`, containing immutable session identity, projected row, and the already-qualified prerequisite rows needed for owner validation.
- Add `.readResultAgreement(...)`, containing the ordered call, result, and final-text projections.
- Extend complete-text evidence with a default-empty prerequisite list; existing single-text callers remain valid.

Evidence remains transient, package-internal, and nonserialized. Validate every carried projection by recomputing through the reader helpers. Use existing `item(for:)` and ledger construction conventions.

### C. Producer state machine

Extend the existing private `Turn` state:

| State | Accepted semantic transition |
|---|---|
| `idle` | Identified outbound → `dispatched` |
| `dispatched` | Existing single-text path, **or** attributed Read assistant → `readCalled` |
| `readCalled` | Matching tool-result user → `readReturned` |
| `readReturned` | Final text assistant → `readAnswered` |
| `readAnswered` | Attributed, agreeing success → `idle` |

Read states retain outbound UUID, native session, projected rows, tool-use ID, and the translator’s call invocation UUID.

Rules:

- The initial Read assistant must affirmatively name exactly the outbound UUID, even when replay exists.
- Replay is optional corroboration, never the ownership source.
- The tool result must match the stored tool-use ID and session; envelope identities must be distinct.
- The final assistant may omit attribution **only in `readReturned`**. Any provided attribution must agree.
- Success must affirmatively name the outbound UUID and match the final text.
- Unexpected ordering, another call/assistant, mismatches, or unsupported shapes permanently disqualify the launch.
- Keep existing O19 result-attribution behavior unchanged.

Thus the unattributed final assistant binds through an explicit, uninterrupted dispatch state—not the latest user row. No-replay tests establish source behavior only.

### D. Translation equivalence and controller delivery

Leave the package translator unchanged.

For each qualified tool envelope, require exactly one corresponding translated semantic result, plus an optional usage companion where applicable:

- Call: `Read`, nonnil invocation UUID, and arguments equivalent to the raw input after parsing and reader-compatible canonical serialization.
- Result: same translator invocation UUID, `Read`, exactly matching output text, and unknown error status (`nil`).
- Final text: existing exact-text translation check.

Compare JSON semantics, not pretty-printed strings. Canonical rows always use reader formatting and deterministic invocation IDs; the translator UUID validates live pairing only.

`classifyLiveTranscriptPayload` continues attaching evidence to the existing result. No second tool event, usage observation, or turn boundary is introduced.

### E. Canonical owner, mutation protection, and accounting

Extend `applyClaudeLiveTranscriptEvidence` to receive the full translated result, allowing accepted rows to reuse existing accounting inputs.

Before inserting a Read row:

- Apply existing foreground, provider-session, projection, refused-producer, and proofless-conversation guards.
- Validate prerequisite ledger entries **and actual canonical payloads**, including complete/nonstreaming state.
- Search the canonical transcript plus suffix, not just `session.items`.
- Require duplicate rows to match all projected semantic fields. A duplicate acquires no ownership and incurs no accounting.
- Insert row, ledger entry, and owned key in one nonsuspending main-actor operation; schedule the existing save.

On Read agreement, validate **all three rows and proofs**, catching dropped call/result deliveries as well as a missing final row.

For newly inserted calls/results, reproduce the existing flush/segment transitions and input/output token accounting, using the original translated arguments/output. Preserve reasoning status across tools. Accepted evidence bypasses legacy tool handlers and mutation; ordinary usage events still follow their existing path.

**Mutation protection is mandatory:**

- Associated Claude tool rows remain immutable in projected semantic fields even after proof invalidation; use `associatesClaudeLocalItem`, not digest presence.
- In generic `tool_result` handling, exclude protected rows from both invocation-ID and name-based replacement.
- When fallback targets a protected row, append a separate unidentified result instead. Never consume the event merely because mutation is forbidden.
- Audit provider handlers, tool-completion/finalization paths, and `AgentTabSession.replaceItem`. Add a central replacement guard against changes to protected tool kind, text, tool name, invocation ID, arguments, output, error status, and streaming state. Permit unrelated presentation metadata changes.
- Call sites must supply visible fallback before reaching that guard; the guard is an invariant backstop, not a replacement display policy.

Keep producer refusal/ownership lifecycle unchanged across hydration, rebinding, cancellation, and clear-chat detach. No new tasks, cancellation behavior, schema, cursor, receipt, or persisted completion claim.

## 4. File-by-file impact

Paths below are relative to the repository:

| File | Change and dependency |
|---|---|
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` | Add two bounded projection helpers; foundational dependency. |
| Same directory: `ClaudeLiveTranscriptQualification.swift` | Add Read evidence, prerequisites, transitions, and translation checks; depends on helpers and sanitized shape inspection. |
| Same directory: `ClaudeNativeProcessSessionController.swift` | Update carrier documentation and any exhaustive handling; preserve launch/suppression/EOF behavior. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Pass translated result into evidence handling; add canonical Read insertion/agreement, accounting, and visible protected-row fallback. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift` | Guard protected tool replacements using existing ledger associations. |
| `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeLiveTranscriptQualificationTests.swift` | State-machine, real-translator/controller, rejection, gate parity, and existing O19 regression tests. |
| `Tests/RepoPromptTests/AgentMode/Recovery/ClaudeSessionHistoryReaderTests.swift` | Helper/native projection equality and live-ledger/import deduplication tests using O20 fixtures. |
| New `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeLiveReadTranscriptOwnerTests.swift` | Main-actor insertion, accounting, dropped/duplicate delivery, mutation/fallback, and scoped-invalidation tests. |
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` and new evidence `phase4d5.md` | Bounded status, assumptions, validation, review findings, and remaining blockers. |

No intended changes to translator, import planner, or recovery schema. The supplied excerpts omit other tool mutation callers: locate them before editing; any required guard changes belong to this step and must appear in its final file inventory.

## 5. Implementation order

1. Inspect approved captures offline; freeze sanitized allowlists and document no-replay assumptions.
2. Add projection helpers and native/live equivalence tests.
3. Add classifier states/evidence and controller tests; preserve all single-text tests.
4. **Land owner consumption and mutation protection atomically.** Test call/result remaining distinct, fallback visibility, canonical JSON equivalence, unknown error preservation, and exactly-once accounting.
5. Test three exchanges across two synthetic launches, import no-op matching, malformed/suppressed disqualification, missing prerequisites, hydration/rebind ownership preservation, and clear-chat reset behavior.
6. Run affected builds/tests/style checks. Main requests independent OracleA/B review under the supplied policy; commit only after required validation/review. Label synthetic evidence accurately.

## Recommendations

- **Approve this bounded inactive step**, subject to offline shape validation; do not spend another provider prompt.
- Remaining **pre-live prerequisites**: actual no-replay installed-profile evidence, admission coverage for supported input paths, end-to-end canonical reconciliation after persisted reload, mutation protection across all relevant callers, and resolution or explicit gating of documented durability/process-ownership limits.
- General tools, thinking, multiblock, parallel/subagent support, polish, and retention remain optional breadth—not implied qualification.
- Full Phase 4 remains blocked. Production activation and final live acceptance remain explicitly pending.
