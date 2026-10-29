# Phase 4 forward guidance — OracleD

Scope: read when the task touches the independent forward-guidance consultation for the inactive lossless-restart Phase 4 checkpoint.
Authority: Reference
Last-verified: 2026-10-22

This is planning advice, not another acceptance review or an owner decision. See [main disposition](phase4-forward-guidance.md) before adopting any recommendation. Source checkpoint: `fbc1ef041cd7000255c102f7abd7e2464120fe25`.

Preset identity verified: `OracleD`, `7F177418-1980-4BF5-9768-B278FBC7C2BB`, explicit selection. Both lanes received the same controlled request and current source excerpts, with the complete review policy attached; automatic workspace selection was excluded. Neither lane received the other's response. No checks were run by either lane.

## Complete exported response

# Oracle Plan



# Forward guidance: lossless restart after the Phase 4 inactive-partial checkpoint

Scope discipline: this is strategy only. Nothing below authorizes activation, live providers, process signalling, home inspection, or lifecycle actions. "Proven" means visible in the packet; everything else is marked as hypothesis or probe.

---

## 1. Ranked roadmap (3 bounded steps) and what to cut

The product promises four things. Three (typed/queued input survives, interrupted work shown honestly, nothing auto-sent) are committed in Phase 1/2 and are presumably running in the owner's daily build. The fourth (one-click Resume) is gated OFF and is blocked by three independent things: O3 live acceptance, the Claude association gap, and the coupled registry activation rule. The smallest useful *complete* outcome is therefore to confirm the three shipped promises hold in real use, and to gather the one piece of evidence that decides whether Phase 4 Claude import is viable at all — before writing any more Phase 4 source.

**Step 1 — Normal-lifecycle live acceptance of Phase 1/2 (owner-run, no kill, no code).**
Quit, window-close, relaunch, Reset, Delete, scheduled-send and MCP-queued paths exercised on the owner's real build with real data, verifying recovery records and R1a presentation by inspection. This is inside O3 ("live acceptance pending") and does not need the deferred crash test or a second instance. It is the only step that produces product value already paid for.

**Step 2 — Claude evidence probe: DEBUG-only stream diagnostics + one owner-run capture (source-only, then owner action).**
Write a DEBUG diagnostic that logs, per Claude stream event, the fields the app already receives (`uuid` envelope ID, `request_id`, API `message.id`, `tool_use_id`, `session_id`, local item ID, local `toolInvocationID`) to a diagnostics file — never to session JSON. The owner then runs one ordinary Claude turn with an edit and a tool call and compares that log with the session's JSONL by hand. This settles two questions no amount of source work can: (a) whether envelope UUID ≡ JSONL entry UUID for assistant/tool-result entries, and (b) whether `ClaudeSessionHistoryReader` accepts a real file at all (see §3 — I suspect it does not).

**Step 3 — Three owner decisions, recorded as one-line Decisions, no code.**
(a) coupled registry activation scope; (b) older-message semantics (keep refusal vs relocation); (c) arm-sent helper policy (keep deferred vs honest Quit-anyway wording). My recommendations are in §2–§4. These decide whether any further Phase 3/4 source is worth writing; writing it first is rigor spent on a path the owner may not take.

**Cut / defer (do not build):** relocation or routing redesign for older messages; any lease/handshake/service redesign for the helper; a generic provider-provenance framework; the O3(a) DEBUG Application-Support root override; expanding SDK fixtures (they are reproducibility, not qualification); performance qualification; full-root suite runs for this consultation; Phase 5 items.

---

## 2. Older saved input: requirements vs. the position assumption

**Actual spec requirements (proven from the spec text):**
- Done-when 1: text, attachments, origin, order, stable ID, and delivery state survive.
- R1a: an unsent intent shows its bubble under the deterministic item ID; *Send* reuses that ID and never appends a second bubble.
- Done-when 4 / R7: nothing moves without a click.
- Output ownership (R1a join keys, R7 step 5): output must attach to the request that produced it.

**Prior assumption, not a requirement:** that an unsent bubble's visual position can never change. Nothing in the spec says this. "Order" in done-when 1 is about surviving the recorded order, and the intent record already preserves the original queued time/origin independently of the bubble's `sequenceIndex`.

**What the code does today (proven):** `recoverySavedIntentBubble` refuses when any other user item has a later `sequenceIndex` (`AgentModeViewModel+RecoveryActions.swift:474-476`, text at `:403-404`); Edit-as-new stays available. The refusal exists because the transcript builder treats each user item as a turn start and the final turn as "from the last user item" (`AgentTranscriptServices.swift:3299-3300`, `:3375-3389`), so output from a resend of U1 arriving after U2 would land in U2's turn — the exact "tail-appending output under the wrong request" hazard.

