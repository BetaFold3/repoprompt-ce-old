# Completion outcome — 2026-11-02

The plan is closed by owner decision after daily-use acceptance on a rebuilt and relaunched Dev build. The owner reported that, after switching sidebar sessions, one press now opens both the quick model picker (⌥⌘K) and quick handoff (⇧⌥⌘K), and that typing goes straight into the composer after selecting a model, without clicking it. The remaining live-checklist items below were not individually exercised and are not claimed.

What landed:
- August hardening, commit `20479a32`: D1 composer focus token, D2 HUD presentation epoch and deferred false→true focus edge, and D4 DEBUG `hud-routing` instrumentation. These remain in place.
- November follow-up, commit `d1f59003`: the root cause of the two-press failure was the shell's redraw-driven active-tab dismissal, which read `PromptViewModel`'s active tab without observing it, so the next redraw (the shortcut's own presentation) could deliver a stale tab change and close the fresh HUD. It was replaced by a synchronous, window-scoped `.activeComposeTabChanged` receiver shared by the navigation, model-selection and handoff HUDs. Successful model selections now request composer focus through the existing token path (`.modelSelectionCommitted`). Lifecycle and focus tracing was extended. Commit `9e6cfa42` separately repaired a guardrails allowlist entry.
- Reviews: OracleA and OracleB reviewed the November change independently, with one policy-aware re-review round. No P0/P1 remained open. Findings and dispositions are kept locally in `.agent-artifacts/agent-focus-delivery-reliability/evidence/` (not committed).

Decisions at closure:
- D3: the navigation HUD's mirrored focus fix was not implemented. Its gate is now satisfied (the five source conditions were confirmed and the model HUD was live-validated), so it may land later without re-adjudication if a navigation-HUD focus failure is observed. The navigation HUD already shares the November dismissal repair.
- D4: no wrong-window routing was reported after the dismissal repair, so no routing fix was made. The pre-specified fallback-only re-resolve remains the response if `hud-routing` logs ever show the race.
- Former deferrals, closed the same day at the owner's request: a local cross-family switch (Codex to Claude Code) was confirmed to keep the same session object and still request focus; replacing the session object under the same tab while the picker is open was confirmed to fail the commit and publish no focus (both now tested in `AgentModeChatSwitchActivationTests`); and DEBUG `composer-focus` tracing now records `drop` (`inactive`, `superseded`), `seed` and `resign` lines (B-R1-P2a). OracleA and OracleB reviewed that change with no P0/P1 findings; their P2/P3 findings were fixed. The new log lines have not yet been observed in a running app.

Durable invariants now live in the [quick model/handoff HUD contract](../../quick-model-picker-and-handoff-hud.md). The original plan follows intact except for its status lines and owner decision; its historical pending statements are not current guidance.

---

# Agent Mode focus delivery reliability: new-session composer and quick model/handoff HUD

Scope: read when the task touches new-session composer focus delivery, the quick model picker / quick handoff HUD keyboard-focus acquisition, `ResizableTextFieldFeatures` focus plumbing, or HUD shortcut routing instrumentation.
Authority: Authoritative
Last-verified: 2026-11-02
Status: completed 2026-11-02 by owner decision on daily-use acceptance (see the completion outcome above). Original status: active implementation plan. The D1 composer-token contingency, D2 model-selection/handoff HUD focus edge, and D4 DEBUG routing instrumentation are implemented in source, activating the pre-authorized D3 contingency of the Agent Mode QoL plan. The November follow-up now replaces shell redraw-driven tab dismissal with synchronous window-scoped tab events, adds success-only model-switch composer restoration, and extends lifecycle/focus tracing. Runtime attribution and daily-use acceptance remain unresolved. The D3 source spike confirms all five navigation-HUD conditions, but the mirrored navigation-HUD implementation has not landed and remains gated on live model-HUD validation. Supersedes nothing.

## How this plan was settled

User-reported instability on the running build (commit `81030bb9`, byte-identical to the repo debug build): quick model picker (⌥⌘K) and quick handoff (⇧⌥⌘K) intermittently "not effective" on first press, and new-session composer focus intermittently absent — while ⇧⌘P (snippet palette) is stable, proving Carbon/T1 delivery works. All findings below were re-verified against source this session.

Two independently prompted Oracle lanes (presets OracleC and OracleD, identical prompts, plan mode) produced positions on decision points DP1–DP6, followed by one adversarial duel round. DP1 (consume timing) and DP3 (shell resign) settled by concession in round 1. In the final round, OracleD responded fully; **OracleC's lane failed with a provider billing error before responding**, so the moderator (session agent) adjudicated the residuals (DP2, DP4/DP5, DP6) using OracleC's completed round-1 positions, OracleD's round-2 defense, and direct source verification. Adjudicated points are marked below. Final decisions are binding for this work; deviations require re-justification.

## Historical pre-hardening findings

F1–F6 below record the August baseline, not the current implementation. The D1/D2 safeguards remain implemented; the November follow-up addresses a separate observation gap.

- **F1 — composer focus request dead-ends in SwiftUI bookkeeping.** `AgentInputBar.applyComposerFocusRequest` on tab match does only `isFocused = true` + `consumeFocusRequest(id:)`. Two stacked `@FocusState` layers exist (outer binding on `ResizableTextField`, inner private binding on `CustomTextField`); nothing calls `makeFirstResponder` on the hosted `ImageAwareTextView`. Failure modes: true→true no-change no-op, and no AppKit bridge even on real transitions. The success-exit request is published while the brand-new tab's composer may not yet be mounted/in-window.
- **F2 — HUD focus acquisition races its own insertion.** `AgentModelSelectionHUDView`'s only initial acquisition is `.onAppear { queryFocused = true }`, executed inside the `withAnimation(hudAnimation)` transaction that inserts the HUD subtree (`ContentRootShellView.animateHUD`), while the composer `NSTextView` holds window firstResponder. `present()` sets `phase` (`.ready`/`.unavailable`) *before* `isPresented = true`, so the `.onChange(of: phase)` recovery cannot fire at presentation.
- **F3 — re-present while mounted has no focus path, and preserves the query.** Same-mode re-press while presented toggle-dismisses (`present()` early return). Cross-mode re-press refreshes the presentation without re-firing `.onAppear`. Verified: `query = ""` runs only when `!wasPresented` — a cross-mode refresh keeps the existing query text and selection (`rebuildFilteredLeaves(preserveSelection: wasPresented)`).
- **F4 — a focus-lost HUD is invisibly dead.** The dim layer blocks clicks but not key events; keystrokes land in the composer beneath a visible HUD. All HUD keyboard interaction (query typing, `.onSubmit`, `.agentModelSelectionHUDKeys` onKeyPress) requires SwiftUI focus inside the HUD hierarchy.
- **F5 — multi-window routing race unconfirmed.** `guardedHUDWindowState()` = `NSApp.isActive` + `activeMainWindowState ?? latestWindowState`. A Carbon press before key-window handover completes could route to the previously-key window (HUD behind another tile). Not yet distinguished from F2 by observation; snippet stability rules out enablement/delivery.
- **F6 — load-bearing seams verified.** `AgentComposerView` has a custom `==` via `hasEquivalentRenderIdentity(props, placeholderText, currentTabID)` (AgentInputBar.swift ~356–368). `ImageAwareTextView: NSTextView` (ResizableTextField.swift:42) has no `viewDidMoveToWindow` override. In-repo precedents: `AgentChangesSearchField` coordinator token-compare + deferred `makeFirstResponder`; snippet-palette receiver's guarded `makeFirstResponder` on the same `NSTextView`.

## Settled decisions

### D1 — Composer focus: D3 `composerFocusToken` contingency, consume-at-match, no key-window gating

(Consume timing settled by OracleC concession; key-window policy adjudicated to OracleD after a crossover — see rationale.)

- `ResizableTextFieldFeatures` gains `composerFocusToken: UUID?` (+ defaulted `.agentInputBar(...)` builder parameter). **No closures are added to features** — a closure member would break the equality-gating the mechanism depends on.
- **Required re-justification after Oracle remediation:** direct source analysis proved that independent `onChange` handlers for `focusRequest` and `currentTabID` were unsafe under SwiftUI update coalescing: the request handler could mint and consume the matching request, then the tab handler could erase the newly minted token. `AgentInputBar` therefore observes one Equatable `AgentComposerFocusObservationCue { tabID, requestID, requestTabID }`. Its single `onChange` detects the tab transition, clears the sole `@State private var composerFocusToken: UUID?` first when the tab changed, then evaluates the new tab+request snapshot. A match mints that request UUID, keeps `isFocused = true` as a non-authoritative mirror, and consumes at match; a publish-time mismatch remains pending, while a tab-change mismatch is consumed/discarded so it cannot ambush a later tab. This ordering correction preserves UUID-only focus plumbing, request supersession, consume-at-match, and the original asymmetric mismatch rules.
- `AgentComposerView`: stored `composerFocusToken`, threaded into features. **It must join the custom `==` (`hasEquivalentRenderIdentity`).** Omission silently defeats the mechanism exactly in the `reusedPlaceholder` case (props unchanged → `.equatable()` swallows the render). It must NOT ride `AgentComposerProps` (QoL D3 prohibition stands).
- `CustomTextField.Coordinator`: `lastAppliedComposerFocusToken`, `pendingComposerFocusToken`, and a colocated pure `ComposerFocusTokenPolicy` (style: `SnippetPaletteScope`):
  - token nil → `.clearPending`
  - token == lastApplied → `.none`
  - `textView.window == nil` → `.waitForWindow` (stash pending; retry on window attach)
  - `window.attachedSheet != nil` → `.drop` (mark applied, never retry; DEBUG diagnostic — see below)
  - else → `.attempt`: if the text view is already first responder, mark applied and return without another AppKit call; otherwise guard `acceptsFirstResponder`, then `window.makeFirstResponder(textView)`, and verify `window.firstResponder === textView`. Success or failure marks the token applied, so an attempt failure is terminal rather than retried; failure increments the DEBUG `ui.composer.focusToken.attemptFailed` diagnostic.
  - **No `isKeyWindow` or app-active gating** (adjudicated). Rationale: `makeFirstResponder` mutates only that window's responder chain — it cannot steal cross-window keyboard focus, so a non-key apply is inert pre-arming that manifests only when the user deliberately returns (composer focused in the window whose session they just created — the desired outcome, not an ambush). A terminal drop on non-key would permanently lose focus in the fresh-window first-composer flow, where `viewDidMoveToWindow` fires before/interleaved with `makeKeyAndOrderFront` and key state is not guaranteed at apply time. Cosmetic: a pre-armed non-key composer shows no blinking caret until the window keys — expected.
- **Placement:** apply the token in `updateNSView` after the `configure*` calls and **before the text-sync block** — that block's `hasMarkedText()` early return would skip an end-of-body apply during IME composition (a marked-text view is already firstResponder; `makeFirstResponder` is a no-op on it). Application is deferred to the next main-queue turn; never call `makeFirstResponder` inline from `updateNSView`. Deferred work re-validates the current token before acting (stale scheduled work drops).
- **Remount-ambush seed:** `makeNSView` seeds `lastAppliedComposerFocusToken = features.composerFocusToken` **without attempting focus**. A representable remount under a surviving parent `@State` token must not treat a minutes-old token as new. Only post-mount token *changes* are focus-bearing; the brand-new-composer flow still works because the parent `@State` is nil at first render and the request lands afterward, producing a real delta. (This seeding supersedes OracleC's alternative token-resolved callback — same hazard, no closure in features.)
- `ImageAwareTextView` gains `var onDidMoveToWindow: (() -> Void)?` + `viewDidMoveToWindow` override (weakly captured coordinator); on `.waitForWindow` the pending token re-runs the policy at attach. `dismantleNSView` clears the hook and pending state. A dismantle-before-attach loses the token by design (the tab/composer ceased to exist — discard is the spec); the `.drop` and dismantle loss paths get a DEBUG diagnostic (`AgentModePerfDiagnostics` counter or `os_log`) so silent loss is observable without an acknowledgement channel.
- Both existing `@FocusState` layers stay untouched and are declared non-authoritative mirrors; unifying them is out of scope.

### D2 — HUD focus: presentation epoch + transaction-escaping false→true edge; no shell resign; pure toggle

(Edge mechanism settled by OracleD concession to OracleC's false→true edge; shell resign settled by OracleD concession; toggle semantics and report channel adjudicated to OracleD over OracleC's held conditional-recover.)

- `AgentModelSelectionHUDViewModel`: `@Published private(set) var focusAssertionEpoch: UInt64 = 0`, incremented (`&+= 1`) at the end of `present()` after `rebuildFilteredLeaves` — on every *completed* presentation (fresh mount and cross-mode refresh). Never bumped by the same-mode toggle-dismiss early return, `dismiss()`, `resetPresentedState()`, `suspendForBlockingOverlay()`, or the committing early return (a press during commit cannot grab focus; suspension's no-stale-remount invariant untouched).
- The query field is disabled only while `viewModel.isCommitting`, not whenever `phase != .ready`. An unavailable completed presentation therefore accepts the same epoch-driven focus edge and keyboard query input; result rows remain independently disabled unless the phase is `.ready`.
- `AgentModelSelectionHUDView`: one helper replacing the bare `.onAppear` true-set:

  ```swift
  private func assertQueryFocusEdge() {
      var t = Transaction(); t.disablesAnimations = true
      withTransaction(t) { queryFocused = false }          // no-op when already false
      let epoch = viewModel.focusAssertionEpoch
      DispatchQueue.main.async {                            // escapes the insertion/animation transaction
          guard viewModel.isPresented,
                viewModel.focusAssertionEpoch == epoch,
                viewModel.phase != .committing else { return }
          var t2 = Transaction(); t2.disablesAnimations = true
          withTransaction(t2) { queryFocused = true }
      }
  }
  ```

  Wired at exactly three presentation sites: `.onAppear` (fresh mount — epoch bumps before the view exists), new `.onChange(of: viewModel.focusAssertionEpoch)` (cross-mode re-present while mounted — the gap where `.onAppear` cannot re-fire), and the `.ready` branch of the existing `.onChange(of: viewModel.phase)` (commit-error recovery; the field was `.disabled`, so live composition there is precluded and the edge cost is nil). The explicit false→true edge is required because a stale-true binding (SwiftUI bookkeeping says focused, AppKit disagrees) makes any plain true-write a no-op, and FocusState's revert behavior for failed claims is undocumented. `DispatchQueue.main.async` (not `Task { @MainActor }`) for deterministic ordering relative to the AppKit runloop.
- **Reactivation residual:** `.onReceive(NSWindow.didBecomeKeyNotification)` filtered to the hosting window: `guard viewModel.isPresented, !queryFocused else { return }; assertQueryFocusEdge()`. Acquire-if-unfocused on this site only — per-site risk asymmetry: on presentation paths the focus prior is unknown/lost and a wrong skip *is* the reported defect (force the edge); on re-key the prior overwhelmingly favors intact (AppKit restores the window's responder) and a wrong skip merely fails to fix a speculative state (the bit may gate).
- **Same-mode re-press stays pure toggle-dismiss.** No view→VM `isQueryFocused` report channel; no `QueryFocusRequest` struct (adjudicated). Rationale: a conditional toggle keyed on possibly-stale, invisible focus bookkeeping creates state-dependent double-press-to-close on the common path and gates *recovery* on the exact bit the edge-forcing already declares untrustworthy; press→dismiss→press→fresh-present is a universal, deterministic two-keystroke recovery from any unenumerable loss state.
- **No shell-side `makeFirstResponder(nil)`** (settled). The shell cannot observe `present()`'s `.unavailable` branch at resign time; an unavailable presentation would leave the window with no useful responder (strictly worse than today), and the edge assertion performs one atomic responder handover — the composer `NSTextView` resigns as part of the same `makeFirstResponder` transfer. `ContentRootShellView` is touched only for D4 instrumentation. *(Historical August scope, superseded in November 2026: the November follow-up below also changed the shell's active-tab dismissal receiver. The no-shell-resign decision stands.)*
- No `NSEvent` monitor (parallel input path; conflicts with digits-are-query-input and commit-cancel invariants). No `.defaultFocus` reliance (undocumented evaluation timing for mid-scene overlay insertion; may be added later as a non-load-bearing hint). No animation changes.
- Spike item: confirm the `.agentModelSelectionHUDKeys` `onKeyPress` attachment point receives events when focus is on the Close button (bears on the Tab-to-Close intra-panel state). Verified during moderation: cross-mode `present()` preserves `query`, so the epoch-site edge may momentarily detach a focused field with preserved text — an accepted, bounded cost.

### D3 — Navigation HUD: excluded from implementation commits; spike + gated same-series follow-up

(Settlement accepted by OracleD with a gate amendment; OracleC's last completed position was gated inclusion — consistent.)

- The nav HUD (`AgentNavigationHUDView`/VM) shares the `.onAppear`-only pattern but is not one of the verified user failures, and neither Oracle lane read its sources. Implementation commits exclude it.
- The Phase-0 source spike confirmed all five navigation-HUD conditions: (1) animated-transaction insertion; (2) focus-required key handlers; (3) readiness established before insertion (the phase-before-`isPresented` analog); (4) subtree retention on re-present; and (5) dismissal/routing semantics (`present(mode:currentWindow:)`) permit a presentation epoch with correctly derived bump/never-bump sites.
- The live checklist includes nav-HUD first-press as a non-blocking observation item.
- A mirrored fix lands as a **separate commit in the same PR series** gated on: five conditions confirmed in source AND the model-HUD fix live-validated. (Amended gate: requiring a live nav repro is evidentially wrong for an intermittent defect — a clean finite session is weak evidence of absence.) No shared HUD-focus abstraction in either round.

### D4 — Multi-window routing: instrument only; pre-specified follow-up fix

(Consensus.)

- Do not change `guardedHUDWindowState()`, its latest-window fallback, or anything in T1 `GlobalShortcutActivation` in this work. The fallback is a designed first-press-after-activation behavior.
- Implemented DEBUG-gated `os.Logger` category `hud-routing` (window numbers and booleans only; no user content):
  - Coordinator seam (`showAgentModelSelectionHUD` / `showAgentNavigationHUD` post sites): every record includes command and mode. Suppressed resolution is logged when `guardedHUDWindowState()` returns nil. A resolved target is classified `.nativeKey` only when both windows are non-nil and identical; otherwise exact identity with `activeMainWindowState` is `.focusFallback`, and the remaining resolved case is `.latestFallback`. The record also includes resolved window ID/number, native key-window number, and app-active state.
  - Shell seam (both HUD `onReceive`s): records command, mode, requested/current window IDs, window number, exact-window match, key-window state, and gate disposition; successful delivery distinguishes `.presented` from same-mode `.toggleDismissed` after `present(...)` returns.
- Instrumentation is observational only: it does not change target resolution, notification payloads, shell gating, or presentation routing.
- Decision rule: a fallback-routed post while a *different* tracked window was natively key, or a shell presenting with `isKeyWindow == false`, confirms the routing race → follow-up fix is a single-runloop-turn re-resolve **limited to the `latestWindowState` fallback branch** (re-read resolution after one main-actor hop, then post — the fallback still fires, one turn later). Otherwise close as subsumed by D2.

## November 2026 focused follow-up

The owner authorized a focused fix and tracing after independent OracleA/OracleB guidance, with daily-work acceptance to follow. This does not reset the earlier rounds or adjudicated D1–D4 decisions.

Step 6 — done | rounds 1/2 | open: none (local implementation and validation; owner daily-use acceptance passed 2026-11-02) | downgraded: none | assumed: repair shared navigation dismissal without changing its focus gate; retain evidence locally | deferred: same-tab/cross-family identity coverage; B-R1-P2a low-level dropped-token tracing (see evidence)

Owner decision (2026-11-02): fix the completed remote-passkey plan allowlist separately, then commit the reviewed HUD fixes locally.
Owner decision (2026-11-02): close the plan on daily-use acceptance of first press after a session switch (both shortcuts) and immediate typing after a model selection.

Evidence directory (local, not committed): `.agent-artifacts/agent-focus-delivery-reliability/evidence/`. Initial findings: `2026-11-02-initial-oraclea.md`, `2026-11-02-initial-oracleb.md`; dispositions and validation: `2026-11-02-step6-evidence.md`. Round counts apply to this November step only; August rounds and owner decisions above are unchanged.

- **Source-confirmed gap, runtime attribution pending:** the shell reads the nested active tab without observing its owner. Its old redraw-driven dismissal could therefore close a fresh HUD when presentation exposed a stale tab comparison. Retained routing logs showed correctly targeted `presented` receives, but did not record the later dismissal cause. They do not prove every reported failure had this cause.
- **Implemented dismissal repair:** consume the existing post-storage `.activeComposeTabChanged` notification synchronously, strictly matching the required window ID, and remove the old nested `onChange`. Apply to the shared navigation/model/handoff dismissal seam; navigation's own selection dismisses before switching/routing. This does not implement or bypass the D3 navigation-focus gate.
- **Implemented focus repair:** model-selection presentations carry an optional success action, not a closure in text-field features. After successful `.switchModel` commit, capture the eligible callback, reset the HUD, then request the existing composer token with reason `.modelSelectionCommitted`. Source tab/session identity and shutdown state are revalidated. Tab change during commit or blocking-overlay suspension invalidates the callback; failure/dismissal/handoff never invokes it.
- **Shared receiver body:** `AgentHUDActiveTabChangeGate.handle` (next to the gate in `ContentRootShellView.swift`) performs the strict window match, navigation dismissal, and `activeTabDidChange()`. The shell wraps it in one HUD animation; tests call the same function.
- **Tracing:** `hud-routing` now includes active-tab receipt, reasoned dismissal attempts, commit/suspension outcomes (`commit-success-invoke-focus-callback` records only that the callback was invoked; it may still reject or the delivery may fail), epochs, and query lifecycle/focus-binding events. Shell receive, VM, and view records carry a DEBUG-only per-HUD-instance trace ID (`hud=`); shell receive records pair it with the owning window ID. Query records include the hosting window's first-responder class name (not contents), and the deferred true leg logs `assert-edge-ran` or `assert-edge-bailed`. `composer-focus` correlates request, input-bar cue action (`applyAndConsume`, `leavePending`, `discard`, `none`), and delivery by token UUID; delivery reports AppKit first-responder state at attempt time, not afterwards. No user content or session IDs are logged.
- **Limits:** logical reset and a deferred token do not prove physical teardown or focus handover. No speculative teardown acknowledgement, retries, delay, new key-window policy, or closure-bearing features were added. Rapid newer-HUD/overlay focus competition remains a live acceptance case, not a guarantee inferred from unit tests.
- **Durable contract:** see [quick model/handoff HUD](../../quick-model-picker-and-handoff-hud.md). Keep this plan active until its outstanding live checks and navigation gate are resolved.

## Tests

New:
- `ComposerFocusTokenPolicyTests` (pure): full action table — nil→clearPending; repeat token→none; no window→waitForWindow; sheet→drop; happy→attempt; seed semantics (a seeded token never attempts); stale scheduled work rejected when the current token changes; drop marks applied (no retry).

Extended (additive only, no weakening):
- `AgentModelSelectionHUDViewModelTests`: epoch bumps on fresh present and cross-mode refresh; unchanged on toggle-dismiss, `dismiss`, `suspendForBlockingOverlay`, commit reset, and the committing early return; monotonic across cycles; cross-mode `query` preservation (locks F3).
- `AgentComposerFocusRequestTests`: if the `applyComposerFocusRequest` decision is extracted into a pure helper (recommended, in `AgentComposerUIModels.swift`), add its table — apply on match / leave pending on publish-time mismatch / discard on tab-change mismatch.

Regression (run unchanged): `AgentModeChatSwitchActivationTests`, `SnippetPaletteHelperTests`, `SnippetPaletteShortcutRoutingTests`, `SnippetPaletteActivationGateTests`, `KeyboardShortcutCatalogTests`, `GlobalShortcutActivationTests`, `AgentModelSelectionIndexTests`.

November follow-up (additive):
- `AgentModelSelectionHUDViewModelTests`: the success callback runs once after logical reset; it never runs for failure, handoff, dismissal, toggle, mode replacement, or idle/ready tab change; switch and handoff commits complete under a mid-commit tab change or suspension without focus; a mid-commit tab change followed by failure keeps the error visible, and a later successful retry never revives the invalidated callback, while a fresh presentation requests focus.
- `AgentModeChatSwitchActivationTests`: local HUD-driven success requests `.modelSelectionCommitted` for the source tab; stale-tab HUD commit fails without focus; the factory callback rejects tab drift and shutdown freeze; handoff publishes no model-selection request; the production post-storage `.activeComposeTabChanged` post drives the shared `AgentHUDActiveTabChangeGate.handle` (foreign/unscoped events ignored, both HUDs dismissed synchronously, first press after the switch presents and requests focus for the new tab).
- `RemoteWorkspaceSidebarTests`: remote host-default HUD success requests source focus; tab drift rejects commit and callback.

Not unit-writable (live-only): actual `makeFirstResponder` success, FocusState↔AppKit bridging, transaction-escape timing, the shell's SwiftUI `onReceive` subscription itself, the redraw-driven regression of the removed nested `onChange`, and physical HUD teardown versus composer focus. Not covered: replacing the session object under the same tab ID, and a cross-family local switch against the identity guard (no existing seam; live or follow-up).

## Live checklist

HUDs (both ⌥⌘K and ⇧⌥⌘K): **switch sidebar sessions, then press once, both immediately and after a pause**; also switch sessions while a HUD is open and verify prompt dismissal, and test rapid A→B→A plus two-window isolation. After a successful local/remote model selection, type immediately without clicking the composer; also immediately reopen another HUD and verify it owns typing. Handoff and Escape focus behavior remain unchanged. First press after ⌘Tab activation, after clicking the transcript, and with the caret actively in the composer — type immediately: characters land in the query, arrows/ctrl-n/p move selection, Enter commits, digits stay query input, empty-query Enter inert; cross-mode switch retains focus each way (query text preserved); same-mode re-press toggles closed; Escape clears-then-dismisses; during a committing handoff Escape/click-outside/re-press do not cancel; blocking overlay during commit unmounts without stale remount or stray focus; commit error refocuses the query; app deactivate/reactivate with HUD up recovers focus (didBecomeKey site); Reduce Motion on and off.

Composer: immediate typing + visible caret without clicking for every creation path — `.agentNewChat`, `.newComposeTab`, both titlebar actions (standard + knowledge), swallowed-placeholder reuse, and a fresh window's first composer (exercises `.waitForWindow` + non-key attempt; caret blinks once the window keys); creating while the old composer is focused still moves firstResponder to the new editor; rapid successive requests apply only the newest; switching away before delivery discards without a later ambush; programmatic creation (`focusComposer: false` — handoff, MCP, restore) stays focus-neutral; IME: mid-composition create-session (marked-text placement path) and HUD open.

Multi-window: 3–4 tiled narrow windows, rapid click-then-press alternation, correlate `hud-routing` logs (fallback classification vs `NSApp.keyWindow`), confirm no HUD-behind-tile; Settings-window-key keeps shortcuts disabled (T1 contract unchanged). Nav HUD first-press: observation item, non-blocking.

## Phased implementation order

0. **Spike (read-only):** `rg` all `.agentInputBar(` construction sites (defaulted params must keep non-agent callers source-compatible); read nav HUD sources against the five D3 conditions; confirm the HUD `onKeyPress` attachment point vs Close-button focus.
1. **HUD fix (atomic commit):** VM `focusAssertionEpoch` + view `assertQueryFocusEdge()` at the three sites + guarded didBecomeKey re-assert + `AgentModelSelectionHUDViewModelTests` extensions. VM and view must land together.
2. **Composer token, step A (inert, landable alone):** `ResizableTextField.swift` — features field + builder param, `ImageAwareTextView.onDidMoveToWindow` + override, coordinator state, `ComposerFocusTokenPolicy` + placement (after `configure*`, before text sync), `makeNSView` seeding, `dismantleNSView` cleanup, DEBUG drop diagnostics. `ComposerFocusTokenPolicyTests`.
3. **Composer token, step B (atomic):** `AgentInputBar` `@State` mint + tab-change clear; `AgentComposerView` stored property + **`==` inclusion** + features threading. These land in one commit — `==` omission is a silent total defeat.
4. **Routing instrumentation:** `GlobalKeyboardShortcutsCoordinator.swift` (both HUD post sites) + `ContentRootShellView.swift` (both receive sites), `hud-routing` DEBUG logs.
5. **Docs + validation closure:** update the QoL plan (record D3 contingency activation and outcome in its status line) and `quick-model-picker-and-handoff-hud.md` (focus-acquisition invariants: every completed presentation asserts focus via epoch + edge outside the insertion transaction; no shell resign; no event monitor; composer token seam in `ResizableTextFieldFeatures`), and bump Last-verified. Run `make guardrails`; the full live checklist remains required before this plan completes. The source half of the nav HUD D3 gate is satisfied, but its separate follow-up commit remains gated on live model-HUD validation.

Gates: `make dev-lint` every Swift change; `make dev-build` phases 1–4; `make dev-test FILTER=` per suite above; `make guardrails` for the routed-doc updates.

## Risks

- **`==` omission (phase 3):** silently defeats the token where props are unchanged (`reusedPlaceholder`); mitigated by atomic commit and the swallowed-placeholder live check.
- **`hasMarkedText` early return:** an end-of-body apply would be skipped during IME composition; mitigated by pinned placement before the text-sync block.
- **Remount ambush:** stale parent token refocusing on representable recreation; mitigated by `makeNSView` seeding (tested).
- **Silent token loss on `.drop`/dismantle:** accepted as spec-correct (discard cases); observable via DEBUG diagnostics rather than an acknowledgement channel (which would put a closure into the equality-load-bearing features struct and leave unconsumed store requests as unbounded deferred-focus ambushes).
- **Edge false-set cost:** momentary field-editor detach when a focused field is edge-forced; bounded to discrete presentation events (fresh mount: binding already false; commit-error: field was disabled; cross-mode: presentation is being replaced — query preserved, accepted).
- **didBecomeKey guard staleness:** benign in both directions (skip = today's behavior; fire = bounded edge).
- **Stale deferred work:** both composer and HUD deferred blocks re-validate current token/epoch immediately before acting.
- **A11y over-assertion:** assertions bounded to presentation events + guarded re-key; verified by keyboard-navigation live check.
- **Routing logs:** must not alter notification payloads or routing decisions; DEBUG-gated; no content logged.
- **Nav HUD:** knowingly ships one more release with the fragile pattern unless the gated follow-up lands; recorded as a deliberate scope decision with a same-series path.
- **`AgentInputBar.swift` diffs stay surgical:** one `@State`, apply-helper edits, one threading argument.
