# Lossless restart Phase 0 — OracleB initial review

Scope: read when the task touches the independent review evidence for Phase 0 of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-20

Review identity verified against the requested OracleB preset. Fresh review on the same code/test diff and contextual slices; no other lane's findings were supplied. Validation was provided as command results, not rerun by the reviewer. Dispositions are recorded in [Phase 0 evidence](phase0.md).

## Verbatim review



# Phase 0 review: lossless app restart

Phase 0 adds one DEBUG-only counter and event, `save.session.written`. It fires inside `saveAgentSessionLocked` once the atomic writer has returned, and records timings for prepare, encode and the writer await, plus the byte count. It also adds two contract tests that always run and two opt-in fixture reports: one for a long text-only stream, one for a 1,500-item save. A new evidence doc covers the counter, the measurements, a mismatch in the session-incarnation authority, an inventory of send and acknowledgement routes, and a static trace of hydration. The code change is minimal and correct. Every addition is lexically inside `#if DEBUG`, control flow and thrown errors are unchanged, and the event fields carry only short IDs and counts, with no content or paths.

**No P0 or P1 findings.** The findings below are about how accurately the evidence doc describes what was measured, and a few small test and diagnostic gaps.

## What I checked against the supplied slices

- **Counter and timing code (`AgentSessionDataService.swift`):**
  - The clocks start at `:1978`, `:1990` and `:1997`. The writer await is at `:1999`. The counter is recorded at `:2003`, before `rememberScheduleAuthority` at `:2012` and `upsertMetadataRecord` at `:2026`.
  - The early `.resetAlreadyCommitted` return at `:1916` and the stale-fence throws come before the prepare clock, so they are never counted.
  - The later clock marks are only taken if the first one was, so one save never reports a partial split.
- **Section 3 line references all match:** `:21–35`, `:231`, `:269–276`, `:1269–1290`, `:1291–1309` and `:2017–2025`.
- **VM line references all match:**
  - `scheduleSave` at `:14074` (it ends at `:14098`, not `:14099`, which is trivial);
  - `save.schedule.replaced` at `:14088`;
  - `save.session.invoked` at `:14194`;
  - `onSourceItemsChanged` calling `scheduleSave` at `:4039–4047`;
  - the workspace-switch ensures at `:3958–3962`;
  - `enqueueAssistantDelta` at `:18923`.
- **Writer contract:** the doc's reading of `drainWrites` (`:172–208`) is correct. Each waiter gets the result of the last write. A success means the newest pending payload for that URL was atomically replaced.

## P2

### P2-1 — "Data-service total" and "outside the data service" misdescribe what was measured
- **Evidence:**
  - The `duration` field runs from the clock at `AgentSessionDataService.swift:1978` to the writer return at `:2003`.
  - Several steps on the same actor fall outside that window:
    - waiting in `acquireSessionPersistence`;
    - `ensureAgentSessionsFolder`;
    - `cachedOrLoadedScheduleAuthority` (`~:1933`), which can parse the whole session JSON on a cold save;
    - applying the schedule authority;
    - `rememberScheduleAuthority`;
    - `upsertMetadataRecord` (`:2026`).
  - `phase0.md` §1 defines `duration` correctly. But the §2 tables (~119, ~126) label it "Data-service total". The note at ~140 says the cold first save spends "about 0.18–0.28 s outside the data service". The R3 tuning note at ~146 reports "31–39 ms on the data-service actor".
- **Failure scenario:** someone tuning R3 reads the cold-save gap as main-actor or VM work and the steady-state figure as the actor's full occupancy. In fact the gap includes unmeasured data-service work: possibly a full JSON parse for the schedule authority and the metadata-index write. That method problem affects the attribution, not the numbers themselves.
- **Smallest fix (docs only):**
  - Rename the column to "Measured data-service phases (prepare + encode + writerAwait)".
  - Change "outside the data service" to "outside the measured phases, including unmeasured data-service work (schedule-authority load, metadata-index upsert, gate wait)".
  - Make the same change in the R3 tuning sentence.

### P2-2 — The spec's quit-time inference, which it says Phase 0 validates, is not addressed
- **Evidence:** spec `:64` says "so the terminal state written at quit is probably lost too. That last point is an inference that Phase 0 validates." `phase0.md` has nothing on it: §5 covers hydration and §6 lists only live sampling, crash tests and main-actor cost.
- **Failure scenario:** Phase 1a's flush-before-teardown is designed on an inference the spec calls validated, with no record that anyone checked it.
- **Smallest fix:** either add a short static trace to `phase0.md`, showing that the close and quit path has no `flushSave`/`flushSaveDetailed` call and that the debounce task dies with the process, or list the item as "not validated" in §6. Either is a docs-only change.

### P2-3 — Inventory row "a dropped fallback resolves `.startAccepted`" may be a second false acknowledgement
- **Evidence:** `phase0.md` §4, the "Codex start, steer, retry" row (Codex coordinator `:2232`). It is listed without saying why a *dropped* fallback reports acceptance.
- **Failure scenario:** if "dropped" means the message was discarded rather than deduplicated against an accepted start, an MCP caller is told "accepted" for a message that never reached the provider. That is the same class of bug as the known `.durablyQueued` one, and it would be missing from R2's "producers must change together" list.
- **Smallest fix:** add one sentence to the row saying why the fallback is dropped. If it can drop an undelivered message, mark the row as a known gap next to the Codex fallback bug. This is evidence only; no code change in Phase 0.

## P3

