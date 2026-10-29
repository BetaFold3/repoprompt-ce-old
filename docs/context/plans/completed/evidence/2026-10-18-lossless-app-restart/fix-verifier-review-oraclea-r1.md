# Step 8-verifier-fixes re-review round 1: OracleA

Scope: read when the task touches Needs Attention session deletion (F8), View popover placement, or recovery accessibility identifiers (Step 8-verifier-fixes of the lossless app restart plan).
Authority: Reference
Last-verified: 2026-10-27
Covers: OracleA round-1 re-review of the delta

The delta addresses VF-01 by anchoring outside placements to the **whole recovery region** and explicitly falling back to the button when neither preferred nor opposite side fits. It also preserves surviving-process recovery items after session deletion, clears deleted sessions’ ownerless composer/retirement state, adds banner accessibility containment, and expands deletion regression coverage. **VF-01 is resolved under the agreed fallback behavior.** No new P0/P1 findings are evident in the supplied delta.

## P2 — Consider

### VF-02 — Fixed sleeps do not reliably drain notification delivery
**File:** `Tests/RepoPromptTests/AgentMode/Recovery/AgentRecoveryCoordinatorTests.swift:3621–3624`

- **Failure scenario:** On the shared, busy host, `drainMainActorPosts()` returns after 100 ms without establishing that all coalesced notification tasks have completed. The exact-count assertions can therefore observe incomplete delivery or notifications left over from setup.
- **Impact:** Otherwise-correct deletion behavior can produce intermittent test failures, weakening the notification regression evidence.
- **Smallest fix:** Await notification expectations for delivery and use an explicit publication-completion barrier where exact counts or setup drainage are required, rather than treating elapsed time as completion.

## Recommendations

- Accept the VF-01 remediation; no blocking changes identified.
- Address VF-02 without another review round.
- Complete the planned live checks for constrained-screen placement, one-click cross-row actions, and accessibility identifiers. Pure placement tests do not verify AppKit’s final geometry.
- Test results cited here are supplied evidence; this review did not execute tests.
