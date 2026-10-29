# Step 9-check worker report (Check and resolve)

Scope: read when the task touches Check and resolve in the Needs Attention sheet (Step 9-check).
Authority: Reference
Last-verified: 2026-10-26
Covers: the pair worker's verbatim reports for Step 9-check, round by round.

## Round 0 — implementation

I've built "Check and resolve" in the Needs Attention sheet. Before activation it is report-only, and its pre-activation report reads "Process and provider-history checks are not active." Build, lint and guardrails pass, and both test suites I ran pass. Nothing is committed or staged, and the app was not launched.

**Existing entry points**
- **Ownership refresh:** `AgentRecoveryCoordinator.refreshRuntimeOwnership()` (`AgentRecoveryCoordinator+RuntimeOwnership.swift:99`). The row's Refresh calls it (`AgentModeViewModel+RecoveryList.swift:818-821`). It does nothing when no process registry is attached; production attaches one at `AgentRecoveryAppComposition.swift:82`. It used to adopt the new snapshot in a background task, so a caller re-reading the catalog could still see the old restrictions. It now waits for the snapshot before returning. That is the only change to existing behavior.
- **Reconcile-only:** `performRecoveryResumeAction(rowID:action: .reconcileHistory)` (`AgentModeViewModel+RecoveryActions.swift:117`) runs through `AgentRecoveryActionRunner.perform` (`AgentRecoveryActionRunner.swift:175`). Its gate is `isAvailable(.reconcileOnly)`, which needs the qualification flag and active process registration (`:154`). The window's runner is set to `.production` at `AgentModeViewModel.swift:679-681`, which turns everything off.
- **Catalog re-read:** `coordinator.catalog.item(id:)` (`AgentRecoveryCatalog.swift:256`).

**What changed**
- New `AgentRecoveryCoordinator+Check.swift`: the result types, the one-at-a-time loop modelled on bulk Dismiss, Stop, clearing the report, and a per-payload classifier that must cover every payload to compile.
- `AgentRecoveryCoordinator.swift`: one stored property, `recoveryCheck`.
- `AgentRecoveryCoordinator+RuntimeOwnership.swift`: the refresh change above.
- New `AgentModeViewModel+RecoveryCheck.swift`: captures the displayed rows and sets "checks active" from the runner's Reconcile gate. It lends the existing Reconcile only for the session open in this window.
- `AgentRecoveryNeedsAttentionSheet.swift`: the button, the report, Stop, and clearing the report when the sheet closes.
- Tests added to `AgentRecoveryCoordinatorTests.swift`.

**Acceptance**
1. **Met.** The three accessibility IDs are in place. The check uses only the items captured at click time, runs one at a time app-wide (a second start returns nothing), and Stop halts before the next item. The report reads "Cancelled: checked 1 of 3, 2 not checked …", and closing the sheet doesn't stop a running check.
2. **Met.** Each item gets one result: resolved, needs you (e.g. "Let it finish or Stop", "Send or discard the saved message", "Answer the question"), could not check, or failed, each with its reason.
3. **Met.** Before activation there is no refresh and no Reconcile; run cards show "Provider history checks are not active." and nothing is resolved. After activation, Check first refreshes ownership, then reconciles each run card that hasn't changed, then re-reads the catalog.
4. **Met, with one cut.** The only possible writes are Reconcile's history imports and its action record. I did **not** build crash-hold confirmation. It needs a registry check that every relevant process exited, and that check doesn't exist. The existing confirm path also only works by opening the session. I suggest moving it to 9-activation. No qualification flags, registration or send gates were changed.
5. **Met.** There is no confirmation dialog. Once checks are active, the report header says "Clearing a restriction may let already-authorized scheduled sends run." The process refresh is the only thing that can clear a restriction.
6. **Met.** The four new tests cover the pre-activation path (no writes, no Reconcile), Stop and one-at-a-time, classification of representative items, and the post-activation path. The post-activation test switches checks on directly; no new tooling was needed.

