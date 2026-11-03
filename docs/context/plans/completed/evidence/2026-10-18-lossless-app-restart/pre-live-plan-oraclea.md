# Remaining pre-live planning — OracleA

Scope: read when the task touches remaining lossless-restart pre-live planning or its dispositions.
Authority: Reference
Last-verified: 2026-10-23

Exact preset identity was verified by main. Full response follows; trailing Markdown hard breaks use explicit HTML line breaks in this retained copy. Original tool export remains unchanged. This is planning advice, not owner authority or source validation. See [main disposition](pre-live-work.md).

# Oracle Plan

# Remaining non-live restart work

## 1. Summary

Finish this as **bounded extensions of the existing architecture**, not another full Phase 4 acceptance round. The smallest useful order is: **close the speculative Claude merge branch; repair late helper-stop notification; trace and preserve pending edit reviews; trace and persist `agent_run` parent/child links; consolidate source-validation evidence and remaining blockers**. Treat the two substantive Phase 5 preservation requirements as included in “all finished,” recording that interpretation as an assumption—not an owner Decision. Keep gates OFF, automated Restart deferred under O10, live acceptance pending under O3, and experiments/polish/retention deferred. Source completion must not be presented as full R4 or lossless-restart acceptance.

This consultation uses only the supplied packet. It does not verify HEAD, inspect omitted files, or execute anything.

## 2. Current-state analysis

### Claude history reconciliation

The reported pipeline has incompatible identity domains:

- Local requests have UUIDs that the Claude protocol does not demonstrably preserve.
- The translator creates random tool IDs.
- The reducer can coalesce or replace output.
- The native reader produces deterministic IDs.

None of those facts establishes a trustworthy relationship between local requests, acknowledgements, stdout envelopes, partial output, and native-file entries.

The supplied importer establishes a separate, concrete constraint:

`observation.rows` → normalized native row key → `knownKeys` insertion → transcript append → ledger entry.

In `AgentProviderHistoryImport.plan`, an already-known key skips **all further processing of that row**. `NativeItem.localItemID` records projection association; its documented `nil` value is not evidence that a native user entry belongs to a known local user message.

Consequently, writing an association-only ledger entry before final content is imported could suppress the final tail. This demonstrates why the proposed association shortcut is unsafe; it does **not** prove the existing importer already receives such entries.

### Restart failure and retained helper ownership

`AppRelaunchCoordinator` retains an unresolved `ProcessRelaunchParentSession`. It:

- refuses replacement while stop remains unresolved;
- distinguishes “arm never sent” from “arm may have been sent”;
- uses absolute work and cleanup deadlines;
- releases its reference after authoritative safe abandonment.

`AgentLifecycleShutdownCoordinator` presents a failure after abandonment. For an arm-sent unresolved helper, it offers no effective choices and ignores any answer. The shown code contains no transition from that presented failure to a later proven-stop state.

The reusable pieces are exact helper ownership, the abandonment result, existing failure presentation, and request/attempt/phase checks. The missing bounded connection is **late stop proof → refreshed failure choices**.

This does not solve the harder case where stop remains unknowable indefinitely.

### Pending edit reviews

The shown normal path is:

`service.preview` → updated text/diff → `requestReview` → in-memory continuation → accept → `host.writeText` → freshness update.

`PendingApplyEditsReview` contains presentation data and a transient approval scope, but no replayable proposal payload or base-file fingerprint. `ApplyEditsApprovalStore` owns continuation, timeout, replacement, cancellation, and scope cleanup.

The write uses the preview’s `updatedText`; no fingerprint revalidation appears in the supplied interval. Whether surrounding services already supply fingerprints, mutation serialization, durable ownership, or recovery hooks must be traced before adding anything.

### `agent_run`

The packet describes routing-only `RequestMetadata` fields and a scout claim about `parentSessionID` plus scheduled saving. It does not supply the dispatch implementation.

Those observations do not establish a durable parent-attempt/tool-call relationship, but neither do they justify a repository-wide absence claim. The critical boundary to inspect is:

**authoritative parent execution context → child allocation → durable relationship commit → child dispatch**.

