# Step 9-activation-b review round 0: OracleA

Scope: read when the task touches crash-hold confirmation from process-registry proof, the run-start registration mark, or Step 9-activation-b of the lossless app restart plan.
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleA round-0 review

The change adds run-start registration evidence and registry-backed crash-hold confirmation, reuses the durable acknowledgement/publication path, and updates Stop handling and pre-check authorization text. The registry query handles mixed instances and excludes current-instance records appropriately; the supplied stop implementation supports accepting `.stopped` as terminal. Review scope is `actb-r0.diff`, excluding the other worker’s deletion/popover changes. Reported validation was not independently run.

## P1 — Should fix

### P1-01 — Card freshness is not enforced at the acknowledgement write
**File:** `AgentRecoveryCoordinator+CrashHoldProof.swift:105–121,185–193`

**Failure scenario:** A Dismiss commits after the final catalog check—or has committed but its asynchronous catalog update has not arrived. The closed-session transaction then obtains the **latest** store revision and writes the crash-hold acknowledgement. Consequently, the dismissal need not cause a revision conflict, and the retry loop does not protect against this race. The supplied store contract validates the held attempts’ existence, not the captured card acknowledgement.

**Impact:** Check can confirm a card that changed while being checked, lifting admission and potentially releasing scheduled sends despite the required freshness refusal. The existing dismissal test waits for catalog adoption *before* the final check, so it does not exercise this window.

**Smallest fix:** Pass the captured card acknowledgement/freshness into the acknowledgement transaction and validate it atomically against the stored record before writing, for both destinations. Add a deterministic test that commits Dismiss after the coordinator’s final check but before the acknowledgement mutation; assert no crash-hold acknowledgement is written.

## P2 — Consider

### P2-01 — Registration-mark provenance depends on independently matching configuration
**File:** `AgentTabSession.swift:829–835,2011–2017`; `AgentRunStartProviderRecordingTests.swift`, `testRunStartMarkFollowsTheLaunchersResolvedAuthority`

The new session-owned `runtimeLaunchAuthority` derives the mark, but the supplied changes do not make the managed launchers consume that same value or obtain it from those launchers. Matching `.production` defaults establish today’s default behavior, not F2’s structural guarantee.

**Failure scenario:** An injected launcher uses `.activationOff` while the session’s separate authority is `.registry`; the dispatch records `"registry"` despite unregistered execution. Conversely, mismatched configuration can unnecessarily disable automatic confirmation. The new provenance test changes only the session authority and never exercises a launcher, so it cannot detect this discrepancy.

**Smallest fix:** Resolve one launch authority and share it between the actual launcher and mark derivation. Exercise off/uncovered/covered cases through that shared configuration. This is P2 because the supplied production configuration is reported to use matching defaults; a production mismatch is not demonstrated.

### P2-02 — The new confirmation path lacks the required scheduler integration test
**File:** `AgentRecoveryCrashHoldProofTests.swift`, `testClosedSessionHoldIsConfirmedFromProofWithoutOpeningAndStaysConfirmed`

The test proves persistence and removal of `blockingCrashHold`, but not that an already-authorized scheduled send remains blocked until the acknowledgement commits and dispatches exactly once afterward.

**Impact:** A publication or scheduler-wakeup regression could pass these tests while breaking the behavior explicitly disclosed to users.

**Smallest fix:** Extend the existing scheduled-send crash-hold test to confirm through Check, pausing the acknowledgement commit to assert zero dispatches before success and exactly one afterward.

## Recommendations

- Fix **P1-01** before approval and add the actual commit-boundary race test.
- Bind mark provenance to the launcher’s shared authority before activation.
- Add the scheduler integration assertion and rerun the affected suites. Keep production activation off in this step.
