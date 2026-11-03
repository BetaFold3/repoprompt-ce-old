# Phase 4 bounded partial-source — OracleA initial review

Scope: read when the task touches lossless restart Phase 4 initial review findings for frozen tree `e876de21cca35adeda4d007930080f8ee9cb199b`.
Authority: Reference
Date: 2026-10-22

Exact explicit preset identity verified: OracleA, `61D024A4-CCFB-4C9C-A614-CC65E0A1864C`. Chat `lossless-restart-phase-4-301EB6`. Text-only review; reported validation was not rerun by this lane.

# Oracle Review

## Summary

The delta adds durable recovery actions, dispatch-bound Claude baselines, inert history-import transactions, cold Codex observation through the existing factory, and Restart safely through R4 and the existing MCP executable’s private mode. Production capabilities remain OFF, and normal-live Claude canonical merging remains **unimplemented and blocked**, as disclosed. This review uses the supplied patch and context; the reported validation was not independently rerun. Several enabled-path correctness gaps remain.

## P1 — Should fix

### P1-01 — Recovery reservations do not participate in shared admission

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActionRunner.swift:130–180`; `AgentRecoveryStore+Actions.swift:26–96`.

The reservation is persisted, but its active ownership exists only in the window-local `inFlight` dictionary. The patch does not connect it to shared pre-dispatch permits or busy aggregation.

**Failure scenario:** While an idle session is awaiting history observation or temporary-controller cleanup, scheduled or other automatic work can obtain admission without seeing the Resume reservation. Existing interruption blockers are not a substitute: they need not exist for every actionable outcome row, and the reservation itself must remain non-bypassable.

**Smallest fix:** Acquire an action-scoped reservation through the existing shared admission authority before observation. Hold it through cleanup and outcome settlement, allowing only that action’s eventual dispatch to pass. Test automatic admission with `runAlongsideOtherSessions` enabled.

### P1-02 — Blocking reconciliation failures fall through to continuation dispatch

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActionRunner.swift:211–261`; `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:569–795`.

The runner dispatches after both `.associationUnavailable` and `.nothingImported`. The latter also represents stale Codex context, transport failure, and other unsuccessful observations—not merely a successful observation with no new rows.

**Failure scenario:** Claude reconciliation reports that canonical associations are unavailable, but Continue sends anyway without displaying that limitation. Similarly, a policy change during cold Codex observation produces `.staleContext`, which is converted into `.nothingImported`; the runner can then dispatch under the changed policy.

**Smallest fix:** Distinguish successful-but-unconfirmed observation from blocking failure. Stop and surface association, stale-context, cancellation, and transport failures. Preserve the separately confirmed new-conversation option under its existing ownership policy. The test asserting dispatch after `.associationUnavailable` should change accordingly.

### P1-03 — A failed transcript save discards already-verified completion

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:650–708`, particularly the `committedHistoryImportID` failure branch.

Completion is established from the expected Codex turn before saving imported rows. If that save fails, reconciliation returns `.nothingImported`, losing the completion evidence.

**Failure scenario:** Codex confirms the interrupted turn completed and returns importable text, but session persistence fails. Continue then sends a new message because the runner no longer receives confirmed completion. The zero-row completed case avoids this, but the nonzero-row failure case does not.

**Smallest fix:** Preserve request-bound completion independently of transcript persistence success. Suppress dispatch and report that the completed result could not yet be saved. Add a VM-level test combining expected-turn completion, nonempty rows, and save failure.

### P1-04 — Codex imports do not reconcile against already-saved live output

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Codex/CodexRecoveryAdapter.swift:105–140`; `AgentProviderHistoryImport.swift:108–139`; `AgentModeViewModel+RecoveryActions.swift:620–680`.

Codex observations manufacture recovery-specific local UUIDs. The planner deduplicates those UUIDs and its own ledger, while canonical-association preflight runs only for Claude.

**Failure scenario:** An interrupted Codex turn already has persisted live assistant output. Its first history observation returns the same native message, but the empty recovery ledger and different recovery UUID cause another assistant item to be appended. Subsequent imports are idempotent; the first overlapping import is not.

**Smallest fix:** Reuse the existing controller-owned native-to-canonical reconciliation association. Where that association cannot be established, refuse overlapping row import rather than appending another copy. Keep verified expected-turn completion usable independently.

### P1-05 — Claude preflight permits the explicitly forbidden association shortcut

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProviderHistoryImport.swift:218–255`; `Sources/RepoPromptAgentCore/AI/Providers/ClaudeCode/SDK/ClaudeSessionHistoryReader.swift:330–366`.

Preflight rejects unassociated user rows only when they remain in `observation.rows`. The reader removes ledger-known rows first, including user entries whose `localItemID` is nil. Preflight also succeeds with only a local user item and assistant-only observations, without requiring any positive native-user association.

**Failure scenario:** A ledger-known but unassociated native user disappears from the observation, or the candidate contains no projected user row. The canonical merge can then pass despite never establishing which native user represents the dispatch.

**Smallest fix:** Require positive association evidence for the dispatch’s user constituents, independently of the filtered observation. A nil ledger association must remain a blocker. Do not interpret an empty output set as sufficient evidence. Existing tests that expect this shortcut to pass should instead expect refusal.

### P1-06 — Never-handed-off runs still send a generic continuation

**Evidence:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+RecoveryActions.swift:107–145, 290–407`.

Continue always creates a new continuation message; it does not inspect the source attempt’s delivery evidence and select its saved constituents. Separately, Send saved refuses an intent when its deterministic user item is already displayed.

