# Step 7-F3F6 — OracleB initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F3F6 (recovery banner header and quit-failure dialog wording) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F3/F6, local fix-f3f6-review.diff, worker report); preset identity verified from the result.

# Oracle Review



# Review: Step 7-F3F6 (recovery banner header and plain failure wording)

**Summary.** I reviewed the diff and the attached spec excerpts only. I didn't have the repository, so I couldn't run anything or grep it; the items in Recommendations are things to grep or run.

The diff fixes F3 by moving the banner header into `AgentRecoveryListProps.headerText`. The header now keeps "this session" and "elsewhere" counts separate and never says "0 items" next to a non-zero Needs Attention button. It fixes F6 by classifying storage failures where the store throws them. `classifiedStorageFailure` reads Cocoa and POSIX error codes and walks underlying errors; it never parses text. The diff then shows only plain wording on the quit dialog, the run-service and runner "delivery not recorded" messages, the startup-failure state, the recovery-list rows and actions, the scheduled-send messages and the restart-dialog reason.

I checked the following and found them sound:
- **Failure handling is unchanged.** Every changed site keeps its result: `.failed`, `.notAdmitted`, `.notProven`, `.heldForRecovery` and the shutdown blocker list. `AgentRecoveryStoreError` is not `Codable`, so its new associated value changes nothing on disk.
- **The cause mapping is correct** for the codes listed and never reads strings.
- **F3 counts are right** for zero here with some elsewhere, one, many, empty, loading, failed and the paused-indicator row.

Nothing rises to P0 or P1. The findings are below.

## P2

### R1 — The scheduled-send refusal message is one fixed sentence, which can be wrong and drops the cause
- **Evidence:** `AgentModeViewModel+ScheduledSend.swift:~3271-3273`, `case .failure(.refused): return .notAdmitted("Scheduled sending is paused until this session's recovery state is ready.")`
- **Failure scenario:** The admission refusal can have a cause that won't clear in this launch. Examples: recovery startup failed (which this diff now turns into plain permission or disk-full text), the lane was retired, or shutdown is in progress. In those cases the user is told sending is "paused until … ready". That suggests it will resume on its own, when it won't. The old text at least said the message "could not be saved for recovery"; the new text drops that.
- **Impact:** The user may wait for a send that never happens, and the now-actionable startup cause (for example, disk full) is thrown away at this site. The refusal is also no longer visible anywhere, because no log was added.
- **Smallest fix:** Switch on the refusal cases. Pass the startup-failed reason through; it is already plain. Use the "paused until ready" wording only for the "not ready yet" case. Log the refusal case as a fixed token. If `.notAdmitted` is final for those refusals, this is P1.

### R2 — Raw failure detail now disappears from several sites without being logged
- **Evidence:** `AgentModeViewModel+RecoveryList.swift:~937, ~1132, ~1250, ~1256, ~1278`; `+RecoveryActions.swift:176`; `+ScheduledSend.swift:~3274` (`.commitFailed`) and `~3389` (delivery evidence). Logs were added only for shutdown (`shutdownBlocked`), startup (`startupFailed`) and the registry (`runtimeRecordsUnreadable`). The runners and run service were already covered by `AgentDeliveryRecordDiagnostics`.
- **Failure scenario:** A recovery action fails with an error the classifier marks `.other`, or with a non-storage store error (`revisionConflict`, `intentConflict`, …). The UI says "saving to disk failed". The raw failure used to be in that text; it is now in neither the UI nor a log, unless the lane or store already logs it, which the report doesn't claim.
- **Impact:** The spec says "Keep the raw detail in redacted logs." With this change, these failures can't be diagnosed after the fact.
- **Smallest fix:** Add one `AgentRecoveryFailureDiagnostics.presentationFailure(site:failure:)` helper. It should log `diagnosticName` publicly and `String(describing:)` privately, and be called at these sites. Alternatively, cite where the lane already logs these failures.

### R3 — The startup-failure text is a fragment, and on its own it may lack context
- **Evidence:** `AgentRecoveryFailureWording.swift:82-89` returns a clause with no trailing period. For disk full it returns the bare cause, "the disk is full; free up some space", which starts lowercase. `AgentRecoveryCoordinator.swift:930` stores that clause in `startupState = .failed(...)`, and the report says this string reaches the banner. `headerText` renders `.failed(message)` exactly as given.
- **Failure scenario:** If the banner shows the startup state directly, the header reads "the disk is full; free up some space". It has no capital, no period, and nothing saying that recovery couldn't start. The permission and "other" variants, by contrast, are full sentences without the period, so the three are inconsistent.
- **Impact:** The wording is unclear in the one place the user sees it.
- **Smallest fix:** Make the startup text one complete sentence that includes context, for example "Recovery couldn't start: the disk is full. Free up some space and reopen RepoPrompt." Then check the scheduler and refusal code that wraps this string, so the punctuation doesn't double up.

### R4 — The focused test run skips the suites most likely to check the changed messages
- **Evidence:** The filter includes `AgentProviderHandoffTests` and one scheduled-send suite. It does not include run-service tests, the Claude, ACP or headless runner tests, or other scheduled-send and recovery-list suites. These message prefixes were changed:
  - "run attempt not recorded:"
  - "could not be saved for recovery ("
  - "Delivery evidence could not be read:"
  - "Runtime records are unreadable:"
  - "couldn't be read ("

  The full suite (`make dev-test-parallel`) was not run.
