# OracleA planning clarification — read-only historical review recovery

Scope: read when the task touches remaining lossless-restart read-only historical review recovery.
Authority: Reference
Last-verified: 2026-10-23

Inherited OracleA preset identity was verified. Full continuation follows, with Markdown trailing hard breaks normalized to explicit line breaks. Original local export unchanged. Planning opinion, not source validation or owner Decision; see [main disposition](pre-live-work.md).

# Oracle Plan

## 1. Summary

**Yes—read-only historical recovery satisfies the quoted review-preservation contract.** The contract requires durable proposals, a pre-application commit, post-crash fingerprint revalidation, and no automatic reapplication; it does not require offering recovered approval. “Approving after restart cannot return a result” constrains such approval **if offered**, rather than requiring an Apply button. Cut recovered mutation, record that as a reversible `assumed:` scope decision, and proceed without an owner blocker. My earlier recovered-approval design exceeded this bounded goal.

This assessment uses only the supplied source trace. Gates remain OFF; no execution or additional inspection is implied.

## 2. Current-state analysis

The current flow is:

`ApplyEditsService.preview` → decoded `originalText` and proposed `updatedText` → approval store receives path/diff → live acceptance → existing host write.

Relevant boundaries:

- `PendingApplyEditsReview` holds presentation data, not the recoverable proposal.
- `ApplyEditsApprovalStore` owns transient continuation, timeout, scope generation, and publication.
- The provider retains the actual proposed text and performs the write.
- `FileContentSnapshot.swift` supplies existing safe-read/raw-fingerprint machinery, but that raw fingerprint is **not automatically the fingerprint of the decoded text used by preview**.
- The detached filesystem write does not provide atomic compare-and-write.

The missing preservation work is therefore **durable proposal ownership and commit ordering**, not a conditional-write subsystem. Removing recovered mutation also removes the need to recreate permissions or bridge historical cards into the live write path.

## 3. Design

### A. Persist the proposal, not merely the diff

Add a review collection to the **existing recovery record**, defaulting to empty when absent. Each entry owns:

| Field | Meaning |
|---|---|
| `reviewID` | Same stable UUID used by the live card |
| Owner | Existing durable session/attempt identity, captured before asynchronous persistence |
| Target | Existing workspace/root identity and resolved target reference; display path separately |
| `createdAt` | Original proposal time |
| `unifiedDiff` | Exact displayed proposal |
| `proposedText` | Exact `preview.result.updatedText` |
| `baseEvidence` | Explicit missing-file state, or fingerprint of preview’s original decoded text |
| `state` | `pending`, `applicationStarted`, `applied`, or `withdrawn` |

Use existing authoritative ownership. Do not make transient window/tab scope into durable ownership or invent an attempt for an independent caller.

**Keep the fingerprint domain explicit.** The smallest sufficient baseline is:

- existence from `preview.exists`;
- for existing files, SHA-256 over the UTF-8 representation of `preview.originalText`;
- a persisted domain/version identifying this as **decoded host text**, not original filesystem bytes.

Reuse an existing digest utility. No generic fingerprint framework is needed. Current-file comparison must use the same host decoding semantics. Encoding-only changes may consequently compare equal; do not label this raw-byte identity.

Do not attach a separately acquired raw snapshot fingerprint to the proposal as though it necessarily represented the preview base. Raw-byte binding would require additional validation and is unnecessary for this read-only scope.

### B. Commit before publication and before live mutation

#### Before display

1. Build the proposal from the preview and captured owner.
2. Await acknowledged recovery-store commit of `pending`.
3. Revalidate cancellation, scope generation, and review identity.
4. Only then install the live wait/publish the card.

A scheduled save is insufficient. Commit failure means **no card and no write**, with an explicit error through the existing tool-failure path.

Persistence introduces an asynchronous gap: use the existing scope generation plus a matching review ID to prevent an older commit from publishing over a newer review or a cleaned-up scope. A stale successful commit may remain historical; it must not restore a live continuation.

#### On live acceptance

1. Confirm that acceptance still belongs to the current review and owner.
2. Optionally perform the small existing-host base check described below.
3. Commit `applicationStarted` and await acknowledgement.
4. Recheck cancellation and ownership.
5. Perform the existing host write and existing freshness updates.
6. Commit `applied` after successful write completion.

A failed `applicationStarted` commit prevents the write. A write error or failed final commit leaves an uncertain application outcome; never report “nothing changed” merely because completion was not recorded.

If the file write succeeds but the final commit fails, return an explicit **write succeeded; recovery recording failed** outcome through existing error/reporting facilities. Do not misleadingly encourage retrying the edit.

**Live fingerprint check:** a small reread using the existing host semantics may reject a known changed base before step 3. It is not required to enable historical recovery and must not expand into filesystem serialization work. If included, document the remaining race across the subsequent persistence/write awaits. Neither this check nor `applicationStarted` protects against an uncooperative external writer.

