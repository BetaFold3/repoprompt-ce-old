# Step 8-attention / 9-activation plan consultation — OracleA, part 2

Scope: read when the task touches Needs Attention UX (O34), the one-button check-and-resolve idea, recovery-action activation (O32), or the verifier live scenarios.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA (preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C) fresh-chat continuation of attention-activation-plan-oraclea.md, which was cut off in Check-and-resolve step 5; this part finishes Check and resolve, activation (O32), verifier scenarios and step order.


5. For each unresolved run eligible for history observation, invoke the existing runner with **`.reconcileOnly`**, bound to the captured card and current session authority. Never invoke a continuation and rely on its completion check to prevent sending. Reuse the existing history-only importer, durable reservation, save ordering, and completion association.
   - Revalidate the source item after session preparation and every awaited ownership operation.
   - A previous unfinished action remains a user decision; the checker must not supply `supersedesActionID`.
   - A joined reservation is not a fresh observation. Report its recorded outcome honestly; do not invent a second reservation to bypass idempotency.
   - Reuse session preparation, but reconcile each distinct run only when its existing action contract supports that association. Observing one run does not prove another finished.

6. Interpret reconciliation results without broadening their meaning:

   | Result | Checker behavior |
   |---|---|
   | `.imported(.confirmed(expectedRunAttemptID), …)` | Treat the run as completed only after the existing durable completion outcome commits. Retain its recovered result under Information. |
   | `.imported(.unconfirmed, …)` | Show “History recovered; completion unconfirmed.” Leave the continuation decision outstanding. |
   | `.nothingImported` | Report a successful check, not completion or proof that the input was never sent. |
   | `.associationUnavailable` | Preserve the item and refusal explanation; no continuation, inferred completion, or proof repair. |
   | `.blocked` | Preserve the obligation and show the failure. Observed completion carried by this result still forbids a send, but does not establish that imported history was saved. |
   | Joined, prior action, or unrecorded outcome | Report the existing uncertainty. Do not retry dispatch or automatically supersede it. |

   Claude remains completion-unconfirmed under the supplied contract. A final-looking answer is not terminal proof.  
   **Evidence:** `AgentRecoveryActionRunner.swift:61–121`.

7. For captured crash holds, optionally call the verified-stop operation described in C3. History completion and process exit are independent:
   - Completed history does not establish that launcher hooks or tools exited.
   - Process exit does not establish successful completion or non-delivery.
   - Missing registry records do not establish exit.

   If complete coverage cannot be established, leave **It stopped** as an explicit individual assertion. Do not weaken that boundary to make the checker appear successful.

8. Refresh presentation from committed coordinator state and publish the batch report. New items arriving during the batch remain visible but are not added to its captured scope. Changed items are skipped rather than silently replaced. No item disappears merely because the checker visited it.

#### Automatic decisions and side effects

**Allowed:** ownership refresh, qualified history observation/import, durable recognition of verified completion, and narrowly proven crash-hold confirmation.

**Still explicit:** Continue, Send saved, Answer as input, fresh-conversation handoff, Stop, Dismiss, Restore/Discard, schedule confirmation/cancellation, and replacing an interrupted recovery action. Checking never consumes saved input or answers historical callbacks.

**Important blind spot — scheduler release.** Clearing an ownership or interruption fence can make an already-authorized future schedule eligible. The proposed “No messages will be sent” wording is therefore too strong unless checking holds a scheduler barrier.

Use this precise preview instead:

> This check will not send recovery messages, stop processes, discard saved input, or confirm schedules. Existing scheduled work may become eligible when recovery restrictions clear.

Do not add a new scheduler suspension system for this UX change. Existing due schedules needing confirmation must remain unconfirmed. Validate normal queue admission as well: a check must not re-project held recovered input into a live queue.

**Inference to validate:** gate removal can release scheduled work, based on R9’s preserved future-schedule behavior and `AgentComposerUIModels.swift:264–293`. Trace the actual scheduler predicate before claiming the checker has no indirect dispatch effects.

#### Before activation

Keep the button available, but report capabilities explicitly:

- Re-read the existing catalog and request the existing index-only schedule refresh.
- Refresh process ownership only if the current composition already supplies active, qualified tracking.
- Do not construct providers, enable tracking, or invoke disabled reconciliation to satisfy the check.
- With both gates inactive, report: **“Saved recovery items reviewed. Process and provider-history checks are not active.”**
- No automatic crash confirmation without the C3 evidence contract.

The runner’s `registrationActive()` gate remains mandatory even for Reconcile.  
**Evidence:** `AgentRecoveryActionRunner.swift:130–158`; `AgentModeViewModel+RecoveryList.swift:83–92,791–795`.

#### Scale and lifecycle

