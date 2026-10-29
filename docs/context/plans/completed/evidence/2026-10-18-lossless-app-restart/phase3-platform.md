# Lossless app restart — Phase 3 Platform process-inspection slice evidence

Scope: read when the task touches the lossless-restart R6 Platform primitives: `ProcessInspection` single-PID inspection or the `ProcessLauncher` `RPCE_RUNTIME_ID` marker.
Authority: Reference
Last-verified: 2026-10-21

Implementation evidence for the bounded, inactive Platform slice of R6 in [the plan](../../2026-10-18-lossless-app-restart-spec.md). Planning guidance: `prompt-exports/oracle-plan-2026-10-21-014808-restart-phase-1-scop-833d.md`. The plan controls; this slice is a primitive, not R6 readiness. Evidence is XCTest against a scripted system-query backend and synthetic `KERN_PROCARGS2` buffers. No real process was inspected, spawned or signalled.

## What remains inactive in production

- Nothing calls `ProcessInspection.inspect(pid:)`.
- No production `ProcessLauncher.spawn` call site passes `runtimeID`; the default `nil` leaves every child environment unchanged.
- No registry, inventory, descendant classification, watcher, durable runtime record, provider, AgentCore or App change.

## Contract

**`ProcessInspection.inspect(pid:)`** (`Sources/RepoPromptPlatform/Infrastructure/Process/ProcessInspection.swift`) is synchronous, read-only, nonthrowing and stateless. Callers run it off the main actor.
- A nonpositive PID returns `unavailable(basicInfo, invalidProcessID)` without any query.
- Order: boot session UUID (`kern.bootsessionuuid`), `PROC_PIDTBSDINFO`, `proc_pidpath`, `getpgid`, then `KERN_PROCARGS2` only when the target UID equals `geteuid()`. Otherwise the environment field is `unavailable(arguments, accessDenied)`. Basic info and boot UUID are then re-read.
- `.observed` requires both samples to agree on boot session, PID, start seconds/microseconds and UID. The final parent PID is reported; reparenting alone is not a mismatch. Any disagreement is `unavailable(consistency, inconsistentObservation)`.
- `.notFound` comes only from `ESRCH` on a basic-info read, first or second. EPERM, other errnos, zero/short responses, PID mismatch, and unavailable or malformed boot identity are `.unavailable` and never imply exit. No internal retry.
- `errno` is cleared immediately before `proc_pidinfo` and `proc_pidpath` and captured immediately after. A zero return with a fresh errno reports `syscallFailed(errno:)`. A zero return with no fresh errno is `malformedResponse`, so a stale `ESRCH` can never declare absence. The `Backend.readBasicInfo` / `readExecutablePath` helpers take the raw query as a closure, so tests prove this with fake queries.
- Executable path, process group and environment are separate fields. `.observed` with unavailable fields is still an identity, not verified ownership.
- `isZombie` reports `pbi_status == SZOMB` (SDK `sys/proc.h`) at the final sample. It is supporting evidence: an exited but unreaped process still returns `.observed`, and consumers must check this flag.
- The internal `unavailable(consistency, inconsistentObservation)` is a sampling race between this call's two reads. It is not the spec's "any mismatch means `exited`" rule. That rule belongs to a later registry comparing a complete observed identity against a recorded one.
- Failures carry an operation and reason (`invalidProcessID`, `syscallFailed(errno:)`, `accessDenied`, `malformedResponse`, `inconsistentObservation`) and no response bytes, arguments or environment.

