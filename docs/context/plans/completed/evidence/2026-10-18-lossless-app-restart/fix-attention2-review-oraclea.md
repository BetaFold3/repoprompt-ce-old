# Step 8-attention-2 review, round 0 — OracleA

Scope: read when the task touches the Step 8-attention-2 review of automatic clearing and bulk Dismiss.
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA round-0 review of prompt-exports/restart-fixes/att2-r0.diff.

The changes add projection-only clearing of informational run cards and app-wide, sequential bulk Dismiss with confirmation, progress, cancellation, and per-row failures. The supplied tests cover important safety properties, including preservation of crash holds and saved input. **No P0/P1 findings established from the supplied code.** Validation results are worker-reported; the UI has not been verified live.

## P2 — Consider

### ATT2-01 — A confirmed batch can dismiss more cards than its confirmation count
**Files:** `AgentRecoveryNeedsAttentionSheet.swift:63–64,115–125`; `AgentModeViewModel+RecoveryBulk.swift:26–31`; `AgentRecoveryCoordinator+BulkDismiss.swift:138–148`

The confirmation count excludes currently busy rows, but the captured batch includes them. Eligibility is checked again only when each row is processed.

**Scenario:** Two needs-action cards are captured, one busy with an individual Dismiss. The dialog confirms **1 card**. While the bulk operation awaits the first card’s write, the other card’s individual Dismiss fails. Its acknowledgement and attention classification remain unchanged, and it is no longer busy, so the bulk operation dismisses it too.

**Impact:** The operation exceeds the confirmed eligible count and automatically retries a card the confirmation excluded.

**Smallest fix:** Freeze eligible IDs alongside the captured rows and confirmation count. Keep initially busy rows as `.busy` skips rather than promoting them into the batch. Add a deterministic test using a blocked write and a failing individual Dismiss.

### ATT2-02 — Workspace-scoped bulk Dismiss remains unimplemented
**File:** `AgentRecoveryNeedsAttentionSheet.swift:28–29,58–106`

The supplied design requires bulk actions per section **and per workspace group**, but both new buttons operate across the entire section.

**Scenario:** The owner wants to dismiss informational cards for one workspace while retaining another workspace’s cards. Only individual dismissal provides that scope.

**Impact:** This part of the agreed workflow is missing, although it is recoverable through per-row actions.

**Smallest fix:** Add workspace grouping with group-scoped bulk buttons, or explicitly obtain acceptance to defer it; the worker report alone does not establish that design change.

## Safety assessment

- **Automatic clearing:** The informational-only guard correctly protects unfinished actions and unsent continuations. Rule precedence and missing-attempt handling match the stated contract. A later failed or interrupted attempt still qualifies under “a later attempt exists”; success is not required. Separate needs-action items remain visible.
- **Ordering and generations:** The generation calculation follows the existing held-input calculation. Array ordering is documented and worker-reported, but the store producer/codec implementations are not supplied for independent confirmation.
- **Stale dismissal:** The bulk precheck rejects changed acknowledgement keys, freshness, and attention classes, and passes the captured item onward. The existing `dismissCatalogItem` implementation is absent, so atomic revalidation across its suspension points cannot be independently confirmed here.
- **Concurrency and refresh:** The running flag is set before the first suspension; explicit cancellation is checked before each subsequent item. The sheet listens for the notifications used to publish bulk status. Closing it does not cancel the unstructured task.
- **Toggle behavior:** Dismissing cleared, undismissed notes while the toggle is on is consistent with acting on the displayed set. It adds durable acknowledgement but does not itself send, discard, or release a hold.

The **post-startup fixture oddity could indicate a production issue**: creating sessions after startup is normal usage. The supplied evidence does not identify the extra item’s payload or origin, so calling it a fixture artifact is premature—not a confirmed defect, either.

## Recommendations

1. Fix the confirmation-count mismatch and resolve the workspace-grouping scope.
2. Identify the extra needs-action item and reproduce session creation with production-equivalent workspace/index setup.
3. Run a live confirmation/Stop/multi-window check, and add a gate-blocked freshness-change test to verify the existing dismissal path rejects changes occurring after the bulk precheck.