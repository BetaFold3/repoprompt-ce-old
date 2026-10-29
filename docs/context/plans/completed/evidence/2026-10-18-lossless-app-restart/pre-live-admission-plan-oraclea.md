# OracleA planning clarification — admission-bound child linkage

Scope: read when the task touches remaining lossless-restart admission-bound child linkage.
Authority: Reference
Last-verified: 2026-10-23

Inherited OracleA preset identity was verified. Full continuation follows, with Markdown trailing hard breaks normalized to explicit line breaks. Original local export unchanged. Planning opinion, not source validation or owner Decision; see [main disposition](pre-live-work.md).

# Oracle Plan

## 1. Summary

**Yes: the authoritative server-side MCP invocation ID plus an admission-time parent-attempt/lifecycle fence can satisfy Step5b. Provider-native tool-call identity is not required by the quoted requirement.** My earlier rejection of a newly generated ID was too broad: `prePolicyInvocationID` identifies the actual local execution, rather than inventing a native correspondence. Persist that invocation’s parent/child relationship before dispatch; make no native-origin or cross-request deduplication claim. Also preserve the reviewed explicit-user-Retry restart behavior: the late-stop notification itself must not renew deadlines or spawn, but a subsequent manual Retry may start the normal fresh attempt.

This conclusion relies on the supplied source readings; no tools or execution were used.

## 2. Current-state analysis

- `MCPConnectionManager.swift:11500–11514` allocates `prePolicyInvocationID` for each received `CallTool` request. It subsequently becomes the production invocation ID, making it an appropriate durable **local tool-execution identity**.
- `AgentRunMCPToolService.swift:971–1042` already freezes the durable parent session and revalidates it across asynchronous phases. Extend this mechanism rather than introduce another ownership system.
- `AgentModeRunLease` carries `runID`, `gateID`, and `tabID`. Those support lifecycle validation, but **none substitutes for `Session.activeRunOwnership.attemptID`**.
- Child identity is allocated at `AgentRunMCPToolService.swift:1091–1113`. The durable link belongs between that allocation and child dispatch.
- A reused provider process cannot establish which historical attempt originated an incoming request. Fortunately, the requirement can be met by explicitly assigning operational ownership at admission instead.

The missing work is therefore local context propagation, attempt fencing, and an acknowledged persistence boundary—not external protocol investigation.

## 3. Design

### A. Define the identity contract narrowly

Record this interpretation under `assumed:`, not as an owner Decision:

> An `agent_run` child is linked to the parent execution that authoritatively admits the server-side MCP invocation. The stored tool-call identity is that invocation’s existing UUID. This does not identify a provider-native call or deduplicate separately received requests.

Use `invocationID` as the persisted field name to avoid suggesting native correspondence.

A request received after attempt B begins may be admitted to B even if the provider internally conceived it during A. Without native evidence, historical origin is unknowable. **That is not a failure of this admission-bound contract.** Recovery still finds the child under the execution that actually admitted it.

Do not use process identity, timestamps, or gate IDs to infer historical origin.

### B. Capture one immutable admission context

Extend the existing frozen parent context in `AgentRunMCPToolService`, conceptually with:

- `invocationID`;
- durable `parentSessionID`;
- `parentAttemptID`, read from `Session.activeRunOwnership`;
- the existing run lease and session/reset-generation fence.

Capture the attempt and validate the lease/session coherently on their existing owning actor, without an intervening suspension. The supplied excerpts do not establish that actor’s declaration; implementation must preserve its actual isolation.

If parent resolution itself awaits, capture the existing lease/reset fence before that suspension and validate it before assigning the attempt. Never read “whatever attempt is current” later and silently replace the captured owner.

For a parent-associated route with no valid active attempt, fail before child dispatch. Keep genuinely independent MCP calls on their existing path; do not invent an attempt for them.

### C. Required fences

At every existing asynchronous-phase revalidation, and immediately before normal dispatch, require:

| Boundary | Required check |
|---|---|
| Session switch or reset | Same durable parent and same valid session incarnation/reset fence |
| Attempt transition | Current `activeRunOwnership.attemptID` equals captured `parentAttemptID` |
| Run/lease retirement | Existing `runID`/`gateID`/`tabID` lease remains valid |
| Cancellation | Invocation remains eligible to dispatch |
| Provider-process reuse | No rebinding: captured attempt and lease remain authoritative regardless of whether the process is unchanged |

Validate whether existing reset handling already invalidates the lease. **If it does, add no new generation.** If it does not, extend the existing lifecycle owner with an in-memory reset generation captured in the admission context and advanced on reset. Do not persist that transient fence or introduce a new registry.

