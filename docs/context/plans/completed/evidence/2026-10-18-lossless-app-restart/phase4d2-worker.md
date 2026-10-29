# Step 4d2: capture-qualified Claude history projection, payload-safe reconciliation and byte-prefix fences (worker implementation evidence)

Scope: read when the task touches the Claude native history reader's attachment or operational-record handling, retraction-marker refusals, chain-order projection, the `NativeItem.envelopeDigest` ledger proof, the byte-prefix fences (`prefixSHA256` on baselines and cursors, the `ImportCommit.target`), the ledger-conflict, rewritten-history or unproven-prefix refusals, or outbound-claim association in Claude history reconciliation.
Authority: Reference
Last-verified: 2026-10-23

Worker evidence for main's bounded Step 4d2. It covers four worker passes:
- **First pass:** projection, envelope proof and claim association.
- **Follow-up pass:** main's decisions on the first-pass questions, plus the approved byte-prefix fence.
- **Final pre-review pass:** the conservative lost-target refusal, and the record cursor as an extra fence. That package was frozen for the OracleA/B initial review; main staged it as the initial snapshot.
- **Re-review 1 repairs:** the blocking A R1 fix plus main's selected cheap P2/P3 fixes, kept unstaged on top of that snapshot (see [Re-review 1 repairs](#re-review-1-repairs)). No new architecture or activation.

**Outcome:** A/B re-review 1 of that delta found no P0/P1, and A closed R1 ([A r1](phase4d2-review-oraclea-r1.md), [B r1](phase4d2-review-oracleb-r1.md)). B's new P3-1 to P3-4 are deferred with no action and no further round. Step 4d2 is complete as bounded source only, and not yet committed. The live carrier, live/profile qualification, activation and final live acceptance remain deferred.

Both build on Step 4d1 (`85aecb82`) and the O19 capture evidence (`3fd836a9`, [capture evidence](phase4d-claude-capture.md)).

**Out of scope:** the live carrier, broader profile qualification, activation and live acceptance.

**Operating constraints, both passes:**
- Every production registry, recovery, Resume and restart gate stays OFF.
- Nothing was run against a provider, helper, MCP executable, app, package or lifecycle.
- No auth, config, private history or capture file was read; no raw capture contents are copied here.
- Nothing was staged or committed.

Main independently verified the five raw structural facts the first pass asked about, using allowlist-only parsing:
- the exact `credential_org` type string;
- attachments carry no `message`, `subtype`, `sourceToolAssistantUUID` or true `isMeta`;
- operational records carry no `uuid` or `parentUuid` key, not even null;
- every present operational `sessionId` matches the session;
- the native user `message.content` is a plain string.

## Two different hashes

| Hash | Lives on | What it is |
|---|---|---|
| **Semantic envelope digest** (`envelopeDigest`) | each ledger row (`NativeItem`) | SHA-256 over one native entry's ordered, supported, projected semantic payload. It proves a known entry still says the same thing. Nonrendering payloads never enter it. |
| **Byte-prefix fence** (`prefixSHA256`) | baselines, cursors, and the receipt `target` | Opaque SHA-256 of the exact captured raw bytes `[0, completeLineOffset)`: original newlines, no normalization, no partial trailing record. It proves the history before a boundary is byte-identical. It is unrelated to the semantic digest and carries no meaning beyond integrity. |

## What this qualifies, and what it doesn't

It qualifies a **visible projection of the observed O19 single-text shape**: one caller user entry, eight whitelisted attachments, one text-only assistant reply, a trailing attachment, and the seven observed operational records. The fixtures are sanitized and hand-written from the capture evidence's structural description. They are not raw capture bytes.

It does not qualify the native format, other attachment kinds, thinking, tools, multi-block replies, resume, compaction or activation.

## Contract as implemented

### 1. Reader classification (`ClaudeSessionHistoryReader.parseEntry`)

**Attachments**
- `attachment` entries whose `attachment.type` is in the exact whitelist are graph nodes:
  - `budget_usd`, `credential_org`, `date`, `environment`, `model`, `prompt_snapshot`, `session_context`, `total_tokens_reminder`.
- Only these fields are read:
  - `uuid`, `parentUuid` and `sessionId`;
  - the existing top-level metadata refusals;
  - `attachment.type`.
- The payload is never projected, interpreted, logged or hashed semantically. It is covered only by the opaque byte-prefix fence.
- Anything else refuses with `.attachment(line:)`, naming no type or payload:
  - a non-whitelisted type, including `structured_output`;
  - a malformed attachment;
  - an attachment carrying a `message` or a source.

