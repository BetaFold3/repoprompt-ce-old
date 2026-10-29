# Phase 3 Platform re-review 1 — OracleB

Scope: read when the task touches review of the bounded process-inspection and launcher-marker slice.
Authority: Reference
Last-verified: 2026-10-21

Preset identity verified: OracleB, `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`. Chat: `restart-platform-r1-orac-14E869`. Each lane received only its own prior findings.

# Oracle Review



# Re-review round 1: Phase 3 Platform (ProcessInspection fixes)

## Summary

My lane's one P1 (F1, zero-filled argv tail) is **fixed correctly**. The P3 fixes and F4 are also correct: selected-only slices, the weak-evidence wording, and the final-sample `isZombie` read from `SZOMB`. I found **no regressions at P0/P1**. `ProcessLauncher` is unchanged; the delta doesn't touch it. The new P2/P3 items below are listed only, not to be looped on.

I checked this by reading the code and tracing synthetic buffers by hand. I ran nothing live, which fits this round's scope.

## Fix verification

- **F1, zero-filled argv tail (`ProcessInspection.swift:302–305`).** I traced the new fixture by hand:
  - The buffer is: `argc=3`, `/usr/local/bin/node\0`, one padding NUL, `claude` followed by 24 NULs, then the environment.
  - The padding skip lands on `claude`. The argc loop reads `claude` and then two empty strings.
  - The new NUL skip moves the cursor onto `RPCE_RUNTIME_ID=…`, and both markers are read.
  - This also matches libuv: `uv_set_process_title` zero-fills `cap - len` bytes, and `cap` covers every argv string plus its NUL. A title no longer than `argv[0]` therefore always leaves at least `argc` NULs.
- **Selected-only slices (`:310–318`).** `entry[(separator + 1)...]` uses indices shared with `buffer`, so it is correct. With an empty value it gives `entry[end...]`, a valid empty slice, and `testParserPreservesEmptyHome…` covers that case. Values that aren't selected are no longer copied.
- **Weak-evidence wording (`:60–64`).** The doc now says "absent from the current exec string area" and "never proof that a process is unowned". This matches what I recommended.
- **F4, zombie (`:115`, `:427`, `:203`).**
  - `isZombie` comes only from the final sample. That is correct: a process can't leave the zombie state, and PID reuse is caught by the identity bracket.
  - The `UInt32(SZOMB)` conversion and `read(status: Int32)` in the test both type-check against the SDK constant.
  - `BasicInfo`'s default `isZombie = false` doesn't affect identity equality, because the identity is built from the other fields.
- **Contract change.** `ProcessObservation.init` now requires `isZombie:`. It is package-scoped and the registry isn't active, so there are no callers outside the tests.

## P2 (listed, not looped)

### R1-1. The NUL skip doesn't help when the title fills the argv area

- **Where:** `ProcessInspection.swift:295–305`.
- **Scenario:** A process sets a title longer than the original `argv[0]`, close to `cap`. The zero run is then shorter than `argc` NULs, so the argc loop runs on into the environment. It counts the first `argc − 1 − (zeroRun − 1)` env entries as arguments. A marker among those entries comes back as `nil`.
- **Impact:** With the new wording this is only weak evidence, not a wrong ownership answer. It is also unlikely: Claude sets a short title.
- **Smallest fix:** No code change. Add one line to the doc comment or evidence doc: "the skip covers title rewrites no longer than the original argv area minus `argc` bytes; longer titles can hide leading env entries."

## P3 (listed)

### R1-2. With an empty environment the parser now reads past the env terminator, and no test pins this

- **What changed:** With an empty env, the NUL skip at `:303` swallows the env terminator, so the env loop now parses the apple strings.
  - That is harmless, as the comment says: apple keys are set by the kernel or dyld and never match the selected keys.
  - The old behaviour for this layout was always `available(nil, nil)`. An unterminated trailing string now gives `malformedResponse`, which fails closed.
- **Test gap:**
  - Every successful parser fixture has either a non-empty env or `trailing: []`. None covers "empty env + default apple trailer → `.success(nil, nil)`".
  - `testParserPreservesEmptyHomeValueAndStopsAtEnvironmentTerminator` only proves the terminator rule for a non-empty env.
- **Fix:** Add one fixture: `procArgs(environment: [])` with the default trailer, expecting `.success(ProcessEnvironmentIdentity(runtimeID: nil, claudeConfigDirectory: nil))`.

### R1-3. One test name contradicts the new weak-evidence contract

- **Where:** `ProcessInspectionTests.swift:93`.
- **What's wrong:** `testMissingSelectedVariablesAreVerifiedAbsenceNotFailure` still says "verified absence".
- **Fix:** Rename it, e.g. `testMissingSelectedVariablesAreAbsentNotFailure`.

### R1-4. The delta rewrites whole unchanged blocks

- **What I see:** Both deltas remove and re-add roughly 350 and 280 lines that read the same apart from the intended edits.
- **Why it matters:** That usually means line-ending or whitespace churn. It would pollute the "stage only this step's hunks" commit.
- **Fix:** Before staging, check with `git diff --check` and `git diff -w --stat`, and run `file` on both files to look for CRLF. If it turns out to be an artifact of how the delta was generated, nothing needs to change.

## Verified, no finding

- `.notFound` still comes only from `ESRCH` on a basic-info read. The zombie and slice changes don't touch the no-false-exit paths.
- The duplicate-key, UUID and UTF-8 checks still run on selected values only. The no-leak test still holds, because the slices are decoded only for the two selected keys.
- The deferred items match my earlier dispositions and need no further action this round: startup marker sanitization (F2), exec during sampling (F3), empty `argv[0]` (F5), and the effective-UID caveat.
- The reported counts are consistent:
  - 25 original tests plus the zero-tail fixture plus the two zombie tests gives 28.
  - 26 before the fix is 25 plus the new fixture, with that fixture failing.

**Disposition for this lane:** no open P0/P1. R1-1 to R1-4 are optional and need no further round.
