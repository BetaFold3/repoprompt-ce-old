# Step4d1 initial review — OracleB

Scope: read when the task touches the Claude outbound identity source or its bounded review.
Authority: Reference
Last-verified: 2026-10-23

Snapshot `2026-10-23/1838`; preset `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C`; chat `step4d1-outbound-identit-72FB10`; operation `5A92DA69-BF5B-4BB1-A30B-AB7AF913B896`. Full response follows.

# Oracle Review



# Step 4d1 review: bounded Claude outbound identity (snapshot 2026-10-23/1838)

## Summary

This change lets the Claude user frame carry an optional top-level `uuid`. The single `writeAdmission` hook now returns a typed verdict (`denied`, or `admitted` with an optional UUID) and takes one Bool from the transport saying whether its launch is eligible. A new `OutboundUserMessage` claim (`uuid` plus a SHA-256 of the provider-bound text) is saved inside the existing per-dispatch baseline, in the same zero-row receipt, before any bytes. The admission now re-checks for an existing baseline after each await, and the handoff states whether its user-item list is complete.

I traced the paths in the step contract against the code:

- The gate-off, unsupported, untracked, already-recorded (including a joined pending receipt) and ineligible-launch paths all send the ordinary frame with no UUID.
- Denied, cancelled and stale-owner paths send zero bytes.
- The codec's default `nil` produces exactly the old frame.
- A legacy baseline is never given a claim later.

I found no P0 or P1 issues. The two P2 findings are a round-trip gap in the new persisted type and a gap in what the stored claim actually tells a future reader. Both matter only once something reads the claim, which this step deliberately leaves out.

---

## Findings

### P2-1: `OutboundUserMessage` loses unknown fields inside the claim

- **Evidence:** `AgentSessionProviderHistoryRecovery.swift:153–171` uses Swift's auto-generated `Codable`. Every sibling type (`NativeItem`, `ImportCommit`, `DispatchBaseline`, the ledger) stores unknown members in `extras` through `HistoryDynamicKey`.
- **Scenario:** A later build adds a field inside `outboundUserMessage`, for example `{"uuid":…,"textSHA256":…,"encoding":"v2"}`. This build loads the session and saves it again (any owner save). The added field is silently removed and the outer baseline still decodes fine. That breaks the "version 7 / unknown members round-trip" rule the file header promises.
- **Impact:** Data written by a newer build is lost when you go back to an older one. No data from this step is lost today.
- **Smallest fix:** Give `OutboundUserMessage` an `extras` dictionary plus a hand-written `init(from:)`/`encode(to:)`, using `HistoryDynamicKey` with known keys `["uuid", "textSHA256"]`, like `ImportCommit`.
- **Optional, same edit:** Reject a `textSHA256` that is not 64 lowercase hex characters during decoding. A malformed claim then lands in `unreadableDispatchBaselines` instead of being accepted.

### P2-2: A saved claim does not prove the UUID was ever written

The claim is saved before bytes, as the contract requires. But there are reachable cases where the claim exists and the frame for that dispatch went out without the `uuid`, or never went out at all:

1. **Joined pending receipt.** Admission A saves the claimed baseline, its receipt commit fails, and A is refused (`RecoveryActions.swift:~978–983`). The receipt stays pending. Retry B of the same dispatch joins it (`RecoveryActions.swift:880–886`), commits it and returns `.alreadyRecorded`. The bytes go out **without** a `uuid`, yet the saved baseline still says the claim was "the instruction to encode `uuid`".
2. **Host returned the UUID, but nothing was written.** Any of these can stop the write after the host admitted the UUID:
   - the coordinator's re-check after the await (`ClaudeAgentModeCoordinator.swift:~2112–2116`);
   - the controller's `Task.isCancelled` or `isInitialized` checks (`ClaudeNativeProcessSessionController.swift:~967, 972`);
   - `sendLine`'s owner check or a failed stdin write (`~1771–1793`).

   The claim stays saved, no frame exists, and `firstDispatchBaseline(runAttemptID:)` can still return this baseline as the run's starting point.

- **Impact today:** none, because nothing reads the claim and production is gated off.
- **Future risk:** A reconciler that reads "claim present but no native entry with that uuid" as "not delivered" or "history not caught up" would get a wrong answer in case 1. It could resend the message (running tools twice) or block forever. The doc comment says the claim is not proof of delivery. It does not say the UUID may be missing from the wire for the claimed dispatch.
- **Smallest fix (docs and plan only, no behaviour change):**
  - Extend the `OutboundUserMessage` doc comment: "May be committed without the UUID ever being encoded (refused-then-joined retry, post-admission supersession, cancellation, or write failure). A missing native entry carrying `uuid` is evidence of nothing."
  - Record in the plan that the later association preflight must treat a claim as "uuid may be absent" and must never infer non-delivery from it.

  Do **not** change the joined-pending path to send the UUID; the step contract explicitly maps it to "no UUID".

### P2-3: The real dispatch path is never tested end to end

