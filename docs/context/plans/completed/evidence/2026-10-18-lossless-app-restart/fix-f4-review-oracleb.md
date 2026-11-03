# Step 7-F4 — OracleB initial review (2026-10-26)

Scope: read when the task touches lossless restart Step 7-F4 (/compact after a cancelled Codex compaction) implementation or review evidence.
Authority: Reference
Last-verified: 2026-10-26

Fresh chat, explicit slices (policy, spec F4, local fix-f4-review.diff, worker report, coordinator context); preset identity verified from the result.

# Oracle Review



# Review: Step 7-F4 — `/compact` after a cancelled Codex compaction

## Summary

The diff changes `/compact` so it reports why it refused. When a saved thread exists but readiness fails, it now says "couldn't reconnect" or "still reconnecting" instead of "Start a Codex conversation". It records the run-attempt generation, run ownership and agent session before calling `ensureCodexNativeSession`. After that call returns, it checks them again, plus run state and availability, and only then begins compaction. A counter tracks native starts in flight so a "reconnect in progress" refusal can be told apart from a failed one. Every refusal writes a fixed reason to an always-on `Logger`. Six new tests cover:
- cancel → `/compact`
- a delayed reconnect
- a failed reconnect
- a controller replaced during readiness
- a concurrent submission
- a session with no thread metadata

I found no P0 or P1. The main claims hold up from the code:

- **Overlap window closed:** after the `await` at `CodexAgentModeCoordinator.swift:1698`, every check through `beginCodexCompaction(session)` (`:1699–1729`) runs without suspending. `beginCodexCompaction` is called synchronously, so a submission arriving later sees the compaction run.
- **Counter balanced:** both marks are cleared by `defer` (`:5288–5289`, `:5393–5394`), so they clear on return, on a throw and on a cooperative cancel. While a mark is set, the local `startController` / `recoveredController` holds a strong reference, so the `ObjectIdentifier` can't be reused by another object. The counter can't leave "still reconnecting" stuck except while a start really hangs.
- **Fences untouched:** the diff only adds lines. It changes no cancellation, late-success or slot fence, no reconnect-metadata handling, and no turn admission.
- **Logs:** they contain fixed reason strings and tab/session UUIDs only, no user content.

The findings below are about wrong refusal text in edge timings and about how realistic the tests are.

## P2

### F4-R1 — The "turn started" check also fires when an old run attempt *ends*
- **Evidence:** `CodexAgentModeCoordinator.swift:1699–1704` refuses whenever `activeRunOwnership` differs from the captured value, and that includes going from a stale non-nil value to nil.
- **Failure scenario:** a run attempt still holds ownership while `runState` is already idle (for example the Stop/settle order, or a recovery-held attempt). `/compact` passes the availability check and captures that ownership. During readiness the old attempt ends. `/compact` then refuses with "A Codex turn started while /compact was reconnecting", although no turn started and compaction would have been safe. The test helper `settleCancelledRun` ends ownership *before* setting idle (test file ~L183–188), so it never exercises the other order.
- **Impact:** a safe refusal with the wrong reason; the user has to retry. I haven't checked whether production can reach this state, so verify the real Stop order.
- **Smallest fix:** refuse only when a *new* attempt is present: `session.runAttemptGeneration != captured || (session.activeRunOwnership != nil && session.activeRunOwnership != captured) || session.runState.isActive`. Alternatively drop the ownership comparison if the generation already advances on every begin.

### F4-R2 — The new readiness guard is never tested on the production startup-lease path
- **Evidence:** the generation and ownership recheck (`:1699–1701`) runs after `ensureCodexNativeSession`. In production that call goes through the global MCP bootstrap lease and possibly the managed-auth recovered start (`:5390–5394`). The worker report says no test view model enables `shouldManageCodexTooling`.
- **Failure scenario:** suppose anything on the lease or recovery path begins or ends a run attempt. Then every idle `/compact` in the shipping app would be refused as "turn started". That is a deterministic break of `/compact`, and the 408 passing tests would not catch it.
- **Impact:** if it happens, `/compact` is broken in normal use (P1-class). It is unverified, so I've filed it as P2.
- **Smallest fix:** confirm in the code that neither the lease path nor the recovered start calls `beginRunAttempt`/`endRunAttempt`, and record that in the evidence file. Better, add one test with tooling management enabled, or a stubbed lease, that runs cancel → `/compact` and expects success.

### F4-R3 — The cancel → `/compact` test doesn't cancel a compaction
- **Evidence:** in `CodexCompactReadinessTests.swift` ~L16–38 the test:
  - sets `runState = .running` and `beginRunAttempt` on a plain controller;
  - never calls `beginCodexCompaction`, so there is no compact pending-turn kind;
  - calls `cancelCodexRun` directly;
  - settles idle by hand instead of through the view model's Stop path.
