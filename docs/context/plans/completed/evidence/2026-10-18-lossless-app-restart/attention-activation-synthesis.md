# Step 8-attention / 9-activation — synthesis of the OracleA and OracleD plans

Scope: read when the task touches Needs Attention UX (O34), Check and resolve, recovery-action activation (O32), or the verifier live scenarios.
Authority: Reference
Last-verified: 2026-10-26
Covers: how the main agent combined attention-activation-plan-oraclea.md, attention-activation-plan-oraclea-part2.md and attention-activation-plan-oracled.md into the step order used for Steps 8-attention and 9-activation, with the reason for each choice.

## Checked in code before deciding

- An interrupted-run card does not itself pause anything. Scheduled sends are held by the crash hold (`AgentModeViewModel+ScheduledSend.swift:2709` maps "interrupted" sessions to `crashHeldSessionIDs`), startup restrictions, surviving processes, held transfers and recovery actions in progress (`scheduledSendHasUnresolvedRecovery`, same file 1538-1586). So run notes can be informational while the crash hold stays its own needs-action item. This settles the one place the two plans disagreed on blocking semantics (OracleA's inference in its section 2).

## Classification (O34-3)

Use OracleD's exhaustive per-payload table with these changes from OracleA (more conservative where the owner's own list says "saved messages"):
- `closedSessionDraft` is needs-action (typed text the owner has not sent).
- `scheduleIndexUnavailable` is needs-action (absence of indexed schedules is not proof there are none).
- Run cards (`turn`, `outcomeTurn`, `recoveryOnlyRun`) are informational, except when the card has an unfinished recovery action ("Resume was interrupted; status unknown"), which is needs-action.
- The switch must be exhaustive so a new payload cannot compile unclassified.

## Banner (O34-1)

Both plans agree: in the ready state the composer banner shows only the current session's needs-action rows, its tab's preparation failure, applicable workspace/runtime restrictions and the existing dismissed-crash-hold "Sending paused" indicator; otherwise it is hidden. Loading and failure notices stay. The "Nothing interrupted in this session. N items elsewhere…" text goes. The sidebar badge and View-menu count count needs-action items only.

## Sheet and bulk actions (O34-2)

- Sections: Needs action, then Information (collapsed), then dismissed/cleared behind the toggle "Show dismissed and cleared"; grouped by workspace, app-wide items in their own group.
- Bulk Dismiss: per section and per workspace group, sequential, each item revalidated against the captured item (not re-fetched by row ID), ineligible/changed/busy items reported as skipped, failures stay on their rows, explicit cancel stops before the next item. Confirmation text for needs-action items states that Dismiss only hides cards and never sends, discards, stops or unpauses.
- Bulk "It stopped" is not built as a separate button. Its safe form (confirm a crash hold only when the process registry proves the old processes exited) lives inside Check and resolve after activation; without that proof "It stopped" stays a per-session assertion. Reason: before activation nothing can prove "safe", and OracleA showed a bulk user assertion over many sessions is exactly the unproven case.

## Automatic clearing

Cut age-based expiry (OracleA) for now: with informational items collapsed and not counted, age expiry only tidies a hidden list and would need a "seen" marker to avoid hiding unread results. Keep projection-only clearing (no writes) when the card's run was resolved by a recovery action, or the conversation was cleared, or a later run attempt exists in the same conversation generation (OracleD rules 1, 3, 4), never while an unfinished recovery action exists. Easy to add age expiry later as one more rule.

## Check and resolve

Observational by default (both plans). It refreshes process ownership, runs history reconciliation (`.reconcileOnly`) where the provider supports it, re-reads the catalog and reports per item: resolved, needs you (with the named choice), could not check, failed. The only automatic writes are history imports and, after activation, crash-hold confirmation when the registry proves every relevant process exited. Never sends, stops, discards, dismisses needs-action items, confirms schedules or opens sessions. Bounded to captured catalog items (never a workspace crawl). Before activation it reports "Process and provider-history checks are not active." The confirmation text must say that clearing a restriction may let already-authorized scheduled sends run (OracleA blind spot).

## Activation (O32)

`production` qualification: `sameConversationResume` and `historyReconciliation` on; `freshClaudeConversation` and `safeRestart` stay off (not part of this activation; each needs its own acceptance). Process registration (Phase 3) turns on in the same commit through one composition used by launch, the action runner and row presentation. A code comment at `AgentRecoveryActionQualification.production` records O32: actions are available for every provider; Claude Code and Codex are the live-qualified ones; a new provider must establish registration, ownership, history association, dispatch identity and settlement before its recovery actions can execute. Unqualified providers refuse when ownership or identity cannot be proven, and missing history support returns an explicit refusal rather than "nothing imported". Stop is wired only if a reviewed registry stop entry point exists; otherwise it stays a separate blocked sub-step.

## Step order

1. 8-attention-1: classification, banner rule, needs-action counts, sheet sections and toggle.
2. 8-attention-2: bulk Dismiss and projection-only automatic clearing.
3. 9-check: Check and resolve (observational; pre-activation report).
4. 9-activation: qualification flags, registration composition, O32 comment, unsupported-provider refusal audit; Stop as 9-stop only if its entry point exists.
5. 9-live: the verifier runs `verifier-scenarios.md`; fixes follow; status stays partial until it passes.

## Deferred / not in scope

- Leaked unit-test fixture workspaces in Application Support (about 50,000): a separate maintenance task (fix test isolation, then a dry-run list the owner approves); not a prerequisite because Check is bounded to catalog items.
- Age-based expiry, bulk Stop, automatic supersession of an unfinished action, fresh-Claude conversation, safe restart.
