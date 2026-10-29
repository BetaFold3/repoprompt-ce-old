# Step 5b initial review — OracleA

Scope: read when the task touches the durable delegated-child link review and its required repairs.
Authority: Reference
Last-verified: 2026-10-23

Main verified the exact requested preset UUID/name. Initial snapshot 2026-10-23/1253-2, 19 source/test files (+1248/-50). Full response follows, Markdown hard-break whitespace normalized; original local export unchanged. [Disposition](phase5b-child-links.md).

# Oracle Review

The changes add dispatcher-derived MCP invocation identity, persist delegated-child links under the admitted parent attempt after a covering child save, and expose those links in recovery without replaying work. The implementation largely reuses existing persistence and ownership mechanisms and respects the explicitly local identity contract. Two boundary issues should be addressed before final live verification. This review is static; the reported validation was not independently rerun.

## P1 — Should fix

### F1 — Child ownership is not fenced through link persistence and dispatch
**Evidence:** `AgentModeViewModel+DelegatedChildLinks.swift:165–202, 213–220`; `AgentModeViewModel.swift:9866–9869`.

After the covering save, `childIsCurrent` checks only the object, session UUID, and parent UUID. It does not retain the child’s persistence binding or reset generation. The dispatch fence subsequently checks only the **parent**.

For an explicitly targeted existing child, clearing its conversation while the parent-link transaction is suspended can preserve all three checked values. The link then succeeds, and normal submission can capture the child’s *new* binding and send the original request into the cleared conversation rather than reject the stale start.

**Smallest fix:** Capture the child’s binding and binding-transition generation after the covering save, retain its owner identity, and revalidate these after link persistence and in the final submission predicate. Add a test that resets the child during the link await and verifies no dispatch.

### F2 — Cancellation is absent from the new admission and dispatch fences
**Evidence:** `AgentModeViewModel+DelegatedChildLinks.swift:134–148, 155–220`; `AgentRunMCPToolService.swift:1562–1643`.

If the MCP request is cancelled while saving or linking the child, but the parent remains current, the new checks still pass. Successful persistence awaits do not automatically throw on cancellation, and the service proceeds to `startRun` without a cancellation check. The final fence likewise considers a cancelled task eligible.

This leaves the explicit “cancel before handoff sends nothing” requirement dependent on downstream behavior rather than enforcing it at the new boundary.

**Smallest fix:** Check cancellation after the persistence awaits and immediately before entering `startRun`; make the final pre-submission predicate reject pre-handoff cancellation. Preserve the existing bounded-ack semantics for operations already handed off. Add a cancellation-at-await test using the real starter with a recording dispatch closure.

## P2 — Consider

### F3 — Repeated links to one existing child produce duplicate SwiftUI identities
**Evidence:** `AgentModeViewModel+RecoveryList.swift:404–413`; `AgentRecoveryListBanner.swift:138`.

Two separate invocations under the same parent attempt can target the same existing child. Both links are valid durable evidence, but presentation appends two identical `.openDelegatedSession(childID)` actions. `ForEach(row.actions, id: \.self)` then receives duplicate identities.

**Smallest fix:** Preserve every durable link, but deduplicate presentation actions by child session UUID. Test two invocation IDs linking the same child.

### F4 — Delegated-child status can be truncated without any way to inspect it
**Evidence:** `AgentModeViewModel+RecoveryList.swift:213–233, 404–435`; `AgentRecoveryListBanner.swift:121–138`.

Child status is appended to the existing run description, while the row limits that description to two lines. These run rows supply neither text nor attachments, so they receive no “View” button. Missing-child warnings and the “never restarted automatically” explanation can therefore be inaccessible; multiple long child buttons also crowd the fixed-height row.

**Smallest fix:** Offer an inspectable delegated-session popover or disclosure with the full status and child links, keeping the main row bounded. This also provides a suitable place to consolidate duplicate child actions.
