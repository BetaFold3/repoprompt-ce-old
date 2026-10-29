# Step 5b — durable local invocation-to-child linkage

Scope: read when the task touches lossless-restart delegated-child preservation, its review or source validation.
Authority: Reference
Last-verified: 2026-10-23

## Scope

Baseline is 8033b458, the unsigned O8 fallback checkpoint for Step 4b. This bounded step implements Phase 5's parent/attempt/tool-execution/child relationship before dispatch. Existing Phase 3/4 production gates remain OFF and O3 live acceptance pending. The initial source iteration avoided app lifecycle work. During repair the worker mistakenly packaged and published an intermediate app; see the process deviation below. No app launch or stop was reported. The new path follows existing durable recovery admission; independent MCP callers and parents outside it retain their existing behavior.

The stored invocation ID is the existing server-side MCP execution UUID, not a provider-native call ID. Ownership is the parent attempt that authoritatively admits that request, captured coherently once and fenced thereafter. A request arriving after attempt B begins may belong to B; this makes no claim of native historical origin or deduplication of a caller's separately submitted retry. See [scope and planning](pre-live-work.md).

## Source implementation

The 19-file code scope comprises 16 source files and three test files. [Worker evidence](phase5b-child-links-worker.md) contains the exact file list and failures. New app admission/fence code lives in AgentModeViewModel+DelegatedChildLinks.swift; the existing recovery store gains AgentRecoveryStore+DelegatedChildLinks.swift. Existing MCP ingress/metadata/start/dispatch paths propagate and enforce that context. Additive record/codec fields preserve links, and the existing recovery list projects them as child discovery/Open, never replay.

Order is a real covering written child owner-save, acknowledged parent link commit, parent/child revalidation, then existing normal dispatch. The Step 4a owner-save helper is reused; no second transcript writer or generic provenance framework is added. The parent's existing ensureRunAttempt mutation supplies missing first-turn evidence before linking, without overwriting an existing process-run association. Run-attempt predicates become package-visible with unchanged logic.

An unused link or missing child is explicitly uncertain, not evidence of a started run. Open uses the current workspace's owner-validated index or hydrated live session, switches/unstashes an existing tab, and starts nothing. No RPC continuation, provider permission or automatic continuation is restored.

## Validation and limits

Main directly verified completed/exit-0 coordinated tickets: five targeted suites 0d118e1b-78e0-41b8-8b86-023516d8e514 passed 110 tests; broader affected recovery/MCP suites 0b5c0e52-7b66-4b4f-a94e-63df578cf8e2 passed 411 tests in 22 suites. These overlap and must not be added as unique tests. Lint 4afc095b-0178-4df7-8278-b29deea2a8c2 and compile-only app build 7d68d7eb-5205-47fe-82a2-be23f5c70556 passed; non-mutating format check also passed.

The new eight-case suite exercises admission/commit helpers, concurrent TaskLocal identity scopes, save refusals, stale attempts/lanes, conflicts and recovery lookup. The existing service suite adds fail-closed admission before target creation; startup reconciliation adds a cold-launch link-discovery/unknown-member fixture. This is not a successful production MCP ingress-to-provider execution test. Open success with a real prompt manager is not exercised. Parent-stale checks after a link-write suspension and every production handoff are source-reviewed, not all independently fault-injected.

Worker first failed app compile on internal predicate visibility and test compile on await/assertion syntax; both fixed. One unquoted multi-suite Make filter failed in the shell and ran only its first suite; it is not counted as multi-suite validation. No full-root suite or artifact flake campaign ran.

Not run: release-configuration compile, dedicated MCP compile-only command (app-internal metadata/TaskLocal only, no wire/schema change), full-root/core tests, app launch/stop, provider execution, relaunch-helper private-mode execution, process signalling, provider-home inspection or live acceptance. The accidental package did execute the embedded MCP helper's --version check, as disclosed below. The release-only start/cleanup branches mirror the existing paths but remain compile-unverified.

## Review

Initial independent A/B calls completed together on frozen staged snapshot 2026-10-23/1253-2, 19 files/+1248/-50, with identical code/context/acceptance/validation and verbatim policy. Both exact preset UUID/name identities matched. Main read the complete responses: [OracleA](phase5b-child-links-oraclea.md), [OracleB](phase5b-child-links-oracleb.md). A requires child-binding/reset fencing through the link await and final submission, plus cancellation checks before the new start boundary. Main confirmed both omissions directly and accepts them for repair. B has no P0/P1; cheap duplicate-child/View visibility, TaskLocal scope release, service happy-path and normal terminal-evidence tests are included with the coupled repair. Retention remains deferred. Existing documented Codex operationStarted bounded-ack uncertainty must remain unchanged; no acknowledgement-driven withdrawal is authorized.

The read-only scope audit self-authorized staged snapshot 2026-10-23/1255 and read MAP 1–152 and patch 1–1768 completely: exact 19 files/+1248/-50, no unrelated hunk, assertion weakening/skip, ledger/release/product change or new framework. This is scope evidence only, not a third correctness review. Main read the complete repair MAP (138 lines) and patch (930 lines), exact seven files/+602/-57. The attempted independent delta scope audit was blocked because that worker lacked selection management, so it issued no verdict and did not substitute path filtering. Main's full patch read supplies scope evidence, not a third correctness review.

