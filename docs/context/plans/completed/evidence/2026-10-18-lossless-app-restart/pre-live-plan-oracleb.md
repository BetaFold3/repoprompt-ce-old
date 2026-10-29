# Remaining pre-live planning — OracleB

Scope: read when the task touches remaining lossless-restart pre-live planning or its dispositions.
Authority: Reference
Last-verified: 2026-10-23

Exact preset identity was verified by main. Full response follows; trailing Markdown hard breaks use explicit HTML line breaks in this retained copy. Original tool export remains unchanged. This is planning advice, not owner authority or source validation. See [main disposition](pre-live-work.md).

# Oracle Plan



# Lossless restart: plan for the remaining non-live work

## 1. Summary

There are four bounded source steps plus one evidence request. Everything else is either an owner decision or explicitly deferred.

- **Step 4c (Claude import):** do not build the merge pipeline. Lock in that native-file import never joins live items to native rows, and record the evidence still needed.
- **Step 4b (Restart):** restore Stage B **Retry / Quit Anyway** once the exact armed helper's exit is actually observed. This is a narrow change and does not change the failure contract.
- **Steps 5a and 5b (Phase 5):** narrow preservation for `agent_run` parent/child links and pending edit reviews. Both write to the existing recovery store, and if those writes fail, normal dispatch carries on unchanged.

Claude detach, ACP/Oh My Pi qualification, power-loss durability, polish, retention, activation and live acceptance stay deferred. Gates stay OFF. The honest end state is "source-complete, inactive, fixture-validated; live acceptance pending O3; Claude live/native merge blocked on evidence".

## 2. Current-state analysis

**Claude import** (`AgentProviderHistoryImport.plan`, lines 89–126):
- Each native row is keyed by `rowKey(provider, nativeSessionID, nativeEntryID, rowKind, ordinal)`.
- `guard knownKeys.insert(key).inserted else { continue }` means any key already in the ledger is treated as fully imported, so its content is never compared.
- A ledger entry is written only when the row is appended, or when its deterministic ID is already in `existingItemIDs`. `NativeItem.localItemID == nil` means "not projected" (for example a native user entry).
- Live items use the translator's random tool IDs, and the reducer coalesces or replaces output. So live items never collide with the native reader's deterministic IDs.
- In the code shown, the plan has no association path. The risk you describe appears only if something writes ledger keys or advances `previousCursor` from live stdout/stdin observations. The packet does not show who writes `previousCursor` or `nativeItems` anywhere else. That is the trace target.

**Restart unresolved stop** (`AgentLifecycleShutdownCoordinator`, lines 785–818; `AppRelaunchCoordinator.abandonCurrent`):
- When `abort()` ends `.unresolved` and `armWasSent` is true, the failure carries `relaunchHelperUnresolved: true`. The prompt is shown, any answer is ignored, and `relaunchHelperUnresolvedPrompts += 1`.
- The driver keeps `session`, and nothing ever observes that helper again. So once the cleanup budget is spent, an exit that happens later is never noticed.
- If Retry later reaches `prepare`, two existing guards block a fresh helper: `abandonCurrent()` must return `.safe`, and `now() < budget.workExpiry`.

**Edit reviews** (`MCPApplyEditsToolProvider` lines 172–212, `ApplyEditsApprovalStore.requestReview`, `PendingApplyEditsReview`):
- `previewResult.updatedText` exists only in the tool provider's stack frame. `PendingApplyEditsReview` holds `{id, scope(windowID, tabID), path, unifiedDiff, createdAt}` in `pendingByScope`, in memory only.
- The accept branch writes `updatedText` with no fingerprint check.
- `cleanupScope` cancels the review with "Approval scope cleaned up", so it has no preserve/withdraw disposition.
- This confirms the scout's "no payload, no fingerprint" claim for the code shown. Whether the base bytes are reachable from `preview` still has to be traced.

**`agent_run` linkage:** nothing in the packet shows it. The scout's claim (parentSessionID saved only by the scheduled save, with no parent attempt or tool-call identity before child dispatch) is unverified. `RequestMetadata` carries routing fields only (main inspected it), so no provider `tool_use` ID reaches the MCP side.

## 3. Design

### 3.1 Q1: Claude identity. Cut the merge pipeline (Step 4c)

**Recommendation:** building a conditional merge pipeline now is speculative work and should be cut.

