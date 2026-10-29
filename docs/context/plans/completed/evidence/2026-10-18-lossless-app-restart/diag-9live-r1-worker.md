# 9-live diagnosis: R1 (Claude dispatching), V1 refusal, R7
Scope: read when the task touches why a Claude delivery intent stays dispatching after a kill, its effects on Check, Reconcile and Continue, the silent send refusal while a survivor lives, or survivor items before a session is opened.
Authority: Reference
Last-verified: 2026-10-28
Covers: diagnosis only, no code changes

Build examined: `74edea8b` plus the uncommitted `AgentRecoveryActivation.production = .claudeAndCodex` (`git diff` confirms that one line). Everything here was read-only: source, the live app's `AgentRecovery/v1` and `AgentSessions` files, the cycle13/cycle14 artifacts, `log show` for the `ComposerSubmit` category, and `lsof` on already-running `claude` processes. Nothing was launched, signalled or edited.

**Labels:** *Verified* means seen in code and confirmed by records or logs. *Inferred* means reasoned from code or evidence without direct observation.

## Summary

| Item | Root cause | Status |
|---|---|---|
| R1 | By design, a Claude intent becomes `providerAccepted` only when the turn's own `.completed` result arrives. A turn that is still running at a kill never produces one. | Verified |
| R1 effect: Check | The startup crash hold contains the earlier-launch `dispatching` intent. Proof condition (b) refuses any hold that has an intent. | Verified |
| R1 effect: paused after Refresh | Refresh only re-reads runtime restrictions; it never touches the crash hold. The hold then can't be confirmed by Check (R1). | Verified |
| "No history position was saved" | **A separate defect, not a consequence of R1.** Every Claude dispatch baseline is recorded `unsupported`. There are two causes: no Claude conversation ID before the first send, and an unknown Claude history home. | Verified (records), mechanism partly inferred |
| V1 "silent" refusal | Not silent in code. Each attempt showed the refusal text in a notice that disappears after 3 s. Each screenshot was taken 5–6 s after its refusal. | Verified (log + timestamps); what the user saw is inferred |
| R7 | By design the survivor item is app-scoped and listed in the sheet without opening the session. It is appended last in a 31-row sheet, below the part that was captured. | Inferred (strong) |

## 1. R1: why a Claude intent stays `dispatching`

### What moves an intent to `providerAccepted`

- The store moves an intent only on delivery evidence for its exact attempt. `AgentRecoveryStore.recordDeliveryOutcome` (`AgentRecoveryStore.swift:973-1020`) sets `deliveryState = .providerAccepted` at lines 1004-1005; any other outcome leaves a `dispatching` intent at its resulting state (1006-1007).
- The evidence object calls it. `AgentRecoveryDispatchEvidence.noteAccepted()` (`AgentRecoveryQueuedInput.swift:366-370`) enqueues `.providerAccepted`. `noteDeliveryUnknown()` (373-377) enqueues `.deliveryUnknown`. An open attempt with neither leaves the intent `dispatching`.
- **Codex** calls `noteAccepted()` when its RPC answers: the `turn/start` or `turn/steer` receipt (`CodexAgentModeCoordinator.swift:2996`, `5881`, `5894`, `5947`). That happens seconds after the send, well before any kill.
- **Claude** calls it in exactly one place. `ClaudeAgentModeCoordinator.noteClaudeTurnCompleted` (`ClaudeAgentModeCoordinator.swift:1919-1939`) calls `noteAccepted()` only for `status == .completed` (1934-1935), and `noteDeliveryUnknown()` for cancelled or failed (1936-1937).
  - Its caller is the runner's `.turnCompleted` event (`ClaudeIntegratedAgentModeRunner.swift:444-446`).
  - The send seam documents this rule: "any other write outcome stays uncertain until the turn's own completion (`noteClaudeTurnCompleted`). A successful write is not acceptance." (`ClaudeAgentModeCoordinator.swift:1990-1995`).
  - After `controller.sendUserMessage` returns (2418-2422), the handoff is parked in `dispatchHandoffsByTurnID` (2424-2429). Nothing records evidence until the completion arrives.
  - When the run attempt ends without a completion, `settleWrittenDispatchHandoffs` (1944-1949, called at `ClaudeIntegratedAgentModeRunner.swift:845`) turns it into `deliveryUnknown`. That is T4's retry.
- **Why it never happens during a running turn.** The turn's `result` event is the only accepted signal, and a turn running at a SIGKILL never delivers one to this app instance. After relaunch, the writing controller is gone, so no later completion can match. The intent is therefore `dispatching` before the kill, after relaunch, and from then on. *Verified* in code.

### Records (live, read-only)

Each Claude acceptance in these records was written 64–125 ms before that run's terminal commit, even for long turns. That fits acceptance being tied to the result event.