## 3. Design

### A. Claude: stop before a speculative merge implementation

**Recommendation: do not build the conditional large merge pipeline now.** Its central algorithm would depend on identity relationships that remain unproven. A disabled implementation would still incur schema, merge-policy, and review costs without establishing correctness.

#### Finishable non-live scope

1. Document the currently supported identity relationships and explicitly list the unproven ones.
2. Audit existing ledger writers in source:
   - distinguish completed native-row imports from any proposed association-only writes;
   - confirm no new followup writes association-only records into `nativeItems`;
   - identify existing violations if present, without presuming them.
3. Add or extend pure importer/model tests for:
   - repeated completed import remains idempotent;
   - `localItemID == nil` is not local-user ownership evidence;
   - the current known-key suppression behavior, explicitly labelled as demonstrating why association-only entries are unsupported.
4. Leave the merge feature blocked and inactive. Do not change the ledger schema merely to accommodate a hypothetical pipeline.

**Invariant:** identity association and completed content import are different facts. If a future design needs both, it must represent and validate both; `localItemID` alone cannot certify content completeness.

Do not join by text equality, timestamps, tool name, matching-looking UUIDs, or apparent event order.

#### Exact unblock input

An acceptable evidence packet must identify:

- the precise provider version/protocol and authoritative source or documentation;
- the supported relationship, if any, between input UUID, acknowledgement, stdout envelope, and native entry;
- partial-to-final identity and replacement/coalescing rules;
- complete versus incomplete native-entry semantics;
- examples that exercise those rules, including multiple output/tool blocks.

Existing authorized source/documentation can supply this. Otherwise, the owner must authorize a **specific controlled capture and its environment**. That is not permission to inspect home data or run providers now. Observed matching IDs alone are not a general identity contract.

### B. Restart: add late-stop recovery, not a new unknown-stop policy

**Recommendation: implement the narrow late-stop notification.** It repairs a demonstrated liveness gap after uncertainty has actually ended. It does not weaken the fail-closed rule while uncertainty remains.

#### Internal interface and ownership

Extend the existing relaunch-driver seam with a retained-helper stop observation capability. Conceptually, its payload is:

- the opaque identity of the retained helper session;
- authoritative stopped/safe-abandonment proof already recognized by the existing protocol.

Reuse an existing observer mechanism if available. Otherwise, add one narrow callback/observation facility—not a general lifecycle event framework.

`AppRelaunchCoordinator` remains the helper owner. The shutdown coordinator remains the failure/UI owner. No persisted schema changes are needed.

#### Transition

1. Register interest while handling the unresolved failure, without an observation gap. Subscription must either replay the already-proven state or be installed before abandonment can complete.
2. The existing helper channel/session detects the **exact retained helper’s exit**, or another safe-abandonment proof already accepted by the protocol.
3. Clear driver ownership only if the stopped session is still the retained session.
4. Deliver the transition onto the shutdown coordinator’s existing isolation context; the shown failure handling uses `MainActor`.
5. Revalidate request identity, attempt, failed phase, and helper identity.
6. Replace the unresolved-helper presentation with the existing Stage B failure presentation, now permitting **Retry flush / Quit Anyway**.
7. Invalidate the previous presentation generation so a delayed answer from it cannot act on the request.

Duplicate notifications are no-ops. Stale notifications cannot clear a different helper or change a newer request. Remove observation when its request is superseded or completed. Do not add a polling timer or restart the cleanup timer.

#### Behavioral limits

- No restored Cancel after the point of no return.
- No renewed eight-second budget.
- No automatic quit, clean-launch marking, helper preparation, arming, or spawning.
- No claim that safe Restart succeeded merely because the helper exited.
- No notification for “probably dead,” timeout, lost connection, or an unrelated process exit.

The existing comment says Retry uses a fresh helper. Therefore **do not blindly reuse that action path**. Trace `handle` and its retry route:

