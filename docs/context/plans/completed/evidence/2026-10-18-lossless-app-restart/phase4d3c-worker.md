# Step 4d3c worker evidence — producer-owned live-proof invalidation

Scope: read when the task touches the Step 4d3c source change (owned-keys-only refusal of Claude live proofs) or its validation evidence.
Authority: Reference
Last-verified: 2026-10-24

## Contract implemented (HEAD bf793f9d, uncommitted)

The two final planning continuations settled on one rule: a refusal clears only the proofs that its own producer newly inserted. It is still inactive and default OFF. There is no new persisted authority, journal, router binding, provider profile, CLI argument, native identity, digest or schema change. There is no agreement-ownership requirement and no contradiction exception.

- `AgentTabSession.claudeLiveTranscriptOwnedKeys: [UUID: Set<String>]` is transient, main-actor and not persisted.
- An accepted `.completeText` inserts the ledger key into the producer's set in the same non-suspending step that appends the ledger entry and the canonical row.
- Duplicates, imported matches and `resultAgreement` never acquire or transfer ownership. Their existing checks are unchanged.
- `refuseClaudeLiveTranscript` follows one rule for every refusal path:
  1. It latches the producer.
  2. It removes and discards the producer's owned set.
  3. It calls `invalidateClaudeEnvelopeProofs(forKeys:)`.
  4. It marks the session dirty and saves only if something changed.

  An empty owned set changes no ledger, no dirty flag and no save.
- `invalidateClaudeEnvelopeProofs(forKeys:)` is mandatory: the no-argument all-tab method was removed. It touches only Claude rows whose exact `key` is listed. It clears the typed digest and the raw `extras["envelopeDigest"]` member. Keys, local items, other extras, receipts, baselines and Codex rows are kept. An empty set returns `false`. No proof is healed.
- These are unchanged:
  - the background positive refusal (`isBackground` refuses);
  - the active-run delivery guard;
  - the internal carrier;
  - the background `sourceID`, which is never compared with `producerLaunchToken`.

## Call-site audit

Sites are listed by line number on the final edited tree, after the F1 fix.

### Invalidator callers

`AgentSessionProviderHistoryRecovery.invalidateClaudeEnvelopeProofs`, model line 518, has one caller: `AgentModeViewModel.refuseClaudeLiveTranscript` (line 20203). No caller lacks a producer token, so no union-of-owners fallback was needed.

### Refusal callers

Every refusal in `applyClaudeLiveTranscriptEvidence` goes through `refuseClaudeLiveTranscript(producer: evidence.producerLaunchToken, …)`:

| Line | Refusal |
|---|---|
| 20140 | completeText guard: background, refused, projection, conversation, proofless, ID |
| 20152 | existing-key mismatch: self-conflict or imported conflict |
| 20159 | canonical-ID collision |
| 20187 | `resultAgreement` disagreement |
| 20192 | `.disqualified` |

Ownership is recorded at line 20172, in the same step as the ledger append (20170–20171) and the row append (20173).

### `session.providerHistoryRecovery` writers and their ownership effect

| Site | Kind | Ownership effect |
|---|---|---|
| `AgentModeViewModel.swift:22087` `performClearChat` (both the plain and the committed recovery reset) | canonical history reset; the Claude controller is detached at 22082 | map reset at 22088 (the only reset); refused latch kept |
| `AgentModeViewModel.swift:5921` `applyPersistedHydration` | ledger replaced on the existing tab session (route activation rebind at 6247; stale-reset recovery replacement at 5697); the Claude controller is not detached | map kept (review B F1, option b); refused latch kept |
| `AgentModeViewModel.swift:20171` live insert | append | records ownership |
| `AgentModeViewModel.swift:20210` refusal | key-scoped invalidation | consumes ownership |
| `+RecoveryActions.swift:909` (baseline record), `:1007` (baseline and receipt append), `:1216` (import `plan.ledger`, built from `ledgerAtStart` as a merge) | merge or append | no reset |
| `AgentModeViewModel.swift:21989` `candidate.providerHistoryRecovery = nil` | persisted candidate copy only, not the session | none |

Hydration does not start from a fresh `AgentTabSession`. Both callers apply it to an existing tab session whose Claude controller may still be attached (see the F1 follow-up below), so ownership is deliberately kept across hydration and rebinding. Not every history replacement resets the map.

### Other transcript replacements that do not replace the ledger

None of these reset ownership, because the ledger is unchanged:

- `.routeActivation` (always followed by hydration, which also keeps the map)
- `.retentionCompaction`
- `.pendingToolFinalizationRepair`
- `.savedInputRelocation`
- the DEBUG helper `test_adoptPersistedIncarnation` (line 6045)