The checker must iterate **captured catalog items**, not enumerate Application Support or scan every workspace’s histories. Build session/workspace maps once; prepare one session at a time; release its temporary references afterward. Overall orchestration is linear in captured items plus the cost of the selected history reads.

Audit `requestIndexedScheduleRefresh()` separately: opening Needs Attention already invokes it, so a bounded checker alone will not fix an expensive sheet-opening scan. Do not add another refresh per row. The coordinator implementation was not supplied; measure its discovery scope with a synthetic large workspace index.

Closing the sheet leaves the coordinator-owned batch running. Explicit cancellation stops before the next operation; an in-flight durable transaction settles normally. If its window disappears, do not recreate the window automatically: report unavailable-owner results and continue operations that need no window.

The reported ~50,000 fixture directories are **not authorization to delete directories by name**. Fix fixture isolation separately. O33 cleanup must use identified synthetic sessions and existing deletion ownership, not recovery dismissal or a broad filesystem sweep.

---

### E. Activation for all providers — O32

#### Smallest safe change

Use the existing capability policy and provider adapters; **do not introduce the earlier plan’s Claude/Codex allowlist**.

After qualification, the intended production configuration is:

| Capability | Setting |
|---|---|
| `sameConversationResume` | On |
| `historyReconciliation` | On |
| `freshClaudeConversation` | Off in this step |
| `safeRestart` | Off in this step |

The last two need separate acceptance and are not prerequisites for the requested actions.

At `AgentRecoveryActionQualification.production`, document:

- O32 authorizes capability availability across providers.
- Claude Code and Codex are the live-qualified providers for this rollout.
- Other providers are not thereby declared qualified.
- New providers must establish registration, ownership, history association, dispatch identity, and settlement contracts before their recovery actions can execute.

Keep `allows(_:)` as capability permission, not a proof of provider support. Preserve the runner’s independent registration and execution-time checks. Enable registry composition consistently with the runner; changing action Booleans alone is insufficient.  
**Evidence:** `AgentRecoveryActionRunner.swift:18–59,130–158`.

#### Unsupported providers and missing evidence

OpenCode, Cursor, Oh My Pi, unknown configurations, and remote sessions must use their existing supported paths or **refuse before dispatch**:

- Missing history support must return an explicit unavailable/blocked result—not `.nothingImported`.
- Unsupported association, legacy prooflessness, unknown ownership, and stale bindings must remain refusals.
- Continue must not skip reconciliation because an adapter or closure is absent.
- Send saved requires its existing verified-never-handed-off eligibility.
- Answer as input requires a fresh durable input and current dispatch ownership; it never invokes the expired question callback.
- A known unsupported capability should not produce an apparently usable send button; show its reason. Execution must independently revalidate for stale UI or direct invocation.

**Required source validation:** the supplied runner body ends before execution. Verify that nil reconciliation performers and provider-adapter absence cannot fall through to dispatch. Fix that narrowly if necessary; do not claim the visible `isAvailable(_:)` check already proves it.

This interpretation makes O32 **global availability subject to proven preconditions**, not permission to guess or to implement unqualified native resume behavior.

#### Let finish and Stop are separate

Let finish already routes through the displayed runtime revision. Keep that contract.  
**Evidence:** `AgentModeViewModel+RecoveryList.swift:797–807`.

Recovered Stop is **explicitly absent** from the supplied production UI, so it is not enabled by `AgentRecoveryActionQualification`:

- Add `.stopProcess` to the existing row action enum and its exhaustive switches.
- Offer it only when the registry can produce a verified process-family preview.
- Confirmation must list the exact displayed processes and explain that they may be editing files.
- Execute through the existing registry stop owner: revalidate birth identities before signalling, follow its bounded escalation policy, then rediscover.
- A changed family requires a new preview/confirmation; never silently include newly discovered processes.
- Unknown identity, incomplete inspection, or signalling failure remains unresolved.
- Never add bulk Stop or invoke Stop from Check and resolve.

The confirmation must be separate from the current discard dialog.  
**Evidence:** `AgentRecoveryCatalog.swift:94–111`; `AgentModeViewModel+RecoveryList.swift:809–833`; `AgentRecoveryListBanner.swift:133–183`.

**Unknown:** no stop implementation was attached. Inspect its real interface and guarantees before wiring it. If it lacks a safe preview/execution contract, isolate Stop as a separate blocked substep rather than reconstructing process signalling inside the VM.

---

### F. External verifier scenarios

Use one identified candidate with consistent registry/action qualification across launch and window composition. Record build identity, selected provider/runtime configuration, exact synthetic session IDs, and relevant redacted record/UI evidence. Fixtures and injected failures remain labelled as such.

For each lifecycle or signalling action, obtain the required fresh approval. The implementer defines these scenarios; Pi executes them.