**Does the full goal need a routing redesign?** Routing output to an earlier turn by anchor rather than position would create non-contiguous turns, which the turn/span/sequenceIndex model does not represent and the UI does not display. That is a redesign; I would not pursue it.

**Is relocation of the SAME item smaller?** Possibly, but only for a restricted subset, and it is not obviously small:

- *Favourable fact:* the turn ID is the user item ID (`:3358`, `:3379`), so moving U1 keeps its turn identity; recovery catalog `turnID` references, span IDs (turnID + ordinal), baseline `userItemIDs`, and the intent's deterministic ID all survive unchanged. No copy, no new ID.
- *Hazard 1 — span-embedded U1:* an unsent follow-up typed during a running turn may be recorded as a user *activity inside T0's response span* (the resolver scans exactly that, `:434-442`). Relocating it means editing T0's canonical span. This is probably the *most common* way an older unsent bubble arises, so a subset that excludes it may cover little. Unknown; needs the probe below.
- *Hazard 2 — compaction:* if U1 (or the turn containing it) is not `retentionTier == .full` or is structurally compacted (`AgentProviderHistoryImport.swift:328`), the canonical rows aren't rewritable. Must refuse.
- *Hazard 3 — later turns and the live suffix:* U1 in the mutable suffix needs a resequence mutation; `appendItem` assigns `nextSequenceIndex` and asserts incremental identity admission (`AgentTabSession.swift:3017-3035`). There is no visible "resequence existing ID" primitive; a remove+append of the same ID may trip `admitsIncrementalSourceItemID`/repair. Unknown.
- *Hazard 4 — two authorities:* the move is a session save; the intent transition is a record write. Order must be move-then-dispatch so a crash between leaves a moved, still-unsent bubble (honest) rather than a dispatched-but-unmoved one.
- *Hazard 5 — presentation flags:* `recoveryDelivery` and the "not sent" presentation must be recomputed after the move.

**Minimum evidence before selecting (source-only, read-only):**
1. The incremental (non-legacy) turn-start rule and what `recordAgentTurnUserAnchor` (`AgentModeViewModel.swift:17430`, `:17449`) actually feeds — does any consumer route output by the anchor rather than by last-user position?
2. Whether any existing transcript/session mutation can change an existing item's `sequenceIndex` without violating the incremental identity asserts.
3. From existing tests/fixtures, which shape U1 takes in the realistic scenarios (suffix item / request anchor with zero spans / span activity).

**Owner-visible tradeoff:** "Send saved on an older message moves that bubble to the bottom" (relocation) vs "Send saved refuses; Edit sends it as a new message" (current). The current behaviour already satisfies every spec requirement above; Edit-as-new is a user-chosen copy, not a system completion. **Recommendation: keep the refusal (cut), revisit only if Step 1 shows Edit-as-new is a real daily annoyance.** Alternatives: relocation for the request-anchor/suffix subset only (needs probes 1–3 first); routing redesign (defer indefinitely).

---

## 3. Claude association: smallest evidence and where it would live

**Proven state:** the preflight requires every dispatch user item to be the explicit `localItemID` of a native user row (`AgentProviderHistoryImport.swift:228-236`), refuses any native user row without an item (`:240-242`), and requires every canonical output item after the dispatch to be ledger-associated (`:243-250`). Nothing writes a user association; `item(for:)` returns nil for `userText` (`:379-380`). `encodeUserMessage` sends no client-side identity (`ClaudeSDKProtocolCodec.swift:189-207`). `AgentChatItem` has no native-ID field (`AgentChatModels.swift:119-166`). The translator extracts envelope `uuid` into `usageObservation.envelopeID` (`ClaudeSDKNDJSONTranslator.swift:1150`), and the bridge carries it (`ClaudeCompatibleProviderRuntimeBridge.swift:273-274`) — for usage only, not identity.

**Hypothesis to validate first (highest strategic risk):** the reader rejects the *whole candidate* on any `file-history-snapshot`, `progress`, `system`, sidechain, compaction, or agent entry (`ClaudeSessionHistoryReader.swift:24-29`, `:271-272`, `:388-393`). If a real Claude Code session that edits files or runs hooks routinely contains such entries, import is unsupported for essentially every real session regardless of association. The Step 2 capture answers this with one file; nothing else should be built until it does.

**Smallest evidence for each association, and candidate carriers (all unproven):**

