# Step4d2 initial review — OracleB

Scope: read when the task touches the initial Step4d2 Claude native history projection and reconciliation review.
Authority: Reference
Last-verified: 2026-10-23

Snapshot: `2026-10-23/2057`. Returned preset `7CDD523E-1D7C-47EA-98FE-D5FEA24D2D8C` / `OracleB` verified; explicit selection. Findings below retained verbatim; main dispositions are in phase4-prerequisite-resolution.md.

# Oracle Review

# Step 4d2 review: Claude capture-qualified projection and payload-safe history import

This diff makes the Claude history reader accept the observed native turn shape (profile `nativeEntriesSubsetV2`):

- **Attachments:** the eight whitelisted attachment types become graph nodes that are never shown in the transcript, and their payloads are never read.
- **Operational records:** the seven UUID-less operational types are skipped, but only if they carry no `uuid`/`parentUuid` key and any `sessionId` matches this session.
- **Refusals:** retraction markers (`supersedes`, `aborted`, `retracted_message_uuids`), thinking blocks, compaction markers and unknown shapes reject the whole candidate.
- **Ordering:** a direct chain is now listed in parent-to-child order, and trailing attachments are not counted as conversation tips.
- **Two proofs per import:**
  - Every row carries a SHA-256 of its entry's supported content. Before any known entry is skipped, every entry in the ledger must reappear with exactly the same row keys and the same digest.
  - A raw SHA-256 of the file's complete bytes is checked from one captured buffer. It covers the attempt's starting position, every dispatch position in the attempt, the latest saved receipt's target, and the stored recovery cursor.
- **Receipt target:** the import receipt now saves its exact target in the same session save as the rows and ledger, so a lost cursor commit no longer loses that position.
- **Claim matching:** the attempt's recorded outbound claims (from Step 4d1) are matched exactly against the native user entries after the starting position.
- **Saved data:** malformed or legacy proofs still load and re-save unchanged, but never qualify.

I traced the reader, preflight, planner, codecs and view-model wiring against the acceptance criteria and found **no P0 or P1**:

- Graph validation runs before any skipping of known entries, and fences are checked before the starting offset is used.
- The fence check rejects offsets past the end or not on a line boundary before converting them to `Int`.
- Missing proofs are never made up. Verified absence produces the empty-input digest.
- A same-length rewrite or a truncation fails closed.
- The exact-repeat cursor commit now also requires the same proof.
- Codex paths are unchanged.
- Refusal values only name constants, entry UUIDs or the `type` string, never attachment or record payloads.

The findings below are wrong messages, permanent stuck states, wasted work and test gaps.

## P2 — Real defects, unlikely or easy to work around

### P2-01: A proofless recovery cursor permanently blocks the conversation
- **Scenario:** a conversation has a stored recovery cursor without a proof, for example one seeded by a Step 4d1 (V1) baseline in a qualified dev run. Every later reconcile adds that cursor as a fence and refuses with `prefixProofUnavailable`.
- **Why it never clears:** only two things can replace the cursor:
  - a successful import, which is now impossible;
  - a baseline seed, which only writes when no cursor exists (`expectedPreviousImportID: nil`).

  So new V2 attempts on that conversation can never import, even with fully proven baselines and claims.
- **Impact:** history recovery for that conversation is permanently disabled, and no message explains it. Production gates are off, so only dev-qualified data is affected today. It will matter once activation happens.
- **Evidence:**
  - `AgentModeViewModel+RecoveryActions.swift` ~1113–1128: `recordCursorFence` is appended to `claudeFences` unconditionally.
  - ~1034: the seed `commitHistoryCursor(expectedPreviousImportID: nil, …)`.
- **Smallest fix (pick one):**
  - When a captured V2 baseline commits and the existing record cursor has `prefixSHA256 == nil`, compare-and-swap it out using the existing `importID`.
  - Or record this as an accepted boundary under `assumed:`. The code comment already says the cursor is "only an optimization", which argues for the first option.

### P2-02: A concurrent receipt change blocks the user's send instead of downgrading it
- **Scenario:** two Claude dispatches are admitted close together, for example send then an immediate steer, or a double-click. The second admission's read used fences from the earlier `lastImportCommit`. The first admission then commits its zero-row receipt. The second hits `guard session.providerHistoryRecovery?.lastImportCommit == fencedReceipt`, returns `.refused(stale)`, and `admitClaudeDispatchBaseline` turns that into `.denied`. Zero bytes are sent.
- **Impact:** the user's message is not sent, even though the session is still current. Before this diff, both admissions went ahead.
- **Evidence:** `AgentModeViewModel+RecoveryActions.swift` ~962–965 (new guard), ~847–850 (`.refused` → `.denied`).
- **Smallest fix:** on a receipt mismatch, either re-run the read once with fresh fences, or call `recordUnsupported(...)` so the ordinary send proceeds with no claim. Keep `.refused` only for real `stillCurrent` failures.

### P2-03: A steering dispatch with an unsupported baseline refuses with the wrong reason
- **Scenario:** a steering dispatch in the attempt is recorded `.unsupported`. That happens easily, because a steer's baseline is read while the CLI is writing, which can give `partialTrailingRecord`. `claimAssociation` then requires every window entry to be `.captured` and returns `.refused(.baselineTargetMismatch)`.
- **Impact:** the user sees "The saved history position doesn't belong to this conversation and run". That is false: it is the attempt's own dispatch without a claim. The refusal itself is correct; only the reason is wrong.
- **Evidence:** `AgentProviderHistoryImport.swift` ~401–407.
- **Smallest fix:** check status separately and return `.legacy`, or `.refused(.outboundClaimUnmatched)`, when a window entry is unsupported. Keep `.baselineTargetMismatch` for provider, conversation, generation or attempt mismatches. Add one row for this to `testOutboundClaimsAssociateOnlyAnExactNativeUserMatch`.