| # | Setup and exact action sequence | Required evidence and pass criteria | Lifecycle |
|---|---|---|---|
| **1. Attention presentation** | Create an unresolved input, terminal outcome, dismissed blocking hold, and unrelated clean session. Open the clean session, then Needs Attention; toggle dismissed/cleared visibility. | Clean ready composer has no recovery banner; startup failures still show. Badge counts Needs Action only. The dismissed hold appears once with its pause explanation; terminal results remain inspectable under Information. | None |
| **2. Snapshot-bound bulk dismissal** | Capture a mixed-workspace dismissal selection; change one item’s freshness before confirming. Include a non-dismissible restriction. Execute, then repeat from another window while running. | Only unchanged eligible acknowledgements commit. Changed/busy/ineligible items are reported separately; input, holds and schedules are unchanged. Both windows show one batch. Relaunch confirms acknowledgement durability. | Normal relaunch |
| **3. Claude active-writer recovery** | Run a synthetic foreground tool through the actual app profile; terminate the app at an approved point while the provider survives. Relaunch, run Check and resolve, attempt Continue. | Registry evidence covers the actual shim/CLI/tool identities. The live or unknown writer blocks continuation; no second managed writer starts. No automatic recovery send. | App kill/relaunch |
| **4. Claude history and explicit Continue** | After the prior execution safely exits, check history, inspect imported rows, then explicitly Continue with unique text; double-click or invoke from two surfaces. Reload afterward. | One continuation intent/attempt and one provider handoff; unrelated held input remains held. Imported rows survive reload without duplication. Completion remains unconfirmed unless the contract genuinely changes. | Reload; builds on #3 |
| **5. Codex activated recovery** | Interrupt synthetic foreground work, relaunch, check ownership/history, then Continue with unique text twice. Include a separate interrupted request whose exact native turn proves completion. | Correct thread and run association; interrupted command is not replayed automatically. Incomplete case dispatches once; verified-complete case commits its result and sends nothing. Normal submission acceptance is not displayed as provider acceptance. | App kill/relaunch |
| **6. Tool-only survivor and Let finish** | Leave a benign Claude-started background tool alive after the writer exits. Relaunch; choose Let finish, then allow the tool to exit and use Refresh if needed. | Descendant remains discoverable despite reparenting/group changes. Tool-only and writer restrictions differ correctly; worktree scheduling stays fenced while required. Let finish does not signal; fresh exit evidence clears the restriction. | App kill/relaunch |
| **7. Explicit Stop** | On a separate disposable survivor, open the Stop preview, cancel once, then approve it. Exercise each materially different Claude/Codex stop family that can be retained safely. | Cancel sends no signal. Confirm targets only verified identities; final discovery determines success. No process-name kill, automatic stop, or false “stopped” after inspection failure. If no Codex survivor is reproducible, record that limit instead of claiming live coverage. | Approved signalling; possibly relaunch |
| **8. Older saved input — each provider** | Preserve a never-handed-off message with later transcript content. Relaunch and choose Send saved once, then repeat the click. | Stable saved input identity and chronology; current-end relocation/reconstruction; exactly one dispatch. Provider acceptance controls “Sent.” Deterministic failure companion verifies unsent content remains at the new position. | Normal relaunch |
| **9. Historical question — each provider** | Preserve a question and partial answer, relaunch, edit its answer and explicitly send as new input. | Exact answer becomes a new durable input with current ownership. No expired callback fires. Duplicate clicks do not duplicate sends; failure remains saved or honestly uncertain. | Normal relaunch |
| **10. Claude unsupported/dangling history** | Separately interrupt a pending permission/tool interaction and an app MCP interaction; relaunch and check before attempting an explicit continuation. | No replayed approval/tool callback. Supported history imports truthfully; unsupported association refuses without sending. Any continuation happens only after its prerequisites pass. | App kill/relaunch |
| **11. Reservation crash window — each provider** | With an approved debugger cut, terminate after spawn but before birth-identity registration. Relaunch and check. | Durable reservation survives; marker discovery accounts for the process family or reports uncertainty. A missing registered root never becomes proof of exit; competing writer is refused. | Controlled kill/relaunch |
| **12. Bounded check and scheduler effects** | Use mixed needs-action items plus indexed fixture-heavy workspace metadata. Check current-workspace scope, cancel remaining work, then run all-catalog scope. Include a legacy untracked hold, a due unconfirmed schedule, and an already-authorized future schedule behind a recovery fence. | No broad history crawl, no recovery sends/discards/Stop, no auto-confirmation of the due schedule. Legacy hold stays manual. Cancellation preserves completed writes. Any release of authorized scheduling matches the preview; unchanged held queues do not drain. | None required |

Use deterministic tests—not additional daily-app destruction—for denied inspection, PID reuse, stale incarnations/reset generations, storage failures, owner loss, cancellation during save, and an unfinished prior recovery action. Add table-driven unsupported-provider tests; **Claude/Codex live results do not qualify those providers**.

