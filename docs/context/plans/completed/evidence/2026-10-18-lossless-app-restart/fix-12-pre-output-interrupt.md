# Step 12: gated acceptance for interrupts before first output
Scope: read when the task touches a Claude steer or Stop that lands before the turn's first visible output, completion origin, or FIFO turn attribution.
Authority: Reference
Last-verified: 2026-10-29
Covers: failing-first test, negative twins, gated acceptance, attribution rule, validation, and the review round

## Decision implemented

OracleB's gated acceptance (owner decision, final). A written Claude message whose turn was **not** credited as started, and which RepoPrompt's own steer or Stop interrupts, settles `providerAccepted` only when **both** hold:

1. the interrupt outcome was `.acknowledged`; and
2. the CLI itself emitted a provider-authored `.cancelled` result for that exact turn.

Completions the controller synthesizes never count: idle fallback, shutdown or queue flush, and EOF or protocol-failure drain. Everything else stays `deliveryUnknown`.

The decision rejects the following, so they were not implemented:
- accepting on the acknowledgement alone;
- crediting from an early payload;
- enabling partial messages;
- making rows informational on "run ended normally".

**Owner rulings after review round 1:**
- Keep the stricter arrival-time rule.
- Keep idle fallback and shutdown flush counted as synthesized.

**Final re-review fixes (Q1/Q2):**
- **Q1.** Acceptance requires affirmative identity: the result must name T's outbound UUID (`.namesTurn`). Unattributed results no longer qualify.
- **Q2.** A started turn that still carries an acknowledged unstarted mark gets no O49 mark, on either the steer or the teardown path. It stays `deliveryUnknown`.

## Confirmed facts

Line numbers refer to `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift` unless noted otherwise. They are current as of the post-review fixes.

**Turn tracking in the controller**
- **CLI launch.** `buildArguments` (:4545, flags at :4554) passes `-p --verbose --output-format stream-json --input-format stream-json`. It never passes `--include-partial-messages`, so a turn has no early `stream_event`.
- **Reasoning extraction is off.** `ClaudeReasoningExtractionFeature.isEnabled = false` is set at `ClaudeSDKNDJSONTranslator.swift:5`.
- **Started-turn credit.**
  - `creditsStartedTurn` (:2707) is true only for `assistant` and `stream_event` payloads.
  - Started-turn evidence is recorded by `noteOutputAttributedToProducingTurn` (:5118).
  - So a turn interrupted before its first assistant payload is never credited as started.
- **Results are attributed by queue position, not identity.** `beginTurnTracking` (:5087) appends to `pendingTurnIDBuffer`. `dequeueTurnID` (:5104) pops the head when a result arrives.
- **Single writer.** `sendUserMessage` → `beginTurnTracking` (:1190) is the only path that adds FIFO entries. The coordinator's `sendClaudeNativeMessage` is its only caller.
- **The interrupt marker is sticky.**
  - `interruptTurn` (:1196) sets `turnWasInterrupted` only when the control response is acknowledged (:1207).
  - `determineTurnStatus` (:3370) then classifies the **next** result as `.cancelled`, whatever that result is and whichever turn it is credited to.

**What the interrupted result itself carries**
- **The SDK subtype is ambiguous.** The CLI's subtype for an aborted turn is `error_during_execution`, which the SDK documents as "API failure OR cancelled request" (`docs/investigations/claude-g1-probe-harness.py:39`).
- **Observed on interrupts.** An interrupt produced an `error_during_execution`/`aborted_streaming` result (`docs/context/plans/2026-09-13-agent-usage-and-wait-efficiency-plan.md:188`).
- **Existing cancel words.** `isCancelledTurnSignal` already matches `interrupt`, `cancel` and `aborted`.

**Per-turn identity on results**
- **Live captures show the echo on success results.** On Claude 2.1.302, the CLI echoes the outbound frame `uuid` as `user_message_uuid` and `user_message_uuids` on `result` envelopes:
  - `phase4d-no-replay-capture.md:85`
  - `phase4d-claude-capture.md:50`
  - `phase4d-tool-resume-capture.md:59`