Ownership is not reset at run completion, cancellation, a new run, a merging import, or persisted hydration or rebinding.

## Files changed

- `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift`: `invalidateClaudeEnvelopeProofs(forKeys:)` replaces the no-argument method.
- `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/AgentTabSession.swift`: the `claudeLiveTranscriptOwnedKeys` map.
- `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`: ownership recording, owned-only refusal, the clear-chat reset, and the comment explaining why hydration keeps ownership.
- `Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeNativeBackgroundTranscriptTests.swift`: an extension of `AgentModeRunServiceLifecycleTests`.
- `Tests/RepoPromptTests/AgentMode/Recovery/ClaudeSessionHistoryReaderTests.swift`
- `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift`

## Tests

### New tests

- **`testClaudeLiveRefusalClearsOnlyTheRefusedProducersOwnNewProofs`** — the ledger mixes an imported same-conversation row, an imported different-conversation row, P, Q and a Codex row.
  - A delayed P refusal (a between-run `.disqualified`) clears only P's key.
  - A repeated refusal is idempotent and leaves nothing dirty.
  - A background complete text from a producer that owns nothing is refused and changes no proof.
  - A Q agreement mismatch clears only Q's key.
  - Rows, IDs, keys, extras and receipts are kept.
- **`testClaudeLiveImportedMatchesNeverAcquireOwnershipAndImportedConflictsClearOnlyOwnProofs`**
  - A refusal before any insert leaves the ledger unchanged and nothing dirty.
  - An imported duplicate and an imported agreement acquire no ownership, and the imported proof survives that producer's refusal.
  - An imported key conflict keeps the imported row and proof, shows the text unidentified, and clears the producer's own earlier proof.
- **`testClaudeLiveOwnershipSurvivesRunCompletionAndResetsOnlyWithTheCanonicalHistory`** — completion keeps ownership; `clearChat` resets the map and keeps the refused latch.
- **`testKeyScopedProofInvalidationTouchesOnlyListedClaudeRows`** (reader suite, model scoping)
  - Typed and raw members are cleared only for listed keys.
  - Unlisted raw members are kept.
  - A listed Codex row is untouched.
  - An empty set returns false, and a repeat is idempotent.

### Existing tests deliberately updated for the changed contract

- **`testClaudeLiveRefusalsInvalidateProofsAndRefusedProducersNeverRequalify`** — its assertions encoded the old all-tab invalidation. It now asserts that the ledger is unchanged, nothing is dirty and the producer is latched for a producer that inserted nothing. All other refusal cases are unchanged.
- **`testClaudeLiveCompleteTextInsertsCanonicalRowOnceAndConflictsInvalidateProofs`** — the self-conflict / no-heal assertions are unchanged. Ownership assertions were added.
- **`testLiveQualifiedRowRoundTripsAndInvalidationRefusesWithoutHealing`**
  - The "all Claude proofs nil" assertion became "the producer's own key is nil; the imported user row keeps its proof".
  - The reconcile-refuses / unchanged-cursor fence and the no-heal fence are unchanged.
  - The reload simulation also empties the owned map.
- **`testAnInFlightOlderSaveNeverOutlivesALiveProofInvalidation`** — unchanged; it passes.
- **Reader live-projection test** — switched to `forKeys: [complete.ledgerKey]`.

### Runs