---

## 4. File-by-file completion impact

These additions complete the preceding design; exact unprovided implementation locations must be resolved by symbol search before editing.

| File | Required changes |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryCatalog.swift` | Derived attention/run facts and visibility rules described above; retain existing IDs and acknowledgement freshness. |
| New `…/Recovery/AgentRecoveryBatchController.swift` | Coordinator-owned sequential batch orchestration, immutable targets, cancellation and retained report; no SwiftUI or VM dependency. |
| File declaring `AgentRecoveryCoordinator` and its existing mutation extensions **[not supplied]** | Own the batch controller; reuse exact-item dismissal and reservations; add verified-stop confirmation only if complete evidence is available. Publish progress through existing coordinator notifications. |
| `…/Recovery/AgentRecoveryActionRunner.swift` | O32 documentation, guarded production capability change after qualification, and any necessary fail-closed reconciliation correction. No alternate dispatcher. |
| Existing registry/support and launch-composition files **[not supplied]** | Consistent registry activation; verify previewed Stop, evidence coverage and admission exclusion. Do not place signalling logic in UI code. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryList.swift` | Attention filtering/counts, captured-item batch bridge, checker session preparation and `.stopProcess` routing. Retain existing navigation and durable mutation owners. |
| `…/ViewModels/UI/AgentComposerUIModels.swift` | Section/group/report presentation shapes, Stop action, removal of obsolete elsewhere-banner fields. Audit the omitted declarations and all initializers atomically. |
| `…/Views/Components/AgentRecoveryListBanner.swift` | Remove elsewhere-only affordance; add distinct process-stop preview/confirmation. |
| `…/Views/Components/AgentRecoveryNeedsAttentionSheet.swift` | Sections, workspace groups, snapshot confirmations, progress/report/cancel controls, and coordinator-change observation. |
| New focused tests under `Tests/RepoPromptTests/AgentMode/Recovery/` | Classification matrix, bulk/check behavior, stale evidence, cancellation, provider refusal, and Stop preview fences; extend existing runner fixtures rather than duplicate stores. |
| Restart spec and its evidence directory | Record Step 8/9 status, O32 interpretation, candidate-specific verifier results and remaining refusals. No invented owner Decisions. |

No new persisted schema is needed. Turning action visibility off must preserve committed history, acknowledgements and reservations; rollback must not remove ownership enforcement while tracked live/unknown processes remain.

## 5. Ordered implementation steps and cuts

1. **Attention projection and presentation — one atomic cycle.**  
   Land classification, banner filtering, badge rules, sheet grouping and shared observation together. Validate scheduler-blocker alignment.  
   **Cut:** age expiry and “unrelated later message means resolved.”

2. **Snapshot-bound bulk Dismiss — one cycle.**  
   Add the batch owner, reporting, cancellation and exact-item acknowledgement path. Test changed freshness and multiwindow execution.  
   **Cut:** bulk destructive actions and transactional all-or-nothing rollback.

3. **Read-only Check and resolve — one cycle.**  
   Add bounded orchestration using existing Refresh/Reconcile capabilities; keep production activation unchanged. Test that no dispatch performer is invoked and that partial failures persist.  
   **Cut:** broad workspace history discovery, automatic supersession, and provider-history support not already implemented.

4. **Verified hold confirmation — separate optional cycle.**  
   Implement only if registry coverage and the existing reservation prove the C3 contract. Test scheduling release explicitly.  
   **Cut:** omit automatic/bulk confirmation entirely if proving coverage needs a new ownership system. Report “Manual confirmation required.”

5. **Activation preparation and Stop — separate cycles if Stop changes behavior.**  
   Unify composition, document O32, test unsupported-provider refusals, and wire the existing verified Stop owner. Defaults remain off for release until acceptance.  
   **Cut:** fresh Claude conversation and safe restart; keep unsafe or unimplemented Stop explicitly blocked, not silently “enabled.”

6. **External qualification, then activation commit.**  
   Pi executes the numbered scenarios on the identified candidate. Fix realistic safety/workflow failures; obtain the required independent A/B reviews on identical snapshots. Activate the reviewed capabilities without claiming every provider was live-qualified.

Each source cycle follows the supplied review cap; do not consume a round solely for optional polish. Fixture cleanup/isolation is a separate maintenance task, not a prerequisite for scanning only the bounded catalog.

## Recommendations

- Ship quieter attention presentation and safe bulk Dismiss first.
- Make **Check and resolve observational by default**; automatically clear holds only with complete exit evidence.
- Honor O32 with global capability availability and strict provider-specific refusal—not blanket qualification.
- Keep Stop explicit and separately verified; keep fresh-conversation recovery and safe restart out of this activation.
- Bound work to catalog targets, and disclose that clearing recovery gates can release already-authorized schedules.