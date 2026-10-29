# Step 4a initial OracleA review

Scope: read when the task touches this lane's bounded O11 saved-input relocation review findings.
Authority: Reference
Last-verified: 2026-10-22

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`, explicit selection. Completed on frozen Git snapshot `2026-10-22/2214` (13 O11 code/test files against `deb4ae5335cab845d61be64d63d992eb3e885bb0`), with controlled source context and review policy verbatim. Original export: `prompt-exports/oracle-review-2026-10-22-222030-o11-saved-relocation-68d0.md`. Main read the full response. The response below is preserved independently, not synthesized with another lane. No findings have been disposed or fixed yet; OracleC failed authentication and owner input timed out. This is not review approval.

## Response

# Oracle Review

The delta implements O11 placement/reconstruction, requires a covering owner save before dispatch, and routes recovery joins to the execution turn. The main flow is appropriately fenced, but historical-envelope preservation is incomplete.

## P0 — Must fix

### O11-01: An unrelated historical envelope can be erased by the new execution turn
**Evidence:** `AgentTranscriptServices.swift:2828–2843` — `transcriptByReplacingWorkingTurns`.

Consider `[T, X]`, where `X` is an unrelated full, requestless, span-less envelope containing interruption evidence. Reconstructing absent input A appends E. The relocation preflight does not inspect X because it checks only A’s occurrence and turns whose ID equals A.

Rebuilding produces `[T, E]`. After matching T, the positional fallback consumes E as X’s replacement. When the merge reaches E’s original position, the new explicit-turn branch drops that unmatched, nonempty envelope. The result is `[T, E]`: **X and its evidence disappear**, while E remains clean and final, allowing validation and sending to proceed. Before this delta, with no E available, the fallback retained X.

**Smallest fix:** Before installation, conservatively refuse relocation when any retained full envelope cannot survive the ownership-aware rebuild—not only H or turns named A. Add this exact regression fixture, including preservation before relocation and refusal without mutation afterward.

## P1 — Should fix

### O11-02: Completed historical spans lose their recorded completion time
**Evidence:** `AgentTranscriptServices.swift:2983–2996` — `preservingExplicitTurnEnvelopes`; `:3662–3673` — importer `finalizeSpan`.

For an accepted historical H with output and a completed span whose `completedAt` is later than its last activity, moving A makes H explicitly owned. A subsequent full rebuild creates a fresh span and sets its completion time from `lastActivityAt`. The preservation helper restores its start, run ID, and provider-turn ID, but **not its completion time**. The interrupted-envelope helper does not repair completed turns.

Thus IDs and activity membership survive while durable historical timing evidence changes. The added graph assertions do not check this metadata.

**Smallest fix:** Preserve completion metadata for unchanged historical envelopes, without freezing the live execution turn E. Add a completed-H fixture with deliberately distinct activity and completion timestamps, checked through rebuild and serialization.

## Verdict and validation gaps

**Changes required before Step 4a acceptance.**

- Reported fixture/build/lint results are useful, but were not independently rerun here. The added JSON round-trip/rebuild test does not demonstrate the actual DataService cold-load/hydration path; its normalization implementation is outside the supplied slices.
- The deferred-save fixture injects a deferred outcome rather than exercising an actual overlapping writer.
- Before activation, document that pre-O11 binaries can regroup/rekey these independent turn/request identities when re-saving. No compatibility layer is requested.
- Gates should remain **OFF**; O3 live acceptance remains pending.