All runs were coordinated, filtered and serial, on the edited tree.

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | 1c6453da-1c21-4a94-9bc0-9d9937f48d67 | 36 tests, 0 failures |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` (includes the background extension) | 2443d8fc-21c2-42db-b773-c150adccb95f | 202 tests, 0 failures |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 3cf59a75-4440-4c14-b2e4-f0dbc21c4bcb | 45 tests, 0 failures |
| `make dev-swift-build PRODUCT=RepoPrompt` | 95f16373-9b88-409b-a6f6-b46e33f91d34 | exit 0 |
| `make dev-format-check` | 6830ea11-6efb-4022-b7a0-c43816ea0f6b | exit 0 |
| `make dev-lint` | 5fadce7d-fc2f-4a90-bdd6-66db174eea06 | exit 0 |

No failures. The frozen ledger was not edited; the reader suite is not in it and ran with default deadlines. No assertions or deadlines were weakened.

### Not run

- `dev-build`, run, package
- the full root lane
- any app, helper or provider process, capture, or auth inspection
- the other suites that only mention the ledger type: `AgentRecoveryActionTests`, `AgentProviderHandoffTests` (no invalidator use)

## Limits (explicitly pending)

- **Same-launch revocation by later unsupported output.** Ordinary tool or thinking output later in the same launch still refuses it and clears that launch's own earlier proofs. This is a real future workflow limit, not closed.
- **Fail-closed P3 residuals, deferred:**
  - the cascade between launches;
  - a producer-inserted key later confirmed by an import, which stays owned by that producer in the same process.
- **Unchanged and still pending:**
  - the proofless-history refusal (`hasProoflessClaudeItem`);
  - the scheduled-save crash window;
  - profile qualification.
- No retention optimization.
- Activation is OFF; final acceptance and A/B review are pending with main.

## Review B F1/F2 follow-up (after snapshot 0831)

Question: can a live producer survive an accepted hydration, so that the hydration ownership reset (`AgentModeViewModel.swift:5924`) leaves a proof it inserted unrevoked when it is later refused?

### Finding: detach/quiescence is not guaranteed; a reachable counterexample exists

#### Delivery depends only on controller identity

Between-run Claude output reaches the owner only while the controller is still attached to the tab:

- `ClaudeIntegratedAgentModeRunner.handleBetweenRunEvent` (around lines 706–733) forwards `.stream` results to `handleBackgroundNativeStreamResult` only while `session.claudeController === controller`.
- The owner's `.background` guard (`AgentModeViewModel.swift` around 19427) checks only `selectedAgent.usesClaudeNativeRuntime`.

So a producer's later `.disqualified` evidence lands whenever its controller is still attached. The existing end-to-end test proves this between-run delivery for an undecodable line and for an EOF tail.

#### Only these calls detach the controller

The calls that detach `session.claudeController` are:

- `ClaudeAgentModeCoordinator.prepareClaudeCancelSync`, reached through:
  - run cancel (`AgentModeRunService.swift:2014` and runner `:848`);
  - `prepareForConversationResetSync` (clear chat at 22081; RecoveryActions `:358`);
  - the provider-identity transition (`handleProviderIdentityTransition*`), reached only when the user changes the selected agent (VM `:319`, `:8887`).
- `shutdownClaudeSession*`, reached through:
  - window close (`:3987`);
  - execution-location change (`:8556`);
  - compose-tab removal (`:14010`);
  - deleted-session references (`:22301`);
  - `deleteSession` (`:22386`);
  - the workspace switch provider.
- `claudeCoordinator.stop()` (workspace or app stop).

#### Hydration paths do not detach it

None of the hydration paths calls any of the above:

- `applyPersistedHydration` assigns `session.selectedAgent` directly (no provider transition).
- `prepareSessionForStaleResetRecoveryReplacement` clears buffers and anchors only.
- `prepareSessionForRouteActivation` clears `providerSessionID` and stops the remote coordinator only.
- `rebindPersistentSession` and `installPersistentSessionBinding` only switch the binding.
- `ensureSessionReady` reconnects only when a run is active.

#### Admission checks do not look at the controller either

- **Stale-reset quiescence** (`staleResetRecoveryIngestionIsQuiescent`) checks run state, `isTabRunning`, `activeRunOwnership`, the terminal commit, the pending delta, `agentTask` and the remote attachment. It does not check `claudeController`.
- **The stale-reset stop** calls `cancelAgentRun` only while a run is active.
- **Route activation and rebind admission** (`activateRoutedAgentSession` and `bindingHasOwnership`) refuse only:
  - an active run or its run ownership;
  - an MCP control context;
  - a blocking interaction;
  - an active registration.

  An idle tab with its Claude process still attached between runs is admitted.

#### Counterexample (route activation A→B→A)

1. In tab T, bound to session A, producer P inserts key K. The ordinary save persists K with its proof, and the run completes. P's process stays attached between runs.
2. T is routed to session B: there is no active run, so it is admitted, and P is not detached. Hydration of B resets ownership.
3. T is routed back to A. Hydration of A installs the persisted ledger, which contains K with its proof, and resets ownership again. P is still attached, because no run happened in B.
4. P emits between-run disqualifying output (an undecodable line, or a contradicting EOF tail). It is delivered while `claudeController === P`. `refuseClaudeLiveTranscript` latches P, but its owned set is empty, so K keeps its proof.

Without the hydration reset, P's set would still contain K's exact key, and K would be cleared. This fails open only relative to the 4d3c policy: `ledgerConflict` still re-checks K against the native file before any import.

#### Stale-reset replacement path

P can also survive here: the run had completed, and quiescence ignores the controller. But the reloaded payload's reset generation covers a peer transcript reset, which set the ledger to nil. That ledger can contain K only if the peer re-acquired P's old native conversation, which is not plausible because its baselines and `providerSessionID` were cleared. No realistic loss was found on this path.

#### Alternative noted for main, not applied

The alternative is to remove the hydration reset (review B option (b)). Keys encode provider, native session and native entry, so the only additional effect is clearing the proof of a key that the same producer inserted. That clearing fails closed, for example for a fork or copy that carries the same native entry.

### Changes made (no behavior change)

- **Source and hydration reset:** unchanged at this stage; the disposition was main's. It is superseded by the final delta below.
- **Hydration-reset regression test:** not added at this stage, because it would lock in a reset that might be removed. Superseded by the final delta below.
- **`testClaudeLiveOwnershipSurvivesRunCompletionAndResetsOnlyWithTheCanonicalHistory`** gained F2 coverage. It now asserts that ownership is kept for a new run attempt, and across a real `harness.service.cancelRun(… .userCancel)`, with the proof intact, before the clear-chat reset. These are unstaged test-only lines on top of the staged file.
- **F3:** deferred (cosmetic).

### Runs

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` | b5064646-4a97-4534-b7ee-53c18cf9e7d2 | 202 tests, 0 failures |
| `make dev-format-check` | fe43e7d5-1b37-418b-b649-13fa8807a316 | exit 0 |
| `make dev-lint` | dfc2d0fc-5a71-437d-93d9-ae4591cb8fb1 | exit 0 |

