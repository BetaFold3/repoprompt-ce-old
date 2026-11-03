# Phase 3 initial OracleA review — complete retry

Scope: read when the task touches Phase 3 process-registry review findings.
Authority: Reference
Last-verified: 2026-10-22

Frozen tree: `aaa821b7755edc7fb9520b7b52efc93328913c53`. The first response was incomplete; this one permitted same-preset retry is complete and supersedes it as the initial review. Returned OracleA preset identity was verified. No implementation approval is claimed.

# Oracle Review

The snapshot adds durable runtime records, a central `AgentProcessRegistry`, launch/association plumbing across native and headless providers, process discovery and watches, a disabled Stop engine, and recovery/scheduler restrictions. The architectural separation is largely preserved, and production activation remains off as required. However, the fixture-enabled implementation still has correctness gaps in discovery, signalling validation, operation fencing, and association coverage; the supplied passing tests do not establish the full R6 contract.

## P1 — Required fixes

### P3-R01 — Birth-only observations can incorrectly establish complete family discovery
**Evidence:** `ProcessInventory.swift:68–80`; `AgentProcessRegistry.swift:323–325, 359–377, 453–462`.

- **Scenario / impact:** A registered root exits while a reparented descendant survives. Inspection establishes the descendant’s birth identity but cannot read its environment. Inventory still reports complete because it counts only whole-result `.unavailable` failures. With no parent link or readable marker, discovery omits that descendant and can declare the runtime `exited`, admitting another writer.
- **Smallest fix:** Propagate supporting-field failures that prevent ownership discovery into incompleteness. An unidentified process with unreadable ownership evidence must not silently count as a fully inspected candidate. Add this case to the existing discovery fixtures.

### P3-R02 — Tool classification is exclusion-based, not positive identification
**Evidence:** `AgentProcessRegistry.swift:422–429`; `AgentProcessRegistrySupport.swift:21–24`.

- **Scenario / impact:** Any newly discovered descendant with an available executable path and environment becomes `.tool` unless its basename appears in the writer list. An unfamiliar shim, interpreter-hosted provider, or changed executable therefore becomes tool-only—even with an absent marker. After root exit, this can release conversation ownership while a writer remains.
- **Smallest fix:** Default unmatched executables to `.unknown`. Only return `.tool` from explicit qualified tool evidence; removing the blanket `.tool` fallback is a safe immediate fix. The existing “never demote a recorded writer” test does not cover misclassifying its first observation.

### P3-R03 — Stop does not perform the required immediate group revalidation
**Evidence:** `AgentProcessRegistry.swift:829–835, 853–888`.

- **Scenario / impact:** Stop takes one inventory per escalation phase, then awaits family inspections and signals multiple groups using that earlier inventory. It neither re-enumerates immediately before each signal nor freshly verifies every group member. Processes whose group field is unavailable are filtered out. The root also uses its persisted group rather than the newly observed group.
- **Smallest fix:** Before **each** signal, obtain fresh group membership and verify every expected and observed member’s identity, group, and ownership; reject unreadable membership evidence and changed groups. Keep Stop disabled until this source algorithm is corrected—or remove the signalling implementation. This defect is additional to the documented unavoidable inspect-then-signal race.

### P3-R04 — Reused server-request IDs can route an old approval to a replacement
**Evidence:** `CodexAppServerClient.swift:1150–1169, 1901–1907`; `CodexAppServerRuntimeFenceTests.swift`, `testServerRequestRepliesGoOnlyToTheIssuingTransport`.

- **Scenario / impact:** Transport A issues approval ID `77`. After replacement, transport B issues its own ID `77`. `broadcastServerRequest` overwrites the ID-keyed owner entry. A delayed response to A then looks up B’s current owner and sends the old decision to B, potentially approving the wrong command.
- **Smallest fix:** Carry an immutable request receipt containing transport generation through `ServerRequest` and require it when responding. Looking up ownership by wire ID at response time cannot distinguish these requests. Extend the existing test to reuse the same ID on the replacement; it currently tests only an ID absent from the replacement.

### P3-R05 — Fresh native Claude conversation discovery is not durably associated
**Evidence:** `ClaudeNativeProcessSessionController.swift:894–922, 965–1004, 1548–1582, 3751 onward` (`recordObservedSessionID`); `AgentProcessRegistry.swift:773–778`.

- **Scenario / impact:** With fresh `--session-id` disabled, the first user write can be associated with no conversation ID. Claude subsequently reports its real session ID. The observed-ID path has no corresponding registry update; association happens on a later owner write instead. A permission reply or authorize-only control operation during that first turn now authorizes the newly known ID against an empty durable conversation set and fails. The permission-response error path shuts down the session.
- **Smallest fix:** Associate the observed ID with the captured launch and originating operation before subsequent conversation-dependent control/reply handling. Preserve affirmative delivery evidence if persistence fails. Add a first-turn fixture that observes a fresh ID and then answers a permission request.

### P3-R06 — New suspension points lack final cancellation/operation-owner checks
**Evidence:** `CLIProcessRunner.swift:336–345, 598–623`; `ClaudeNativeProcessSessionController.swift:1227–1247, 1548–1582`; `ClaudeAgentModeCoordinator.swift:2014–2024`.