- *Live output ↔ native rows.* Capture the envelope `uuid` on each assistant/tool-result stream item and compare with the JSONL entry `uuid`. If equal 1:1, the carrier is one optional member on `AgentChatItem` (e.g. a provider-native entry ID), populated only by the Claude runtime bridge where local items are created, and the ledger's `NativeItem.localItemID` becomes writable from that field (either at stream time or at import by matching). Version 7 compatibility holds for an optional member (older builds drop it on resave, which the spec already accepts). Also probe how the live `toolInvocationID` is derived versus the reader's deterministic one (`ClaudeSessionHistoryReader.swift:68-69`) — if both derive from `tool_use_id`, tool rows may already join with no new field. Read-only source probe, no live run.
- *Native user ↔ local user.* Three candidates: (i) the CLI echoing accepted user messages with their native `uuid` on stdout (a hypothesis about a CLI option; must be verified by the capture, not assumed); (ii) byte-exact equality between the first post-baseline native user text entry and the payload the app sent through `encodeUserMessage` — exact, not fuzzy, but still "text match" under the current rule; (iii) positional: the first native user text entry after the dispatch's own baseline offset in a fully validated file. (ii) and (iii) are inferences the reviews excluded; adopting either is an owner change.

**Can a narrower path meet the contract without a generic provenance redesign?** Yes in shape: Claude-only, one optional item field, one ledger write site, no new store/translator authority. But it cannot meet the *current preflight* without an owner change, because user association has no proven carrier today. **Scope reductions that require an owner decision:** accept (ii) or (iii) as user evidence; restrict import to "no output streamed locally" dispatches (crash before first byte — the R1a tail-fill case) and drop the output-association check there (review A P1-05 explicitly rejected an empty-output shortcut, so this is a reviewed reversal); relax the decoder subset to *skip* non-conversation entry types instead of refusing the file. Each is a reviewed source change with evidence, not something this consultation grants.

**Recommendation:** Step 2 probe only. Do not add the item field until the capture shows the UUIDs match and the reader accepts a real file.

---

## 4. Restart helper: resolve the arm-sent policy now, or keep deferred?

**Proven:** `AppRelaunchCoordinator.production` returns nil (`AppRelaunchCoordinator.swift:172`), so the arm-sent unresolved path (`AgentLifecycleShutdownCoordinator.swift:800-807`, `offeredChoices` empty at `:97-101`) is unreachable in production. Arm is sent only in Stage B after the all-stopped proof, so when this case arises, teardown and the R6 proof have already happened. The helper's own state machine fails with zero opens 15 s after arm if the parent hasn't exited (`ProcessRelaunchHelper.swift:24`, `:501`) — but the parent cannot prove the helper is running that state machine, so this is not exit proof.

**Keep Restart deferred (recommended).** Manual quit/reopen is preserved and already committed; the freeze is a latent defect in gated-off code. Resolving it now is rigor beyond the goal.

