# Step 9-check review, round 0 — OracleA

Scope: read when the task touches the Step 9-check review of Check and resolve.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA round-0 review of prompt-exports/restart-fixes/check-r0.diff.

The patch adds an app-wide, sequential “Check and resolve” operation with captured items, per-item reporting, Stop, and sheet integration. The pre-activation branch invokes neither ownership refresh nor reconciliation and introduces no direct durable writes. The main concerns are the refresh completion guarantee and reporting around reconciliation outcomes.

Review is limited to the supplied code. Validation results are worker-reported; the omitted callers and `performRecoveryResumeAction` implementation prevent a complete caller/reentrancy audit.

## P1 — Should fix

### CHECK-01 — Refresh can still return before refreshed restrictions are adopted
**File:** `AgentRecoveryCoordinator+RuntimeOwnership.swift:99–108`

**Scenario:** While `refreshRuntimeOwnership()` awaits `restrictionSnapshot()`, the registry’s change-handler task calls `pullRuntimeRestrictions()`, incrementing `runtimeSnapshotRequest`. The refresh then returns at its generation guard, although the newer pull may still be awaiting its snapshot. Check immediately reads the old catalog and can report an exited process as still requiring attention.

The generation guard prevents stale overwrites, but does **not** establish the completion guarantee this change needs.

**Smallest fix:** Await the superseding pull’s adoption before returning, using a shared adoption task or revision barrier. Add a controlled interleaving test that delays the newer pull and verifies Check cannot proceed against stale restrictions.

### CHECK-02 — Automatic clearing masks a reconciliation failure
**File:** `AgentRecoveryCoordinator+Check.swift:182–190`

**Scenario:** Reconciliation confirms that the provider turn finished but fails to save imported rows. The supplied runner explicitly supports this: `.blocked(text, completion: .confirmed(...))` can record `.importedCompleted` while retaining the failure reason. If that projects to `automaticClear == .resolved`, Check returns **Resolved** before examining `failure`.

**Impact:** The report presents recovery as complete while hiding a failure that may leave the result unavailable locally.

**Smallest fix:** Surface a non-`nil` reconciliation failure before returning the automatic-clear success, while preserving the durable completion evidence that prevents duplicate sending. Test confirmed completion combined with an import/save failure through the actual reconciliation adapter.

## P2 — Consider

### CHECK-03 — Revalidation misses items automatically cleared while Check waits
**File:** `AgentRecoveryCoordinator+Check.swift:172–179`

**Scenario:** Check is awaiting an earlier item when another window finishes reconciling a later captured run. That later card becomes automatically cleared without necessarily changing its original run payload or acknowledgement. The current guards inspect neither `isHidden` nor `automaticClear`, so Check can reconcile the already-cleared card again.

**Impact:** Unnecessary provider-history work and action-record writes; superseded cards can also receive inappropriate “Continue it or dismiss” guidance.

**Smallest fix:** Handle current automatic-clear/hidden state before invoking reconciliation. Report the actual clearing reason where established; otherwise skip the changed item. Add a test where another action clears a captured card before its turn.

### CHECK-04 — Successful, inconclusive observations are reported as failures
**Files:** `AgentModeViewModel+RecoveryCheck.swift:69–73`; `AgentRecoveryCoordinator+Check.swift:182–190`

**Scenario:** The runner defines `.nothingImported` as a **successful observation** that establishes neither completion nor new rows. The worker report confirms that its explanatory text—including “Codex has no matching record”—is returned through the adapter’s failure string and displayed as **Failed**.

**Impact:** A normal inconclusive check is indistinguishable from a transport, read, or save failure.

**Smallest fix:** Preserve a typed distinction between successful-but-unconfirmed observation, inability to check, and actual failure. Map successful unconfirmed observations to the appropriate named user choice rather than `.failed`.

## Recommendations

- Fix CHECK-01 and CHECK-02 before closing this review.
- Add integration tests for the ownership-refresh interleaving and real runner-to-report outcome mapping; the injected reconciliation tests do not cover these paths.
- Keep activation separate. Verify C2 with the documented open-session limitation and temporary Codex observation process explicitly accounted for; current unit-test results are not live acceptance.