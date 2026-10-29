# Step 8-popover re-review — OracleA (round 1)

Scope: read when the task touches the recovery banner View popover (Step 8-popover).
Authority: Reference
Last-verified: 2026-10-26
Covers: OracleA (preset 61D024A4-CCFB-4C9C-A614-CC65E0A1864C) fresh-chat re-review of the round-1 fixes (popover-delta and popover-r1 diffs).

The delta gives the hosted viewer ownership of its comparison state and task, defers teardown-related binding writes, and broadens outside-click activation to eligible app windows. B F1 is addressed structurally; A R1’s anchor-only restriction is removed. B F2’s stale-binding case is addressed, but its deferred reset introduces a small lifecycle race. No P0/P1 findings identified. Validation results are worker-reported; live behavior remains unverified.

## P2 — Consider

### R1 — Deferred reset can clear a newer presentation

**File:** `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRecoveryNativePopover.swift:148–155`

**Failure scenario:** AppKit closes the popover, or SwiftUI dismantles its anchor, scheduling a binding reset. If the same row’s presentation is reopened before that queued block executes, the old block sees `true` and writes `false`, dismissing the new presentation. Checking the Boolean does not distinguish the old presentation from the new one.

**Impact:** A newer popover can unexpectedly disappear. This is a timing-dependent edge case, not a demonstrated live failure.

**Smallest fix:** Associate deferred resets with a presentation generation and ignore resets superseded by a new presentation. Account for anchor replacement as well as reuse of the same coordinator; a coordinator-local token alone cannot protect against an old coordinator resetting a replacement’s binding.

## Recommendations

- Verify comparison completion, fresh inspection on reopening, and cancellation on close. The extracted viewer removes the previous cross-host state dependency; no new stale-action capture issue is apparent.
- Exercise close/reopen and anchor removal/recreation before a queued reset runs.
- Live-check outside-click activation in another ordinary window and the Needs Attention sheet, including any relevant panels. `canBecomeKey` establishes eligibility, not correct focus behavior in every window configuration.
- Check Escape immediately after opening, without clicking inside first.
- Keep decision-table test results separate from live AppKit verification. No additional review round is warranted solely for this P2 finding.