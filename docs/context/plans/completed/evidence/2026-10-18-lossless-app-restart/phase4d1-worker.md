# Step 4d1: built-in Claude outbound user-message identity (worker implementation evidence)

Scope: read when the task touches a Claude dispatch's outbound caller `uuid`, the `DispatchBaseline.outboundUserMessage` claim, the typed `AgentRuntimeOperationOwner.writeAdmission` result, or the pre-byte `admitClaudeDispatchBaseline` admission.
Authority: Reference
Last-verified: 2026-10-23

Status: implemented in source only, on HEAD `cb15d40f`. Unstaged and uncommitted.

Production stays gated OFF. Baselines are captured only when `recoveryActionRunner.capturesDispatchBaselines` is on, so production mints no claim and sends no `uuid`; nothing was activated live. No history parser, association preflight, live carrier, reducer, partial or replay flag, deterministic tool-ID change or new runtime flag was added.

Main owns plan/status, review, synthesis and commit. Source is frozen for main's initial A/B review.

## Contract as implemented

**When the UUID is sent.** The existing `dispatchID` is sent as the lowercase top-level `uuid` of the streamed user frame only when all of these hold:
1. The writing transport's own launch is eligible. This is decided in the controller before the admission await. A launch is eligible only if:
   - its `commandProvenance` is `.automaticResolved`;
   - its backend is `.defaultClaude`;
   - it has no backend-routing environment keys.
2. The single admission of this write newly committed a captured baseline carrying the claim. This returns `.committedWithOutboundUserMessage(uuid)`.
3. That baseline's exact zero-row receipt committed, and the session was still current after the cursor CAS.
4. The coordinator rechecks that the dispatch reservation and the controller are still current after the host's awaits.
5. Cancellation and stale-owner fences still pass. Any failure means zero bytes, through the existing `processNotRunning` and `sendLine` owner check.

**When the UUID is omitted.** Every other admitted write sends no `uuid`, never a fresh one. That covers:
- `alreadyRecorded`, including a joined pending receipt;
- `unsupported`;
- `notCaptured` (gate OFF, not Claude, or no durable dispatch);
- legacy baselines;
- an ineligible launch.

A retry therefore never reuses or mints an identity. A denied admission is still `.denied`, with zero bytes.

**Claim.** `DispatchBaseline.outboundUserMessage` is optional and has the shape `{uuid, textSHA256}`:
- `uuid` is the dispatch's own ID, stored explicitly.
- `textSHA256` is the lowercase hex SHA-256 of the UTF-8 bytes of exactly the `providerBoundText` the codec encodes. The controller passes its `text` unmodified to the codec.

The claim is an instruction to encode, not evidence of delivery, native persistence or fsync. A claim may be committed while its UUID is never encoded (see "Claim meaning" below). Persistence behaves as follows:
- It is written with `encodeIfPresent` under the known key `outboundUserMessage`.
- Baseline `extras` and schema 7 are unchanged.
- The claim keeps its own unknown members in `extras`, through `HistoryDynamicKey` (known keys `uuid` and `textSHA256`).
- A legacy baseline decodes with `nil` and is never upgraded.
- A malformed claim (a bad UUID, a missing digest, or a digest that is not exactly 64 lowercase hex digits) makes that baseline unreadable, kept verbatim, and it is never treated as a claim.

**Constituent completeness (all-or-nothing).** `AgentDispatchBaselineIdentity.hasCompleteUserItems` defaults to `false`. The handoff sets it only when the list is non-empty, has one user item per constituent, and has no duplicates. The ordered `userItemIDs` list is unchanged, so the existing capture policy is unchanged.

At admission, a claim is attached only when all of these hold:
- the claim's UUID equals `dispatchID`;
- the identity is complete, non-empty and duplicate-free;
- every constituent is exactly one `.user` item in `session.items`.

Otherwise the baseline is captured as before, with no claim, and the ordinary send proceeds.

**One boundary per dispatch.** The existing-baseline lookup runs before the first await. The same lookup (`admitRecorded`) runs again after all read and save awaits:
- in `recordUnsupported`, which is now `async`;
- immediately before the captured append, with no suspension in between.

Two admissions of one dispatch therefore cannot both record a boundary or mint a claim. This reuses the existing serialized owner save and receipt join; no reservation store was added.

## Claim meaning (review B P2-2)

A committed claim does not mean its UUID was ever written. It can be committed while the UUID is never encoded:
- **Refused, then joined.** The admission saved the claimed baseline, its receipt commit failed and the write was refused. A retry then joins that pending receipt and sends without the UUID (`alreadyRecorded`).
- **Admitted, then not written.** The host returned the UUID, but nothing was written:
  - the coordinator's post-admission currentness recheck failed;
  - the controller's cancellation or initialization check failed;
  - `sendLine`'s owner check or the stdin write failed.
- **No longer current after the CAS.** The session stopped being current after the claim's receipt committed, so the admission returned `.committed` without a UUID.