No provider process, app run or gate change.

## Final delta: F1 accepted, option (b) applied

Main accepted review B F1 and chose option (b). These source and test changes are unstaged, on top of the staged 0831 snapshot.

### Source changes

- **`AgentModeViewModel.applyPersistedHydration`** (around line 5921): the added `claudeLiveTranscriptOwnedKeys = [:]` was removed. A comment now says ownership is deliberately kept, because hydration does not detach the tab's Claude controller.
- **`performClearChat`:** the clear-chat reset is unchanged. It is now the only ownership reset, and it follows the controller detach (`prepareForConversationResetSync`). Its comment says so.
- **`AgentTabSession.claudeLiveTranscriptOwnedKeys` doc:**
  - the map is reset only by clear chat;
  - it is kept across completion, cancellation, a new run, a merging import, and persisted hydration or rebinding;
  - exact keys (provider, native session, entry) never match another conversation's rows;
  - a copied key the producer created stays its own;
  - the refused latch is never reset.
- **No changes to:**
  - routing or controller lifecycle;
  - the refused latch;
  - persisted state.

### Test changes

**New: `AgentRecoveryReconciliationTests.testPersistedHydrationKeepsLiveOwnershipSoALaterRefusalStillRevokesItsProof`.** It uses the existing producer harness, real persistence, and the existing `loadSessionFromDisk(for:)` hydration path.

1. P owns K, alongside an unrelated imported proof from conversation conv-0.
2. Save, then run an accepted persisted hydration. An in-memory-only ledger marker proves the ledger was replaced from disk, and P's ownership is kept.
3. P's later between-run `.disqualified` (background delivery) revokes K. K keeps its key and local item, and the imported proof is kept.
4. The revocation is saved durably.

**Kept:** the new-run and cancel ownership assertions in `testClaudeLiveOwnershipSurvivesRunCompletionAndResetsOnlyWithTheCanonicalHistory`.

### Gaps

- The A→B→A rebind is not exercised end to end. It needs a second persisted session and a route-activation fixture, and the existing route tests don't compose with the live producer harness. Rebind and route activation reach the same `applyPersistedHydration`, which no longer writes the map, and no rebind path writes it.
- The stale-reset replacement path is likewise covered only by the same code path.

### Runs

All runs used coordinated filtered serial `make dev-test` on the final tree.

| Command | Ticket | Result |
|---|---|---|
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | 7d614f23-3ec0-4d5d-996c-bc2c32186973 | 46 tests, 0 failures; the new test passed |
| `make dev-test FILTER=AgentModeRunServiceLifecycleTests` (includes the background extension) | b90712cd-ddca-4102-8b1f-9a62b5561549 | 202 tests, 0 failures |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | 9f39c72d-5c5c-4497-8fb5-aa04ef589b12 | 36 tests, 0 failures |
| `make dev-swift-build PRODUCT=RepoPrompt` | 77bbddfb-fce2-4a4e-af62-95b69e133658 | exit 0 |
| `make dev-format-check` | 0a7d608b-8e11-43c2-9031-027ced3de43e | exit 0 |
| `make dev-lint` | 1b6fb989-c87b-42d9-9ce0-7d4f421d259e | exit 0 |

No provider process, capture, app action or gate change. Nothing was staged or committed.