| Fixture | Session | First intent | Accepted later sends (accepted → terminal) |
|---|---|---|---|
| T7 | `3BC977C7…` | `3D99C330` `dispatching`, attempt with no outcome, run `AAF9B1E8` with no terminal | `890894EA` 1793177771900 → 1793177772002; `F5DC217F` (a 64 s turn) 1793181399541 → 1793181399674 |
| T11 | `5FCE22D3…` | `6712D191` `dispatching`, no outcome, no terminal | none |
| T15 | `048632F3…` | `5D61E0FA` `dispatching`, no outcome, no terminal | `AE670A38` 1793183942278 → 1793183942347 |
| T16 | `66827DF5…` | `83C23BED` `dispatching`, no outcome, no terminal | none |
| T17 | `1D281185…` | `207D462F` `dispatching`, no outcome, no terminal | none |
| T4 (extra) | `7EB810F5…` | the retry `E74FB495` is `deliveryUnknown`: its run ended without its own completion | — |

*Verified.*

### The outbound-identity work (3e9bf63b, Step 4d)

- 3e9bf63b puts a qualified outbound UUID on the wire, but only when the pre-send baseline committed. `admitClaudeDispatchBaseline` returns `.admitted(outboundUserMessageUUID:)` only for `.committedWithOutboundUserMessage` (`AgentModeViewModel+RecoveryActions.swift:917`). Every other case, including `.unsupported`, sends `admittedWithoutIdentity` (918).
- In this run every baseline was `unsupported` (see §2), so no fixture's message carried a RepoPrompt UUID. *Verified* from the session files.
- The Step 4d capture (`phase4d-no-replay-capture.md`, "Stdout without replay") shows Claude 2.1.302 naming the caller UUID early on stdout: `command_lifecycle queued/started (command_uuid=Cn)`, `system/init user_message_uuids=[Cn]`, and `user_message_uuid` on the first assistant record.
- In the source these fields appear only in the qualification classifier (`ClaudeLiveTranscriptQualification.swift`), not in delivery evidence. So even with a UUID on the wire, nothing today would record acceptance before the result. *Verified* by search; whether those fields are reliable mid-turn evidence is *inferred* from the capture.

## 2. Effects

### Check: "it has a saved message or an older interrupted turn"

- At startup, `deriveCrashHolds` (`AgentRecoveryCoordinator.swift:1019-1050`) puts into the hold every earlier-instance intent that is `dispatching` or `deliveryUnknown` (1031-1034), alongside the open run attempts.
- `confirmCrashHoldFromRegistryProof` (`AgentRecoveryCoordinator+CrashHoldProof.swift:66-69`) requires `hold.uncertainIntentIDs.isEmpty`; otherwise it returns `needsYou(notOnlyRuns)`, the reported text (line 39).
- Codex holds have accepted intents, so they contain only run attempts and pass. Claude holds carry the `dispatching` intent and fail. *Verified* (T7, T15, T17).

### Sending stays paused after Refresh clears the survivor

- Refresh is `refreshRuntimeOwnership()` (`AgentRecoveryCoordinator+RuntimeOwnership.swift:101-108`). It re-runs discovery and adopts new runtime restrictions. That clears the survivor row and the `.restricted` refusal (`AgentRecoveryCoordinator.swift:1546`).
- Admission checks the crash hold first, though (`blockingCrashHold`, 1543-1544, 1600-1607). The hold is lifted only by "It stopped" or by Check's proof. Refresh never calls the proof: its only caller is Check (`AgentRecoveryCoordinator+Check.swift:385-386`).
- With R1, Check refuses (above). Sending therefore stays paused until "It stopped".
- The "Message may have been delivered" row is the intent's own row for `.dispatching` or `.deliveryUnknown` (`AgentModeViewModel+RecoveryList.swift:628-629`). *Verified.*
- **Note:** even with R1 fixed, Refresh alone would not resume sending; the user would still need Check or It stopped. The guide's "Refresh, sending resumes" step assumes behavior the code does not have. *Verified* in code.

### Reconcile and Continue: "No history position was saved…"

The refusal comes from the baseline, not from the intent:
- Claude reconcile looks up the interrupted attempt's own first dispatch baseline (`AgentModeViewModel+RecoveryActions.swift:1164-1179`).
- `AgentProviderHistoryAssociationPreflight.baselineRefusal` returns `.baselineUnavailable` unless `baseline.status == .captured` with a cursor (`AgentProviderHistoryImport.swift:818-819`).
- That maps to the reported text (`AgentModeViewModel+RecoveryActions.swift:1490-1491`). The observation path has the same guard (1401-1402).
- Continue reconciles first, so it gets the same refusal.

**This is a separate defect.** All five sessions' `providerHistoryRecovery.dispatchBaselines` entries are `status: unsupported`:

