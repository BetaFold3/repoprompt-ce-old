# Step 5c initial review — OracleA

Scope: read when the task touches Step5c merge-review preservation findings and disposition.
Authority: Reference
Last-verified: 2026-10-23

Returned identity verified: OracleA (61D024A4-CCFB-4C9C-A614-CC65E0A1864C), explicit selection. Chat step5c-initial-a-29C1EC; operation AE382E76-0FB9-4E70-8D42-AE238A525EFB; status completed/ok. Same source snapshot2026-10-23/1620, tree e86152af1da0579a94fcd6a7cbb091782d24fa82. Full response follows. Markdown hard breaks normalized to explicit line breaks and trailing spaces removed; original export unchanged at /Users/tnguyen/workspace/repoprompt-ce-personal-touch/prompt-exports/oracle-review-2026-10-23-162758-step5c-initial-a-29c-2b54.md.

# Oracle Review

The changes retain merge-preview bundles under captured session storage, require written saves before review publication and initial Git apply, and restore unanswered reviews as read-only history with View/Copy/Discard actions. The implementation and fixtures cover the main paths well, but decision-resolution races and withdrawal rollback durability leave gaps in the preservation contract. **P1 findings below block this bounded source checkpoint.** This assessment is source-only; the supplied validation results were not independently rerun.

## P1 — Should fix

### S5C-01 — A shown review can be mistaken for an unshown reservation
**File:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+WorktreeMerge.swift:807–814`

- **Scenario:** A timeout calls `submitWorktreeMergeReviewDecision`, which clears the pending review before resuming its continuation (`640–647`). Before the waiting request resumes and marks the operation historical, a run-end or replacement calls `cancelPendingWorktreeMergeReview`.
- **Impact:** `shownOperationID` is now `nil`, so lifecycle handling marks the previously shown operation `.cancelled` and removes its preservation marker. The resumed timeout handler cannot repair it because its exact-operation check fails. The saved proposal disappears from historical View/Copy/Discard despite receiving no reviewer decision.
- **Smallest fix:** Preserve shown/resolving identity until decision processing finishes, rather than deriving “was shown” solely from `pendingWorktreeMergeReview`. For timeout, an alternative is to transition to history synchronously before clearing/resuming the continuation.
- **Regression test:** Submit `.timeout`, immediately invoke lifecycle cancellation or replacement in the same MainActor turn, then await the request and verify historical state survives.

### S5C-02 — A failed withdrawal acknowledgement can leave a durable cancellation
**File:** `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+WorktreeMerge.swift:1044–1054`

- **Scenario:** Reject/Discard writes `.cancelled`, but a binding transition or reset makes the captured owner invalid before acknowledgement. The function returns failure and restores history only in memory through a scheduled save.
- **Impact:** An immediate app kill before that scheduled save leaves `.cancelled` on disk. Relaunch therefore removes the historical review even though the caller was told withdrawal failed and the review was kept. The current race tests inspect the restored in-memory state, not immediate cold recovery from this written-but-unacknowledged withdrawal.
- **Smallest fix:** Revalidate ownership before starting the withdrawal write, and distinguish a definitely unwritten failure from a withdrawal that reached disk. For the latter, require a covering compensating restore under valid authority before claiming history is kept; never overwrite a replacement operation.
- **Regression test:** Change ownership during a real withdrawal save, then reload the session immediately after failure—without an additional flush—and assert recoverable history.

## P2 — Consider

### S5C-03 — Discard failure feedback belongs to a card that has already disappeared
**Files:**<br>
`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+WorktreeMerge.swift:1040`<br>
`Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift:2847–2869`

- **Scenario:** Discard immediately changes the operation to `.cancelled` and publishes the updated snapshot. During an asynchronous save, SwiftUI removes the historical card. If saving fails, rollback recreates the card, while `onDiscard()` returns its error to the original card’s `@State`.
- **Impact:** The review reappears without the promised “Discard wasn’t saved” explanation. View-model return-value assertions do not verify this presentation behavior.
- **Smallest fix:** Keep the card mounted in a discarding state until acknowledgement, or store withdrawal progress/error in session-owned presentation state that survives card removal and recreation. Test with a suspended save that subsequently fails.