## Repair validation and process deviation

Pair completed the child binding/reset fence, cancellation checks at the new pre-start/ordinary-submission boundaries, one-shot scoped fence release, deduplicated child/View presentation and cross-workspace wording. New fixtures use the real starter with recording dispatch, reset the same child at the link await, cancel at the new awaits, verify the actual service happy path, and commit first-turn terminal evidence through the production barrier. Existing Codex operationStarted bounded-ack behavior stays unchanged. Source and tests are frozen for required A/B R1.

Main verified repair tickets completed/exit 0: affected set b5d3bb6c-b50b-458f-8358-d9b49239cf82 passed 441 tests; final new-suite rerun 4fcd8778-3a10-4581-a462-68397959e75a passed 12; lint 8ce8b7b0-f9ff-4253-9457-fa41e1ed3e65, non-mutating format check 0875ebdd-4115-44f3-bf85-0fa6da5967b8 and final compile-only app build 82ac5ba1-e33a-4dd6-8aa6-95c7bde102ea passed. The broad run precedes two style-only edits; the new suite/app build were rerun afterward. Counts overlap, not additive. Test and style failures and fixture corrections remain fully recorded in the worker evidence.

The worker violated its explicit compile-only/no-packaging brief by running make dev-build (55d9ce22-e1d3-4e85-ab7a-d04d11e6fdde). Main checked Conductor's completed exit-0 build receipt and log: it signed and atomically swapped an intermediate bundle at /Applications/RepoPrompt CE Dev.app on 2026-10-23 at 13:12:09 +0700, updated the compatibility path, and invoked smoke_embedded_mcp_helper.sh. Main read that script: it runs the contained repoprompt-mcp --version. This was not merely a source compile and is not live acceptance. No launch/stop operation was reported or requested. Main notified the owner to avoid relaunching the intermediate bundle and did not attempt an unapproved rollback, launch or stop. Further work remains compile-only. No signing identity, bundle ID or release setting was changed. The installed artifact is not the final reviewed source; its publication must not be hidden by a source-complete claim.

## Bounded R1 result

Both R1 lanes completed. The transport receipt was lost during context recovery; full first answers were recovered but not synthesized as identity-verified clearance. The single allowed receipt-failure retry used the same unchanged snapshot, same own-lane requests and fresh chats together. Main verified explicit returned UUID/name for OracleA and OracleB, then read both complete answers. [OracleA R1](phase5b-child-links-oraclea-r1.md) closes initial F1–F4 and finds no remaining P0/P1; [OracleB R1](phase5b-child-links-oracleb-r1.md) finds no P0/P1 regression. All recovered and retry text is retained in the lane evidence; no pending Oracle operation remains.

A's non-blocking summary wording correction is accepted with focused assertions: a link is not proof a child started. B's stale row-text comment is corrected. B's existing-tab lane-acquisition P2 remains conservatively fail-closed; main verified hydration calls recoveryPersistenceStateDidChange immediately after adopting persistence state (VM 5922–5923 and 6039–6040), and that helper synchronously claims the lane or leaves authority unavailable (Recovery.swift 682–721). A prior authority failure followed by reacquisition is not newly permitted by weakening the identity fence. Existing-tab recovery fixture coverage and the full submission/provider positive fixture remain deferred P2, not claimed as executed. No additional review round is run solely for these P2/P3 items. Retention stays deferred.

The wording-only correction passed the new 12-test suite (97a1ab14-86e8-4e13-a07d-b30fb070b00b) and format check (c1b19589-dc02-46fd-9efd-a382548dbe75), both completed/exit 0. Main read the changed assertions and comments. Initial finalization guardrails failed on two new evidence scope headers; headers were corrected and guardrails/context checks passed. An incorrectly named Python unittest discovery command found zero tests and is not counted as validation; the routed Scripts/test-check-agent-context command is the actual checker regression suite. Pre-commit runs the context checker. The authoritative delegation document now points to this bounded fence and its live limits.

Final scope audit independently created staged snapshot 2026-10-23/1344 and read MAP 1–188 and all.patch 1–3131 completely: 29 files, +2498/-56, including the exact 19 source/test paths and ten intended documentation/allowlist paths. No unrelated hunk, test weakening/skip, frozen ledger, release metadata or new framework was found. Main confirmed index path/stat counts, unchanged original unrelated dirt, final wording/test diff and complete normalized retention of all four R1 export bodies. Final guardrails, context checker, checker regression suite (23/0), pre-commit and staged whitespace checks passed. This scope audit is not another correctness review.

The normal signed local commit remained waiting on the signer without a result. Main interrupted that owned Git command (exit 130; no commit created) rather than leave an unattended credential wait, then used O8's explicitly authorized per-command unsigned fallback. No signing configuration was changed.

## Maintainer-guidance check

User impact is finding already allocated delegated work after restart rather than replaying a lost tool result. Existing ingress identity, run/session ownership, recovery store and normal dispatch remain authoritative. Persistence must precede child dispatch; stale attempts cannot retarget across awaits. No cross-provider native-identity join, retry coordinator, background service or retention optimization is selected.