### P2-04: Baseline mode does the full row projection and then throws it away
- **Scenario:** every Claude dispatch admission, which runs before any bytes are sent, runs `chainOrder`, then `project`, which computes a per-entry SHA-256 and deterministic UUIDs for every row. In `.baseline` mode the rows are then discarded. This comes on top of the new whole-prefix SHA-256.
- **Impact:** extra delay on every send, for conversations up to 64 MB. The host is noisy, so treat this as advisory.
- **Evidence:** `ClaudeSessionHistoryReader.swift` ~420–421, before `switch mode` at ~423.
- **Smallest fix:** move `order` and `rows` inside `case let .importAfter(cursor):`.

## P3 — Improvements

- **P3-01 (`ClaudeSessionHistoryReader.swift` ~420, `AgentProviderHistoryImport.swift` ~270–277): window fences are not filtered by conversation.** `claudePrefixFences` fences every captured baseline in the attempt window, even one with a different `conversationID`. Such an attempt then refuses inside the reader with "history no longer matches", before the preflight can return its more accurate `baselineTargetMismatch`. Fix: `window.filter { $0.conversationID == conversationID && $0.providerRaw == ClaudeSessionHistoryReader.providerRaw }`.
- **P3-02 (`AgentModeViewModel+RecoveryActions.swift` ~942–946): one message covers two different failures.** `prefixProofUnavailable` (the last target was lost or never proven) records the reason "no longer matches its last recovered position". Give it a separate reason string, mirroring `recoveryHistoryUnprovenText`, so diagnostics can tell the two apart.
- **P3-03 (`AgentSessionProviderHistoryRecovery.swift` ~187–196): fragile number round trip for the receipt target.** `target` is decoded by converting to `AgentScheduledSendJSONValue`, encoding with `JSONEncoder`, then decoding `TargetCoding`. If that JSON value type stores numbers as `Double`, a large `inode`/`device` that isn't exactly representable could fail to decode. The target would be dropped and the conversation would then refuse as unproven. The test only covers `1 << 60`, which is exactly representable. I couldn't confirm the number representation because `AgentScheduledSendJSONValue` isn't among the selected files.
  - Fix: decode `TargetCoding` straight from the container with `try? container.decodeIfPresent(TargetCoding.self, …)`, keep the raw value only for the member-subset check and `extras`, and add a test with a non-power-of-two value above 2^53.
- **P3-04 (`AgentProviderHistoryImport.swift` ~252–254 and ~287–289): duplicated logic.** The `hasImportedHistory` predicate appears twice; extract it into one private helper.
- **P3-05 (`ClaudeSessionHistoryReaderTests.swift:5`): stale doc.** The class doc still says `nativeEntriesSubsetV1`.
- **P3-06 (tests): coverage gaps at the view-model level.** None of these has a test:
  - a baseline admission over a rewritten prefix while the saved target is still present and proven (the reader covers `.baseline` with fences, but not the `recordUnsupported` wiring);
  - the `fencedReceipt` mismatch race (P2-02);
  - a reconcile whose window contains an unsupported steering baseline (P2-03).
- **P3-07 (`ClaudeSessionHistoryReader.swift` `parseEntry`, tool_use branch): digest could drift across OS versions.** The content digest for a `tool_use` hashes JSON re-serialized by `JSONSerialization` with `.sortedKeys`, not the original bytes. If an OS update changes how numbers are formatted, the ledger conflict check would refuse for good on conversations containing tool calls. That fails safe, and tool turns aren't qualified for live use yet, but it's worth noting before they are.

## Checked and found sound
- The SHA-256 is finalized at several offsets without a reset. This works because CryptoKit's `finalize()` doesn't change the hasher, and the intermediate-offset tests confirm it.
- The "an entry before the starting position may not descend from one after it" check, and the `Int(...)` conversions, are only reached after the fence check has bounded the offset.
- Receipt, cursor and baseline proofs round-trip exactly. A typed value overwrites a preserved raw one, and a `nil` never erases it.
- The fixtures are hand-written and sanitized. The test that checks no sentinel string reaches the saved session file covers session persistence only. The recovery store holds only digests and offsets.
- The test changes rewrite the old rescan test to match the intended behavior (truncation now fails closed instead of rewinding). I didn't see a weakened assertion.
- Validation scope: no full suite, provider package, app lifecycle or live acceptance was run. That matches what the step claims.

## Recommendations
1. **No P0 or P1 is open.** Under the policy the step can be committed after the cheap fixes.
2. Fix P2-04 (a few lines) and P2-03 (a small check change plus one test row) now.
3. For P2-02, I'd go with "re-read once, else record unsupported" so a user's send is never blocked by a concurrent receipt update. This only matters once production gates are on, so it can be deferred, but list it.
4. P2-01 needs an owner decision: either let a captured V2 baseline replace a proofless cursor, or record "a proofless stored cursor permanently disables recovery for that conversation" as an accepted boundary. I recommend the replacement, since the cursor is documented as an optimization.
5. Take P3-01, P3-02, P3-04 and P3-05 now if convenient. Defer P3-03, P3-06 and P3-07 with notes, and don't run another review round just for them.