Even if UUID = ack = native-entry identity were proven, merging would still need a content rule for partial→final. The reducer coalesces and replaces output, so a key match does not prove the content matches. Any rule written before seeing real captures would be guessed and later thrown away. Worse, an association-only ledger write would hit the `knownKeys` skip and silently drop the final tail. That is a P0 data-loss path.

**What can finish non-live:**
1. **Trace (no code).** List every writer of `AgentSessionProviderHistoryRecovery.nativeItems` and of the history cursor (`AgentRecoveryHistoryCursor`).
   - The required invariant: both are written only from native-file reads, inside `plan` or its caller.
   - If any writer is fed by the live stream (stdout envelope `uuid`, stdin ack), that is a P1. Fix it by removing that write, not by adding a merge.
2. **Regression tests for `plan`** (fixture-only):
   - Transcript holds random-ID live items for a turn, and the observation holds native rows for the same turn. The native assistant and tool rows are appended, never suppressed. Duplication is accepted; loss is not.
   - Running the same observation twice appends nothing the second time (idempotent).
   - A native row whose deterministic ID already exists is recorded with that `localItemID` and not appended.
   - A known key with `localItemID == nil` stays skipped and is never treated as a local user item.
3. **Doc invariant in the plan:** "Claude live/native association: not implemented. Import is native-authoritative and duplicate-tolerant."
4. **Evidence request, saved to the evidence directory.** It needs one tool-using turn with partial messages, captured on the O3(b) account:
   - the stdin stream-json (with the local `uuid`);
   - the stdout stream-json envelopes;
   - the resulting native JSONL.

   This capture is live execution and home inspection, so it needs the owner's approval. It should be folded into the final live verification.

Step 4c makes no behavior change unless the trace finds a live-fed writer.

### 3.2 Q2: Late helper stop restores choices (Step 4b)

**Recommendation:** worth doing, and it needs no owner decision. Choices are restored only after proof that the exact helper has exited, which is the state A P1-07 already approves. The rule "no choice while unresolved" is unchanged.

The safety argument rests on one assumption, which must be checked against the helper's source: the helper opens the bundle only after it observes the parent exit. The parent is alive while this code runs, so a helper whose exit was observed can never open anything.

**Interface additions:**

```swift
// ProcessRelaunchParentSession
func awaitObservedExit() async        // same exact-process observation abort() uses; no deadline;
                                      // returns at once if already observed; returns on task cancel
// relaunch environment protocol (the type behind `environment.relaunch`) + AppRelaunchCoordinator
func awaitRetainedHelperStop() async -> Bool
  // false: no session retained, or cancelled
  // true:  exit observed; `if session === observed { session = nil }`
```

**Coordinator flow** (the `.unresolved` arm only):
1. Await `presentFailure` exactly as today. The answer is still ignored and the counter still increments.
2. `guard await relaunch.awaitRetainedHelperStop() else { return }`.
3. `guard isCurrent(request, attempt: attempt, phase: failedPhase), request.lastFailure?.relaunchHelperUnresolved == true`. Then, in the same MainActor turn, set `request.lastFailure` to the same failure with `relaunchHelperUnresolved = false`, plus the message "The restart helper has stopped. The app will not reopen automatically."
4. Present it, then `handle(choice, …)`.

Flipping the flag inside that one turn makes the step idempotent. Any other path that re-presents `lastFailure` (whatever increments `relaunchHelperUnresolvedPrompts`) automatically sees the resolved state.

**Ordering:**
- If the exit arrives while the no-choice prompt is still showing, the choices appear after the user dismisses it.
- An exit observed twice is a no-op, because of the flag.
- If the exit is never observed, the state stays as it is today.

**Constraints (each covered by a test):**
- **No budget renewal.** Retry goes through the existing finalization. `abandonCurrent()` is `.safe` because the session is nil. Then `now() >= workExpiry` returns `budgetSpentMessage` with choices, and `spawnCount` is unchanged.
- **Quit Anyway** relaunches nothing.
- **No autoquit.**
- **`.unresolvedUnarmed` is untouched.**

**Does this fully satisfy R4's uncertainty? No.** If the helper is never observed exiting, the user still has no in-app choice and must force-quit. Removing that dead end means offering a choice while the helper may be armed, which is a contract change and needs the owner. Leave it unless the owner asks.

If the trace shows `abort()` never escalates termination of the exact child, list that as a deferred P2. It changes reviewed abort timing, so it does not belong in this step.

### 3.3 Q3: Phase 5 scope

Read "all finished" as covering the two data-preservation items in Phase 5. They are written as requirements, not experiments. Record this under `assumed:`. It is reversible, so it is not blocking.

