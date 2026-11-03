# Phase 2 OracleA first re-review

Scope: read when the task touches Phase 2 first re-review findings for lossless app restart.
Authority: Reference
Last-verified: 2026-10-21

Frozen snapshot: `0cabecc5cb118849e687f097782d226109d6eb3f`. Preset identity verified before synthesis. Raw reviewer response follows unchanged; any self-label in its prose is not preset identity.

# Oracle Review

R1 adds preservation-gated answers, ownership-fenced native questions, ordinary-outcome restoration, provider-loss attribution, and broader recovery discovery while retaining the existing architecture. Most original findings are addressed, but question hand-over can bypass preservation, and ordinary-outcome warnings are not durable across another restart. This review uses only the supplied source and diff; validation results are reported evidence, not independently rerun or live acceptance.

## P0 — Must fix

### F01-R1 — Hand-over treats unsaved answers as committed
**Evidence:** `AgentRecoveryCoordinator.swift:1084–1116`; `AgentRecoveryQuestionPersistenceController.swift:135–140,235–244`; `AgentModeViewModel+RecoveryQuestions.swift:86–89`.

- **Scenario:** A live question has a pending answer when its lane is replaced under the same owner and binding. `liveSnapshots` includes pending snapshots, but `adoptLiveInteractions` installs them directly into the successor’s `committedSnapshots`. If the predecessor’s retirement flush fails, the successor nevertheless considers that answer durable. Resubmitting the same answer produces no draft mutation; `needsPreservation` returns false and the caller replies immediately.
- **Impact:** The answer can be sent and its snapshot subsequently removed without ever being preserved—the data-loss boundary F01 required fixing.
- **Smallest fix:** Adopt unverified snapshots as pending, and persist them after predecessor retirement before permitting a reply. Do not infer successful persistence from `liveSnapshots`. Add a hand-over test with an unsaved answer and failed retirement flush; the current test hands over an already-committed answer.

**Disposition:** F01’s direct failure/timeout path is fixed, but **F01 cannot close** until this bypass is removed.

## P1 — Should fix

### F03-R1 — Missing-transcript-tail warnings disappear after another restart
**Evidence:** `AgentSessionDataService.swift:3494–3514,3718–3735`; `AgentSessionRestoreSupport.swift:552–590`; `AgentRecoveryStartupReconciliation.swift:174–190`.

- **Scenario:** Terminal evidence commits, but the app crashes before saving the transcript tail. The next launch correctly closes the saved-open turn with its ordinary outcome and lists an `outcomeTurn`. However, that classification exists only in `coldRestoreOrdinaryOutcomeTurnIDs`, an in-memory map. After another restart, the persisted turn is already closed, has no interruption, and represents its run attempt; nothing recreates the warning.
- **Impact:** The user can lose the “transcript tail may be missing” notice without viewing or dismissing it. The incomplete conversation then looks like an ordinary completed transcript.
- **Smallest fix:** Persist the tail-missing recovery obligation, keyed by attempt/turn, without manufacturing an interruption. Keep it discoverable until acknowledged or reconciled. Extend the save/reload test to check the catalog in a second fresh service instance.

**Disposition:** F03’s incorrect interruption stamp is fixed, but **F03 cannot close** with the replacement warning being launch-local.

## P2 — Consider

### F05-R1 — Newly created, subsequently closed sessions lack Open routing
**Evidence:** `AgentRecoveryCatalog.swift:613–652`; `AgentModeViewModel+RecoveryList.swift:138,257–269,1061–1070`.

- **Scenario:** A session created this launch saves a draft and releases its lane. The catalog now lists the draft, but the unlisted-session projection passes `tabID: nil`. With no startup resolution supplying a tab, `openAction` is empty and the routing method cannot open it.
- **Impact:** The row instructs the user to open the session but provides no Open action. Sidebar navigation remains a workaround.
- **Smallest fix:** Retain the compose-tab identity alongside the latest workspace identity and supply both to these catalog rows.

**Disposition:** F05’s discovery failure is fixed; this remaining navigation defect is **P2**, not an outstanding P1.

### F08 — Legacy index entries retain the hydration-freshness defect
**Evidence:** `AgentSessionMetadataIndex.swift:59–63`; `AgentRecoveryCoordinator.swift:627–635`; `AgentRecoveryCatalog.swift:209–213`.

- **Scenario:** An existing index entry decodes with `attemptID == nil`; hydration later supplies its existing attempt UUID.
- **Impact:** An unchanged dismissed confirmation can reappear.
- **Smallest fix:** Require Open before dismissing an index-backed card whose occurrence identity is unavailable, or retain compatible acknowledgement semantics through hydration.

**Disposition:** Fixed for newly written summaries; the disclosed legacy-entry residual remains **deferred P2**.

## Original finding disposition

| Finding | R1 disposition |
|---|---|
| F01 | **Open P0** — hand-over preservation bypass above |
| F02 | Closed — persistence result and captured ownership now gate publication |
| F03 | **Open P1** — ordinary outcomes corrected, but warning durability regresses |
| F04 | Closed — current committed interruptions are projected |
| F05 | Required discovery fix closed; navigation residual P2 |
| F06 | Closed on supplied source — typed process-loss causes reach finalizers |
| F07 | Closed — acknowledgement eviction removed |
| F08 | New summaries fixed; legacy residual P2 deferred |
| F09 | Closed — unsupported historical claims removed |
| F10 | Closed — elsewhere count participates in banner visibility |

## Recommendations

- **Do not approve R1 yet:** resolve F01-R1 and F03-R1, then use the remaining R2 review.
- Add focused failed-hand-over and successive-restart regressions; rerun affected validation.
- Fix the P2 residuals if cheap; otherwise record their deferral without another round solely for them.
- Keep O3 live acceptance pending. Reported fixture/stub passes do not establish real-app crash or provider acceptance.