**Operational records**
- The exact types `queue-operation`, `atis-latch`, `api-request-shape`, `api-request-blob`, `api-request`, `last-prompt` and `cost-state` are skipped unread.
- That holds only when they have no `uuid` key and no `parentUuid` key (an explicit null still counts as present), and any `sessionId` they carry matches this session.
- `last-prompt.leafUuid` is never read, so a trailing attachment never becomes a message or a resume ID.

**Unknown types:** still refuse, including `structured_output`.

**Profile:** the profile is now `nativeEntriesSubsetV2` (main decision 2).
- V1 baselines stay as recorded and are never upgraded.
- They lack a prefix proof, so they fail closed through requirement 6.
- No new version or activation mechanism was added, and there was no existing profile-eligibility check to reuse: `profileName` is only recorded.

### 2. Whole-graph validation

**What is validated:** the entire complete-line capture, before the byte fences, the frontier and ledger suppression. That covers attachments and every existing safeguard.

**Branches**
- An attachment-only side branch is not a continuation, but it can't hide a message branch.
- A trailing attachment is not a tip.

**Tool results:** association is unchanged; an interposed attachment refuses. A tool result must name its source explicitly only when its call has more than one message-bearing child (a genuine fork); an attachment-only sibling no longer counts (re-review A R2).

**Projection order:** a direct chain projects in ancestor order with its original IDs and ordinals. A demonstrated tool fork keeps file order.

### 3. Semantic refusals

**Documented markers:** `supersedes`, `aborted` and `retracted_message_uuids` refuse with `.semanticMarker` when present and non-null at an entry's top level or in its `message`. An explicit `aborted: false` is not a marker. There is no recursive search.

**Already refused:** thinking blocks, compaction metadata and system entries.

**Sibling fallback and ambiguous branches:** refuse.

**Unknown persisted fields:** still round-trip.

### 4. Complete-envelope proof

**The digest:** every row carries its entry's `envelopeDigest`. The encoding is length-prefixed and covers the entry type, the block count, and each block's kind, ordinal and supported payload. Every row of an entry carries the same value.

**Persistence:** `NativeItem.envelopeDigest` is optional and omitted when nil.

**Tolerant decoding (follow-up, main decision 4):**
- Exactly 64 lowercase hex digits → a typed proof.
- Missing → nil.
- Anything else → nil, with the exact raw value kept in `extras` and re-encoded unchanged. That covers wrong case, wrong length, the wrong alphabet, an empty string, null, a number or an object.

A valid typed value overwrites a preserved raw one; nil never erases it. A malformed proof therefore never fails the ledger or the session.

The 4d1 `OutboundUserMessage` decoding is unchanged: a malformed claim still makes its baseline unreadable.

**The ledger check:** before any ledger suppression, every ledger-known entry of this session must:
- exist in the observed capture;
- have exactly the observed row-key set and count;
- carry, on every row, the observed digest.

A missing entry, a missing or malformed legacy proof, a changed payload, a partial keyset or a superset keyset refuses with `.ledgerConflict`.

**Materialization and Codex:** suppression is per entry, so materialization is all-or-nothing per entry. Codex rows carry no digest, and Codex behavior is unchanged.

### 5. Claim association (`AgentProviderHistoryAssociationPreflight.check(..., dispatchWindow:)`)

**The window:** the source attempt's baselines only (main decision 5). Native user entries from a later attempt after the boundary conservatively refuse.

**When it applies:** only when every window baseline carries a 4d1 claim.

**What must match exactly:**
- One native user entry per claim.
- Each entry ID equals its claim's UUID (lowercase).
- Entries are in dispatch order, with equal text digests.
- There are no duplicate claims and no unclaimed native user entry.
- Every dispatch's complete constituents are in the canonical transcript, in order.

**On any mismatch:** the result is `.outboundClaimUnmatched`.

**What never happens:**
- A claimed UUID is never treated as proof of a write.
- A missing entry is never read as non-delivery.
- Nothing is resent.
- Consumed claimed users are never re-created as rows.
- Saved live output under unmatched IDs still refuses.

**Legacy windows:** a window containing an unclaimed baseline keeps the existing `.nativeUserAssociationUnavailable` path. So does a same-attempt baseline recorded unsupported, such as a steer read mid-write (re-review B P2-03). Only a provider, conversation, attempt or generation mismatch in the window is `.baselineTargetMismatch`.