- For this restored Stage B presentation, Retry must be flush recovery, not helper replacement.
- Apply existing deadline checks; if the original budget no longer permits work, report that without renewing it.
- Successful flushing alone must not enter safe-Restart success without its required helper conditions. Keep the failure explicit; Quit Anyway remains a deliberate user choice and leaves the launch unclean.

#### Validation

Extend the existing late-exit/refusal fixtures to cover:

- arm sent, stop unresolved, then exact helper exit;
- proof arriving before observer registration completes;
- duplicate proof;
- stale request/attempt/helper proof;
- stale presentation answers;
- no proof: choices remain unavailable;
- unchanged deadline and spawn count;
- no automatic quit or clean marker;
- Retry cannot enter fresh-helper preparation.

Use injected channels and clocks, not the helper executable.

#### R4 boundary and owner choice

No small notification change can fully satisfy R4’s bounded, usable failure behavior when an armed helper’s stop remains unknowable. Releasing choices without proof changes the failure contract and may permit a retained helper to act later.

**Recommendation:** retain fail-closed behavior and keep that R4 condition blocked. The owner’s actual alternatives are:

- **Keep the current policy** and explicitly leave safe Restart unqualified; recommended now.
- **Authorize a revised failure contract**, with explicit semantics for exiting while a helper may remain armed.
- **Authorize a broader protocol redesign** aimed at a stronger revocation guarantee; feasibility must be established, not assumed.

This decision blocks activation/acceptance of that behavior—not the late-stop fix or Phase 5 preservation work.

### C. Pending reviews: preserve the proposal and application boundary

**Scope assumption:** the latest “all finished” includes pending edit-review persistence. It is functional preservation work, not optional polish.

#### Trace before editing

Follow the complete paths for:

- preview construction and original-file access;
- review creation, publication, replacement, timeout, and cleanup;
- accept through actual filesystem mutation;
- recovery-record ownership, hydration, and commit acknowledgement;
- historical-card rendering;
- shutdown preservation versus explicit dismissal.

Identify the existing stable session/attempt authority and fingerprint facility. Do not persist `windowID`/`tabID` as durable execution ownership.

#### Durable proposal

Extend the existing recovery record with an optional collection of review proposals; old records default to an empty collection. Each proposal needs:

| Field | Meaning |
|---|---|
| `reviewID` | Stable ID shared with the live review |
| `sessionID`, `attemptID` | Existing authoritative owners |
| `createdAt` | Original proposal time |
| `target` | Existing workspace/root identity plus canonical file target |
| `displayPath`, `unifiedDiff` | Saved presentation |
| `proposedText` | Exact preview output; do not reconstruct it from the diff |
| `baseFingerprint` | Missing-file marker, or fingerprint of the exact preview base |
| `state` | `pending`, `applicationStarted`, `applied`, `dismissed`, or `uncertain` |

Reuse the codebase’s existing fingerprint representation and target encoding. If none exists, use a content digest over original bytes plus explicit existence; do not use modification time alone. The concrete owner types and coding placement require source tracing.

Do not store continuations, connection routing, or permission scopes.

#### Commit and mutation sequence

1. Construct the proposal from the exact preview inputs and output.
2. Commit `pending` through the existing recovery store.
3. Only after acknowledged commit, publish the review and await its live decision.
4. On acceptance, revalidate the target and base fingerprint.
5. Commit `applicationStarted` before mutation.
6. Use the existing host write path and freshness updates.
7. Commit `applied` after success.

Persistence failure before publication means no review is shown and no write occurs; return an explicit tool failure. Failure before `applicationStarted` commit means no write. Failure after the mutation may have started means retain uncertainty, not “not applied.”

Revalidation and writing must use the existing mutation serialization where available. If that boundary cannot prevent an intervening application-managed write, resolve that concrete gap before enabling recovered approval; a separate hash check is not an atomic write guarantee.

#### Recovery behavior

- Restore proposals as historical reviews with **no live continuation or inherited approval scope**.
- Never apply automatically.
- `applicationStarted` becomes an uncertain application outcome. Show current-state comparison; never blindly retry.
- For a still-pending proposal, explicit recovered approval requires fresh authorization, target resolution, matching base fingerprint, and the same commit-before-write path.
- Missing roots, changed files, or unsafe target resolution block application and preserve the proposal for inspection/dismissal.
- State clearly: applying this saved proposal cannot return a result to the old provider.
- Lifecycle cleanup expires the transport wait but preserves the durable proposal. Explicit rejection/replacement/dismissal records its terminal disposition.