Still deferred: Claude detach, ACP/Oh My Pi qualification, power-loss durability hardening, polish, retention, automated Restart activation and live acceptance.

#### Step 5b: `agent_run` parent/child link (smaller, so do it first)

**Trace first:**
- the `agent_run` handler;
- where the child session ID is allocated relative to dispatch;
- how the parent session is resolved from the connection;
- where the parent's active attempt ID lives in its recovery record;
- whether the recovery record type keeps unknown keys, as `HistoryDynamicKey.extras` does.

Confirm or refute the scout's claim and save the result as evidence.

**Records** (optional fields with defaults, in the existing recovery store):

```
parent record:  agentRunChildren: [{ childSessionID, invocationID: UUID (local, made at handler entry),
                                     connectionID, parentAttemptID?, createdAt, state: committed|dispatched }]  default []
child record:   agentRunParent: { parentSessionID, parentAttemptID?, invocationID }                             default nil
```

- The tool-call identity is the local `invocationID` plus `connectionID`.
- The provider `tool_use` ID is explicitly **not** joined. This is honest, and it means MCP retries cannot be deduplicated, as the spec already accepts.

**Ordering:**
1. Allocate the child ID.
2. Commit both records with an awaited commit, not the scheduled save.
3. Dispatch.
4. Mark the link `dispatched`.

**Failure handling:** if the commit fails, dispatch proceeds as today. Log it; the only cost is that recovery cannot find the child. With the gate OFF, none of this runs.

**On recovery:**
- The interrupted-turn card lists the children, with status and an Open action.
- The Resume continuation gets one line: "this turn already started agent_run child <id> (<status>); check it before starting another".
- `agent_run` is never replayed automatically.

**Tests:**
- the commit is observed before the dispatch closure runs;
- a crash between commit and dispatch shows the child as "not started / unknown";
- a failed commit still dispatches;
- with the gate off, the call sequence is byte-identical.

#### Step 5a: pending edit reviews

**Trace first:**
- whether `service.preview` exposes the base bytes it read;
- whether `ApplyEditsRequest.mode` is Codable without loss;
- whether `effectivePath` is absolute;
- the mapping scope (`tabID`) → agent session (via whoever subscribes to the review snapshot);
- every caller of `cleanupScope` and `cancelPendingReview`;
- the existing preserve/withdraw disposition enum used by `cancelPendingInstruction`.

**Record** (in the session recovery record, `pendingEditReviews: [...]`, default `[]`):

```
{ reviewID (= PendingApplyEditsReview.id), sessionID, attemptID?, absolutePath, displayPath, unifiedDiff,
  requestMode?: encoded mode, baseFingerprint {exists, sha256, byteCount},
  proposedFingerprint {sha256, byteCount}, state: awaitingReview|applicationStarted, createdAt }
```

- **Store the request, not `updatedText`.** This avoids putting whole files into recovery records. Applying after a restart re-runs `preview` with the stored mode and requires both the current base and the regenerated output to match their fingerprints.
- **Fallback:** if the mode cannot be encoded losslessly, `requestMode = nil` and the restored card is view-only.
- **Base fingerprint:** it must come from the exact bytes `preview` read. Extend the preview result with a digest. Do not re-read the file separately, because that opens a time-of-check gap.

**Flow in `MCPApplyEditsToolProvider`:**
1. After preview and before `requestReview`, commit `awaitingReview`.
2. On `.accept`, commit `applicationStarted` before `host.writeText`.
3. Remove the record after the write, on reject, on timeout, and on any non-lifecycle cancel (including "Replaced by newer…").
4. All persistence fails open. A failed write marks the review non-durable and never blocks showing or applying it, so normal dispatch is unchanged.
5. The live accept path keeps its current behavior (no new fingerprint check).

**Disposition:**
- Lifecycle teardown (quit and `prepareSessionForWindowClose`) cancels the continuation with *preserve*, which keeps the record. Add a disposition parameter to `cleanupScope`/`cancelPendingReview`. Existing callers default to *withdraw*; only the lifecycle callers pass *preserve*.
- If the tab does not resolve to an agent session (an external MCP caller), the review is not persisted. Record this as `assumed:`; the caller's RPC expires anyway.

**Card shown after restart:**

| Current file state | Card status | Actions |
|---|---|---|
| matches proposed | "applied" | Dismiss |
| matches base, state `awaitingReview` | "not applied" | Apply / Discard |
| matches base, state `applicationStarted` | "not applied" | Apply / Discard |
| matches neither | "file changed since" | View, Discard |