**Canonical output after the boundary:** only the turn holding the dispatch's first user item filters output before it. Every later persisted turn's output counts in full, whatever that turn's own request (re-review A R1). The Codex overlap check shares this helper, so it is now equally strict across turns.

### 6. Byte-prefix fences (follow-up, approved bounded completion; existing authorities only)

**Representation.** No new store, journal, collection or framework was added.
- `AgentRecoveryHistoryPrefixFence { file?, completeLineOffset, prefixSHA256? }` is a plain value.
- **Baselines and cursors:**
  - optional `DispatchBaseline.prefixSHA256` (session JSON);
  - optional `AgentRecoveryHistoryCursor.prefixSHA256` (recovery-record JSON, through the existing codec).
  - Both use the same tolerant rule: a valid value is typed, and anything else is nil with the raw value preserved and re-encoded unchanged.
- **Receipt:** `ImportCommit.target`, an optional nested object `{fileDevice?, fileInode?, fileBirthSeconds?, fileBirthNanoseconds?, completeLineOffset, prefixSHA256}`.
  - It is all-or-nothing. A missing or wrong-typed member, an unknown member, half a file identity, or an invalid proof leaves no target, with the raw value preserved.
  - It is bound in the same session save as the rows and the ledger.
- **Codex:** Codex observations carry no proof, so Codex receipts have no target and Codex cursors have no proof; both encode as before.

**Capture**
- The reader computes the proof inside its existing off-main decode, from the same buffer it validated. There is no second path read, and nothing raw is logged or persisted.
- One incremental SHA-256 pass covers every fence offset plus the candidate's own complete end.
- Every candidate carries `prefixSHA256` for its complete lines; a partial trailing record is excluded.
- Verified absence gives the SHA-256 of the empty prefix, never nil. It keeps `file == nil`, while an existing empty file keeps its identity.
- An unreadable or ambiguous file is never verified absence, as before.
- No legacy proof is synthesized on decode.

**Verification.** All checks run against the same captured buffer.
- **Applicable fences:**
  - the import boundary, which is the source attempt's earliest baseline;
  - every captured baseline in the source attempt's dispatch window for this provider and conversation (the claims' baselines included). A foreign one fences nothing, so the preflight reports its `baselineTargetMismatch` (re-review B P3-01);
  - the latest durably saved Claude target of this conversation;
  - the persisted record cursor for this conversation, when present (final pass, below).
- **When the latest saved target is unavailable** (`latestSavedClaudeTargetFence`): it contributes a proofless fence instead of being left out, so the import fails closed. That covers:
  - the latest receipt is Claude's, for this conversation, but has no valid target (legacy or malformed);
  - Claude rows of this conversation were imported, but the latest receipt is absent or belongs to another provider or conversation.
- **Record cursor fence (final pass, main spot-check):** reconcile passes the matching persisted record cursor's fence as one more fence, before the observation.
  - It is never the frontier or a fallback; the attempt's baseline stays the starting boundary.
  - A present cursor with a missing or malformed proof fails closed.
  - A changed proof refuses even when the baseline and the latest receipt verify.
  - A different file identity with a verifying prefix is accepted as before.
- **What each fence requires:**
  - a valid proof (else `.prefixProofUnavailable`);
  - an offset at or below the complete end, on a record boundary;
  - the exact digest of the bytes before it (else `.rewrittenHistory`).

**Changed file identity:** a rescan is permitted only when every fence verifies byte-for-byte. The frontier is then the boundary offset (no rewind), and the existing graph and session checks apply.
- Truncation or any different prefix refuses, whether the inode is the same or not.
- The former ledger-based resume (`baselineLost`) is removed.
- The pre-boundary/post-boundary parent check stays.

**Receipt, cursor and CAS**
- The planner binds the observation's target into `ImportCommit.target` and into the new cursor's `prefixSHA256`.
- The store's cursor CAS exact-repeat check now compares the proof too: an equal import ID with a different file, offset or proof (including a missing one) conflicts.
- The existing fresh-UUID-per-reconcile plan is kept, so a durable import ID is never given a new target.

**Durable save-before-CAS gap.** Main identified that the receipt had no target tuple. The receipt now carries one. After a crash between the session save and the cursor CAS, the record cursor is older, but the next reconcile still fences the saved receipt's target. Append-only growth imports under a new receipt only after the previous target verifies.