Factor the existing write sequence only as much as necessary so live and recovered approval share validation and mutation behavior.

#### Required tests

Cover commit failure before display; cancellation during commit; replacement and stale acceptance; shutdown preservation; base mismatch; originally missing files; crash points before/after `applicationStarted` and write completion; terminal-commit failure; and absence of old continuation/permission restoration.

### D. `agent_run`: persist linkage before dispatch, without changing normal dispatch

**Scope assumption:** this preservation requirement is also included. It is not cross-request exactly-once support.

#### Trace and narrow interface change

Trace from MCP tool invocation through routing, authoritative runtime ownership, child-session creation, recovery commit, and the actual dispatch call.

At the existing execution-context boundary, carry an optional typed parent execution context containing:

- parent session ID;
- parent attempt ID;
- authoritative tool-call ID.

Do not derive these from routing-only `RequestMetadata`. If the tool-call identity is already available upstream, thread that value through the existing internal call chain. An unrelated newly generated UUID is not a substitute.

Independent MCP callers without a parent run remain independent; do not invent a parent.

#### Durable link and order

The parent’s existing recovery record owns an additive child-link collection:

- `parentAttemptID`;
- `toolCallID`;
- `childSessionID`.

The enclosing record supplies the parent session ID.

Required order:

1. Resolve authoritative parent context.
2. Allocate the child session and persist its existing durable stub.
3. Commit the parent’s child link and await acknowledgement.
4. Only then enter normal child dispatch.

A scheduled save alone is insufficient. If either required commit fails, do not dispatch.

No distributed transaction is necessary: an interrupted sequence may leave an unused child stub, but must not dispatch an unlinked child. Leave orphan cleanup to deferred retention work.

#### Recovery and duplicate behavior

- Parent recovery resolves the committed child ID and exposes that child; it does not replay `agent_run`.
- A linked child that never acquired a dispatch attempt remains not dispatched/uncertain, with no automatic start.
- A missing child record is reported as unresolved, not recreated and dispatched.
- Duplicate invocation of the **same authoritative parent attempt/tool call** uses the existing link; it must not allocate another child. Serialize this check/commit under the existing owner so concurrent duplicates cannot race.
- A genuinely new caller retry remains outside deduplication guarantees, as the specification already states.
- Old RPC continuations and permission scopes expire.

Test the commit boundaries, duplicate invocation race, missing child, child-dispatch failure, restart discovery, and unchanged independent-MCP dispatch.

## 4. File-by-file impact

Only supplied paths are definitive. Unseen integration paths must be enumerated during the trace steps; inventing filenames would make the plan less actionable.