| Session | Dispatch | `unsupportedReason` |
|---|---|---|
| T7 | first | "no Claude conversation identity before sending" |
| T7 | three later | "Claude history location unknown" |
| T11 | first | "no Claude conversation identity before sending" |
| T15 | first | "no Claude conversation identity before sending" |
| T15 | after | "Claude history location unknown" |
| T16 | first | "no Claude conversation identity before sending" |
| T17 | first | "Claude history location unknown" |

*Verified.* So a Claude history baseline has never been captured on this machine, whether or not the intent was accepted. The two reasons:

1. **No conversation ID before the first send.** `captureClaudeDispatchBaseline` records unsupported when `session.providerSessionID` is empty (`AgentModeViewModel+RecoveryActions.swift:984-985`).
   - Fresh `--session-id` preallocation is off. `claudeStandard` in `AgentRecoveryActivation.swift:55-60` doesn't set `freshSessionID`, which defaults to `false` (`AgentProcessRegistrySupport.swift:36`). So `ClaudeNativeProcessSessionController.swift:1394` never preallocates.
   - The conversation ID only arrives from the CLI after launch. *Verified.* T17 happened to have its ID before its send, presumably from an earlier init (*inferred*).
2. **Unknown history home.** `recoveryClaudeHistoryRoots` (`AgentModeViewModel+RecoveryActions.swift:1340-1356`) uses only `AgentProcessRegistry.claudeProviderHomes` (`AgentProcessRegistry.swift:1174-1180`), i.e. runtime records' `providerHome`. **No runtime record on disk has a `providerHome` field.** *Verified* (grep count 0 across `runtimes/`). Why:
   - The app launches `node ~/.claude-rotator/shim/bin/claude`. The shim sets `CLAUDE_CONFIG_DIR` only in its child's environment (`shim/bin/claude:3933`). The real CLI's history is under `~/.claude-rotator/profiles/38b72e00…/projects/…/<id>.jsonl` (all three K-fixture files found there).
   - At spawn, `registerSpawn` reads the root's (shim's) environment (`AgentProcessRegistry.swift:834-836`). That environment doesn't carry the profile's value. *Inferred* from the shim code and the result.
   - Discovery takes a home only from a member classified `.writer` (`AgentProcessRegistry.swift:532-537`), and classification is by executable basename (`classifyNewMember`, 585-596; writer basenames `["claude"]`).
   - The real CLI's kernel executable path is `~/.local/share/claude/versions/2.1.302` (`lsof` txt of the running `~/.local/bin/claude` processes). Its basename `2.1.302` is classified `.unknown`, so its `CLAUDE_CONFIG_DIR` is never kept. *Verified* for the path; that `proc_pidpath` returns the same text vnode is *inferred* (standard Darwin behavior).
   - Nothing guarantees a discovery pass between spawn and the first dispatch either. *Inferred.*
   - The spec's second route, finding `<sessionID>.jsonl` across known Claude roots including `~/.claude/projects` (spec R6 "Provider home"), isn't implemented. The code's comment rules out guessed defaults on purpose (`AgentModeViewModel+RecoveryActions.swift:1338-1339`). This is a spec/code conflict to settle. *Verified.*

## 3. V1: refusal while a survivor lives

- **Where.** Composer send → `executeComposerSubmitAttempt` → `submitUserTurnAdmittingRecoveryInput` → `admitRecoveryInput` → `AgentRecoveryCoordinator.admissionRefusal` (`AgentRecoveryCoordinator.swift:1531-1555`). It returns `.crashHeld` first (1543-1544); otherwise `.restricted(runtime reason)` (1546-1547).
- Each refusal is mapped to a full sentence (`AgentModeViewModel+Recovery.swift:232-258`), and the input bar shows it through `showSteeringUnsupportedNotice` (`AgentInputBar.swift:2471-2475`).
- **Why it looked silent.** The notice is transient: it clears itself after 3 s (`AgentInputBar.swift:2487-2507`) and is limited to 2 lines (871).
  - The always-on `ComposerSubmit` log shows three `view_rejected reason=completion_blocked` entries at 17:29:52, 17:30:34 and 17:31:00. That reason is logged only on the path that calls the notice with a non-empty message. *Verified.*
  - The screenshots were taken at 17:29:57, 17:30:40 and 17:31:06 (r10, r12, r13): 5–6 s later, after the notice had cleared. The run's notes also say screenshots lag the UI.
  - So the code did give a reason, briefly. Which sentence (crash hold or runtime restriction) can't be told from the log; by code order it was the crash-hold one (*inferred*).
  - The text stays in the composer by design (`shouldClearInput: false`, `AgentComposerUIModels.swift:141-147`).
- **Real gap (UX, inferred).** For a hold the banner already explains, a 3-second notice that is cut to 2 lines is easy to miss. The verifier also had no way to capture it.