**Failure scenario:** A crash occurs after saving the original user bubble but before provider handoff. Continue sends “RepoPrompt restarted…” rather than the original request and attachments; Send saved rejects the existing bubble and asks the user to edit instead. This misses R7 step 4 and the R1a reuse-without-duplicate-bubble rule.

**Smallest fix:** Classify the source attempt before choosing dispatch behavior. For verified non-handoff, route the saved constituents through normal dispatch using their existing identities and attachments. At minimum, remove Continue for this unsupported case rather than sending the wrong payload.

### P1-07 — Helper abandonment extends the sole R4 deadline

**Evidence:** `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift:744–791`; `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:712–733`; `AppRelaunchCoordinator.swift:70–80`.

After an arm acknowledgment timeout, `stopUnarmed()` starts another **16-second** timer and can then await child exit without a bound. R4’s failure presentation waits for serialized abandonment, which joins that operation.

**Failure scenario:** The arm acknowledgment and abort acknowledgment are lost. The eight-second deadline fires, but no failure choice or termination reply can be delivered until the additional cleanup wait finishes—potentially indefinitely. The supplied lost-ACK test explicitly exercises the extra 16-second wait.

**Smallest fix:** Budget acknowledgment and abort/termination recovery inside the same absolute deadline. Reserve cleanup time before arming and use bounded exact-child termination rather than adding another helper-lifetime wait after R4 expires. Do not solve this by showing choices while an armed helper remains uncertain.

### P1-08 — The all-stopped proof is not protected through arming and exit

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentProcessRegistry.swift:1060–1089`, together with `reserveLaunch`; `Sources/RepoPrompt/App/AgentLifecycleShutdownCoordinator.swift:620–641`.

`verifyAllFamiliesStopped()` returns a point-in-time value. It does not seal registry launch admission. R4 then suspends during helper preparation on Retry and during arming.

**Failure scenario:** A delayed managed launch—particularly a sessionless operation, which `reserveLaunch` explicitly permits—reserves after verification while helper work is awaiting completion. The helper can still be armed using the now-obsolete all-stopped result.

**Smallest fix:** Seal new registry launch admission for irreversible safe-restart finalization before obtaining the proof, and retain that seal through exit. The existing registry can own this fence; no new service is needed. Test a launch reservation attempted during the prepare/arm suspension.

### P1-09 — Cancelling Restart confirmation can change a later ordinary Quit

**Evidence:** `Sources/RepoPrompt/App/WindowStatesManager+LifecycleShutdown.swift:99–109`; `Sources/RepoPrompt/App/AppDelegate.swift:263–267`.

`requestSafeRestart()` sets `pendingShutdownReason` before invoking the ordinary termination/confirmation path. It is reset only when execution reaches the lifecycle coordinator.

**Failure scenario:** The user chooses Restart Safely, cancels the earlier quit confirmation, then later chooses ordinary Quit. The pending reason remains `.safeRestart`, so that ordinary quit can relaunch the application.

**Smallest fix:** Bind the reason to the particular termination request and clear it on every pre-R4 cancellation/refusal path. Add a cancellation-then-ordinary-Quit test.

## P2 — Consider

### P2-01 — A ready but unarmed helper has no expiry

**Evidence:** `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift:440–535`.

The startup timer targets `.awaitingPrepare`. Once the helper becomes `.ready`, its expiry is treated as a stale event; no ready-state deadline replaces it.

**Impact:** A prepared helper can remain alive beyond the promised eight-second unarmed lifetime.

**Smallest fix:** Apply the original startup expiry to both unarmed states. Test successful preparation followed by neither arm nor abort.

### P2-02 — Post-exit relaunch failure is invisible

**Evidence:** `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift:795–820`; `Sources/RepoPrompt/App/AppRelaunchCoordinator.swift:158–161`.

The helper maps open failure to an exit code, and the parent redirects stderr to the null device. No generic error presentation is implemented.

**Impact:** After the old application exits, bundle-open failure leaves the user with no explanation or manual-reopening instruction.

**Smallest fix:** Present the bounded generic Platform-owned error required by the helper amendment, without initializing app services.

### P2-03 — In-flight joins bypass exact-parameter validation

**Evidence:** `Sources/RepoPromptAgentCore/AgentMode/Runtime/Recovery/AgentRecoveryActionRunner.swift:160–179`.

The runner joins solely by `actionID` before reaching the store’s `hasSameParameters` check.

**Failure scenario:** A concurrent request reuses an action ID with changed text, target, or lane and receives the first request’s result instead of a conflict.

**Smallest fix:** Retain the request and lane identity alongside the task and validate them before joining. Extend the existing changed-parameters test to cover an action still in flight.

### P2-04 — Private argument classification reserves too narrow a prefix

**Evidence:** `Sources/RepoPromptPlatform/Infrastructure/Process/ProcessRelaunchHelper.swift:35–44`.

The reserved prefix includes a trailing hyphen. Consequently, `--rpce-private-relaunch` and other strings beginning with the contract’s reserved prefix can select ordinary MCP handling.

**Smallest fix:** Reserve `--rpce-private-relaunch`; continue accepting only the exact single v1 argument.

## Recommendations

Fix the P1 issues with focused injected tests at the existing boundaries; no live campaign, packaging expansion, or speculative Claude identity pipeline is required. Keep production capabilities OFF and retain the disclosed partial-Claude scope.

**P0 verdict: none identified. P1 verdict: changes required; this bounded checkpoint is not approved yet.**