**Validation:** `make dev-build` passes. `make dev-lint` passes after I hand-fixed 2 formatting findings in my own files (I didn't run `dev-format`). `make guardrails` passes; its only warning is an existing one about AGENTS.md having too many routes. `AgentRecoveryCoordinatorTests` ran 70 tests with 0 failures, including the 4 new ones. `AgentRecoveryRuntimeOwnershipTests` ran 10 with 0 failures.

**Things to decide for 9-activation / C2**
- **Open session only:** Reconcile only works for the session open in that window. Others report "Open this session to check its provider history." So for C2 the verifier has to open the finished Codex session first, unless you want a lookup that doesn't need it open.
- **Codex starts a temporary process:** after a cold relaunch, the existing Codex Reconcile starts a temporary read-only `codex app-server`. That arguably conflicts with "never start a provider". It isn't active yet.
- **"Stop" wording:** the surviving-process text says "Let it finish or Stop" as you specified, but Stop isn't offered yet.
- **Failure wording:** any Reconcile failure text is reported as "failed", including "Codex has no matching record". Splitting that out would need a change to the action function's return value.
- **Plan document:** I didn't edit the lossless-restart plan or synthesis docs to mark 9-check done.


## Round 1 — fixes for the round-0 reviews (worker report, verbatim)

All seven fixes are in, and the four test suites I ran pass. `make guardrails` fails only on docs reachability for the two new review files, as you expected. Nothing is committed and I staged nothing. `git status` does show my two new Swift files as `A`, but the staged diff is empty, so someone else probably marked them intent-to-add; I didn't.

**CHK-1 is real.** Record commits reach the coordinator through `store.commitPublisher.setHandler { Task { @MainActor in self?.adoptRecordCommit(commit) } }` (`AgentRecoveryCoordinator.swift:559-562`). The catalog only changes in `adoptRecordCommit` (`:584-589`), one hop later, so a catalog re-read straight after Reconcile can still show the old card. The old test's `fixture.perform` only passed because it waits for that adoption itself.

**Timeout finding (fix 6).** There is no Stop-reachable bound on the Reconcile path:
- **Codex:** the observation passes `timeout: 15` (`AgentModeViewModel+RecoveryActions.swift:1323`) into `CodexNativeSessionController.observeRecovery` (`:1806`). There it only bounds the two read requests (about `:1857` and `:1877`). `client.startIfNeeded` and `associateObservedConversation` (`:1826-1835`) take no timeout from this path.
- **Claude:** the history read is a synchronous file read with no timeout (`readClaudeHistory`, RecoveryActions `:~1267`).
- **Both:** the runner's lane transaction waits have no timeout, and neither does the ownership refresh discovery.

A hung Codex cold start can therefore hold the check until the app quits. Your call.

**Per fix**
1. **Typed outcome, not a re-read.** `performRecoveryResumeAction` takes an optional `report:` box (RecoveryActions `:124`). It records the runner's result (`:233`) and the history observation it ran (`:228`); no other caller changes. The check maps that in `AgentRecoveryCheckReconcile.outcome` (`AgentRecoveryCoordinator+Check.swift:59`):
   - confirmed completion with rows saved → resolved;
   - confirmed completion with a save failure → failed, naming the failure (the runner's completion record is untouched);
   - unconfirmed, nothing imported, or association unavailable → needs you, "Continue it or dismiss the note…";
   - refused, disabled, already joined, prior launch's action, or provider without history → could not check, with the reason;
   - transport/read failures and unrecorded outcomes → failed.

   Refusals that happen before the runner (session not open, record unreadable) are reported as could not check. One test goes through the real view-model path, using the existing Reconcile test harness: `testCheckReportsTheRealReconcileTypedResult` in `AgentRecoveryReconciliationTests`. A Claude card with no pre-send baseline comes back as needs you, nothing imported, and the row is not left busy.
2. **Refresh waits for an adoption at least as new as its own.** There is a new `runtimeSnapshotAdopted` counter (`AgentRecoveryCoordinator.swift:542`). `adoptRuntimeRestrictions(_:request:)` (`+RuntimeOwnership.swift:154`) skips a snapshot only when a newer request is already adopted. Refresh (`:101`), the background pulls and startup all use it. Test: `testRefreshAdoptsAtLeastItsOwnSnapshotBeforeReturningAndNeverGoesBackwards`. It runs two overlapping refreshes held by the existing inventory hook and checks the ordering rule deterministically. The existing fakes can't pause `restrictionSnapshot()` itself, so the exact supersession timing isn't forced.
3. **Cleared while waiting.** A card cleared or dismissed while the check waited is reported from that state and never reconciled (Check `:243-248`). Clearing reasons come from `checkClearText` (`:265`). Covered in `testCheckAfterActivationReportsEachReconcileResult`, where another action resolves a later card first.
4. **No exit claims for vanished items.** A vanished item reports "It is no longer listed." (`:236`). "The process exited." appears only when the adopted snapshot lacks that runtime ID and has no global uncertainty (`runtimeExitIsProven`, `:259`). Tested both ways: proven exit in `testCheckRefreshesOwnershipFirstAndReportsAProvenExit`, and a survivor with no registry stays unclaimed.
5. **Help text.** With checks active it now reads "Refreshes process ownership and checks provider history… Clearing a restriction may let already-authorized scheduled sends run." It no longer says nothing can be sent (`AgentModeViewModel+RecoveryCheck.swift:62`, sheet `:57`).
6. **Refreshing phase.** Progress shows "Refreshing process ownership…" during the refresh, or "…Stopping before the first item." if Stop was pressed (Check `:188`). It is tested in the proven-exit test. In-flight work is still not cancelled.
7. **Neutral reason and real totals.** The active path now says "This card needs action; Check doesn't reconcile it." (`:250`). The button's enable state and the total both use `recoveryCheckItems(rows)` (RecoveryCheck `:56`), i.e. visible rows that have a catalog item.

**Files changed:** `AgentRecoveryCoordinator+Check.swift`, `AgentRecoveryCoordinator+RuntimeOwnership.swift`, `AgentRecoveryCoordinator.swift`, `AgentModeViewModel+RecoveryCheck.swift`, `AgentModeViewModel+RecoveryActions.swift`, `AgentRecoveryNeedsAttentionSheet.swift`, and tests in `AgentRecoveryCoordinatorTests`, `AgentRecoveryRuntimeOwnershipTests` and `AgentRecoveryReconciliationTests`. The other modified files in the tree (`WorkspaceSwitchRecoveryTests`, `ClaudeAgentModeCoordinatorMCPRecoveryTests`, the lossless-restart spec, `fix-check-worker.md`) aren't mine.

**Validation**
- `make dev-build`: passes.
- `make dev-lint`: passes after hand-fixing my own formatting; `dev-format` was not run.
- `make guardrails`: source-layout and allowlist checks pass. The only errors are the reachability ones for `fix-check-review-oraclea.md` and `fix-check-review-oracleb.md`, plus the existing route-count warning.
- `AgentRecoveryCoordinatorTests`: 71 tests, 0 failures.
- `AgentRecoveryRuntimeOwnershipTests`: 12 tests, 0 failures.
- `AgentRecoveryReconciliationTests`: 53 tests, 0 failures.


## Round 2 — cheap fixes after re-review 1 (worker report, verbatim)

All three fixes are in. Build and lint pass, and all four requested suites pass with 0 failures.

**Fixes**
1. **R1-1 (startup ordering): done.** `startRuntimeOwnership` now takes its request number only after `registry.start()` returns (`AgentRecoveryCoordinator+RuntimeOwnership.swift:134-138`). A background pull that read part-way through start can no longer win over start's final snapshot. I added no test: the fakes can't pause `start()` part-way, so it isn't trivial. The startup and runtime-ownership suites still pass.
2. **R1-2 (confirmed and saved → resolved): new test through the real path.** `testCheckReportsAConfirmedAndSavedCodexCompletionAsResolved` (`AgentRecoveryReconciliationTests.swift:3913`) reuses the existing cold-Codex tooling. A fake controller reports the turn completed, Check runs the real Reconcile, the rows are imported, and the card is reported resolved. Nothing is sent and no thread is started or resumed.
   - For the record, the runner contract: on a reconcile-only action, `.imported(completion, _)` sets the outcome and leaves `reason` nil (`AgentRecoveryActionRunner.swift:250-251`). Only `.blocked(text, completion)` sets `reason = text` (`:252-254`). The 300-character cap (`:293`) only shortens a reason that is already set.
3. **R1-3 ("already made" wording): done, with one correction.** `performRecoveryResumeAction` never returns nil before reaching the runner; all of its early returns carry text. "Found already performed" comes back from the runner as a joined result, which the round-0 code reported as "already in progress".
   - Both the joined result and the unreachable empty-report fallback now report "Could not check: A choice on this card was already made. Review it on the card." (`AgentRecoveryCoordinator+Check.swift:52,70`; `AgentModeViewModel+RecoveryCheck.swift:100`).
   - The mapping test has a new row for the joined case.

R1-4 and R1-5 were not touched, as instructed.

**Files changed:** `AgentRecoveryCoordinator+RuntimeOwnership.swift`, `AgentRecoveryCoordinator+Check.swift`, `AgentModeViewModel+RecoveryCheck.swift`, `AgentRecoveryReconciliationTests.swift`, `AgentRecoveryCoordinatorTests.swift`. Nothing is committed or staged.

**Tests**

| Suite | Tests | Failures |
|---|---|---|
| `AgentRecoveryReconciliationTests` | 54 (one new) | 0 |
| `AgentRecoveryCoordinatorTests` | 71 | 0 |
| `AgentRecoveryRuntimeOwnershipTests` | 12 | 0 |
| `AgentRecoveryStartupCompositionTests` | 16 | 0 |