**`KERN_PROCARGS2` parsing** keeps only `RPCE_RUNTIME_ID` and `CLAUDE_CONFIG_DIR`.
- Allocation is bounded by `KERN_ARGMAX`.
- It validates the count (nonnegative, within the buffer), a non-empty NUL-terminated executable path, NUL padding, and exactly `argc` terminated argument strings.
- A NUL run after the arguments is skipped before the environment. This covers an argv area zero-filled by a process-title rewrite: libuv `uv_set_process_title` does `memcpy` of the title into `argv[0]` and `memset` of zeros through the end of the original argv area (primary source `libuv/src/unix/proctitle.c`, v1.x). With an empty environment, the skip reaches the trailing apple strings, whose keys never match.
- Environment entries run to the first empty string or the buffer end and split at the first `=`. Argument strings are never treated as environment. Only the two selected values are referenced, as slices of the temporary buffer; no other value is copied or decoded.
- Any string `UUID(uuidString:)` accepts is the same marker identity, including lowercase; the launcher still emits the canonical form. An unterminated entry, a duplicate selected key, an unparseable marker, or invalid UTF-8 in a selected value makes the environment field `malformedResponse`. Invalid bytes in an unselected value are ignored.
- `CLAUDE_CONFIG_DIR` is kept verbatim, with no symlink resolution or default. An empty value is preserved.
- `nil` means absent from the process's current exec string area. That is weak evidence, never proof that a process is unowned: the process can overwrite that memory, and later `setenv` changes never appear there.

**Launcher marker** (`ProcessLauncher.swift`): `spawn(...)` and the DEBUG `debugSpawn(...)` gain `runtimeID: UUID? = nil`.
- With `nil`, the supplied environment passes through unchanged, including any existing marker.
- With a value, `RPCE_RUNTIME_ID` in a local copy is set or replaced with `runtimeID.uuidString`.
- Command, arguments, descriptors, flags, process group, errors and cleanup are unchanged. Birth identity is not captured inside `spawn`.

## Known limitations (documented, no code change)

- **Inherited marker (OracleB F2).** With `runtimeID: nil` the launcher passes any inherited `RPCE_RUNTIME_ID` through unchanged; this is the explicit nil-preservation contract. A CE app started from an agent's shell would hand the outer marker to its children. Deferred: process-wide startup sanitization (`unsetenv`, covering every spawn path) must be decided at registry activation.
- **Exec during sampling (OracleB F3).** PID, start time and UID survive `execve`, so a shim exec between the path read and the arguments read can pair the old image's path with the new image's environment. The identity bracket cannot detect it. Fields remain supporting evidence.
- **Long process title (OracleB R1-1).** The NUL-run skip covers a title rewrite that leaves at least `argc` zero bytes, meaning the new title is no longer than the original argv area minus `argc` bytes. A longer title shortens the zero run, so the argument loop consumes leading environment entries and a marker there reads as `nil`. That result is still weak evidence.
- **Empty `argv[0]` (OracleB F5).** An empty `argv[0]` is indistinguishable from exec-path padding. The parser consumes it as padding, then takes one environment entry as an argument, which can hide a marker in that slot. `ps` and psutil share this ambiguity.
- **Effective UID (OracleB P3).** `pbi_uid` is the effective UID. A `seteuid` or setuid exec changes the identity, which a later registry would read as a different lifetime. The `KERN_PROCARGS2` gate correctly uses the effective UID.

## Reviews

An earlier review packaging contained only imports. OracleA was blocked and OracleB cancelled on it, and no approval was counted. The complete-source initial reviews, with verified preset identities, are:
- [OracleA initial review](phase3-platform-oraclea.md): no P0/P1. P2-1, copying unrelated environment values, is fixed with selected-only slices.
- [OracleB initial review](phase3-platform-oracleb.md), dispositions:
  - F1 (P1, zero-filled argv tail → false absence): fixed by the NUL-run skip, the narrowed `nil` wording, and the fixture `testParserReadsEnvironmentAfterZeroFilledArgumentTail`.
  - F2: documented, deferred to registry activation.
  - F3: documented.
  - F4 (zombie): fixed with `isZombie` and scripted and fake-query tests.
  - F5: documented.
  - P3 selected-only copy: fixed.
  - P3 effective UID: documented.
  - P3 internal versus recorded identity: documented under Contract.
  - P3 test gap: closed.

Round 1 re-review, rounds 1/2, both lanes with verified preset identities:
- [OracleA re-review 1](phase3-platform-oraclea-r1.md): no open P0/P1.
- [OracleB re-review 1](phase3-platform-oracleb-r1.md): no open P0/P1. All F1–F5 and P3 fixes and dispositions are confirmed, and no further round is needed. Dispositions:
  - R1-1: documented under Known limitations.
  - R1-2: closed. The empty environment with the default apple-string trailer is pinned in `testParserPreservesEmptyHomeValueAndStopsAtEnvironmentTerminator`.
  - R1-3: closed by renaming the test to `testMissingSelectedVariablesAreAbsentNotFailure`.
  - R1-4 (apparent whole-block rewrites): an artifact of main's synthesized single-hunk delta, which spanned from the first to the last changed line. It is not repository churn. `git diff --check` on `ProcessLauncher.swift` is clean, and its `git diff -w --stat` equals `git diff --stat` (22 insertions, 3 deletions). `git diff --no-index --check` reports no whitespace errors for the four new files, and `file` reports no CRLF line endings.

