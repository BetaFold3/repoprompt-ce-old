# 9-live fix 2 (recovery list): OracleA review, round 2

Scope: read when the task touches the recovery list's Continue editor text, refused-continuation row text, the order of surviving-process items, or the composer's send-refusal notice.
Authority: Reference
Last-verified: 2026-10-28
Covers: the OracleA review (round 2) of the recovery-list diff, copied from its export; the fixes are in fix-9live-list-worker.md


# Round-2 final review

**Not approved: two new P1 paths and two unresolved P1 paths remain.** No P0 or wrong-session transfer is demonstrated by the supplied code.

References below use post-change source line numbers from the diff. Validation claims in the notes were not independently verified.

## P1 — R2-01: Rescuing multiple drafts can erase all but the last from the mounted composer

**Evidence**
- `AgentModeViewModel+RecoveryList.swift:903–931`: the rescue helper synchronously loops over multiple drafts.
- `:974–990`: each successful move deletes its source draft.
- `:1048–1063`: each placement overwrites the single `draftRestorationEvent`.
- `:1073–1076` and `AgentInputBar.swift:855–868`: the consumer appends only that event’s text to live editor text, then stores the result.

**Failure scenario**

Two orphaned drafts, A and B, accumulated while the composer was unavailable. Resolving its saved draft triggers their rescue:

1. The model stores `M + A`, then `M + A + B`.
2. The synchronous loop publishes event A, then replaces it with event B before SwiftUI’s `onChange` consumes it.
3. The mounted editor still contains M. The last event carries only B, with `expectedPrior = M + A`.
4. The consumer computes `M + B` and stores it, overwriting `M + A + B`.
5. A’s dictionary entry was already deleted. **A disappears from every surface.**

The equality check fixes one event already reflected in the editor; it does not make multiple events lossless.

**Smallest fix:** Batch the rescued texts into one append and one restoration event per destination. Ensure any restoration event produced by the preceding list action is also preserved—not overwritten. Alternatively, use an acknowledged event queue.

**Regression:** Rescue two drafts with a mounted editor; consume the resulting event delivery and assert both texts remain in the editor **and** stored draft.

## P1 — R2-02: The session-wide sweep can move another action’s in-flight text

**Evidence**
- `AgentModeViewModel+RecoveryList.swift:793–795,849–861`: action exclusion is per row.
- `:903–923`: the sweep examines other rows without excluding `.working` rows.
- `:869–886`: the originating continuation applies its disposition only after its awaited action returns.

**Failure scenario**

1. Continue on row A submits X; A remains `.working`.
2. Its runner records a resolving outcome. The catalog now stops offering Continue, but A’s wrapper has not resumed to dispose of its draft.
3. An action on another row of the same session finishes—for example, Copy on a proposal—and invokes the sweep.
4. The sweep moves X into the composer and deletes A’s draft.

Two bad outcomes follow:

- **A dispatched X:** already-sent text is restored as supposedly unsent, contaminating the next composer submission.
- **A returned `importedCompleted`:** A’s wrapper subsequently evaluates `draft ?? text`, falls back to X, and appends X **again**.

This is distinct from the mounted-editor equality problem: two separate placements occur.

**Smallest fix:** Exclude other `.working` rows from rescue. Allow the originating continuation to rescue its own row only after applying its result disposition. Do not treat temporary absence of Continue as sufficient evidence that another in-flight action’s text is unsent.

**Regression:** Suspend A after committing its resolving outcome but before returning to its wrapper; perform another same-session list action. Cover both `.dispatched` and `.importedCompleted`.

## P1 — R1-01 remains partially unfixed: `importedCompleted` preserves only the newer revision

**Evidence**
- `AgentModeViewModel+RecoveryList.swift:871–887`: `.moveToComposer` selects `continuationDraftsByRowID[rowID] ?? text`, preserving only one value.
- `AgentRecoveryActionModels.swift`, changed `unsentContinuationText(for:)` block: resolving outcomes suppress the submitted continuation’s text.
- `AgentRecoveryReconciliationTests.swift:2372…`: the new regression explicitly expects `"newest"` alone.

**Failure scenario**

Submit X. While awaiting completion, another still-open editor writes distinct Y. The result is `.importedCompleted`: neither was sent. The code restores Y, removes the dictionary entry, and leaves X only in an action record that the resolved card does not expose.

The new dispatched-result test correctly protects newer Y without restoring sent X. **The unsent-result case still does not satisfy the previous review’s requirement to preserve both submitted X and distinct newer Y.**

**Smallest fix:** Treat the submitted payload and subsequent editor revision separately. For `importedCompleted`, preserve X and distinct non-disposable Y; deduplicate when equal. For dispatched outcomes, preserve only Y. Use the batched placement above.

## P1 — R1-02 remains: unhosted drafts are inaccessible, and eventual rescue is not guaranteed

**Evidence**
- `AgentModeViewModel+RecoveryList.swift:884–887`: no host means dictionary retention only.
- `:903–907`: later rescue discovers drafts through their **current catalog item’s** session ID, plus the currently acted row.
- `:224–232`: a resolved row without Continue does not expose its dictionary draft.
- `AgentRecoveryCoordinator.swift:527–535`: the store contains only row ID → text, in memory.

**Failure scenario**

The originating session closes during the await. Its card resolves, and X remains invisible in the dictionary. Reopening through ordinary session navigation does not itself run this helper.

Furthermore, if the original item leaves the catalog, a later action on another row cannot associate X with its session. The special handling of the acted row does not help: that original row is no longer actionable.

**I do not agree this is P2 under the stated hard-fail.** Temporary invisibility could be explicitly accepted as a policy exception, but the implementation does not guarantee the claimed eventual recovery. In the missing-catalog-item case, retention can become indefinite.

**Smallest fix:** Retain session identity alongside orphaned text and expose a session-keyed pending-text surface independent of the original card. Session opening/readiness should trigger recovery without requiring another unrelated list action. Keep the text viewable/copyable while composer placement is blocked.

## Fix disposition

| Requested check | Result |
|---|---|
| **R1-01** | Dispatched/newer-edit path improved; unsent submitted X still lost from accessible surfaces when Y replaces it. |
| **R1-02** | Cross-window host lookup added; no-host fallback remains insufficient. |
| **N1: any resolution orphaning drafts** | Explicit same-session action paths improved, but missing catalog identity and the sweep races remain. |
| **N2: double append** | Single-event stored-result equality case fixed; multiple placements/events remain unsafe. |
| **N3: abnormal composer state** | Placement now correctly requires a live, `.ready` lane with no unsaved predecessors. Blocked-state behavior lacks regression coverage; retained text still needs an accessible fallback. |

### Other checks and lower-priority items

- **Release hook:** Declaration and invocation of `test_recoveryActionResult` remain inside `#if DEBUG`.
- **Wrong session:** Host selection checks session ID and coordinator identity; no concrete wrong-session transfer is established here.
- **Deferred duplicate surfaces:** The noted relaunch duplication after an unrecorded outcome is not, by itself, proof of duplicate dispatch.
- Missing multi-window and abnormal-composer tests remain verification gaps, not separate P1 findings.

## Recommendations

1. **Block approval on the four P1 paths above.**
2. Batch composer transfers and exclude other in-flight rows from sweeping.
3. Preserve submitted-unsent text separately from newer edits.
4. Give orphaned drafts session identity and an accessible fallback independent of catalog/card lifetime.
5. Add regressions for event coalescing, interleaved row actions, and unhosted recovery before accepting the final patch.