| File/component | Change and dependency |
|---|---|
| `docs/context/plans/2026-10-18-lossless-app-restart-spec.md` | Record bounded followups, assumptions, blockers, and deferred work. Do not alter owner Decisions or relabel full Phase 4 accepted. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift` | No speculative merge change. Document/test the completed-import ledger contract; modify behavior only if the writer audit establishes a concrete existing violation. |
| `Sources/RepoPromptAgentCore/AgentMode/Models/AgentSessionProviderHistoryRecovery.swift` | Preserve schema; clarify that association is not completeness if needed. No hypothetical provenance fields. |
| `Sources/RepoPrompt/App/AppRelaunchCoordinator.swift` | Publish exact retained-helper stop proof through the existing driver seam; preserve ownership and absolute deadlines. |
| `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift` | Consume matching proof, invalidate stale presentation, restore bounded Stage B choices, prevent helper-retry routing for this recovery path. Depends on driver observation. |
| File defining `ProcessRelaunchParentSession` and relaunch-driver interface — trace required | Expose existing terminal proof if not already observable. No new stop heuristic or timer. |
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/PendingApplyEditsReview.swift` | Connect presentation to the stable durable review ID; keep transient scope separate from persisted ownership. |
| `Sources/RepoPrompt/Infrastructure/MCP/ApplyEdits/ApplyEditsApprovalStore.swift` | Extend `requestReview(scope:path:unifiedDiff:timeoutSeconds:)` to receive the durable proposal/context needed for commit-before-publication; preserve continuation/timeout ownership and stale-review checks. Update all callers found by reference search. |
| `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPApplyEditsToolProvider.swift` | Supply preview payload/base identity; enforce application-start commit, revalidation, shared host-write sequence, and completion recording. |
| Existing recovery schema/store and historical review UI — trace required | Add proposal/link fields, empty defaults, acknowledged writes, hydration, and historical actions. No parallel store. |
| Existing `agent_run` provider, execution-context seam, child-creation and dispatch owner — trace required | Thread authoritative parent context and commit link before normal dispatch. Update every affected call site together. |
| Existing importer, relaunch, review, and child-dispatch test files — locate during tracing | Add the specified deterministic fixtures; no provider/helper/MCP executable or visible lifecycle execution. |
| Plan’s existing evidence directory | Store trace maps, validation results, and A/B findings; distinguish fixture evidence from live evidence. |

## 5. Risks and migration

The review proposals and child links introduce additive persisted data:

- Missing collections decode as empty; existing records remain valid.
- Do not synthesize proposals from historical diffs or parent attempts/tool-call IDs from session ancestry.
- Verify the existing store’s unknown-field preservation before landing the schema. New code reading old data is straightforward; an older binary reading and rewriting new records may discard the additions.
- Unless preservation is demonstrated, rollback is **not lossless for these new records**. Document that limitation and preserve the store before an authorized downgrade.
- Apply the store’s existing atomic-commit and hydration protections. Stronger power-loss durability remains deferred.

The largest remaining product risk is not schema work: it is claiming safe Restart or Claude reconciliation correctness beyond the identity and stop guarantees actually established.

## 6. Implementation order

1. **Record the bounded scope.**<br>
   Keep `ff475f0b` and reviewed Step4a as the supplied baseline. Record inclusion of the two Phase 5 preservation items under `assumed:`. Close the speculative Claude merge workstream as blocked on precise evidence.

2. **Trace only the required extension points.**<br>
   Produce exact file/call-site maps for helper stop observation, review persistence/application, and `agent_run` ownership/dispatch. Resolve scout claims with source evidence. Any missing authoritative identity blocks only its dependent route.

3. **Implement and validate late-stop notification.**<br>
   Land driver observation, shutdown transition, presentation invalidation, and affected tests atomically. Keep unknown-stop policy and gates unchanged.

4. **Implement pending-review preservation.**<br>
   Add backward-compatible schema first; land commit-before-display, commit-before-write, lifecycle preservation, and historical recovery behavior together before calling the step complete.

5. **Implement `agent_run` linkage.**<br>
   Land execution-context propagation, durable link commit, dispatch guard, and recovery lookup atomically. Preserve normal dispatch and the explicit exclusion of independent caller-retry deduplication.

6. **Review each new bounded behavioral step with OracleA and OracleB only.**<br>
   The main agent makes those requests, attaches the full policy verbatim, and gives both lanes the same snapshot. These are new scopes, not a reset of the capped full Phase 4 R2 round. Do not re-review unchanged Step4a. Follow the existing retry caps and record each step’s prescribed status line.

7. **Produce the honest remaining deliverable.**<br>
   Report **completed inactive source followups, their source/fixture evidence, and explicit acceptance blockers**—not “lossless restart finished.”

   Remaining inputs are:
   - authoritative Claude identity/completeness evidence, or authorization for a narrowly specified capture;
   - an owner-approved R4 contract change only if indefinite unknown-stop blocking must be removed;
   - later O3 test-environment selection and explicit live-execution authorization.

**Continue now:** the bounded helper fix and the two preservation features.<br>
**Remain deferred:** automated Restart activation, Claude detach, ACP/OMP qualification, power-loss hardening, polish, retention, and live verification.