### C. Preserve lifecycle interruptions; withdraw explicit cancellations

Keep durable proposal state separate from continuation lifetime:

- Lifecycle cleanup, transport expiry, and shutdown cancel the live wait **without withdrawing the proposal**.
- Explicit Reject/Discard records `withdrawn`.
- Timeout or automatic replacement must not silently erase the saved proposal. Retain it historically unless the action explicitly withdraws it.
- Late answers cannot mutate or resolve a replacement review.
- Failed withdrawal persistence must not claim durable dismissal; keep the item visible with a retryable error.

Reuse the existing preserve-versus-withdraw convention where available. Do not infer user intent from cancellation-reason strings.

### D. Historical recovery is strictly read-only

Restore cards with **View, Copy proposal, and Discard only**:

- View shows target, saved diff, and exact proposed text.
- Copy copies the saved proposed text; it does not enqueue or send it.
- Discard commits withdrawal; it never changes the target file.
- No Apply, continuation, old permission scope, or tool-result delivery is restored.

Display:

> This is a saved proposal from an ended agent request. Nothing will be applied automatically. The original agent cannot receive a result.

On historical-card hydration, perform a read-only target check using existing authorized workspace resolution and safe-read facilities. Revalidate whenever the card is reopened; do not add a watcher or polling service.

Report separately:

- current content matches the saved base;
- current content matches the proposal;
- current content differs from both;
- target is missing;
- comparison unavailable, including inaccessible or unsafe targets.

For an originally missing file, “still absent” is the base match. For comparisons involving proposed text, use the same decoded-text domain.

**These are observations, not execution evidence.** “Matches proposal” does not prove this review applied it. A recovered `applicationStarted` record remains “application outcome uncertain”; a read cannot upgrade it to `applied`.

Keep comparisons transient. Tag asynchronous results with review/target identity so stale reads cannot update another card. Unavailable files must not prevent viewing or copying the saved proposal.

## 4. File-by-file impact

Only paths supplied in this conversation are definitive; locate the omitted integration files during implementation rather than inventing replacements.

| File/component | Essential change |
|---|---|
| `Sources/RepoPromptAgentCore/AgentMode/Runtime/Session/PendingApplyEditsReview.swift` | Retain the stable review ID linking live presentation to its durable proposal. Keep transient scope separate. |
| `Sources/RepoPrompt/Infrastructure/MCP/ApplyEdits/ApplyEditsApprovalStore.swift` | Extend `requestReview(scope:path:unifiedDiff:timeoutSeconds:)` with durable proposal/owner context; commit before publication; fence asynchronous publication; distinguish preservation from withdrawal. Update all callers. |
| `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPApplyEditsToolProvider.swift` | Construct proposal/base evidence from preview; commit `applicationStarted` before the existing write; record completion and propagate partial-success failures honestly. |
| Existing recovery model/store—path not supplied | Add proposal entries, empty decode defaults, and acknowledged state transitions. No parallel store. |
| Existing historical recovery-card implementation—path not supplied | Add read-only actions, warning, and current-file comparison states. |
| `ApplyEditsService` / `FileContentSnapshot.swift` | Reuse existing preview/read capabilities. No required conditional-write or raw-fingerprint API expansion. |
| Existing targeted tests | Add ordering, cancellation, lifecycle, persistence-failure, and historical-read tests. |
| Existing plan/evidence files | Record the reversible cut and fixture evidence; do not claim recovered application or live acceptance. |

## 5. Risks and migration

- Old records decode with no saved reviews; do not reconstruct exact proposals from historical diffs.
- Follow existing unknown-field preservation. If older binaries discard the new entries on rewrite, document that rollback does not preserve pending reviews.
- Existing live check-through-write races remain outside this step. Historical read-only recovery introduces no new file-write race.
- Unresolved `applicationStarted` records must retain their payload even when current contents match the proposal.

## 6. Implementation order

1. **Record the scope cut:** historical View/Copy/Discard only; recovered Apply deferred, not required for bounded completion.
2. **Add additive proposal persistence and round-trip tests.**
3. **Land commit-before-display, commit-before-write, and lifecycle preservation together.** Verify no publication/write on failed prerequisite commits and no stale publication after reset/replacement.
4. **Add read-only cards and fingerprint comparisons.** Test matching base/proposal, changed/missing/unreadable targets, stale reads, and uncertain application outcomes.
5. **Validate crash boundaries with fixtures:** before display, before write, after write but before completion commit; assert historical recovery never invokes write or restores a continuation.
6. **Use A/B review for this bounded delta under the existing policy.**

**Disposition:** proceed with the cut. No quoted requirement is violated, no owner answer is necessary, and no recovered-write framework is justified. Completion means durable review preservation and honest read-only recovery—not recovered approval, atomic live writes, or live qualification.