The final check must connect to the existing normal dispatch ownership gate without an unguarded suspension. If dispatch awaits internally before accepting ownership, carry the context through to that existing acceptance boundary.

**Concrete failure prevented:** invocation admitted under A awaits persistence; A ends and B begins using the same process/session; the invocation resumes and dispatches a child under stale A ownership. Rechecking only session or process identity would miss this. Comparing the captured attempt and lease prevents it.

### D. Persist the relationship, then use normal dispatch

Add a child-link collection to the existing parent recovery record. Each link contains:

- `parentAttemptID`;
- `invocationID`;
- `childSessionID`.

The enclosing record supplies `parentSessionID`; if the existing storage shape is not parent-scoped, include it explicitly. Missing collections decode as empty.

Sequence:

1. Capture and validate admission context.
2. Allocate the child identity through the existing path.
3. Commit the existing durable child stub.
4. Revalidate admission context.
5. Commit the parent link and await the recovery store’s acknowledged save—not merely `scheduledSave`.
6. Revalidate again and enter normal child dispatch.

If a commit fails, do not dispatch; surface the failure through existing MCP error handling. If ownership expires during a commit, retain any committed records but do not dispatch or relink them to the new attempt.

A committed link is **not proof of dispatch**. Recovery resolves the child and uses its existing attempt state to distinguish dispatched execution from an unused stub. Missing child data remains an explicit unresolved link; it must not trigger automatic recreation or replay.

Use the invocation ID for idempotent link insertion. A conflicting child ID for the same invocation is an error, not an overwrite. Do not add a broader duplicate-request coordinator unless source tracing shows the same invocation can actually enter dispatch more than once. A newly received MCP request gets a new ID and remains outside deduplication guarantees.

Old continuations and permission scopes expire normally.

### E. Helper Retry correction

The supplied implementation evidence corrects my earlier recommendation:

- Exact retained-helper stop proof restores the failure choices.
- The notification alone does not renew a deadline, spawn, arm, quit, or mark clean.
- A subsequent explicit Retry may call `startFinalizationAttempt(freshDeadline: true)` and run the normal safe-Restart pipeline, including a fresh helper after the old helper is proven stopped.
- Do not convert safe Restart into plain quit.

**I would not flag that as an R4 violation.** R4 permits Retry; its eight-second bound can consistently govern each explicit user attempt. Prohibiting all later user-initiated budgets was an unsupported extra restriction. Document the existing per-user-attempt interpretation rather than change reviewed behavior.

The still-unknown-stop case remains blocked under the original policy.

## 4. File-by-file impact

| File/component | Smallest change |
|---|---|
| `MCPConnectionManager.swift` | Forward the existing production invocation ID into `agent_run` execution context if not already available. Do not allocate another identity. |
| `AgentRunMCPToolService.swift` | Extend frozen parent context with invocation/attempt identity; extend existing phase checks; insert acknowledged child-stub/link persistence before normal dispatch. |
| `AgentModeRunLease.swift` | No change by default. Change only if tracing shows reset invalidation is missing and belongs in this existing lease mechanism. |
| Existing parent recovery model/store—path not supplied | Add child links with empty decode defaults and acknowledged commit support, reusing existing serialization and ownership. |
| Existing parent recovery lookup/presentation—path not supplied | Resolve stored child IDs without replay; distinguish a link from evidence of execution. |
| Existing targeted tests—paths not supplied | Exercise ownership transitions, commit boundaries, recovery lookup, and manual-Retry behavior. |
| Existing plan/evidence files | Record admission-bound semantics and the Retry correction; retain gates OFF and acceptance blockers. |

The exact omitted paths and call sites require a bounded source trace before editing; no external identity evidence is needed.

## 5. Implementation order

1. **Confirm existing lease/reset invalidation and invocation-ID propagation.** Resolve only those local extension points.
2. **Add additive link serialization and round-trip tests.** Preserve existing unknown-field behavior; do not promise lossless downgrade unless demonstrated.
3. **Land context capture, fence checks, and pre-dispatch commits together.** Test attempt replacement and reset during each suspension, commit failure, cancellation, reused process, and ordinary successful dispatch.
4. **Add recovery lookup tests.** Cover linked dispatched child, unused stub, missing child, and a separate new MCP request remaining independent.
5. **Validate the helper delta against existing manual Retry semantics.** Assert notification alone leaves deadline/spawn count unchanged; explicit Retry follows the normal pipeline.
6. **Review the bounded changed behavior with A/B under the existing policy.** No renewed acceptance round on the old Phase 4 snapshot.

**Disposition:** Step5b is feasible non-live source work. No owner choice or provider-native identity proof blocks this admission-bound design. The remaining validation is local: verify the existing lifecycle fence and acknowledged recovery-commit boundary.