- **Failure scenario:** A test, or production code, that checks one of these prefixes with `contains` or `hasPrefix` now fails or quietly takes another branch.
- **Impact:** The check you asked for ("any message that tests or other code match on") hasn't actually been done.
- **Smallest fix:** Grep `Sources/` and `Tests/` for each old prefix, then run the full root test suite once.

### R5 — `recoveryCompositionFailure` is the same kind of leak, reaches the same banner, and wasn't audited
- **Evidence:** The report's audit list says `AgentModeViewModel+RecoveryList.swift:16`, "Its producers were not audited, and the string is shown verbatim."
- **Failure scenario:** One of the `failRecoveryComposition(...)` callers passes `String(describing: error)`. The banner then shows raw `Domain=` or path text, which is exactly the F6 symptom.
- **Smallest fix:** Grep for `failRecoveryComposition(` callers. Route any raw-error caller through `startupFailureDescription` and the startup diagnostics log.

## P3

### R6 — The default `cause: .other` lets the classification be skipped silently
- **Evidence:** `AgentRecoveryStore.swift:137`. The report says other `.storageFailure("…")` constructions still exist.
- **Failure scenario:**
  - Any remaining `throw .storageFailure(String(describing: error))` site, including future ones, shows "saving to disk failed" even when the real cause is permission or disk full.
  - Separately, any `case let .storageFailure(x)` pattern now binds a `(String, cause:)` tuple. If that value is put into text, the output changes shape.
- **Smallest fix:** Grep `storageFailure(String(describing:` and convert what remains. Consider removing the default so the compiler forces each site to classify.

### R7 — The permission wording says "write" for read failures and read-only volumes
- **Evidence:** `AgentRecoveryStorageFailureCause` maps `NSFileReadNoPermissionError` and `NSFileWriteVolumeReadOnlyError`/`EROFS` to the permission cause (`AgentRecoveryFailureWording.swift:34, 43`). The text at line 59 is "doesn't have permission to write to its data folder; check that folder's permissions".
- **Failure scenario:** The runtime directory can't be read at startup (code 257), or the volume is read-only. The advice points at the wrong fix. This is also an open question in the worker report.
- **Smallest fix:** Use neutral text, for example "RepoPrompt can't access its data folder; check that folder's permissions and that its disk is writable".

### R8 — The "delivery not recorded" sentence is duplicated, and "It stays saved" is unchecked on the runner paths
- **Evidence:** `AgentProviderHandoff.swift:~538-540` hard-codes the sentence. Previously, `AgentModeRunService.swift:682` built it from `dispatchFailureText(failure)`. The three runners use the same new text in their `attachRunAttempt` failure branches.
- **Failure scenario:**
  - `dispatchFailureText(.commitFailed)` and the new constant drift apart.
  - In the headless runner (which throws `deliveryNotRecorded`), or in the Claude and ACP runners (which finalize with `sent: false`), the input may not actually stay saved. The message would then tell the user something false.
- **Smallest fix:** Build the text from `dispatchFailureText` plus the plain cause. Confirm that each runner path keeps the input saved before saying so.

### R9 — The registry logs on every failed refresh, not once
- **Evidence:** `AgentProcessRegistry.swift:~230, ~270` add `runtimeRecordsUnreadable` inside the `refresh()` catch blocks.
- **Failure scenario:** The records stay unreadable, so every refresh (start, proof, publish triggers) writes another `.notice` line. The report's "logged once" is not accurate.
- **Smallest fix:** Log only when the failure first appears or its value changes (`storageFailure` going from nil to a value).

### R10 — A composition-test assertion only runs if a condition holds
- **Evidence:** `AgentRecoveryStartupCompositionTests.swift:~358-362` checks `if pausedProps.otherItemCount > 0 { … }`.
- **Failure scenario:** The fixture's count is fixed. If it is 0, the "both counts stay separate" check on the real view model never runs.
- **Smallest fix:** Assert the fixture's actual `otherItemCount` exactly, then assert the exact header string.

## Recommendations
1. Fix R1 and R2 before committing; both are small, contained edits.
2. Do R4's grep and run the full root test suite once. It's the cheapest way to confirm that no code or test depends on the old message prefixes.
3. Do R3, R5 and R7 together as one wording pass. Owner choices, with my recommendation: use the neutral read-only wording (R7), and keep the "paused until ready" text only for the "not ready yet" refusal (R1).
4. R6 and R8 through R10 can be deferred, or done now if they turn out cheap. R6's grep is worth doing in the same pass as R4.
5. Docs that need no review: the spec's F3 and F6 entries still say "Open; not fixed". The Step 7-F3F6 status line needs to link `evidence/2026-10-18-lossless-app-restart/fix-f3f6-worker.md` to clear the `check-agent-context` reachability error.
6. Before marking the step done, re-check the `cycle8.H_shutdownFault` case (quit with permission denied) on the live app. It is the only end-to-end proof of the dialog wording, and it is visible to the user, so it needs the owner's approval first.