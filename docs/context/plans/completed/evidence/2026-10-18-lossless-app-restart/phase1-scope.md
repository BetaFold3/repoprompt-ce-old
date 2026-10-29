# Lossless restart — Phase 1 scope and identity assumptions

Scope: read when the task touches the Phase 1 implementation split or durable lifecycle authority for lossless app restart.
Authority: Reference
Last-verified: 2026-10-20

This is implementation evidence for [the plan](../../2026-10-18-lossless-app-restart-spec.md), not an owner Decision or a rewrite of its requirements.

## Owner question and reversible assumptions

The main agent asked the owner two questions after scoped inspection and an OracleA planning consultation. The question timed out after 300 seconds with neither answer supplied. Under the review policy, reversible local implementation may continue on the recommendation.

- **Assumed scope:** Phase 1a contains the 10-second transcript save-request deadline and buffered-text draining only. Both lifecycle flush passes and window-close input preservation move together into Phase 1b, with durable input, admission freezing, and the complete reversible/irreversible shutdown contract. No temporary best-effort shutdown guarantee is introduced.
- **Assumed identity:** `AgentSessionDataService` alone assigns durable lifecycle identity in an optional version-7 session member. Transcript reset and reset identity commit in one atomic session replacement. Durable deletion tombstones fence an incarnation before unlink. Recovery records reference this identity; they do not advance a second authority.
- These assumptions may be revised before the relevant implementation commit. After a local commit, changing course requires an ordinary follow-up change, not a history rewrite. No visible app lifecycle action is authorized by either assumption.
- Owner decision O3 still defers real-app crash testing. Live acceptance must not be inferred from isolated tests.

## Why the split changes

Phase 1a's transcript serialization cannot preserve drafts or queues that have no persisted representation until Phase 1b. Current quit calls `signalTermination` before asynchronous shutdown (`Sources/RepoPrompt/App/AppDelegate.swift:256–277`), while `WindowState.beginClose` tears down observers and feature owners irreversibly (`Sources/RepoPrompt/App/WindowState.swift:303–327`). Failure-vetoing lifecycle flushes therefore belong with Phase 1b's admission freeze and two-stage UI, not behind today's irreversible boundary.

The smaller first step still fixes a directly measured defect: continuous transcript changes can perpetually postpone the one-second save debounce. It does not claim lossless quit, queued-input recovery, or restored drafts.

## Why embedded lifecycle identity

`AgentSessionPersistenceStamp` and reset/deletion generations are process-local (`Sources/RepoPromptAgentCore/AgentMode/Runtime/AgentSessionDataService.swift:21–35,252–276,1269–1309`). R1's assumption of an already durable generation is not satisfied.

The alternative lifecycle sidecar would need a pending/committed reset protocol across two files. Embedding active lifecycle identity makes transcript reset atomic with that identity. Deletion still needs durable tombstones, retained independently of recovery-record cleanup. Compatibility remains decoding-only for older builds; unknown or corrupt lifecycle/tombstone data must fail closed without overwriting it.

Proposed Phase 1b packages, each requiring its own validation and review:
1. Lifecycle model/codec, migration, all session rewrite preservation, reset identity, tombstone-first deletion and reconstruction fences.
2. Recovery storage, durable stub, managed attachment ownership, composer persistence, held-input projection and reconciliation.
3. All intent/receipt handoffs and queue drains together, both Codex acknowledgement producers, scheduled receipt transfer with startup barrier, and crash hold.
4. Complete quit/window-close integration: admission freeze, two flush passes, preserve-versus-withdraw, reversible Stage A, irreversible Stage B, and one absolute deadline.

These are implementation packages, not claims that durable sends are complete before the coupled routes are integrated.

## Foundation refinements (implementation assumptions)

OracleA's continued planning consultation (`restart-phase-1-scope-an-DABF9B`, verified inherited preset) was exported to `prompt-exports/oracle-plan-2026-10-20-230525-restart-phase-1-scop-cc4a.md`. Main adopts the following reversible implementation assumptions, not owner Decisions:

- Session UUIDs are globally unique. A permanent tombstone retires that UUID across workspaces; recreating a conversation uses a new UUID. No tombstone garbage collector is added.
- Lifecycle contains incarnation, reset generation and latest reset receipt. Reset transcript and identity commit together. Absent legacy identity migrates under the existing gate before editable authority escapes; null, unknown or malformed identity remains unreadable and non-writable.
- Initial preparation commits the normal initial session under the same gate; exactly one creator wins. No extra reservation table or creation-operation protocol is added.
- Generic existing-session saves require loaded lifecycle authority. Stale or missing authority cannot silently acquire the current generation. Ordinary saves cannot reconstruct a missing old session.
- Missing-file scheduled reconstruction is allowed only with current-process authoritative identity/reset evidence; after restart, absent authority fails closed rather than resurrecting an old snapshot.
- Tombstone commit is logical deletion. Subsequent unlink failure is cleanup residue, not a return to an active session. Unknown tombstone data is preserved and blocks access.

The foundation package is necessary storage ownership only; it does not yet provide durable input acknowledgements, composer recovery, or safe shutdown.

The next package is [inactive recovery transactions and a composer controller](phase1b-recovery.md), including integration with the existing lifecycle gate. Production composer persistence is not activated separately: input capture, durable acknowledgements, all queues/drains, schedule receipt transfer/startup barrier and held-input UI must cut over together. This avoids a temporary draft-only implementation that could erase the sole durable input copy on an unprotected send clear.

## Shared-writer gate audit

The Phase 0 concern about a load/migration write bypassing the same-session gate was resolved by source inspection:
- Editable load acquires the gate at DataService `:1631`.
- Hydration acquires at `:1669`, commits its storage rewrite at `:1705`, and releases afterward.
- General load acquires at `:2637` before its locked load/storage commit.
- Stub migration acquires at `:2695` before its locked metadata rewrite.
- Full saves, schedule mutations/finalization, and conditional deletion likewise enter the existing session gate before locked loads.

The main agent independently read the editable-load, hydration, general-load and stub-load paths. No writer redesign is indicated by this audit. The private storage-commit helper assumes its caller holds the gate.

## Oracle planning evidence

OracleA's identity was verified (`61D024A4-CCFB-4C9C-A614-CC65E0A1864C`, explicit selection). Planning chat: `restart-phase-1-scope-an-DABF9B`. The local export is `prompt-exports/oracle-plan-2026-10-20-211352-restart-phase-1-scop-bbb2.md`; it supplied the bounded scheduling/drain contract and embedded-identity recommendation. It is not an implementation review. Independent OracleA/OracleB review is still required for each implementation snapshot.

## Implementation evidence

- [Phase 1a evidence](phase1a.md): transcript maximum wait, mutation observation, fences, retry, buffered-text drains, cleanup inventory, tests and validation (pre-review).