A missing native entry carrying the claimed `uuid` is therefore evidence of nothing. It never proves non-delivery and must never trigger an automatic resend. A future association preflight must treat every claim as "the UUID may be absent from the wire". The doc comment on `OutboundUserMessage` states this. Recording it in the plan is main's note.

## Changed files (exact)

Source:
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRuntimeLaunch.swift`
  - Adds `AgentRuntimeWriteAdmission` (`.denied` / `.admitted(outboundUserMessageUUID:)`, plus `admittedWithoutIdentity`).
  - `writeAdmission` changes from `@Sendable () async -> Bool` to `@Sendable (_ outboundIdentityEligible: Bool) async -> AgentRuntimeWriteAdmission`. This is the same TaskLocal; there is no second callable and no result box.
- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift`
  - `DispatchBaseline.OutboundUserMessage`, with its own `extras`, `HistoryDynamicKey` coding and strict digest validation.
  - The claim-meaning doc comment.
  - The optional `outboundUserMessage` field and its coding.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionHost.swift`
  - Adds `AgentDispatchBaselineIdentity.hasCompleteUserItems`.
  - `admitClaudeDispatchBaseline(_:outboundUserMessage:session:)` now returns `AgentRuntimeWriteAdmission`; the host default admits without an identity.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Runners/AgentProviderHandoff.swift`: explicit completeness instead of trusting `compactMap`.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift`: the closure builds the claim only when the transport reports eligibility. The claim is the dispatch ID plus the digest of the captured immutable `providerBoundText`. The closure returns the host verdict only after the existing currentness recheck.
- `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift`
  - `outboundUserMessageIdentityEligible`, read from `usageLaunchState.identity`.
  - `sendUserMessage` captures eligibility before the await, takes the UUID only from this admission's `.admitted`, and passes it to the codec.
- `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSDKProtocolCodec.swift`: the core facade forwards the optional `messageUUID`.
- `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKProtocolCodec.swift`
  - `encodeUserMessage(text:sessionID:messageUUID: UUID? = nil)` writes `uuid` lowercase at the top level, and only when the UUID is non-nil.
  - With `nil`, the frame keeps the legacy members.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift`
  - Adds the `committedWithOutboundUserMessage(UUID)` case, the typed `admitClaudeDispatchBaseline`, the `outboundUserMessage` parameter on `captureClaudeDispatchBaseline` (default `nil`), the `admitRecorded` recheck and `qualifiedOutboundUserMessageClaim`.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`: the DEBUG `test_claudeDispatchBaselineAdmission` override now has the typed signature.

Tests (existing suites; adapters are typed, and no assertion was weakened):
- `Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests/SDK/ClaudeSDKProtocolCodecTests.swift`: new `testUserMessageOutboundUUIDIsOptionalTopLevelAndLowercase`.
- `Tests/RepoPromptTests/AgentMode/Recovery/RegisteredNativeTransportWriteFenceTests.swift`
  - The Bool closures became `.denied` / `.admittedWithoutIdentity`. The cancellation test's gated admission now even returns a UUID and still writes nothing.
  - New `testClaudeUserFrameCarriesTheAdmittedOutboundUUIDOnlyForAnEligibleLaunch`. It runs on the real controller over the pipe-only fixture, with no process. It covers:
    - no launch, `.configuredOverride` and a routing key are each ineligible;
    - an eligible launch writes the lowercase top-level `uuid`;
    - a retry omits it, with exactly the legacy keys;
    - a denial writes zero bytes;
    - each write has exactly one admission.
- `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeAgentModeCoordinatorLifecycleTests.swift`: the opt-in fake (an extension of `AgentModeRunServiceLifecycleTests`) gained the typed admission, the `outboundIdentityEligible` option, and frames recorded through the production codec.
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentProviderHandoffTests.swift`
  - Typed probe; the expected identity is now `hasCompleteUserItems: true`.
  - The superseded/cancelled test now mints a claim and asserts zero recorded frames.
  - The multi-constituent batch test asserts the ordered, complete identity.
  - New `testClaudeOutboundIdentityRidesOnlyOnTheAdmissionThatCommittedItsClaim` and `testClaudeOutboundIdentityIsOmittedWithoutAnEligibleLaunchOrANewClaim`.
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift`
  - Bool asserts became exact typed asserts.
  - `makeProducerHarness` gained an optional `claudeController:`. When set, it injects the existing `LifecycleFakeNativeController` through `claudeControllerFactory`, with an inert `connectionPolicyInstaller` and `mcpRunRoutingCleaner`. With the default `nil` the construction is unchanged.
  - New tests:
    - `testOutboundUserMessageClaimRoundTripsWithUnknownMembersAndLegacyStaysUnclaimed`. It covers the SHA-256 `"abc"` known-answer check, an unknown member inside the claim surviving two saves, and five malformed claims that become unreadable, with a valid-digest positive control.
    - `testNewlyCapturedBaselineCommitsTheOutboundClaimBeforeReturningItsUUIDAndARetryOmitsIt` (two users, durable before return).
    - `testIncompleteOrNonCanonicalConstituentsAndLegacyBaselinesNeverCarryAClaim`.
    - `testConcurrentAdmissionsOfOneDispatchNeverBothMintTheClaim`. Admission A is held in the existing `test_recoveryClaudeHistoryHomes` hook after its first lookup; B commits and returns the UUID; A is released, re-checks and returns `admittedWithoutIdentity`. The overlap is forced, not left to the scheduler.
    - `testRealCoordinatorDispatchCommitsTheClaimThroughTheHostProducerAndEncodesItsUUID` (review B P2-3, composition). The pieces are:
      - a real committed durable dispatch, admitted through the session's own lane, with its user item in `session.items`;
      - the real `ClaudeAgentModeCoordinator.sendClaudeNativeMessage`;
      - the real host producer, with no DEBUG admission override, a qualified runner, a fixture history home and real owner-session persistence;
      - the managed-transport fake, encoding with the production codec.

      It asserts the frame's `uuid` equals `dispatchID` (lowercase), and that the in-memory and persisted baselines carry the claim over exactly the encoded provider-bound text. No process is started.
    - `testClaimWhoseReceiptCannotBeSavedIsRefusedAndARetryNeverReturnsItsUUID`.

## Validation (coordinated, one suite at a time)

Final run, after the style fixes:

| Check | Ticket | Result |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` | `5853178e` | passed |
| `make dev-test FILTER=RegisteredNativeTransportWriteFenceTests` | `bc1f2f69` | 17 passed |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `5a7ef366` | 27 passed |
| `make dev-test FILTER=AgentProviderHandoffTests` | `ab899d54` | 12 passed |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | `d627b3c1` | 193 passed |