**Smallest honest alternatives for when activation is actually on the table** (none approved; all keep R4's single deadline and R6, and none claims a signal proves exit):

- **A. Status quo:** retain ownership, no choices, document the wedge as a Phase 4 activation blocker.
- **B. Honest Quit-anyway:** in the arm-sent case offer only `proceedAnyway` with wording "RepoPrompt will quit; it may or may not reopen on its own." No Retry (fresh helper refused), no Cancel (Stage B has none anyway). This claims nothing about the helper. Hazard: a double launch if the owner reopens manually while an armed helper later opens the bundle — whether that creates a second instance depends on the `openBundle` implementation (bounded source probe: does it use default `NSWorkspace` open semantics, which activate an existing instance?). Owner-visible tradeoff: "possible unexpected reopen" vs "frozen prompt".
- **C. Abort+kill then proceed as B:** already what `stopUnarmed` does (`:916-949`); it changes nothing about proof.

A lease/service/handshake redesign is not justified: B achieves honesty with a wording change and one `offeredChoices` case, and A costs nothing. Deferral is smaller than both.

---

## 5. Source-only work before live O3 acceptance; what must not activate

**May precede live acceptance (source-only or read-only):**
- The Step 2 DEBUG diagnostics logger (stream-side only; it records what the app already receives; no home inspection by the app).
- Read-only source probes: incremental turn-start rule and anchor consumers; `toolInvocationID` derivation in translator vs reader; existence of a resequence primitive; `openBundle` open semantics; whether the shim's Claude arguments include any user-message replay option (do not add one).
- A Step 1 acceptance checklist document for the owner (normal lifecycle only).

**Must not activate or change:** `AgentRecoveryActionQualification.production` (all false, `AgentRecoveryActionRunner.swift:46`); `AgentRuntimeQualification.production` (empty, `AgentProcessRegistrySupport.swift:60`); `AppRelaunchCoordinator.production` nil; `--session-id` preallocation; kqueue/signals; any qualification record derived from fixtures. The coupled rule (`activatesRegistration` requires every pair in `supportedPairs`, `:65-80`, and an uncovered pair is refused before spawn, `:82-86`) means the registry — and thus every Phase 4 action gate — cannot activate until every ACP and Claude-compatible backend is live-qualified. Narrowing (qualify only the owner's Claude-native/Codex pairs and refuse the others, or let unqualified pairs launch unregistered and lose two-writer coverage) is a separate design/owner choice. It is the single biggest structural blocker and should be the first of the three decisions in Step 3.

---

## 6. Per-step detail and maintainer-guidance check

**Step 1 — Phase 1/2 normal-lifecycle acceptance (owner-run).**
Done-when: each of quit, window close, relaunch, Reset, Delete, queued MCP send, scheduled send shows the R1a/R2 presentation and leaves records consistent, with a one-line result per path in the evidence directory, labelled "live, owner-run". Checks: none in CI; read-only inspection of `AgentRecovery/v1` files. Anchors: `AgentModeViewModel.swift:16887-16918` admission; `prepareSessionForWindowClose`; launch-state/clean mark. Uncertainty: Phase 1/2 may already be in daily use, in which case this is a checklist formalization. Owner decision: run it (recommended) vs. accept daily use as implicit acceptance.
Guidance check — invariant: nothing typed is lost on normal lifecycle; confidence: high in source, unverified live; authority: owner action; state safety: no code change, git-reversible data if a bug surfaces; observability: record inspection; scope: checklist only; validation boundary: live normal lifecycle, no kill.

**Step 2 — Claude evidence probe.**
Done-when: DEBUG logger lands with a unit test that it emits the expected fields from an injected stream result, plus an owner-run capture comparing log to JSONL, recorded as a dated evidence note with the CLI version. Checks: the Claude provider/bridge suites; lint/guardrails. Anchors: `ClaudeSDKNDJSONTranslator.swift:1150`, `ClaudeCompatibleProviderRuntimeBridge.swift:254-276`, `ClaudeSessionHistoryReader.swift:24-29`. Uncertainties: UUID interchangeability; real-file acceptance by the reader; tool-ID derivation. Owner decisions: authorize the one live capture (recommended; alternative: stay blind and keep Phase 4 Claude permanently deferred).
Guidance check — invariant: no production behaviour change; confidence: high for the logger, unknown for the result; authority: owner for the capture; state safety: diagnostics file only; observability: the log itself; scope: one DEBUG file + test; validation boundary: injected stream in tests, one live run by owner.

**Step 3 — Owner decisions.**
Done-when: three one-line Decisions recorded. Recommendations: (a) decide the coupled-activation scope before any further Phase 3/4 source — alternatives: full qualification of every pair (status quo, likely never), narrow to used pairs with refusal of others, or unregistered launches for unqualified pairs; (b) keep the older-message refusal (alternatives in §2); (c) keep Restart deferred, with option B as the recorded candidate (alternatives in §4). Anchors: `AgentProcessRegistrySupport.swift:65-86`; `AgentModeViewModel+RecoveryActions.swift:474-476`; `AgentLifecycleShutdownCoordinator.swift:97-101`, `:800-807`.
Guidance check — invariant: architecture preserved; confidence: n/a; authority: owner only; state safety: none; scope: decisions, no code; validation boundary: none.

**Rigor challenged:** the whole-candidate reader rejection is not "rigor" if it yields zero imports in practice — it is a strictness that must be measured (Step 2) before being defended; the arm-sent freeze is unreachable and should not consume a review round; the older-message gap is already satisfied by refusal + Edit and should not drive a transcript redesign.

---

## Recommendations

1. **Do Step 1 first** (owner-run normal-lifecycle acceptance of Phase 1/2). It is the only step that turns already-committed source into confirmed product value and needs no code.
2. **Do Step 2 next** (DEBUG stream diagnostics + one owner-authorized live capture). It decides Claude Phase 4 viability — reader real-file acceptance and UUID interchangeability — before any association field or ledger write is designed. Build nothing association-related until it reports.
3. **Record the three decisions** (coupled activation scope first; older-message semantics; helper policy). My recommendations: narrowing of activation is the owner's call but the status-quo rule blocks everything; keep the older-message refusal; keep Restart deferred with option B as the documented candidate.
4. **Cut:** relocation/routing work, any helper lease/handshake, generic provenance, the DEBUG App-Support override, fixture expansion.

**Proven facts (packet):** all Phase 4 gates and `AppRelaunchCoordinator.production` are OFF; the preflight always refuses live Claude conversations; the reader rejects whole candidates on non-conversation entry types; Send saved refuses non-latest bubbles with Edit available; turn ID equals user item ID; arm is Stage-B only after all-stopped proof; kill/ESRCH/timeout are not exit proof; activation requires every supported pair.
**Hypotheses:** real session files contain rejected entry types; envelope UUID ≡ JSONL UUID; tool IDs may already join deterministically; older unsent bubbles are commonly span activities; `openBundle` activates rather than duplicates an instance; the CLI can echo user-message IDs. Absence of any of these in the packet is not proof of absence in the repository.