- **P3-1 — `save.schedule.replaced` may not measure what the doc says.**
  - `replacedPendingSave = session.saveDebounceTask != nil` (VM `:14085`). Nothing in `scheduleSave` sets the handle back to nil after the debounced save runs (`:14093–14097`), and whether `saveSession`/`flushSave` clears it isn't in the supplied context.
  - If nothing clears it, the counter counts every schedule after the first, and "38 = 38" proves nothing. The starvation conclusion still holds, because `save.session.invoked` = 0 and `save.session.written` = 0 during the stream.
  - This matters for live sampling, where the spec relies on this counter.
  - **Fix:** cite where the handle is cleared, or add a note that only `invoked` and `written` support the conclusion.
- **P3-2 — "Other real-run mutations … would only restart the same timer" is an overclaim** (`phase0.md` ~105).
  - It holds for `scheduleSave` callers. Direct `saveSession`/`saveSessionDetailed` callers during a run, such as the dispatch-attempt callers mentioned in the doc comment near VM `:14177`, were not inventoried and could break starvation in real runs.
  - **Fix:** reword to "`scheduleSave` callers only re-arm the timer; direct save callers during a run were not inventoried."
- **P3-3 — A race in the stream report** (`AgentStaleResetOwnershipTests.swift` ~2119–2131).
  - A write that lands after the last in-loop sample but before `streamEnd` is credited as the quiet-period save.
  - `quietSaveLatency` then reads about 0, and `savedText.contains(finalToken)` can fail because that snapshot came before the final flush.
  - This becomes reachable once Phase 1a's 10 s maximum wait exists and this retained report is rerun.
  - **Fix:** read the counter once more right after the loop, add that reading to `writeOffsetsDuringStream`, and wait for a value above it.
- **P3-4 — The `duration` field name collides with `save.session.complete`'s `duration`** (`AgentSessionDataService.swift:2059`).
  - They cover different spans: from data-service prepare in one, from VM entry in the other. Live-sampling readers comparing the two will misread them.
  - **Fix:** rename it to `measured` (or similar). It's cheap: one key in the code, one in the test's key loop, and the doc.
- **P3-5 — The per-tab counter uses the persisted `session.composeTabID`** (`:2053`), while the VM counters use the VM tab ID.
  - A nil or different `composeTabID` (for example MCP-originated or headless sessions) yields only the global counter, so per-tab joins in live sampling miss silently.
  - **Fix:** a note in §1 that the `sessionID` field is the reliable join key.
- **P3-6 — The status line's `assumed: fixture-only measurements` doesn't fit the policy's meaning of `assumed:`** (spec `:8`).
  - Per the policy, `assumed:` is for a reversible choice made because the owner didn't answer. "Fixture-only measurements" follows from decision O3 and the Stakes section, which treats app lifecycle actions as irreversible. It's already covered by `deferred: live sampling`.
  - **Fix:** leave `assumed:` empty, unless the owner was actually asked about live sampling.
- **P3-7 — Two contract claims are untested.**
  - The doc says `.resetAlreadyCommitted` is not counted, and that the clocks aren't read when diagnostics are off. Both hold by construction in the diff.
  - Defer unless a replay fixture already exists.
- **P3-8 — Test placement.**
  - The Phase 0 reports sit in `AgentStaleResetOwnershipTests` only to reuse its private harness.
  - Acceptable for now. Consider moving them when the `Recovery/` suites are created.

## Missing evidence (unverifiable from the supplied context, not defects)

- `acquireSessionPersistence` at `:2584` and the scheduled-send writes at `:2193` and `:2558`.
- That neither `AgentSession.swift` nor `AgentSessionMetadataIndex.swift` serializes a generation. The incarnation-mismatch conclusion rests on this.
- Most §4 route line numbers (VM `:9593+`, `:16xxx`, the Codex coordinator and RunService). They were spot-checked by the author only.
- §4 doesn't say how routes were found (search patterns, files covered), so completeness can't be judged. Possible omissions: retry, edit-and-resend, `/compact` for Claude, and child `agent_run` sends.
- §5 doesn't examine `scheduleProvisionalClaudeContextWindowResolutionForActiveSession` (VM `:3957`), which runs unconditionally when a workspace switch completes. It's probably not a `--resume` writer, but the trace should say so.
- That `AgentModePerfDiagnostics` is entirely DEBUG-only (the indentation at `:90` suggests it is). The release-build argument doesn't depend on this, because every addition is already inside `#if DEBUG`.

## Recommendations

1. **Fix P2-1 and P2-2 in `phase0.md`.** Both are wording changes or one added paragraph and need no code. Add a one-line explanation to the P2-3 row.
2. **Cheap code tweaks, optional:** P3-3 (one extra counter read after the loop) and P3-4 (rename the `duration` key). Rerun the two focused counter tests, plus the opt-in reports if P3-3 changes. Neither needs a review round.
3. **Defer the rest:** P3-1, P3-2 and P3-5 as doc notes; P3-6 as a status-line tidy; P3-7 and P3-8 as deferred items.
4. **Carry into Phase 1a planning, outside this step:** audit whether load-rewrite paths (`commitLoadedSessionStorage :1742`, the migration rewrite at `:2756`) use the same `diskWriter` URL without holding the per-session gate. If they do, a full save could return success while a rewrite replaced its payload. The counter would count it, the VM would mark the session clean, and flush-before-teardown would depend on that success. Phase 0 already says these paths weren't audited.
5. **Commit:** with no P0 or P1 open, this step can be committed once the doc edits land.