## 4. R7: survivor item only after the session is opened

- **By design it should not need the session open.**
  - `addRuntimeRestrictions` (`AgentRecoveryCatalog.swift:1039-1069`) appends one app-scoped `survivingRuntime` item (no session or workspace) for every restriction in the coordinator's snapshot.
  - The snapshot comes from the registry's app-wide records (`AgentProcessRegistry.swift:99-148`), loaded and discovered at startup (`start()`, 231-238).
  - The sheet lists every catalog item (`needsAttentionItems`, `AgentRecoveryCatalog.swift:262-264`).
  - Only the composer banner is session-filtered (`recoveryListRuntimeBannerItems`, `AgentModeViewModel+RecoveryList.swift:111-121`), which is why it appears in T15's banner once T15 is open. *Verified* in code.
- **What the evidence shows.**
  - The sheet at 17:27:37 (r03/r04) says "Needs action (31)". The T15 banner at 17:30:40 (r12) reads "3 … in this session … 28 items elsewhere", i.e. 31, and the survivor is one of the 3. The total didn't change when the survivor row appeared.
  - Runtime items are appended last (`AgentRecoveryCatalog.swift:310`), so the survivor row was most likely the bottom row of the sheet. Only the first two screens were captured.
  - Conclusion: an observation gap, not a binding gap. *Inferred, strong.* Counts could coincide if one item cleared as another arrived; a sheet scrolled to the end would settle it.
- **Usability point (inferred).** The most urgent item in the sheet, a live process, sits last, behind 30 crash-hold rows.

## 5. Fix directions (not implemented)

| Item | Smallest correct direction | Risk |
|---|---|---|
| R1 | Record Claude acceptance from the earliest turn-scoped evidence from the controller that wrote the turn, instead of only from `result`. Prefer stdout `command_lifecycle started` or `system/init`, or the first assistant record whose `user_message_uuid` equals the outbound UUID. Fallback for a single in-flight message (no steer pending): the first output of the expected turn. Keep `result` as the backstop and the existing late-completion refinement. | Medium. Acceptance attributed to the wrong message when steering puts several messages in flight; UUID attribution needs the baseline fix (no UUID is on the wire today). Must never accept on output from a successor controller. Needs a live re-check with a kill. |
| R1 effect (Check), alternative or addition | Let Check's proof cover the hold's earlier-instance `dispatching` or `deliveryUnknown` intents whose only attempts belong to held run attempts the registry proves exited. Write the same acknowledgement "It stopped" writes (it already lists intent IDs). Keep the "Message may have been delivered" row and the no-resend rule. | Medium. It lifts a delivery uncertainty without the user's judgement. Acceptable only if lifting the hold never re-sends (spec R7). This needs a spec decision: deriveCrashHolds deliberately says terminal run evidence doesn't settle unknown delivery. |
| Paused after Refresh | Either update the V1 guide (Refresh clears the survivor; Check or It stopped then lifts the hold), or let Refresh attempt the crash-hold proof for sessions whose restriction it just cleared. | Low (guide) / medium (code: Refresh would gain a write path). |
| No history position (separate defect) | (a) Learn the provider home from any discovered descendant whose environment carries `CLAUDE_CONFIG_DIR`, independent of basename (home is not ownership classification), or add the versioned native-installer path to the qualification. Run one discovery pass before the first dispatch baseline. (b) Implement the spec's `<sessionID>.jsonl` lookup across known roots (recorded homes plus `~/.claude`), with exactly one match required. (c) Enable `freshSessionID` for `claudeStandard` after its own shim check, so first sends have an ID. Or capture an "empty history" baseline for a brand-new conversation once the preallocated ID is known. | (a) Low–medium: a tool that sets its own `CLAUDE_CONFIG_DIR` could mislead; first-writer-wins plus the prefix fences limit this. (b) Medium: conflicts with the code's "never a guessed default" rule; needs an owner decision. (c) Medium: `--session-id` through the rotator shim is a separate qualification gate. |
| V1 refusal | Make the hold or restriction refusal persistent while the hold lasts, e.g. a disabled send with an inline reason, or keep the notice until the draft changes, instead of a 3-second notice. Show the full sentence. | Low. UI only; keep `shouldClearInput: false`. |
| R7 | Put `survivingRuntime` and global-uncertainty items first in the catalog order (call `addRuntimeRestrictions` first, or sort by severity). Re-verify by scrolling the sheet to the end. | Low. Item IDs are stable; only display order changes. |

## Validation

No build or tests were run: this is a read-only diagnosis with no code changes. No routed document was changed. The spec/code conflict on the Claude provider-home lookup (spec R6 "Provider home", second bullet, vs `recoveryClaudeHistoryRoots`) is reported here for the owner.
