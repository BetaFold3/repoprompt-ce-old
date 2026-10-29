# Phase 4 forward-guidance consultation and disposition

Scope: read when the task touches the next bounded work after the signed inactive lossless-restart Phase 4 checkpoint.
Authority: Reference
Last-verified: 2026-10-22

## Outcome and boundary

The owner requested independent guidance from OracleD and OracleE. Both consultations completed, their exact preset names and UUIDs were verified, and both full exports were read. These are planning opinions, not another Phase 4 acceptance-review round. No new owner decision, source change, feature activation, or implementation commit resulted.

At consultation time, HEAD was the signed checkpoint `fbc1ef041cd7000255c102f7abd7e2464120fe25`. Phase 1 quit/window-close preservation and Phase 2 presentation are committed; Phase 3 registry source and Phase 4 partial source remain production-inactive. Full Phase 4 stays blocked. O3 live acceptance and O9's architecture/scope constraints are unchanged.

- [OracleD's complete response](phase4-forward-oracled.md).
- [OracleE's complete response](phase4-forward-oraclee.md).

Both fresh lanes received the same request, policy and line-numbered current source excerpts without the shared workspace selection or prior review responses. The packet covered saved-message lookup/dispatch, transcript grouping, Claude history associations and stream/encoding seams, production qualification, relaunch helper and shutdown failure handling. It was a bounded source packet, not a complete inventory of canonical mutation APIs or live reducers. Absence from the packet is not repository-wide absence.

## Agreements

Keep the existing recovery store/coordinator, normal dispatch, canonical session writer, provider controller, history ledger and cursor transaction. Do not add a parallel transcript authority, generic provider-provenance framework, helper daemon/lease/service, or speculative protocol fields.

Do not prioritize the gated automated Restart helper over already-committed ordinary quit/window-close preservation. Its arm-sent/unknown-stop freeze is not an accepted usable failure policy; production Restart remains off. A successful signal is not proof of helper exit. Defer polish, retention, broad performance work and additional review cycling.

Claude identity must be established before adding association writes. The pre-byte baseline producer already exists and is not another task. Establish both the user-record relationship and live-output relationship, including cardinality, and whether the whole-candidate reader supports an ordinary real-file shape. Stream envelope UUID, API message ID, tool identity and native JSONL entry identity are not interchangeable by assumption.

## Material differences and main disposition

### Older saved input

OracleD recommends keeping refusal plus Edit-as-new and considers that sufficient. OracleE says it remains a product gap and proposes investigating a canonical move of the SAME unsent item before a routing redesign.

OracleD's sufficiency conclusion is not adopted: O9 explicitly preserves the older-message requirement and keeps the full step blocked. Edit-as-new remains a workaround, not completion. Neither the spec excerpts nor O9 require an unsent bubble's visual position to be immutable; however, relocation's execution/order semantics are not approved.

Recommended next action is a read-only bounded source probe: trace the canonical mutation authority, original intent ordering, actual output-routing consumers of the runtime anchor, and retained state after compaction. Test the hypothesis against request anchors, mid-turn user activities, canonical-only older input and compacted history. Identify a complete same-ID operation or an exact counterexample; do not implement a suffix-only move and call the full requirement done.

If feasible, present the owner-visible choice: sending now moves the existing unsent bubble after later turns while preserving identity and saved chronology, versus keeping the original position and requiring correctly targeted canonical output insertion. No relocation or routing change is selected by this consultation.

### Live work and diagnostics

OracleD prioritizes owner-run normal-lifecycle acceptance and a new DEBUG identity logger. OracleE prioritizes source tracing and requires separately authorized native evidence.

No live acceptance, provider execution, home inspection or visible app lifecycle action is authorized or performed here. O3 remains pending; ordinary lifecycle testing is not silently treated as accepted merely because it avoids killing the app. Use existing source/fixtures first; request one precisely bounded, sanitized native observation only if the missing relationship cannot be established otherwise. Do not build a logger before showing existing evidence paths are insufficient. Do not use real owner data for destructive Reset/Delete experiments.

### Partial output and association

OracleE identifies a necessary future distinction: knowing a native row's local identity does not prove that its full content was imported. Main spot-checked `ClaudeSessionHistoryReader.swift:331-350` and `AgentProviderHistoryImport.swift:97-125`: current known-key filtering suppresses those rows. Reusing that completed-import ledger for a partial live answer without changed semantics could omit the missing tail.

Any later Claude-specific implementation must preserve this distinction within existing session-owned state, update the correct original local item without duplication, and commit content plus evidence before advancing the cursor. No new association schema or implementation is selected now.

### Activation coupling and helper policy

Both lanes note that registry activation requires every supported family/provider pair (`AgentProcessRegistrySupport.swift:58-96`). OracleE also notes that Continue, Send saved and Answer as input share one action gate (`AgentRecoveryActionRunner.swift:23-53`), which main re-read. Solving an individual source gap does not authorize an independent release. Coupling changes are separate design/owner choices, not selected or required for the next source probe.

OracleD offers a possible future “quit; reopening uncertain” helper policy. OracleE treats that as an owner-approved contract alternative, not a compliant fix. Main agrees it is not selected: neither hidden retry/renewed deadlines nor forgetting an armed helper resolves R4. Keep automated Restart deferred rather than changing the current contract.

## Owner approval to proceed

After receiving the consultation report, the owner answered: “ok sounds good, proceed after persists our notes/decision.” Decision O10 records approval to persist this guidance and perform the recommended source-only investigations. It does not select relocation semantics, weaken the older-message requirement, approve a provider identity inference, authorize live observation or enable a feature. The original O3/O9 constraints remain.

## Recommended bounded order

1. Investigate older saved-input canonical ownership and same-ID relocation feasibility, read-only; return evidence and a precise product choice or blocker.
2. Independently establish Claude native identity/cardinality and ordinary-reader viability from authorized evidence. Only then select a narrow transport/reducer/ledger change, with partial-output-aware reconciliation.
3. Keep automated Restart and all activation deferred. Retain existing coupled qualification and O3/O9 boundaries; do not request scope cuts merely to label Phase 4 complete.

O10 approved the source-only investigations above; it did not select any new product semantics. Their [completed evidence](phase4-source-investigations.md) records results and remaining boundaries. A subsequent behavioral change needs its own bounded scope, validation and applicable review policy; this consultation does not reopen the capped Phase 4 review.

## Validation and limitations

This consultation verified repository HEAD/status, named-preset identity, completion of both sends, complete export retrieval, and the load-bearing source references above. The earlier checkpoint's 592 injected tests and compile-only builds were context, not rerun or live qualification here. No build, test, packaging, provider/helper/MCP execution, app lifecycle action, performance measurement, signing, commit or push was performed for this consultation. Only the local consultation evidence files and a link from the existing Phase 4 evidence were added; the plan and its owner Decisions were left unchanged. The first context-structure check failed because the three new evidence documents were not yet reachable. Adding a link from existing evidence fixed the errors; that rerun passed but exposed two new depth warnings. Direct response links from the existing evidence remove those extra hops. The final context check and tracked-diff whitespace check passed, with only the pre-existing 24-route warning. No test suites were rerun for evidence-only changes.
