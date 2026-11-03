# Phase 3 registry — OracleA first re-review

Scope: read when the task touches Phase 3 registry first re-review findings for frozen tree `1862f178b341897ebdf83fa6053df8150d6117a2`.
Authority: Reference
Date: 2026-10-22

Preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`, explicit selection. Chat `lossless-restart-phase-3-3444E2`. No live validation was performed by the reviewer.

# Oracle Review

The delta repairs most registry discovery, admission, receipt-routing, and storage-retry defects while retaining the existing architecture and disabled production gates. **Nine required findings are closed; P3-R05 and P3-R06 remain open, and one required regression is identified below.** This is a text-only review of the supplied frozen source and patch; the reported 522 passing tests/build/lint results were not independently reproduced.

## Required finding dispositions

References below use the supplied filenames and test names.

| ID | Status | Code and test evidence |
|---|---|---|
| **P3-R01** | **Closed** | `AgentProcessRegistry.discoverFamily` now makes discovery non-decisive when an unidentified inventory process has unreadable environment evidence. `testUnreadableOwnershipEvidenceNeverProvesFamilyExit` covers the reparented-survivor counterexample. Changing `ProcessInventory` itself is unnecessary. |
| **P3-R02** | **Closed** | `classifyNewMember` defaults unmatched executables to `.unknown`; `.tool` requires explicit qualified membership and readable environment evidence. `testUnfamiliarDescendantsAreUnknownNotTools` verifies that root exit does not release the conversation. |
| **P3-R03** | **Closed** | `previewMembers` uses the freshly observed root group. `stop` obtains a fresh complete inventory before each signal, rejects unreadable group membership/unowned members, and checks expected identities and groups. The added Stop test covers unreadable membership and a moved root. The documented non-atomic inspection/signal limitation remains separate. |
| **P3-R04** | **Closed** | `CodexServerRequestReceipt` carries client identity, generation, and wire ID through the interaction models and reply callers. Registered wire-ID-only replies are refused. `testServerRequestRepliesGoOnlyToTheIssuingTransport` now explicitly reuses ID `77` on the replacement. |
| **P3-R05** | **Open** | Normal first-turn association is repaired and tested, including permission replies and interrupts. However, the new association suspension allows remaining buffered lines from an old transport to be handled against its replacement; details below. |
| **P3-R06** | **Open** | Both CLI runner paths now cancel after reservation and release through `spawnFailed`; the new cancellation test covers them. Native Claude still lacks that post-reservation check, and its post-fence admission await introduces another unchecked cancellation window. |
| **P3-R07** | **Closed** | `writerConflict` checks session overlap independently of `activeLaunches`, exempting only the exact runtime. `testActiveSameSessionRuntimesExcludeEachOtherBeforeAnyConversationIsKnown` covers unresolved-ID reservations. |
| **P3-R08** | **Closed** | Registered Codex requests, notifications, and receipt replies now authorize against captured launches. Thread creation rejects unavailable session context before writing. Extended revocation and creation tests cover these paths. |
| **P3-R09** | **Closed** | Requests capture `cwd` before suspension and pass it through both existing-thread and returned-thread associations. `testEachThreadOperationAssociatesItsOwnWorktree` exercises distinct worktrees through the client. |
| **P3-R10** | **Closed** | Activation requires every supported family/provider pair; reservation additionally checks exact-pair coverage. `testNarrowedProviderQualificationDoesNotActivateRegistration` covers partial ACP and compatible-provider qualification. |
| **P3-R11** | **Closed** | Explicit Refresh retries storage discovery and merges records without replacing in-memory ownership. `testRefreshRetriesAFailedRuntimeDirectoryRead` verifies restored access clears global uncertainty while loading existing restrictive evidence. |

## P1 — Required fixes

### P3-R05 — Open: buffered Claude output can cross the replacement boundary

**Evidence:** `ClaudeNativeProcessSessionController.swift:1854–1874`, particularly the loop calling `handleLine` followed by `associateObservedConversationIfNeeded`; `handleControlRequest` at approximately `2998–3000`.

**Scenario and impact:** A stdout chunk contains an observed session ID followed by a permission request. Associating the first line suspends. If the controller’s transport is replaced during that await, the helper notices `runtimeLaunch !== launch` and returns—but the outer loop proceeds to the next old line without rechecking its stdout launch token. `handleControlRequest` then captures the **replacement’s** `runtimeLaunch`. Old output can therefore mutate replacement state or receive a response on the wrong transport.

The new first-turn test exercises successful association without replacement during that suspension; the existing replacement tests suspend outgoing writes, not buffered inbound processing.

**Smallest fix:** Retain the chunk’s originating transport identity and revalidate it before processing each remaining line and after association awaits. Associate using that captured launch/context rather than retargeting stale output through current controller fields. Add a two-line chunk test that replaces the transport during the first line’s association and verifies no second-line effects or replacement bytes.

### P3-R06 — Open: native Claude still permits work after cancellation

**Evidence:** `ClaudeNativeProcessSessionController.swift:1270–1278` and `sendUserMessage`’s new post-fence checks around `923–934`.

Two cancellation gaps remain:

- **Before spawn:** After `try await launch?.prepareSpawn()`, Claude checks only `process == nil`. Cancellation during reservation still reaches `ProcessLauncher.spawn`, allowing startup hooks to execute.
- **Before user bytes:** `Task.isCancelled` is checked **before** awaiting `writeAdmission`. If cancellation occurs during that await and admission returns `true`, execution reaches `sendLine` without another cancellation check.

**Smallest fix:** For registered Claude launches, check cancellation immediately after reservation and call `spawnFailed()` before throwing when no child was spawned. Check cancellation again after `writeAdmission` returns, before encoding/writing. Add deterministic suspended-reservation and suspended-admission tests; the current admission test uses immediate constant results and does not cover this window.

### P3-R12 — Required regression: Claude automatic replies bypass registry authorization

**Evidence:** `ClaudeNativeProcessSessionController.swift:2998–3029`, plus the fallback approval and unsupported-request branches in the same `handleControlRequest` method.

**Scenario and impact:** The delta changes these paths to call:

```swift
try sendLine(encoded, shutdownOnFailure: false, writeOwner: receivingLaunch)
```

That supplies the local transport-owner identity, but none of these branches calls `fenceRuntimeWrite` or `launch.authorizeWrite`. If registry authority has ended while the local transport remains installed—the condition already exercised by the Codex revocation test—an automatic approval or control response can still write. Passing the launch to the synchronous byte fence is not registry authorization.

**Smallest fix:** Route these responses through an asynchronous authorize-only fence bound to the receiving transport, then retain the final synchronous transport check. Add a registered Claude test that revokes the launch while leaving the fixture transport installed and feeds automatic-approval and unsupported-control requests; both must produce zero bytes.

## Recommendations

Keep this round **blocked on P3-R05, P3-R06, and P3-R12**. Make the bounded transport-binding and cancellation fixes, add the focused counterexamples, and rerun affected suites before round 2.

Keep production registration/marker injection, fresh Claude session IDs, and recovered Stop **OFF**. No live qualification campaign or unrelated baseline audit is needed to resolve these findings.