- **Evidence:**
  - The coordinator tests (`AgentProviderHandoffTests.swift`, `BaselineRoute`) replace the host decision with the `test_claudeDispatchBaselineAdmission` override.
  - The view-model tests (`AgentRecoveryReconciliationTests.swift:~799–930`) call `admitClaudeDispatchBaseline` directly, with user items added by hand via `session.appendItem`.
- **What this leaves unchecked:** No test takes a real committed durable dispatch through `sendClaudeNativeMessage` and the real `qualifiedOutboundUserMessageClaim` (`RecoveryActions.swift:~1002–1020`). So nothing confirms that a real dispatch's `userItemIDs` are present in `session.items` as `.user` items at admission time.
- **Scenario:** If any real input path adds its user item after the write, or keeps it outside `session.items` (steering, coalesced batches, relocated saved messages), every claim on that path is quietly dropped.
- **Impact:** This fails safe (ordinary send, never a wrong UUID). The risk is a feature that looks finished but never claims, found only during live qualification.
- **Smallest fix:** Add one composition test. Use the `makeBaselineRoute` harness with `eligible: true`, a qualified `recoveryActionRunner`, history homes pointing at a fixture, and **no** override. Assert that the frame's `uuid` equals `dispatchID` and that the saved baseline carries the claim. If the fixture cannot produce real user items, that already answers the question the step brief raises.

### P3-1: The re-check that stops two claims is only safe because nothing suspends

- **Evidence:** `RecoveryActions.swift:949` calls `if let recorded = await admitRecorded()` and then appends synchronously.
- **Why it works now:** `admitRecorded` is a local function that inherits the main actor and does not suspend on the "nothing recorded" path, so nothing can run between the check and the append.
- **The risk:** The `await` keyword hides this. A future edit that adds a real suspension before the `nil` return quietly reopens the race.
- **Fix:** Split the lookup into a synchronous helper (`recordedBaseline() -> DispatchBaseline?`) and call it directly before the append. Keep the async join only for the pending-receipt case.

### P3-2: The concurrency test does not force the two admissions to overlap

- **Evidence:** `testConcurrentAdmissionsOfOneDispatchNeverBothMintTheClaim` (~line 886) depends on the off-main history read happening to interleave the two admissions. The worker already flagged this.
- **Fix:** Use `test_saveSessionBeforeWriteHook` or a gated `test_recoveryClaudeHistoryHomes` to hold admission A after its read. Run B to completion, then release A. Assert exactly one `.admitted(dispatchID)`.

### P3-3: The coordinator passes on any UUID the host returns

- **Evidence:** `ClaudeAgentModeCoordinator.swift:~2117` returns `admission` unchanged. The controller encodes whatever UUID it receives.
- **Scenario:** Only the DEBUG override can return a UUID other than `baselineIdentity.dispatchID` today.
- **Fix:** One line of hardening: replace any `.admitted(u?)` where `u != baselineIdentity?.dispatchID` with `.admittedWithoutIdentity`.

### P3-4: An unreadable baseline lets the same dispatch claim again

- **Scenario:** A baseline for the dispatch that this build cannot read (for example, a newer claim shape after a downgrade) makes `dispatchBaseline(dispatchID:)` return `nil`. The same dispatch then saves a second baseline and could get a second claim.
- **Assessment:** This already applied to unreadable baselines before this change, and it needs a downgrade in the middle of a dispatch, so it is contrived. P2-1 makes it less likely; also checking `unreadableDispatchBaselines` for a matching `dispatchID` would close it.

---

## Accepted limits (stated by the worker; not findings)

- Launch eligibility (`automaticResolved` + `defaultClaude` + no routing keys) does not prove the binary is genuine, does not exclude wrappers, and does not check the CLI version. An automatically found `claude` on `PATH` may be a wrapper or an old CLI whose handling of a top-level `uuid` is untested. This belongs to the later CLI qualification, not this inactive slice.
- `hasCompleteUserItems` is checked in both `AgentProviderHandoff.dispatchBaselineIdentity` and `qualifiedOutboundUserMessageClaim`. The duplication is reasonable defence in depth, since the host may not trust the identity it receives.

---

## Recommendations

1. **Fix P2-1 now.** It is cheap, local, and keeps the persisted claim consistent with the round-trip rule every sibling type follows.
2. **Fix P2-2 with docs and a plan note only:** clarify the claim's meaning on `OutboundUserMessage` and record the requirement for the future preflight. Keep the joined-pending behaviour as the contract defines it.
3. **Add the P2-3 composition test if the fixture supports it;** otherwise list it as deferred and make it a precondition for live qualification. It is the only check that the claim actually fires on real dispatch paths.
4. P3-1 through P3-4 are cheap and optional; P3-1 and P3-3 are a few lines each and worth taking along. Defer the rest.
5. With no P0/P1 open, the step can be committed after the P2-1 fix and the doc note are re-validated with `AgentRecoveryReconciliationTests`. Production activation stays OFF and live acceptance stays pending.