- **Failure scenario:** cycle9.K was a *cancelled `/compact`*. If cancelling a compaction leaves different state (pending turn kind, tracked turns, fallback queue, a different interrupt path), this test still passes. The claim that "(b) is refuted on unmodified logic" then only holds for a cancelled ordinary run.
- **Impact:** the diagnosis that decided what to fix rests on a weaker reproduction than it claims. A real lazy-resume bug after a compaction cancel would go unnoticed.
- **Smallest fix:** start from a controller with an active thread, run `/compact` (it succeeds), cancel through the view model's Stop path, then run `/compact` again and assert it resumes the same thread and compacts once.

### F4-R4 — The concurrent-submission test reuses one controller instance for both readiness passes
- **Evidence:** the test factory returns the last controller for every request (`CompactReadinessControllerFactory.next()`, ~L215). The concurrent test (~L124–148) waits until `fresh` has two suspended resumes (`waitUntilWaiting(count: 2)`). So the send's readiness calls `startOrResume` again on the *same* object, or `prepareCodexController` "replaces" `fresh` with itself.
- **Failure scenario:** with a real factory, the send's readiness creates a separate controller, which turns this into the replacement case. The slot-identity fence (`codexControllerSlotHolds`) and retire paths behave differently when the identities are equal, so whether compaction is refused, and with which text, may differ from the live case. The send also bypasses the MCP or run-service intent path; the report says so itself.
- **Impact:** this test is the main evidence for "compaction never overlaps a newly admitted turn", and it doesn't model the production object graph.
- **Smallest fix:** give the factory two distinct controllers that share the gate. Assert which controller started `K3`, and that neither compacted. If feasible, submit through the run service as an MCP intent.

## P3

### F4-R5 — "Reconnect in progress" isn't signalled while the lease is being acquired or from other start call sites
- **Evidence:** the report says the controller is installed at ~`:5163` and the lease is acquired at ~`:5202–5210`. The mark is set only at `:5288`, around the starts inside this one function.
- **Failure scenario:** a concurrent readiness has replaced the controller and is waiting on the global lease (for example, another tab is bootstrapping). `/compact` sees a controller with no thread and no mark, and says "Couldn't reconnect… try /compact again" even though a reconnect is pending. The same happens for any other `startCodexNativeSession` caller.
- **Impact:** wrong wording only; it is still safe.
- **Smallest fix:** mark when the controller is installed in the slot, before the lease, and clear it on the same `defer`. Or move the mark into `startCodexNativeSession` so every caller is covered.

### F4-R6 — The failed-reconnect test doesn't check the retry the message promises
- **Evidence:** `compactReconnectFailedMessage` (`:1655`) tells the user to "try /compact again". `/compact` only sets `codexNeedsReconnect` when `codexController == nil` (`:1695–1697`). The failed-reconnect test (~L62–77) never retries.
- **Failure scenario:** the failed start leaves a controller with no thread in the slot. On the next `/compact`, whether `ensureCodexNativeSession` resumes again is untested. If it doesn't, the message points to a retry that always fails.
- **Smallest fix:** feed the factory a failing controller and then a succeeding one, and assert that a second `/compact` succeeds.

### F4-R7 — The refusal-reason mapping duplicates the availability logic
- **Evidence:** `compactAvailabilityRefusalReason` (`:1675–1680`) repeats the checks in `nativeSlashCommandAvailabilityMessage` (`:1587–1593`), with an `"unavailable"` fallback.
- **Impact:** if a new compact gate is added to one and not the other, the logs will silently name the wrong reason.
- **Smallest fix:** have a single compact-availability helper return a reason together with its message, and use it in both places.

### F4-R8 — Second logging channel
- **Evidence:** `slashCommandLogger` plus `logCodex` (`:1663–1673`) log every refusal twice, through two different systems.
- **Smallest fix:** this is acceptable if the always-on `Logger` is intended. Otherwise route through the existing diagnostics facility.

### F4-R9 — An evidence-reachability error blocks the commit
- **Evidence:** the worker report says `Scripts/check-agent-context` flags `fix-f4-worker.md` as an orphan.
- **Smallest fix:** link the report from the spec's Step 7-F4 status line, as was done for F2 and F7. This is a docs-only edit and needs no review.

## Recommendations

1. Fix **F4-R1** (one-line condition change) and settle **F4-R2** before committing. Code-reading evidence is enough for R2 if a lease test is too costly.
2. Strengthen the tests cheaply: give the factory distinct controllers in the concurrent test (R4), retry after failure (R6), and make cancel → `/compact` start from a real `/compact` (R3). R3 matters most, because the diagnosis depends on it.
3. Move the in-flight mark to the point where the controller is installed, or into `startCodexNativeSession` (R5). It is small and makes the "still reconnecting" text match production.
4. Defer R7 and R8 unless you're already editing those lines. Do R9 as part of the commit.
5. When you re-run live, use the new `CodexSlashCommand` reasons to find which concurrent change hit cycle9.K. The race explanation is supported but still an inference.