Status: implementation, validation and bounded reviews are complete. Signing was restored for the Phase 1b checkpoint c9138767; this inactive Platform slice is ready for its separate local checkpoint. Quit/window-close implementation remains separate and unstaged.

## Validation

All runs are coordinated and source-validating on the stable shared source.

F1 before and after:
- Before the fix, with only the fixture added: `make dev-test FILTER=ProcessInspectionTests`, job `dc5e0cf7-c842-4e64-bdff-a639a55d9328`, exit 2, 26 tests, 1 failure. The new fixture parsed `runtimeID: nil, claudeConfigDirectory: nil`.
- After the review fixes: `make dev-test FILTER=ProcessInspectionTests`, job `5ea23e3d-f47f-4277-a43d-2d65a37cd042`, exit 0, 28 tests, 0 failures.

Other runs after the review fixes:
- `make dev-test FILTER=ProcessLauncherRuntimeMarkerTests`: job `ef28a302-9e87-419c-9dc6-88662202ec6b`, exit 0, 5 tests, 0 failures.
- `make dev-lint`: job `d0932c83-53d0-40cc-8857-1a185bb6e375`, exit 0, 0/2116 files require formatting.

Earlier runs, before the reviews:
- Inspection suite: job `01a06635-3af3-447f-9c36-d70a33dfc2b9`, 25/25.
- Marker suite: job `c683f1dc-cab6-41c8-be72-3bb6e8f5837a`, 5/5.
- Lint: job `90760d26-fee1-413f-9be5-af96659017d2`.

After the R1 test and doc corrections:
- These corrections changed only tests and docs. No production source has changed since job `5ea23e3d`.
- `make dev-test FILTER=ProcessInspectionTests`: job `536fba66-09c3-4209-9dd7-92d0cf747dae`, exit 2. The build stopped on external in-progress startup-reconciliation code in `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStartupReconciliation.swift:314,364` (missing `AgentSessionDataService` members). The renamed test and the new empty-environment assertion have therefore not executed yet.
- `make dev-lint`: job `34b91241-09fa-40a6-b3b5-6ba63e77dd5f`, exit 2. It flagged only `AgentRecoveryStartupReconciliation.swift`, `AgentSessionDataService.swift` and `AgentSessionRestoreSupport.swift`, none of them slice files.
- `Scripts/check-agent-context` passed with the existing route-count warning, and `make guardrails` exit 0.

The conductor filter check rejects combined `FILTER` alternation (exit 64), so each suite runs separately. Neither suite is in the frozen ledger; both run with default deadlines.

## Final validation after shared startup code compiled

The final test-only cleanup was subsequently source-validated in the 26-suite run `edb19409-c5fe-473a-90b7-28c438748301` (exit 0, 421 tests, zero failures or retries). Its filters included both Platform suites: `ProcessInspectionTests` passed 28/28 and `ProcessLauncherRuntimeMarkerTests` passed 5/5. The main agent verified the Conductor job's completed result and filter inventory. The combined startup package also passed lint, guardrails and the context check, as recorded in [cutover evidence](phase1b-cutover.md). There are no remaining P0/P1 implementation/review findings for this bounded slice; signing is available for its separate checkpoint. The final cleanup changed tests and evidence only, not reviewed production behavior, so no additional review round was required.

## Deferred

- Same-UID inventory, descendant traversal, the real Claude descendant's provider home, watchers, `AgentProcessRegistry`, reservations, registration before the first message, and signalling.
- Live gates: marker propagation through both shims, Claude's Bash tool and Codex sandboxed commands; Claude `--session-id` qualification; real `proc_*`/`sysctl` behaviour for zombie, other-UID and hardened targets; whether the shipped Claude build rewrites its process title.