- Nothing is ever applied automatically.
- The card always says "the agent will not receive this result".
- Apply writes through the session window's existing host, and only if the path is under a loaded root.

**Tests:**
- write ordering (commit happens before write);
- crash in each state;
- fingerprint mismatch blocks Apply;
- *preserve* vs *withdraw*;
- a failed persistence write still shows and applies the review;
- with the gate off, nothing changes.

### 3.4 Q4: Honest labels and next input

Proposed status lines:
- `Step 4b — done | source, inactive, fixture-validated; live pending O3 | deferred: never-exits escape (owner), abort escalation P2 if absent`
- `Step 4c — done | invariant locked | blocked-sub: Claude live/native merge, evidence`
- `Step 5a / 5b — done | source, inactive | assumed: Phase 5 data items in scope; external-caller reviews excluded; local invocation identity`
- Phase 4 overall: "source-complete except Claude live/native merge (evidence-blocked)". Never "accepted".

**Exact next input from the owner (one line).** Either:
- (a) "Authorize Claude identity capture as part of the final live verification on the O3(b) account". This is my recommendation. Or:
- (b) "Accept native-only Claude import for this release; merge deferred."

## 4. File-by-file impact

| File | Change | Driver | Order |
|---|---|---|---|
| `…/Recovery/AgentProviderHistoryImport.swift` | No change expected; fix only if the trace finds a live-fed cursor or ledger writer | 3.1 | 4c |
| History import tests (existing test target) | 4 `plan` regression cases | 3.1 | 4c |
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` status and evidence dir | Invariant note, evidence request, status lines | 3.1, 3.4 | any |
| `ProcessRelaunchParentSession` (trace its file) | `awaitObservedExit()` | 3.2 | 4b-1 |
| `App/AppRelaunchCoordinator.swift` | `awaitRetainedHelperStop()`; clear `session` on an observed exit | 3.2 | 4b-2 |
| Relaunch environment protocol and its test fakes | Add method | 3.2 | 4b-2 (atomic with the line above) |
| `App/AgentLifecycleShutdownCoordinator.swift` | Late-stop continuation in the `.unresolved` arm | 3.2 | 4b-3 |
| Late-exit fixture tests | Exit after budget → choices; Retry → budget-spent, `spawnCount` unchanged; Quit Anyway → no relaunch; double exit is a no-op | 3.2 | 4b-3 |
| Recovery record model (core `Models/`) | `agentRunChildren`, `agentRunParent`, `pendingEditReviews` (optional, defaulted, extras-preserving) | 3.3 | 5b / 5a first |
| `agent_run` handler and child creation (trace) | Awaited commit before dispatch | 3.3 | 5b |
| Resume continuation builder and interrupted-turn card (trace) | Child line and children list; edit-review card | 3.3 | 5b, 5a |
| `MCPApplyEditsToolProvider.swift` | Persist, state transition and removal around lines 178–212 | 3.3 | 5a |
| Preview result type (trace) | Base digest from the bytes it read | 3.3 | 5a |
| `ApplyEditsApprovalStore.swift` | Disposition on `cleanupScope`/`cancelPendingReview` | 3.3 | 5a |
| `PendingApplyEditsReview.swift` | Unchanged (the record is a separate type keyed by `id`) | — | — |

## 5. Risks and migration

- **New record fields.** All are optional and default to empty. If the record type does not keep unknown keys, rolling back to old code silently drops them. That is acceptable, since it only loses recovery hints. Verify this during the 5b trace.
- **4b's safety argument** depends on "the helper opens only after the parent exits". If the helper's source contradicts it, stop and take it to the owner.

## 6. Implementation order

Each step gets an A/B review per O12, plus up to 2 re-review rounds.

1. **Step 4c:** trace, tests and doc. It is the smallest step and has no behavior change unless the trace finds a live-fed writer.
2. **Step 4b:** the session API, then the coordinator plus its protocol and fakes, then the shutdown coordinator and tests. The protocol and fake changes must land together.
3. **Step 5b:** trace (the scout claims become evidence), then record fields, then the commit-before-dispatch ordering, then the card and continuation line, then tests.
4. **Step 5a:** trace, then the preview digest, then the disposition parameter, then the provider persistence, then the restored card with Apply, then tests.
5. **Stop.** Report the owner input from §3.4, plus the optional never-exits escape choice. Defaults: native-only import, and keep the fail-closed behavior with no in-app escape. Continue to the final live verification only once the owner approves.