Run once, before the style fixes (it did not change afterwards):
- `make dev-provider-test FILTER=ClaudeSDKProtocolCodecTests`, ticket `472723f1`: 4 passed.

The baseline-route and lifecycle-fake tests live in `AgentModeRunServiceLifecycleTests`. `FILTER=ClaudeAgentModeCoordinatorLifecycleTests` is not a ledger suite, and conductor refused it.

Style:
- `make dev-format-check`, ticket `090ad24f`: 0/2175 files need formatting.
- `make dev-lint`, ticket `3186feac`: passed.
- The first format check flagged `redundantSendable`, `preferCountWhere` and `hoistTry` in this diff. They were fixed by hand; `dev-format` was not run.

Not run: `make dev-build`, packaging or run, the full suite, live or installed Claude, any helper, MCP executable or app action.

## Review repair round (A R1 / B P2-1, B P2-2, B P2-3, B P3-2)

What changed:
- **Source:** only the `OutboundUserMessage` model in `AgentSessionProviderHistoryRecovery.swift`, as described above.
- **Tests:** only `AgentRecoveryReconciliationTests.swift`: the extended round-trip test, the forced-overlap concurrency test, the harness injection and the composition test.
- **Evidence:** this file.

Deferred, as optional hardening (no runtime behavior was expanded):
- B P3-1: a synchronous recheck helper;
- B P3-3: coordinator UUID equality hardening;
- B P3-4: unreadable-baseline dispatch matching.

Validation after the repair:

| Check | Ticket | Result |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` | `f349973e` | passed |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `859b9506` | 28 passed |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | `05601d86` | 193 passed |
| `make dev-format-check` | `04ec30e5` | 0/2175 files need formatting |
| `make dev-lint` | `e31713f9` | passed |

Not rerun: the codec suite (its files are unchanged), `RegisteredNativeTransportWriteFenceTests` and `AgentProviderHandoffTests` (their files and code paths are unchanged).

## Limitations and remaining qualification

- **Eligibility is not proof of a qualified binary.** It does not authenticate the binary. Automatic resolution may still reach a PATH wrapper or symlink, and `runtimeVariant` is not checked. Requiring no backend-routing keys is fail-closed: an inherited `ANTHROPIC_*` key disqualifies the launch.
- **Live qualification is still pending.** None of the following is established:
  - that the installed CLI persists the streamed `uuid` as the native entry `uuid`;
  - wrapper transparency;
  - ordinary-history coverage.
- **A claim may outlive an unsent UUID.** See "Claim meaning" above. A future preflight must never read a missing claimed entry as non-delivery or as a reason to resend.
- **Durable constituents always carry a user item.** A missing constituent is therefore covered only through the identity and host tests, not through a production handoff.
- **The composition test places the user item itself.** It appends the dispatch's user item to `session.items` before the send. Whether every real input path (steering, coalesced batches, relocated saved messages) has its item there at admission time still needs live qualification. If one doesn't, that path fails safe: an ordinary send with no claim.
- **Retries remain unassociated.** A retry with the UUID omitted stays unassociated and is not eligible for history reconciliation. The preflight, parser, carrier and reducer are deferred to later steps.