**Baselines** (main decisions 1 and 3: kept). A new Claude baseline verifies this conversation's latest saved target (`claudeBaselineFences`) before it can become the latest receipt.
- On a mismatch, or when the target is unavailable after imported history, the baseline is recorded unsupported, with separate reasons (re-review B P3-02):
  - changed history: `recoveryBaselineRewrittenReason`, "Claude history no longer matches its last recovered position";
  - a lost or unproven target: `recoveryBaselineUnprovenReason`, "Claude history's last recovered position has no integrity proof this version can check".
  - It gets no claim and no UUID, and the ordinary existing unsupported send proceeds.
  - The old receipt stays latest, and a fresh proof is never minted over a lost previous import target.
- If only the latest receipt changed between the read and the append, while the session, owner and conversation are still current, the baseline is recorded unsupported (`recoveryBaselineReceiptMovedReason`) and the ordinary send proceeds (re-review B P2-02, main's revision). There is no reread or retry. A real ownership change is still refused as stale, with zero bytes.
- Its zero-row receipt binds the same target the baseline owns.
- A legacy target-less zero-row receipt, with no imported Claude rows for this conversation, fences nothing. A normal fresh first baseline stays allowed.

**Conservative multi-conversation limit (main decision 2: no per-conversation target collection).**
- The session keeps exactly one latest receipt. Once Claude rows of a conversation were imported, its last saved target must still be that latest receipt.
- If a receipt from another provider (Codex) or another conversation replaced it, or it is absent:
  - returning imports of that conversation refuse with `recoveryHistoryUnprovenText`;
  - its new baselines are recorded unsupported.
- This deliberately gives up per-conversation retention rather than adding architecture.
- Rows, ledger and raw data are kept unchanged; nothing is resent, and normal sending isn't blocked.

**User-visible text**
- `.rewrittenHistory` and `.ledgerConflict` show `recoveryHistoryChangedText`.
- `.prefixProofUnavailable` shows the new `recoveryHistoryUnprovenText`: "A saved history position for this conversation has no integrity proof this version can check, so its history can't be matched safely. Nothing was imported."
- The `baselineLost` text was removed together with its case.

**Left untouched:** the pending-write, ownership, hydration, lease and generation checks.

## Re-review 1 repairs

Scope fixed by main after verifying both review presets and reading the full responses: one blocking finding (A R1) and the selected cheap P2/P3 items. No new architecture, activation or live work. The repair delta is unstaged on top of the staged initial snapshot.

| Finding | Exact delta | Test evidence |
|---|---|---|
| **A R1** (blocking): later persisted turns' output was skipped | `AgentProviderHistoryImport.swift` `outputItemIDs`: `afterUser` starts true when the first user item was passed in an earlier turn (`passedInEarlierTurn \|\| requestMatches`). First-turn filtering is unchanged. | `testCanonicalOutputOfEveryLaterPersistedTurnIsChecked` (pure; Claude claimed window plus a Codex overlap row). `testUnassociatedLiveOutputInALaterPersistedTurnRefusesWithoutChangingAnything` (window 4994, real composition): two persisted turns, both claims exact, live output in turn 2 → `.canonicalOutputAssociationUnavailable` with items, ledger and cursor unchanged; without that output, both replies import. |
| **A R2**: attachment-only sibling forced the fork-source rule | `ClaudeSessionHistoryReader.validateGraph`: the explicit-source requirement uses `childIndexes.count(where: { bearing[$0] }) > 1`. | `testAttachmentsKeepEveryGraphSafeguard`: a sequential result without a source plus an attachment sibling projects `u1, a1, r1, a2`; a genuine fork without a source still refuses `forked tool result without source r1`, with or without the sibling. |
| **B P2-03**: wrong reason for an unsupported same-attempt baseline | `claimAssociation`: identity checks give `.baselineTargetMismatch`; a non-captured window entry gives `.legacy`. | New row in `testOutboundClaimsAssociateOnlyAnExactNativeUserMatch` → `.nativeUserAssociationUnavailable`. The foreign-conversation row still gives `.baselineTargetMismatch`. |
| **B P2-04**: baseline mode projected rows it discarded | `ClaudeSessionHistoryReader.decode`: `chainOrder`/`project` moved into `case .importAfter`, after the whole parse, graph and fence validation. Neither can fail, so baseline validation is unchanged. | Existing baseline and import reader tests pass unchanged. |
| **B P2-02** (main revised the earlier refusal) | `captureClaudeDispatchBaseline`: a receipt-only change re-checks `stillCurrent` (refused if stale), then `recordUnsupported(recoveryBaselineReceiptMovedReason)`. No claim, UUID or proof; the unsupported entry never replaces the receipt. | No view-model test: the only seam (`test_recoveryClaudeHistoryHomes`) fires before `fencedReceipt` is captured, so it would need a new read hook. Not built, per main. |
| **B P3-01** | `claudePrefixFences` filters window fences to Claude and this conversation. | `testClaudePrefixFencesCoverTheWindowAndTheLatestSavedTargetOnly`: a foreign captured baseline with a proof contributes nothing. |
| **B P3-02** | Separate reason constants for changed history and missing proof (above). | Wiring only; no new test. |
| **B P3-03** | No code change needed (main verified `Decimal`). | `testMalformedOptionalProofsLoadRoundTripVerbatimAndClaudeRefusesThem`: a target with inode `(1 << 60) + 3` round-trips exactly, both re-encoded and from a JSON literal. |
| **B P3-05** | Reader test class doc says `nativeEntriesSubsetV2`. | n/a |

**Negative checks.** Each fix was reverted temporarily, and the suite rerun, to confirm the new assertions catch the defect. Both reverts were restored byte-for-byte from a backup.
- Without the A R1 fix: 8 failures, all in the two new R1 tests. The view-model test imported native output on top of the live item. Ticket `b4e9d5d6`.
- Without the A R2 fix: 2 failures, both on the new sequential-sibling case. Ticket `08d3c83c`.

**Errors during this pass:** one format/lint `docComments` finding, from a comment placed directly above a nested test function. It was moved into the function body; `dev-format` was not run.

**Deferred by main (not changed):**
- P2-01: requalifying a proofless legacy cursor. Accepted as a fail-closed pre-activation boundary; no CAS renewal of an old unknown proof.
- P3-04: the optional predicate cleanup.
- The rest of P3-06: view-model coverage without a cheap existing seam, including the P2-02 race.
- P3-07: cross-OS qualification of the tool JSON digest.
- Overlap protection for imported rows' canonical semantic payload and for mutated live identifiers belongs to the next carrier step.

## Changed files (worker pass inventory)

This inventory was recorded before the final review repairs. The initial review snapshot contains ten intended source/test files (+2206/−112); its repair delta adds +275/−20 across five of those files. Pre-existing changes in `CodemapSeamTestSupport.swift` are unrelated and are excluded from the checkpoint.

| File | Change |
|---|---|
| `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift` | See below |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | See below |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentRecoveryActionModels.swift` | `AgentRecoveryHistoryPrefixFence`; `AgentRecoveryHistoryCursor.prefixSHA256` and `prefixFence` |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryRecordCodec.swift` | Tolerant cursor `prefixSHA256` decode; a typed value overwrites the raw one |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryStore+Actions.swift` | The cursor CAS exact repeat compares the proof |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift` | See below |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift` | See below |
| `Tests/RepoPromptTests/AgentMode/Recovery/ClaudeSessionHistoryReaderTests.swift` | Proof-carrying cursor helper; 12 Step 4d2 tests; one replacement test rewritten |
| `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryReconciliationTests.swift` | Step 4d2 model, pure and composition tests |
| `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryActionTests.swift` | Cursor proof CAS and codec test |
| This file | Rewritten for both passes |

`ClaudeSessionHistoryReader.swift`:
- the first-pass changes (whitelists, semantic markers, chain order, envelope digest, ledger proof, claim user entries);
- the `nativeEntriesSubsetV2` profile;
- `Candidate.prefixSHA256`;
- `read` and `decode` take `fences:`;
- `verifyFences`, a single incremental pass;
- the strict frontier, with `baselineLost` removed;
- `.prefixProofUnavailable`;
- the header contract.

`AgentSessionProviderHistoryRecovery.swift`:
- tolerant `NativeItem.envelopeDigest`;
- `DispatchBaseline.prefixSHA256`, which its `cursor` carries;
- `ImportCommit.target`;
- `HistoryDynamicKey.tolerantDigest` and an `encode(…overriddenBy:)` that skips overridden raw values;
- `hex(_:)`.

`AgentProviderHistoryImport.swift`:
- the first-pass association changes;
- `AgentProviderHistoryObservation.prefixSHA256`;
- the planner binds the receipt `target` and the cursor proof;
- `claudePrefixFences` and `claudeBaselineFences`, sharing `latestSavedClaudeTargetFence`, which returns a proofless fence when the target is unavailable after imported history.

`AgentModeViewModel+RecoveryActions.swift`:
- the first-pass changes;
- baseline admission:
  - verifies the previous proven target;
  - records the proof and the receipt target;
  - records an unsupported baseline if only the latest receipt changed; actual ownership staleness still refuses;
- reconcile passes the window fences, the receipt fence and the record cursor's fence;
- the unproven text;
- `baselineLost` text removed.

**Not changed:** the controller, the TaskLocal, the live translator/reducer, the Codex adapters, the frozen ledger, and plan, status or guardrail docs. The dirty `CodemapSeamTestSupport.swift`, `phase4d-claude-capture.md` and other docs are pre-existing dirt that isn't mine, and were left untouched.

## Acceptance coverage

**Reader, first pass** (`ClaudeSessionHistoryReaderTests`):
- `testCaptureQualifiedSingleTextTurnProjectsOnlyTheClaimedUserAndAssistantText`: covers all 8 attachment types and all 7 operational types.
- `testDirectChainProjectsInAncestorOrderWithOriginalIDsAndOrdinals`
- `testAttachmentAndRecordPayloadsNeverReachRowsDigestsOrRefusals`: sentinels never appear in rows, digests, descriptions or refusals.
- `testUnknownMalformedOrIdentityBearingNonrenderingRecordsRefuseTheWholeCandidate`
- `testAttachmentsKeepEveryGraphSafeguard`
- `testDocumentedRetractionThinkingAndCompactionMarkersRefuse`
- `testRefusalsBeforeTheCursorStillRejectWithAKnownLedger`
- `testLedgerKnownEntriesMustMatchTheirCompleteEnvelopeBeforeSuppression`
- `testASameFileCursorMustStayOnARecordBoundaryAndNeverSplitTheGraph`: the boundary case now uses a matching digest, so only the boundary rule refuses.

**Reader, follow-up:**
- `testReplacementRescansOnlyWhenItsFencedPrefixVerifiesAndTruncationOrADifferentPrefixRefuses`
  - It replaces the old replacement test, deliberately updating the fixture authority. The old test pinned the removed ledger-fallback rescan and `baselineLost`.
  - It keeps "a replacement with the same history rescans and never duplicates known rows". It adds the cursor and receipt binding, and that truncation and a different prefix refuse, on the same inode or a replaced one. A legacy cursor refuses with `.prefixProofUnavailable`.
- `testCandidatesCarryTheExactRawDigestOfTheirCompleteLinesOnly`: exact prefix capture; trailing whitespace and a partial appended tail are excluded; CRLF is hashed raw (no normalization); verified absence and an existing empty file both prove the empty prefix and are distinguished by file identity.
- `testASameLengthChangeBeforeTheBoundaryRefusesEvenInNonrenderingBytes`: same-length changes to a pre-cursor attachment payload, or to an operational-record payload, refuse with `.rewrittenHistory` on the same inode. A missing, malformed or uppercase proof refuses with `.prefixProofUnavailable`.
- `testEveryCallerFenceIsVerifiedOnTheSameBufferBesideTheBoundary`:
  - A change after the boundary passes with the boundary alone, but refuses once the later saved target is fenced.
  - A fence beyond the complete lines, or a proofless fence, refuses.
  - Baseline mode verifies fences and produces its own proof.
  - Verified absence satisfies only an empty-prefix fence.

**Reconciliation and model** (`AgentRecoveryReconciliationTests`):
- `testNativeItemEnvelopeDigestIsOptionalAndKeepsUnknownMembers`: renamed from the first-pass strict test. Its malformed-throws loop was replaced by the tolerant test below, per main decision 4.
- `testMalformedOptionalProofsLoadRoundTripVerbatimAndClaudeRefusesThem`
  - Malformed envelope digests, baseline prefixes and receipt targets cover wrong case, wrong length, the wrong alphabet, an empty string, null, a number and an object. Targets also cover a malformed nested proof, a missing offset, an unknown member and half a file identity.
  - Every one decodes as nil, keeps its exact raw value, and re-encodes unchanged.
  - A typed value overwrites the raw one.
  - A whole session with all three malformed proofs loads and round-trips through `AgentSessionDataCodec`, and its baseline stays readable.
  - Claude refuses each: a malformed row digest gives `.ledgerConflict`, a proofless boundary and a legacy receipt each give `.prefixProofUnavailable`.
- `testClaudePrefixFencesCoverTheWindowAndTheLatestSavedTargetOnly` (pure): fence assembly, never backfilled.
  - Without imported rows, another conversation's or Codex's receipt is excluded, and a fresh first baseline is allowed.
  - With imported Claude rows of this conversation, these all give a proofless fence for both imports and baselines: no receipt, a Codex receipt, another conversation's receipt, or a receipt without a target.
  - A matching proven target is used.
  - Another conversation's imported rows never block this one.
- `testOutboundClaimsAssociateOnlyAnExactNativeUserMatch` (pure, first pass).
- `testClaimedBaselineImportsTheCaptureQualifiedReplyOnceAndRefusesUnprovenLedgers` (composition, first pass; passes unchanged): import, second no-op, crash-replay no-op, and changed text, a superset keyset and missing digests each refusing with no state change. The changed text is now caught first by the saved-target fence, with the same text.
- `testAMissingClaimedSteeringEntryRefusesWithoutChangingAnything` (composition, first pass).
- `testTheLatestSavedTargetFencesTheImportAfterALostCursorCommit` — the **critical** composition:
  - **Seams:** real `ProducerHarness` and persistence, recovery store, reader and planner; no process.
  - **Setup:** the V2 baseline proves the empty prefix, and its zero-row receipt binds that target.
  - **Import:** the import binds `target` (file, the exact complete offset, and the SHA of the complete bytes) durably in the session save. The cursor carries the same fence.
  - **Crash after the save, before the CAS:** emulated by rolling the record cursor back to the OLD boundary. A normal replay is a no-op.
  - **Rewrite after the old cursor but before the saved target:** a same-length change to an attachment payload refuses with `recoveryHistoryChangedText`. No envelope proof covers that payload, and the old boundary alone verifies. Items, ledger and cursor are unchanged.
  - **Truncation below the saved target:** refuses with no change.
  - **Legacy proofs:** a latest receipt without a target, and a V1 baseline without a proof, each refuse with `recoveryHistoryUnprovenText` and no change.
  - **Growth:** append-only growth with a partial tail imports exactly the new reply under a new receipt and import ID. Its target excludes the partial tail; the cursor CAS from the old cursor succeeds and follows it.
  - **Persistence:** the session JSON has no sentinel, original or rewritten. Only digests are persisted.

- `testALostSavedTargetAndTheRecordCursorProofFailClosed` (final pass, real composition, no process):
  - **Record cursor fence:** after an import, the record cursor is replaced through the real CAS.
    - A changed proof refuses with `recoveryHistoryChangedText`, even though the baseline and the latest receipt verify.
    - A nil proof refuses with `recoveryHistoryUnprovenText`.
    - A different file identity with the same verified prefix is a no-op, as before.
  - **Lost target:** after A was imported and the latest receipt became Codex's, another conversation's, or none, the returning A import refuses with `recoveryHistoryUnprovenText`. Items and ledger are unchanged.
  - **No renewal:** a new claimed A baseline over the lost target gives `.admittedWithoutIdentity`.
    - The baseline is unsupported, with no claim and no prefix.
    - The latest receipt is unchanged (no fresh proof).
    - Rows are kept.

**Cursor store and codec** (`AgentRecoveryActionTests`):
- `testHistoryCursorPrefixProofIsPartOfTheExactRepeatAndDecodesTolerantly`:
  - An exact repeat with the same proof is `unchanged`; an altered or missing proof under the same import ID conflicts.
  - Malformed stored proofs (uppercase, short, number, null, object) survive a fresh store verbatim as `extras` with a nil proof.
  - A typed proof replaces a stale raw one.

All meaningful earlier tests still pass. No assertion was weakened.

## Validation

**First pass** (before the follow-up):

| Check | Ticket | Result |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` | `f3617c85` | passed |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | `ea4094c9`, rerun `25b7b2d7` | 31 passed both times |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `6b479158`, rerun `6686ada9` | 32 passed both times |
| `make dev-format-check` (first) | `056af240` | 5 findings, fixed by hand |
| `make dev-format-check` | `1dd01eba` | clean |
| `make dev-lint` | `df48c84f` | passed |

**Follow-up pass:**

| Check | Ticket | Result |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` (compile only, after all source edits; no source changed after) | `1ce5feac` | passed |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` (first attempt) | n/a | test-target compile error in my new `AgentRecoveryActionTests` code (`await` inside `XCTUnwrap`); fixed |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | `6a55e343` | 34 passed |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `c6a44495` | 35 passed |
| `make dev-test FILTER=AgentRecoveryActionTests` (cursor CAS and codec) | `99b9ce9e` | 29 passed |
| `make dev-test FILTER=AgentRecoveryStoreTests` (store and record encoding) | `7e5dd0b0` | 21 passed |
| `make dev-format-check` (first) | n/a | 2 findings in the reader tests (`hoistTry`, `redundantThrows`); fixed by hand, `dev-format` not run |
| `make dev-format-check` | `1bd647d6` | 0/2175 files need formatting |
| `make dev-lint` | `84197bab` | passed |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` (after the test-only format fixes) | `af369ba1` | 34 passed |

**Final pre-review pass:**

| Check | Ticket | Result |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` (compile only, after the source edits; no source changed after) | `219cd785` | passed |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `643210a6` | 36 passed |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | `ecbf7899` | 34 passed |
| `make dev-format-check` (first) | `3d81d583` | 4 `docComments` findings in my new test comments, fixed by hand |
| `make dev-lint` (first) | `a7fed2d9` | failed on the same 4 findings |
| `make dev-format-check` | `ad93f455` | 0/2175 files need formatting |
| `make dev-lint` | `ae924b90` | passed |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` (after the comment moves) | `3768bdfb` | 36 passed |

The cursor codec and store paths were not re-run in this pass, because they did not change.

**Re-review 1 repairs:**

| Check | Ticket | Result |
|---|---|---|
| `make dev-swift-build PRODUCT=RepoPrompt` (compile only, after every source edit; no later source change) | `dffc6416` | passed |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` | `750531a6` | 38 passed (36 + 2 new) |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` | `1bb3636b` | 34 passed |
| Negative check, A R1 fix reverted then restored | `b4e9d5d6` | 8 expected failures |
| Negative check, A R2 fix reverted then restored | `08d3c83c` | 2 expected failures |
| `make dev-format-check` (first) | `ed5cd72c` | 2 `docComments` lines in one new test comment, fixed by hand |
| `make dev-lint` (first) | `5901b32d` | failed on the same finding |
| `make dev-format-check` | `4b91e11c` | clean |
| `make dev-lint` | `5c97f0d0` | passed |
| `make dev-test FILTER=AgentRecoveryReconciliationTests` (final, restored sources) | `dc05a62a` | 38 passed |
| `make dev-test FILTER=ClaudeSessionHistoryReaderTests` (final, restored sources) | `1000d8dd` | 34 passed |

The cursor, action and store code did not change in this pass, so `AgentRecoveryActionTests` and `AgentRecoveryStoreTests` were not rerun.

**Not run:**
- the full test suite, `make dev-build`, packaging, the app or lifecycle;
- `make dev-provider-test`, and the controller, write-fence, handoff and `AgentModeRunServiceLifecycleTests` suites, because their code paths are unchanged;
- the Codex-specific recovery suites beyond the Codex tests inside `AgentRecoveryReconciliationTests`, which passed;
- `Scripts/check-agent-context`, because main owns the allowlist, links and status.

## Limitations and questions for main

1. **The fixture is sanitized and hand-written.** Main verified the five raw structural facts. Only the O19 single-text shape is qualified.
2. **Marker locations in native files are unobserved.** Only the documented snake_case names, at the entry top level and in `message`, are checked.
3. **Baseline-side verification: kept** (main decision 1).
4. **The multi-conversation limit is resolved conservatively** (main decision 2), as described in requirement 6. A conversation whose last saved target was displaced can't import or qualify new baselines again in this session until a future, approved retention design. No per-conversation target collection was added.
5. **The stale-receipt race.** Main decision 3 (refusal, zero bytes) was revised at re-review 1 (B P2-02). A receipt-only change now records an unsupported baseline, and the ordinary send proceeds. A real ownership change still refuses. This path has no view-model test (no existing seam).
6. **The planner does not re-check proofs.** It relies on the reader's checks and on the view model's unchanged-ledger guard between read and plan.
7. **A full-file hash on every reconcile.** Fence verification hashes the full captured complete prefix once per reconcile or baseline, up to the existing 64 MiB read cap, off the main actor in one incremental pass.
8. **Deferred.** The live single-text carrier; matching live output with random IDs (it still refuses); broader thinking, tool, multi-block and resume qualification; activation; live acceptance (O3).
