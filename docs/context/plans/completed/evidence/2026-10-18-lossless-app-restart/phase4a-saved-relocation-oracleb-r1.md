# Step 4a OracleB re-review, round 1

Scope: read when the task touches this lane's O11 relocation re-review and required finding closure.
Authority: Reference
Last-verified: 2026-10-23

Exact returned preset `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` / OracleB, explicit model, verified before synthesis. Fresh independent chat `o11-relocation-r1-oracle-F78A91`, operation `772E84CF-DBCC-4F47-9961-CFD929BA8ED1`. Both lanes reviewed frozen snapshot `2026-10-23/0845` (13 source/test changes against `deb4ae5335cab845d61be64d63d992eb3e885bb0`), the common fix delta and updated fixture validation, with review policy verbatim and only their own prior response/dispositions. Full response read by main. Original export: `prompt-exports/oracle-review-2026-10-23-084810-o11-relocation-r1-or-ba63.md`. Markdown trailing hard-break whitespace is rendered as `<br>`; original export remains unchanged.

The response's internal heading says OracleA; returned preset ID/name and chat receipt identify OracleB. This display-heading error is preserved below and is not treated as a different reviewer.

## Response

# Oracle Review

# OracleA re-review, round 1/2: Step 4a, O11 saved-input relocation (snapshot 2026-10-23/0845)

**Verdict: no open P0 or P1 from this lane, so Step 4a is clear to commit from my side.** Full Phase 4 stays blocked, every production gate stays off, O3 live acceptance is still pending, and the tests prove fixture behaviour only.

**Scope.** I checked the fix delta since 2026-10-22/2214 and any regressions those fixes caused. That delta covers:
- **Shape preflight:** `hasSupportedWorkingEnvelopes` now checks every retained full turn before any reuse or change.
- **H metadata:** a closed, unchanged explicit H now keeps its terminal state and completion data across rebuilds.
- **Incremental ownership:** the incremental path now collects ownership from the final full working turn only.
- **Hydration fence:** `stillCurrent()` now requires paired save-hydration authority.

I found no regression from these fixes.

What I traced from source:
- **Supporting behaviour before the fixes:**
  - **No mutation before the check.** There is no suspension between the second `stillCurrent()` and `prepareRecoverySavedInputPlacement`; the attachment lookup is synchronous.
  - **E is not frozen when a run starts.** A rebuild under `.running` opens E's span, which fails `isClosedUnchanged`.
  - **The incremental path falls back correctly.** A new user message B after E causes `requestIDMismatch` and falls back to the full rebuild, which then finds H and E by ID.
  - **Ordinary sessions are unaffected.** Importer-only sessions get empty ownership, so they behave as before apart from the requestless-envelope change I accepted last round.
- **Gate in both submit paths:** the gate in `submitPreparedUserTurn` also runs on the post-hydration path (`submitUserTurnAfterHydration`), so neither path can skip the preparation check.

## My prior findings

| ID | Your disposition | My response |
|---|---|---|
| **P1-1** (H terminal state reset by `finalizeTurn(nil)`) | Downgraded to a P2 test gap | **Accept, no contest; now closed.** `AgentTranscriptServices.swift:5734` reads `turn.terminalState = terminalState ?? turn.terminalState`. The next lines keep `lastActivityAt`, and keep `completedAt` when `isCompleted` is true (which the relocation passes as `turn.completedAt != nil`). Span `lifecycle` and `completedAt` are never touched, because only `collapsedSummary` is rebuilt per span. My premise was wrong. Diagnostics 1086+ covers completed, cancelled and failed H through relocation, full rebuild, a JSON round trip, a reload rebuild, and beside a live E. |
| **P1-2** (placement before deferred hydration) | Accepted and fixed | **Verified, closed.** `stillCurrent()` (`RecoveryActions.swift:~671-681`) runs before `readRecord`, after it (immediately before the synchronous preparation), and inside `placementStillCurrent()` after both the save await and the receipt await. `hasTranscriptSaveHydrationAuthority` is stricter than `hasLoadedPersistedState`: it rejects a pending load, a binding transition, and `.unresolved`, `.failed` or `.suppressed` loads. The VM test (1146+) checks four of those states with no change to graph, items, bytes or record, no save and no start. |
| **P2-1** (E's ownership depends on its span shape) | Deferred | **Accept the deferral.** Preparation refuses every full turn that isn't import-shaped, and nothing on a current live path creates a non-import-shaped E. |
| **P2-2** (whole-transcript ownership work on every incremental update) | Cheap fix applied | **Verified, closed.** `incrementallyUpdatedTranscriptForFinalTurnWithDiagnostics` now calls `explicitFinalWorkingTurnOwnership`; full ownership is computed only in the full-rebuild fallback. The `workingDetailTranscript` copy that remains is O(n) with no sort. A possible cleanup is listed as P3-2. |
| **P2-3** (older binaries re-saving relocated sessions) | Documented in evidence | **Accept** a note in evidence plus the pre-activation gate as enough. |

## New findings (listed only, not to be looped on)

**P2-A: unverified durable-frontier and retiering effect when A is relocated out of a compacted frozen prefix.**
- **Scenario:**
  1. A's only occurrence sits in a turn that is not full tier and lies inside a valid `compactionFrontier` prefix (the canonical-only case).
  2. `relocatingSavedInput` clears that turn's `request` and `summary.requestText` (`AgentTranscriptServices.swift:~3110-3113`).
  3. The next save runs `rebuiltTranscriptPreservingCompactedPrefix`, which re-checks `validatedFrozenPrefixTurnCountForIncrementalReuse`.
  4. If the frontier validation covers prefix request or summary content, that check fails and compaction falls back to `.recomputeAll`.
- **Impact:** earlier turns could be retiered, which O11 forbids ("no retier"). This is unproven in either direction.
- **Why the existing test misses it:** `testSavedInputRelocationOfACanonicalOnlyCompactedOccurrenceKeepsItsTier` builds its transcript with `compact: false` and no frontier.
- **Likelihood:** low. It needs a saved input that stays queued until enough later turns arrive to compact it.
- **Smallest fix (either):**
  - Add one test with a valid frontier that asserts the frontier is still valid after relocation plus one rebuild, and that no tiers change.
  - Or refuse relocation conservatively (`.historicalEnvelopeNotReconcilable`) when the occurrence's turn index is below the validated frozen-prefix count.

**P3-1: the shape preflight is broad, so Send saved may refuse often.**
- `hasSupportedWorkingEnvelopes` (`~3043`) refuses whenever any retained full turn fails either check:
  - not import-shaped (for example, a turn saved by older code with non-deterministic span IDs);
  - carrying a foreign mid-turn user activity (for example, recorded steering).
- On older or steered sessions, Send saved may therefore refuse most of the time.
- The owner explicitly allowed this kind of conservative refusal, and Edit remains available. I mention it only so that how often it refuses gets watched once O3 runs.

**P3-2: optional cleanup of the incremental path.** The incremental path could read only `existingTranscript.turns.last(where: { $0.retentionTier == .full })` instead of building `workingDetailTranscript`. This is advisory only, since timing on this host is noisy.

## Remaining validation gaps (not findings)

- A real DataService cold load end to end has not been exercised against a relocated session.
- A truly overlapping save writer has not been exercised; the deferred-save case is covered only by an injected outcome.
- There is no full-root run. The earlier one was cancelled, and its partial failures are untriaged.
- Nothing ran live.
