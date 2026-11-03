# Step 4b review — OracleA

Scope: read when the task touches the retained-helper late-stop recovery review.
Authority: Reference
Last-verified: 2026-10-23

Main verified the exact requested preset UUID/name. Initial snapshot 2026-10-23/1204, seven source/test files. Full response follows; original local export unchanged. [Disposition](phase4b-helper-stop.md).

# Oracle Review

The patch adds replayable, cancellable late-stop proof observation, releases only the retained helper, and restores normal failure choices without automatically retrying or renewing deadlines. Presentation fencing protects against dismissed prompts’ stale answers. Production gates remain off.

**Verdict: Approve with one minor correction.** No scoped P0/P1 findings. This is source-only approval; O3 live acceptance remains pending. Reported validation was not independently rerun.

## P2 — Consider

### R1 — Preserve the actual proof across repeated abort calls
**File:** `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift:989–992`, and `ProcessRelaunchParentSession.abort()`

- **Scenario:** An exact-child exit arrives after cleanup became unresolved. The new latched-proof shortcut returns `.safe(.exitObserved)` and sets `.finished`, but leaves `helperExited` false. A subsequent `abort()` therefore returns `.safe(.abortAcknowledged)`, even though no acknowledgement arrived.
- **Impact:** Safety remains intact—the exit was proven—but the typed result incorrectly reports different evidence on repeated calls.
- **Smallest fix:** Set `helperExited = true` when consuming a latched `.exitObserved` before marking the session finished. Extend the late-exit test to call `abort()` twice and require `.safe(.exitObserved)` both times.