- **Scenario / impact:** Cancellation while `prepareSpawn()` is suspended still permits spawning afterward; streaming’s former “last chance” cancellation check now precedes that await. Startup hooks can consequently execute after cancellation. Similarly, Claude’s registry awaits validate transport identity but not cancellation or whether the captured run/dispatch owner remains current on a reused transport.
- **Smallest fix:** Recheck cancellation and the existing operation-generation guard after reservation, immediately before spawn, and after write-fence awaits immediately before bytes. On pre-spawn cancellation, close the reservation through the no-spawn path and release the runner gate. Capturing ownership for attribution is not equivalent to validating that it still authorizes execution.

### P3-R07 — Active runtimes bypass same-session exclusion before conversation discovery
**Evidence:** `AgentProcessRegistry.swift:544–555`.

- **Scenario / impact:** A live or reserved fresh Claude runtime owns session S but has no native conversation ID yet. A second runtime reservation for S passes: conversation overlap is absent, and session overlap is checked only when the first runtime is **not** in `activeLaunches`. This defeats the required same-session protection during startup/replacement races.
- **Smallest fix:** Enforce session overlap against other active runtimes too. Exempt only the exact runtime being associated, not every current-instance launch. Add concurrent same-session reservations with unresolved conversation IDs to the existing registry tests.

### P3-R08 — Codex authorization covers selected mutations, not every outgoing write
**Evidence:** `CodexAppServerClient.swift:999–1036, 1076–1103, 1150–1185, 1926–1940`.

- **Scenario / impact:** Model/auth/control requests and `thread/start` bypass `authorizeRuntimeWrite`; replies and notifications also rely on local transport/commit checks rather than current registry authority. Once the registry revokes a launch, these paths can still write while its local transport remains installed. Additionally, `thread/start` with missing session context creates the thread before association rejects the response.
- **Smallest fix:** Authorize every registered outgoing operation against its captured launch. Validate owner context before thread-creating requests, then associate the returned thread before returning it. Keep the synchronous transport-generation check as the final fence; it cannot substitute for registry authorization. Extend the reaped-launch test beyond turn mutations.

### P3-R09 — Codex request associations lose per-thread worktree context
**Evidence:** `CodexAppServerClient.swift:896–923, 999–1036`; `AgentRuntimeLaunch.swift:165–186, 225–230`.

- **Scenario / impact:** Requests capture session scope and permissions, but not their worktree. `associateRuntimeConversation` omits `worktreePath`, so associations inherit the transport’s launch directory. A shared app-server serving a thread in another directory—or a sessionless transport launched without one—records the wrong or no worktree. Surviving processes then fail to restrict automatic work in the directory they actually serve.
- **Smallest fix:** Carry the operation’s captured worktree through the existing request context and pass it into association, including returned `thread/start`/`thread/fork` identities. Test this through the client with two distinct thread worktrees; the direct registry association test alone does not verify this plumbing.

### P3-R10 — Coupled activation requires only one qualified provider per family
**Evidence:** `AgentProcessRegistrySupport.swift:63–74`; `AgentRuntimeLaunch.swift:80–83`; `AgentProcessRegistry.swift:567–589`.

- **Scenario / impact:** Qualifying only Cursor within `.acp`, or only one compatible backend, still satisfies `activatesRegistration` when every family has a nonempty provider set. `makeLaunch` and reservation then register and inject markers for the other, unqualified providers. Their discovery remains unqualified, recreating the indefinitely blocking registration-only behavior the amendment expressly rejected.
- **Smallest fix:** Require coverage of every enabled managed family/provider pair before coupled activation. Also reject an uncovered pair at launch admission rather than issuing a launch or falling back to unregistered operation. Add a narrowed-provider activation test.

### P3-R11 — Refresh cannot recover a failed runtime-directory read
**Evidence:** `AgentProcessRegistry.swift:187–213, 217–244`; `AgentRecoveryCoordinator+RuntimeOwnership.swift:85–95`.

- **Scenario / impact:** Startup encounters a temporary directory-read failure and sets `storageFailure`. `hasStarted` nevertheless becomes true. Refresh runs process discovery only: it never retries the directory read or clears the failure. Even after access is restored, all ownership-dependent work remains blocked while the UI repeatedly recommends an ineffective Refresh.
- **Smallest fix:** On explicit Refresh, retry failed storage discovery and unreadable entries, clearing uncertainty only after successful reads. Merge this with active registry state rather than replacing live launch ownership. Add a failed-read → restored-read → Refresh fixture.

## Review limits

This review used the supplied immutable diff and birth-inspection context; no tools or validation were run. The reported 406 passing tests are supplied evidence, not independently reproduced results. Unchanged portions of existing controllers and callers were not fully included, so exhaustive coverage of every pre-existing outbound and fallback path cannot be certified.

Missing live qualification, deferred crash acceptance, optional metrics, and retention work are **not** findings.

## Recommendations

Fix P3-R01–P3-R11 before declaring Phase 3 source-complete. Extend the existing focused suites with the identified counterexamples; no new framework or live campaign is needed. Keep production registration/marker injection, fresh Claude session IDs, and recovered Stop disabled. Rerun affected validation and submit the bounded fix delta for the prescribed re-review.