- **Where it was parsed before.** Only `ClaudeLiveTranscriptQualification.attribution` (`ClaudeLiveTranscriptQualification.swift:496-509`) parsed it, with result keys listed at :343-347.
- **Not universal:**
  - The outbound `uuid` is sent only on identity-eligible launches that also have a write admission (:1088, :1125-1131). Those are first-party backends with automatic or configured command provenance and no routing environment keys.
  - No capture shows the field on an **interrupted** result.
- **Positional fields are not identity.** `result_index` is positional, so it is not identity evidence.

**Coordinator ordering** (`ClaudeAgentModeCoordinator.swift`)
- **Steer.** `interruptClaudeTurnIfNeeded` (:2800, called at :2441) runs before the steer's own `sendUserMessage` write (:2666).
- **Stop.**
  1. `noteRepoPromptTeardownRequested` marks started turns only.
  2. `prepareClaudeCancelSync` detaches the controller, and run end settles the message `deliveryUnknown`.
  3. `cancelClaudeRunAndCaptureSessionRef` (:3028) then interrupts, waits 200 ms after an acknowledgement, and shuts down.
  4. Results from the detached controller still reach `noteClaudeTurnCompleted` through the draining router, so a late `noteAccepted` refines `deliveryUnknown`.

## Attribution rule and why

A provider `.cancelled` result counts for the targeted turn T only when every check below passes. This is `isExclusiveInterruptedResult`, at :96 (identity condition at :100).

1. **At issue time (coordinator).** T is the sole written-but-unresolved turn for that controller when RepoPrompt issues the interrupt (`soleUnresolvedWrittenTurnID`, `ClaudeAgentModeCoordinator.swift:2029`). This is the owner's conservative rule.
2. **At arrival time (controller).** When the result is processed:
   - the FIFO holds exactly one outstanding turn; and
   - in deferred mode, no earlier result is still waiting for `idle`.
3. **Payload evidence (P1-A).** The result payload itself reports an interruption (`resultPayloadReportsInterruption`, :3761), independent of the sticky marker:
   - `type == "result"`;
   - the subtype is not `success`;
   - and either the subtype is `error_during_execution`, or the subtype, `stop_reason`, `terminal_reason` or `errors` name a cancellation.
4. **Affirmative identity (P1-A, tightened by Q1).** The result's `user_message_uuid` or `user_message_uuids` must name exactly the outbound UUID that the credited turn was written with (`resultMessageIdentity`, :3776, must return `.namesTurn`). The per-turn UUIDs are kept in `outboundUserMessageUUIDByTurnID`. Each of these leaves the turn uncertain:
   - absent or null attribution (`.notReported`);
   - a different UUID;
   - a list with more than one entry;
   - a turn that was written without an outbound UUID, so ineligible launches never qualify.

**Why each check is needed**
- **Arrival time.** If the FIFO holds only T, then n−1 results were consumed by n−1 earlier writes, so a later write cannot own this result. Without this check, the "phantom alone" case is falsely accepted:
  1. A skipped message P is steered, and the interrupt is acknowledged.
  2. The steer message S is written, so the FIFO is [P, S].
  3. S's result is classified `.cancelled` by the sticky marker and FIFO-credited to P.
- **Payload evidence.** The sole-turn check proves only that the queue had one entry, not that the CLI processed T. Without this check, OracleA's case is falsely accepted:
  1. A lone skipped P is stopped, and the interrupt is acknowledged.
  2. An unrelated background-continuation or replay result arrives. The sticky marker makes it `.cancelled`, and it is credited to the sole P.

  Such results are `success`, so they now fail check 3.
- **Identity.** Checks 1–3 cannot rule out an unrelated `error_during_execution` (for example an API failure in a background continuation) credited to a sole turn. Requiring the CLI's own attribution of T closes that case (OracleA, final round).

**Mechanism chosen for P1-B: a bounded steer wait, not a UUID substitute.** UUID correlation is not reliable enough to replace the arrival-time check: the CLI sends it only on eligible launches, and it has never been observed on an interrupted result. Since Q1 it is required in addition to the arrival-time check, not instead of it. After an acknowledged interrupt that placed an **unstarted** mark, the steer holds its own write until one of these happens:
- T's evidence is decided;
- the controller has no turn in flight, meaning T's result was processed and its origin fixed;
- ownership is lost;
- `unstartedInterruptResultWaitSeconds` (1.5 s, capped at the interrupt's 1.5 s control timeout) passes.

On timeout the steer is written anyway, and T stays uncertain. Steers that target a started turn, or whose interrupt was not acknowledged, are not held.

## What changed

**`ClaudeNativeProcessSessionController.swift`**
- `TurnCompletionOrigin` (:41):
  - `providerResult(ProviderResultEvidence)` (:54) records `soleOutstandingTurn`, `reportsInterruption` and `messageIdentity`.
  - `MessageIdentity` (:80) is `notReported`, `namesTurn` or `contradictsTurn`.
  - `controllerSynthesized`.
  - `isExclusiveInterruptedResult` (:96), renamed from `isExclusiveProviderResult`. Since Q1 it requires `messageIdentity == .namesTurn` (:100).
- `.turnCompleted` (:181) carries `origin`, defaulting to `.controllerSynthesized`.
- `DeferredTurnCompletion` (:633) keeps the origin of deferred completions.
- `outboundUserMessageUUIDByTurnID` is filled by `beginTurnTracking(outboundUserMessageUUID:)`. It is cleared in `dequeueTurnID` and `clearTurnIDQueue` (:5140), which `drainAllTurnIDs` calls, so the final-round P2 needed no code change.
- Result path (:2781):
  - finds the credited turn by bounds-safe index, since surplus deferred results can outnumber queued turns;
  - computes the evidence, including the deferred-mode `pendingAuthoritativeTurnCompletions.isEmpty` condition;
  - uses that evidence for immediate and deferred emission alike.
- `resultPayloadReportsInterruption` (:3761) and `resultMessageIdentity` (:3776).
- Synthesized emits: idle fallback (:2865), shutdown/EOF flush (:2881), EOF drain (:4019) and protocol-failure drain (:4821). `emitTurnCompleted(turnID:status:origin:)` is at :4028.
- The DEBUG hook `test_beginTurnTracking(outboundUserMessageUUID:)` is at :3531.

**`NativeAgentRuntimeContracts.swift:136`**
- Typealias `NativeAgentRuntimeTurnCompletionOrigin`.

**`ClaudeIntegratedAgentModeRunner.swift`**
- Both `.turnCompleted` handlers forward `origin`.

**`ClaudeAgentModeCoordinator.swift`**
- **New state:**
  - `unstartedInterruptResultWaitSeconds = 1.5` (:143);
  - `WrittenDispatchHandoff.unstartedInterrupt` (:185);
  - `RepoPromptInterruptMark { started, unstarted }` (:190);
  - `UnstartedInterrupt { acknowledged, providerCancelledResultHeld }` (:198).
- **`noteClaudeTurnCompleted`** (:1970). The new case `.cancelled where unstartedInterrupt != nil && origin.isExclusiveInterruptedResult` (:1998) runs after the teardown and `interruptPending` cases:
  - if the interrupt is acknowledged, it accepts;
  - otherwise it holds the result until the interrupt resolves.
- **`noteRepoPromptInterruptRequested`** (:2052) returns the mark it placed.
  - Started path: if the turn has an acknowledged unstarted mark, it places no O49 mark (Q2, :2057). Otherwise it marks `interruptPending` and drops a stale unacknowledged unstarted mark (P2).
  - Otherwise it marks the sole unresolved turn as unstarted.
- **`noteRepoPromptTeardownRequested`** (:2141) applies the same Q2 guard (:2146). The helper `hasAcknowledgedUnstartedInterrupt` is at :2153.
- **Why Q2.** An acknowledged unstarted turn with no result of its own that is later credited as started is suspect: the credit is likely the next message's output. Promoting it through O49 would accept on the wrong turn's evidence.
- **`resolveRepoPromptInterrupt`** (:2070) resolves by mark kind (P2). The unstarted kind goes to `resolveUnstartedInterrupt` (:2109):

  | Interrupt acknowledged? | Provider result held? | Result |
  |---|---|---|
  | yes | yes | `noteAccepted` |
  | yes | no | marked acknowledged; waits for a result |
  | no | yes | `noteDeliveryUnknown` |
  | no | no | mark cleared |

- **`awaitUnstartedInterruptedTurnResult`** (:2777) is the P1-B bounded wait. It is called from `interruptClaudeTurnIfNeeded` (:2834-2845) only for `.acknowledged` plus `.unstarted`. Stop (`cancelClaudeRunAndCaptureSessionRef`, :3028-3035) resolves by kind and writes nothing afterwards, so it needs no wait.
- **Unchanged:** `settleWithoutCompletion`, so an unstarted mark never accepts at run end.
- **DEBUG hooks:**
  - `test_setUnstartedInterruptResultWaitSeconds` (:1367);
  - `test_hasUnstartedInterruptMark`;
  - `test_tracksWrittenDispatchHandoff`;
  - `test_holdsCompletionDuringInterrupt`, which also reports a held provider result.

**Test support** (`ClaudeAgentModeCoordinatorLifecycleTests.swift`)
- The fake's `emitProviderCancelledTurnCompletion(turnID:soleOutstandingTurn:reportsInterruption:messageIdentity:)` (:3134) gained the evidence parameters.
- `emitControllerSynthesizedTurnCompletion` was added.
- `emitCancelledTurnCompletion` keeps the synthesized origin.

**Other updated tests**
- `ClaudeNativeUsageAttributionTests.swift` and `AgentRunTerminalCauseTests.swift` match the 3-field `.turnCompleted` case.

## Tests and what each proves

**Coordinator tests.** These are in `Tests/RepoPromptTests/AgentMode/Recovery/AgentProviderHandoffTests.swift` and run under `FILTER=AgentModeRunServiceLifecycleTests`.
- In the table, `…` stands for the `testClaudeUnstarted` or `testClaudeUnstartedTurn` prefix.
- Runs use a 0.05 s steer wait, except the positive steer test, which uses the production 1.5 s.

| Line | Test | What it proves |
|---|---|---|
| :1350 | `testClaudeUnstartedTurnSteeredWithAcknowledgedInterruptAndProviderCancelledResultSettlesAccepted` | **Positive steer case.** The provider result names T's UUID (`.namesTurn`). After the acknowledgement the steer is held: it polled the turn after the interrupt, and the writes are only `["first"]`. The acknowledgement alone accepts nothing. The CLI's result is processed before the steer write, which the real controller reports as exclusive (see :264 below). The write follows, the message settles `providerAccepted`, and Needs Attention is unchanged. |
| :1484 | `…SteerProviderResultBeforeAcknowledgementWaitsThenAccepts` | A result naming T that arrives before the acknowledgement is held, then accepted once the acknowledgement resolves. |
| :1523 | `…SteerThenControllerSynthesizedCompletionStaysUncertain` | Synthesized `.cancelled` and `.failed` completions never accept. |
| :1544 | `…SteerAcknowledgedWithoutResultStaysUncertainAtRunEnd` | When the wait times out with no result, the steer is still written (`["first","steer"]`) and the message stays `deliveryUnknown`. |
| :1565 | `…SteerWithUnacknowledgedInterruptStaysUncertain` | `.timedOut` and `.failed` outcomes stay `deliveryUnknown`, whether the result arrives during or after the interrupt. |
| :1619 | `testClaudeSkippedMessageAheadOfAFreshOneNeverAcceptsEitherOnAnInterruptedResult` | Two unresolved turns: no mark is placed and nothing is accepted. |
| :1657 | `testClaudeSkippedMessageAloneIsNotAcceptedOnTheSteerMessagesResult` | A phantom alone, then a shared-FIFO result: `deliveryUnknown`. |
| :1681 | `…StoppedWithAcknowledgedInterruptAndProviderCancelledResultSettlesAccepted` | **Positive Stop case.** The provider result names T's UUID. The message is recorded `deliveryUnknown` first, then refined to `providerAccepted`, and Needs Attention returns to baseline. |
| :1714 | `testClaudeSkippedMessageAloneStoppedIsNotAcceptedOnAnUnrelatedResult` | **OracleA regression.** A lone skipped message, then an acknowledged Stop, then an unrelated result. Each case ends `deliveryUnknown`: a `success` result (`reportsInterruption: false`), one that names another message (`contradictsTurn`), and (Q1) an unattributed `error_during_execution` (`reportsInterruption: true`, `.notReported`). |
| :1752 | `testClaudeAcknowledgedUnstartedTurnLaterCreditedAsStartedIsNotPromotedByO49` | **Q2, steer and Stop routes.** An acknowledged unstarted mark with no result, then the turn is credited as started. A second steer, or a Stop, places no O49 mark: the unstarted mark remains, nothing is parked in `completionDuringInterrupt`, and the message ends `deliveryUnknown`. |
| :1805 | `testClaudeSteerOfAStartedTurnIsNotHeld` | **Not held.** With the production 1.5 s wait, a steer of a started turn writes immediately (`["first","steer"]`) without polling the turn after the interrupt, places no unstarted mark, and the started turn settles `providerAccepted`. |
| :1824 | `…StoppedWithoutResultStaysUncertain` | Stop with no result (the quit/kill gap) stays `deliveryUnknown`. |

**Real-controller tests.** These are in `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeTurnTeardownTests.swift`.

| Line | Test | What it proves |
|---|---|---|
| :221 | `testInterruptedResultIsExclusiveProviderEvidenceOnlyForTheSoleOutstandingTurn` | In immediate and deferred modes, a sole turn's attributed `error_during_execution` result is exclusive. A shared FIFO is not. A later `success` result records `reportsInterruption: false`. |
| :278 | `testAcknowledgementThenSteerWriteThenResultIsNotExclusiveButResultBeforeTheWriteIs` | **P1-B, both modes, attributed results.** The order acknowledgement → steer write → result gives `sole: false`, so the result is not exclusive. The order acknowledgement → result → write gives an exclusive result. In immediate mode, the turn leaves flight at its result, which is the signal that ends the coordinator's wait. |
| :338 | `testOnlyAResultThatItselfReportsAnInterruptionIsExclusiveEvidence` | **P1-A payload.** Every payload names the turn's UUID, so only the payload varies. With the sticky marker set, every case below is classified `.cancelled`. Only these are exclusive: `error_during_execution` (including with `terminal_reason: aborted_streaming`) and `errors` naming an abort. None of these is exclusive: a background-style `success` result, a bare `success`, a `success` with a cancel `stop_reason`, or `error_max_turns`. |
| :377 | `testResultAttributionMustNameTheCreditedTurnsOutboundUUID` | **P1-A identity (Q1).** Only attribution that names the turn's UUID is exclusive. Absent or null attribution (`.notReported`), including on a turn written without a UUID, is not exclusive. Each of these contradicts and is not exclusive: another UUID, a two-entry list, single and list disagreeing, or any attribution on a turn written without a UUID. |
| :417 | `testDeferredSurplusResultIsNotExclusiveForALaterTurn` | **P2 deferred.** A surplus result, processed while an earlier one waits for `idle`, binds to a later turn with `sole: false`. |
| :441 | `testControllerTimedCompletionsAreSynthesizedNotProviderResults` | Idle fallback, shutdown flush and EOF drain are all `.controllerSynthesized`. |

## Failing-first and mutation-check tickets

**Round 1 failing first**
- `make dev-test FILTER=AgentModeRunServiceLifecycleTests` ran with only the positive test added.
- Ticket `81080e05-5cd5-4595-a3e9-8bef42f2efa1`: 243 tests, 4 assertion failures, all in that test. It got `deliveryUnknown` instead of `providerAccepted`, and Needs Attention was 1 instead of 0.

**Round 1 mutation check**
- I removed the acceptance branch. Ticket `95e31e7f-6148-4fc1-b175-4da4fe0dcfc0`: 4 tests failed.
- I restored it. Ticket `630a366f-075f-418f-a469-fcca5d378531`: 251 tests, 0 failures.

**After the review fixes: mutation check repeated**
- I removed the `.cancelled where unstartedInterrupt != nil && origin.isExclusiveInterruptedResult` branch. Ticket `98c367f4-0646-4bf8-9b96-c9a56bf3699e` failed 4 tests:
  - the positive steer test;
  - the positive Stop test;
  - result-before-ack;
  - the unacknowledged twin, whose held-result precondition depends on the branch.
- I restored the branch byte-identical. Ticket `a33898e4-af43-424f-a358-8061353d909e`: 253 tests, 0 failures.

**After the final (Q1/Q2) fixes: mutation check repeated**
- I removed the same acceptance branch. Ticket `9bb1db27-af45-4985-a59d-485536f7f32e` failed 4 tests: the positive steer and Stop tests, result-before-ack, and the unacknowledged twin.
- I restored it byte-identical. Ticket `658d84ff-0dc0-42b9-95fc-ffe0352a6d86`: 254 tests, 0 failures.

**Not repeated.** Neither the post-review nor the Q1/Q2 fixes were re-run failing first, and no mutation check targets the Q2 guard on its own.

## Commands and results

**Round 1**

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentProviderHandoffTests` (wrong suite for the new tests) | `67679731-4986-474f-905f-5b4884b5f209` | 12 tests ran; the new tests are not in this class |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | `c00e5a29-676d-4c74-bfa8-943798eab758` | compile error (main-actor isolation in the test helper); fixed with `@MainActor` |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | `81080e05-5cd5-4595-a3e9-8bef42f2efa1` | failing first, as above |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | `13eefcb7-1e04-4f63-be9a-19061e25d556` | 1 failure. A result that lands during an unacknowledged interrupt lets the steer write; the test expectation was corrected, and production behavior was not changed. |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | `d9cd5581-c925-4f23-a144-894fe2266568` | 251 tests, 0 failures |
| `make dev-test FILTER=ClaudeNativeTurnTeardownTests` | `74dae72c-7c8b-4c1b-9fea-29a117faa58b` | 8 tests, 0 failures |
| `make dev-test FILTER=AgentProviderHandoffTests` | `40c645e3-a136-4703-90f6-f5ed28017366` | 12 tests, 0 failures |
| `make dev-test FILTER=AgentDeliveryQuietByDefaultTests` | `eef87779-a73c-46cc-a865-f22f30c6c50c` | 16 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | `1d81a06c-a5a1-4229-8610-4edaa6748871` | 79 tests, 0 failures |
| `make dev-test FILTER=ClaudeNativeUsageAttributionTests` | `1e58c709-340e-41be-a031-28ae0441c44c` | 16 tests, 0 failures |
| `make dev-test FILTER=AgentRunTerminalCauseTests` | `2d18ff05-cbc1-4508-baeb-c8fcfad055d7` | 17 tests, 0 failures |
| `make dev-lint` | `0963b382-67db-4a8f-97b4-ce01248f1af1` | passed |
| `make dev-swift-build PRODUCT=RepoPrompt` | `433e8ca8-d3b1-4176-800c-50a380c277e6` | succeeded |

**After the review fixes**

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=ClaudeNativeTurnTeardownTests` | `707fb14c-442e-4ff2-932b-1c8d4b338f02` | 12 tests, 0 failures |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | ticket line not captured (output truncated) | 253 tests, 0 failures |
| `make dev-test FILTER=AgentProviderHandoffTests` | `204f23d3-8935-4419-9ea1-cccd2273b923` | 12 tests, 0 failures |
| `make dev-test FILTER=AgentDeliveryQuietByDefaultTests` | `73476d55-b1e3-4f49-96e8-1020afdc937d` | completed successfully (16 tests, 0 failures on the preceding run) |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | `909d7a28-058b-47b1-949f-26929ccbd9eb` | completed successfully (79 tests, 0 failures on the preceding run) |
| `make dev-test FILTER=ClaudeNativeUsageAttributionTests` | `1b92ca82-70a9-40f4-af4e-a9dbbc251a57` | completed successfully (16 tests, 0 failures on the preceding run) |
| `make dev-test FILTER=AgentRunTerminalCauseTests` | `53b907f5-4fe4-439c-8ef8-f05c94a36ab8` | completed successfully (17 tests, 0 failures on the preceding run) |
| `make dev-lint` | `0bb8560d-0934-4b9f-a1c2-03c096442329` | completed successfully |
| `make dev-swift-build PRODUCT=RepoPrompt` | `2b26938f-399e-474c-8046-b68f24fb9089` | completed successfully |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` (mutation) | `98c367f4-0646-4bf8-9b96-c9a56bf3699e` | 4 failing tests, as expected |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` (restored) | `a33898e4-af43-424f-a358-8061353d909e` | 253 tests, 0 failures |

**After the final (Q1/Q2) fixes**

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=ClaudeNativeTurnTeardownTests` | `2f9de74e-ac66-482c-97b6-4846828d79a3` | completed successfully (count line not captured) |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | `e3125331-9ce0-4579-a8f8-b764a0c9e974` | 254 tests, 0 failures |
| `make dev-test FILTER=AgentProviderHandoffTests` | `48f7a109-a942-434f-8fa9-b25a97fde5af` | 12 tests, 0 failures |
| `make dev-test FILTER=AgentDeliveryQuietByDefaultTests` | `1c9ff417-c945-4794-a000-d7f8e4a9080f` | 16 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryCoordinatorTests` | `3e298472-c262-43e9-9829-7e96f4de2de2` | 79 tests, 0 failures |
| `make dev-test FILTER=ClaudeNativeUsageAttributionTests` | `805420da-4f90-46c4-99d7-a43d5bdcce87` | 16 tests, 0 failures |
| `make dev-test FILTER=AgentRunTerminalCauseTests` | `140289b5-5fbf-4f5b-acdc-92cee4be2c8f` | 17 tests, 0 failures |
| `make dev-lint` | `846ed6bb-937a-4c22-bbd5-c00ce7b16f31` | passed |
| `make dev-swift-build PRODUCT=RepoPrompt` | `46a9ce2f-8bca-4dbf-aee8-4544afad2d93` | passed |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` (mutation) | `9bb1db27-af45-4985-a59d-485536f7f32e` | 4 failing tests, as expected |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` (restored) | `658d84ff-0dc0-42b9-95fc-ffe0352a6d86` | 254 tests, 0 failures |

**Runtime cost.** Two existing Auto-steering lifecycle tests now take about 1.8 s each:
- `testAutoSteeringRestoresDraftWhenInterruptedTurnNeverSettles`
- `testAutoSteeringSurvivesInterruptAcknowledgementBeforeOldTurnCompletion`

Their fake never credits the turn as started, so they meet the production 1.5 s hold.

## Not covered

**Unproven without a live Claude CLI capture**
- **Whether there is a result at all.** It is unknown whether the CLI emits a `result` for a turn interrupted before its first assistant payload. If it does not, both routes always end `deliveryUnknown`.
- **Its shape.** It is unknown whether that result is `error_during_execution` or carries another cancellation field. Today the payload rule depends on the SDK documentation and one observed interrupt.
- **Timing on steer.** It is unknown whether the result arrives within the steer's 1.5 s hold.
- **Timing on Stop.** It is unknown whether the result arrives within the 200 ms window after the acknowledgement. In deferred mode, the result's `idle` must also arrive in that window, because the shutdown flush is synthesized.
- **Identity on interrupted results.** Since Q1, acceptance depends on it. It is unknown whether an interrupted result carries `user_message_uuid(s)` and names the interrupted message. If it does not, both routes always end `deliveryUnknown`.
- **Ineligible launches.** Turns written without an outbound UUID never qualify, so these launches always stay `deliveryUnknown`. This is a permitted false unknown.

**Residual risks and coverage costs**
- **Synthesized completions.** Idle fallback and shutdown flush count as `controllerSynthesized`, by owner ruling. This can leave a provable turn `deliveryUnknown`.
- **Arrival-time cost.** If the steer's hold times out before the result, T stays `deliveryUnknown`.
- **Quit or kill before the result** stays `deliveryUnknown`, by design.
- **Other RepoPrompt cleanup interrupts** use the same paths: launch-settings recycle, MCP-health restart, provider switch and reset. None has a dedicated test. The steer hold applies only to `interruptClaudeTurnIfNeeded`.
- **Unacknowledged steer "not held".** `testClaudeSteerOfAStartedTurnIsNotHeld` covers the started-turn case only. No test asserts that a steer whose interrupt was not acknowledged is not held.

**Process notes**
- `docs/context/agent-crash-recovery.md` was edited by the main agent, not by this worker.
- No ACP or other provider changes were made.
- `Scripts/check-agent-context` was not run by this worker.

## Review round

There were two OracleA/OracleB rounds under the O52 process cap: one review, then one re-review, which was allowed because round 0 found P1s. The two P1s left after the re-review were fixed without a further round. The raw exports stay in `prompt-exports/`.

**Round 0**
- **OracleA P1 (safety):** a lone skipped message could be accepted on an unrelated result that arrived after an acknowledged Stop.
- **OracleB P1 (effectiveness):** steer acceptance was unreachable. The steer wrote its own message before T's result arrived, so the arrival-time "sole" check failed. The positive test also used a state the real controller can't produce.
- **Fixes:**
  - The result payload must itself report an interruption.
  - If the result names a message, that name must match T.
  - After an acknowledged unstarted interrupt, the steer holds its own write for up to 1.5 s.
- **P2s fixed:** the interrupt mark now records its kind, and the deferred-mode sole check also requires no pending authoritative completions.

**Round 1 (final)**
- **Confirmed fixed:** OracleB's P1, with no deadlock and no unbounded hold.
- **Still open, both now fixed:**
  - **Q1 (OracleA, sharpened by OracleB).** An interrupt can abort an unrelated background turn, so an unattributed `error_during_execution` result proves nothing about T. Acceptance now requires the result to name T's outbound UUID. A turn written without a UUID, or a result with no attribution, stays `deliveryUnknown`.
  - **Q2 (OracleB, new).** A turn with an acknowledged unstarted interrupt and no result could later be credited as started from the steer's own output, then accepted through the O49 path. Steer and teardown now place no O49 mark on such a turn.
- **Cheap P2:** a test shows that a steer of a started turn is not held.

**Downgraded or deferred**
- **Live CLI behaviour is unproven.** Nobody has yet observed the CLI naming the interrupted message's UUID on an interrupted result, and that is now required. If it never does, a steer or Stop before first output always ends `deliveryUnknown`. That false unknown is allowed by the safety bar.
- **The steer hold delays pre-output steers.** Every steer on a turn with no output yet waits up to 1.5 s. If the CLI never sends a result for those turns, each such steer pays the full wait.
- **Gaps in proof:**
  - no test shows that a steer whose interrupt wasn't acknowledged is not held;
  - the Q1/Q2 fixes were not run failing-first;
  - the Q2 guard has no mutation check of its own.
- **Interrupt routes without a test of their own:** settings recycle, MCP-health restart, provider switch, and reset.
- **Test helper:** `test_holdsCompletionDuringInterrupt` still reports two different kinds of hold.

## Live verification (2026-10-29)

An external verifier rebuilt and relaunched build `76383c82` with Claude Code 2.1.302.
- **Stop before first output:** the CLI acknowledged the interrupt in 6 ms. Its result came 2 ms later as `error_during_execution`, `terminal_reason` `aborted_streaming`, and named the message in `user_message_uuid(s)`. The message settled `providerAccepted` with no row and appears once in Claude's history.
- **Steer before first output:** acknowledged in 2 ms, with the result 2 ms later naming the message, and the message was accepted. The steer was written about 106 ms after the acknowledgement. Claude answered the steer, and each message appears once.
- **Unchanged edge cases:**
  - The first send of a launch carries no UUID, so it stays `deliveryUnknown`.
  - A Stop before the message is written to the CLI sends nothing. The intent stays `queued`, with no row.
- **Not exercised:** a Stop after output (the control case), because a turn with no tools finishes as soon as its text appears.
- **Records:** after the relaunch, the O51 marker reads `completed: true`. The read-only recount shows 3 `deliveryUnknown` intents, 0 left to settle: 1 old user Stop and 2 runs with no recorded end.
- **Raw capture:** kept locally under `.agent-artifacts/lossless-restart-ordinary-acceptance/cycle18/live/`.
