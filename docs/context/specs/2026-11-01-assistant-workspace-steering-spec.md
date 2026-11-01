# Cross-workspace steering for an Assistant workspace — spec

Scope: read when the task touches workspace-to-workspace steering grants, the `workspace_steer` MCP tool, or an Assistant workspace that oversees and steers sessions in other workspaces.
Authority: Reference
Last-verified: 2026-11-01

## Status and goal
Implementation in progress: Steps 1–3 are implemented; grant requests and live acceptance remain pending. Steps follow the [review policy](../review-policy.md).

An owner-designated "Assistant" workspace runs Agent Mode sessions that periodically read other workspaces' saved transcripts (existing `history` tool), check a long-horizon plan, tell the owner about deviations, and sometimes send a steer or follow-up into a session of another workspace. This spec adds the missing parts: an owner-approved, persistent, one-way workspace→workspace grant, and a tool to list and message sessions in granted workspaces.

**Non-goals:** app-managed scheduling or live monitoring (the Assistant uses its own timer); filtering `history` reads; Stop, answering questions/approvals, or slash commands on targets; steering MCP-controlled workers, Knowledge targets or remote-host sessions; opening or switching workspaces; other Macs.

Evidence directory (local, not committed): `.agent-artifacts/specs/2026-11-01-assistant-workspace-oversight/` (scouting facts with file:line, Oracle lane positions).

## Design
**Grant.** `WorkspaceSteeringGrant { sourceWorkspaceID: UUID, targetWorkspaceID: UUID, createdAt: Date }`, stored as an optional array (default empty) in the global settings document and written through the existing save-with-rollback pattern (`updateTelegramScalarAndSave`). Pairs are unique and directed; a self-grant is rejected; there is no chaining and no reciprocity, because lookup is one exact pair. A grant covers every current and future session on both sides. Workspace UUIDs survive renames. Dev and release builds share the file, and therefore the grants. A grant naming a deleted workspace stays inert and can be removed in Settings.

**Caller.** The source workspace is `RequestMetadata.actorRoutedRunTab.workspaceID` (actor-owned run policy, `MCPConnectionManager.swift:4096-4128`), and the window `actorRoutedRunTab.windowID` must still show that workspace. Tool arguments, `_windowID`, `context_id`, selected tabs and client names never establish the source. Calls with no run route (external MCP clients, gateway devices) are refused. Every local Agent Mode session counts, including workers, explore sessions, delegation leaves and Knowledge sessions.

**Tool `workspace_steer`.** It is a separate tool, not `agent_run` ops, because `agent_run` is hidden and denied for delegation leaves ([delegation depth](../agent-mcp-delegation-depth.md)). It is advertised to every local Agent Mode run and added to `KnowledgeSessionPolicy.allowedMCPToolNames`. Existing `agent_run` restrictions stay unchanged.

| op | arguments | result |
|---|---|---|
| `list` | `target_workspace_id?` | `{workspaces:[{workspace_id, name, is_open, sessions:[{session_id, name, run_state}], warnings:[]}]}` for granted targets only; an ungranted explicit target is an error |
| `send` | `target_workspace_id, session_id, message` | `{workspace_id, session_id, delivery}` using the existing `MCPInstructionDispatch` encoding |
| `request_grant` | `target_workspace_id` | `{status: granted \| already_granted \| denied}`; works without an existing grant |

**Target resolution (`list` and `send`).** Enumerate `WindowStatesManager.shared.allWindows` whose active workspace is the target. If none: `"Workspace '<name>' is not open on this Mac. Open it, then retry. Nothing was sent."` Within each matching window, the session must resolve with `remoteAttentionRootSession(sessionID:)`, which covers a top-level session the owner started, with no MCP control, a local host and a unique binding. Exactly one match across windows is required; zero or ambiguous matches are refused (`list` omits ambiguous IDs with a warning). `send` also applies `remoteRootDispatchRefusal`, which refuses unloaded sessions and `/compact`- or `/goal`-style commands checked on the original text, and inherits the existing refusal when the target waits on a question or approval (`AgentModeViewModel.swift:9878-9884`). The window, its view model and the session object are pinned for the rest of the request.

**Delivery.** Add `SessionInstructionTarget.workspaceGrant(sourceWorkspaceID:)` and dispatch through `dispatchSessionInstruction` on the pinned view model, as the paired-phone path does. Running targets are steered, and idle targets get a follow-up that starts a new turn. The final synchronous predicate (ordinary admission and the Codex bounded-acknowledgement path) requires the grant to still exist for the pinned window's current workspace and the same session object to still resolve there; a revocation or target replacement mid-send therefore sends nothing. It never falls through to `ensureSteerControlContext`, installs no MCP control and changes no lineage, so the target keeps its approvals and its Telegram attention alerts. A message admitted before a revocation or before the Assistant is stopped is delivered and reported truthfully.

**Attribution.** The app prefixes the submitted text with `[Steer from workspace "<source name>" (<source workspace UUID>), session <source session UUID>]`, followed by a blank line and the message. This lets the owner and the target agent tell it apart from the owner's typing, and the Assistant can find its own steers through `history`. No new transcript fields are added.

**Retry rule (tool description).** After an error or timeout whose outcome is unclear, read the target transcript for the attributed message. If delivery is still uncertain, report that to the owner and do not resend: saved history can lag up to about 10 s, and absence does not prove non-delivery. Refusals that happen before admission can be retried once their cause is fixed.

**Grant request.** `request_grant` queues an approval on the caller's window, reusing the `WorkspaceApprovalManager` overlay (queueing, foregrounding, cancellation→denied) through a new operation kind that skips `shouldAutoApprove`, hides and ignores Always Allow, and creates no client policy. The app writes all the wording from workspace names and IDs, and the request carries no agent text: "Allow every session in '<source>' to list and steer top-level sessions in '<target>' until you revoke it?" After Allow, the app revalidates the caller and the target workspace, then persists the grant through the grant store. Deny, cancellation or a watchdog timeout write nothing.

**Revocation.** Removing a grant in Settings blocks the next `list`/`send` and any send not yet admitted. Delivered messages and running turns are unaffected.

## Steps
### Step 1 — Grant storage and Settings
- Change: grant type, global-settings field, store with add/remove/`isGranted(source:target:)`, and a Settings section that lists grants (source → target, or "unknown workspace") with Remove and Add (two workspace pickers, reusing the `ManageWorkspacesView` list model).
- Validation: `make dev-test FILTER=WorkspaceSteeringGrantStoreTests`. The suite covers decoding old settings to empty, rejecting duplicate and self grants, a failed save leaving prior grants in effect, Remove ending `isGranted`, and a grant surviving a workspace rename. Plus `make dev-lint`.
- Done when: grants change only on a successful save, and the Settings section lists, adds and removes grants (checked in Step 5).

Step 1 — done | rounds 1/2 | open: none | downgraded: none | assumed: Settings placement and schema protection (step1-stop.md) | deferred: unrelated formatting/context diagnostics, nonblocking review items, live UI acceptance (step1-stop.md)

### Step 2 — `workspace_steer` tool, caller derivation and `list`
- Change: tool name, schema and provider registration, Agent Mode advertisement (including leaves and Knowledge), caller derivation, cross-window resolver, and `list`.
- Validation: `make dev-test FILTER=WorkspaceSteeringToolTests`. The suite covers advertisement in depth-2, explore and Knowledge-worker leases; refusal without a run route and for gateway callers; `_windowID` and `context_id` not changing the source; an ungranted target refused; a closed target giving `is_open: false` with the open-it message; distinct sessions in two windows listed; duplicate bindings omitted with a warning; MCP-controlled, remote-host and Knowledge targets omitted.
- Done when: `list` shows exactly the eligible sessions of open granted workspaces.

Step 2 — done | rounds 1/2 | open: none | downgraded: none | assumed: shared run-route population; missing identity refused (step2-dispositions.md) | deferred: full dispatcher and live per-provider coverage; nonblocking review items (step2-dispositions.md)

### Step 3 — `send`
- Change: entry checks, pinning, the `workspaceGrant` target case and final predicate, attribution prefix, retry rule in the tool description.
- Validation: `make dev-test FILTER=WorkspaceSteeringSendTests`. The suite covers:
  - a running target steered and an idle target given a new turn;
  - revocation, or target replacement, between entry and the final predicate sending nothing, on both the ordinary and Codex bounded-acknowledgement paths;
  - a closed workspace, an unloaded session, a pending question or approval, and `/compact` all refused, including `/compact` behind the prefix;
  - the prefix persisted in the target transcript;
  - no `mcpControlContext` after a send, and the target still an attention root.
- Done when: every refusal sends nothing, and accepted sends reach the target without changing its control, approvals or alerts.

Step 3 — done | rounds 1/2 | open: none | downgraded: none | assumed: source process identity verified (step3-remediation.md) | deferred: nonblocking coverage and wording; live acceptance (step3-dispositions.md)

### Step 4 — `request_grant` and approval prompt
- Change: the new approval operation kind without auto-approve or Always Allow, fixed wording, revalidation, and persistence through Step 1.
- Validation: `make dev-test FILTER=WorkspaceSteeringGrantRequestTests`. The suite covers Allow writing exactly one grant; Deny and queued-request cancellation writing nothing; an existing auto-approve or Always Allow policy for the client not granting; an existing grant returning `already_granted` without a prompt.
- Done when: only Settings or an owner click on this prompt creates a grant.

Step 4 — todo | rounds 0/2 | open: none | downgraded: none | assumed: none | deferred: none

### Step 5 — Live acceptance (owner-run, Dev build)
- Change: none. Requires owner approval for the visible app launch. Update the routed context documents for the new steering path after acceptance.
- Validation: with Assistant and target workspaces open in separate windows, run these checks and record the outcomes in the evidence directory:
  - `list`;
  - a steer into a running root;
  - a follow-up into an idle root;
  - a refusal after closing the target workspace;
  - `request_grant` Allow and Deny;
  - Revoke blocking the next send;
  - the prefix visible in the target transcript.
- Done when: the owner accepts the checks.

Step 5 — todo | rounds 0/2 | open: owner approval for app launch | downgraded: none | assumed: none | deferred: none

## Decisions
- Accept unrelated lint formatting errors for now and continue implementation.
- Access is a persistent, one-way workspace→workspace grant covering every current and future session on both sides, with no per-session or per-steer approval and no chaining.
- The Assistant schedules its own periodic checks; the app adds no live monitoring.
- Steering is refused when the target workspace is not open; the app never opens or switches workspaces.
- Reading stays broad; `history` is not filtered by grants.
- Only top-level sessions the owner started can be steered.
- The only action is a steer or follow-up message; Stop and answering questions stay with the owner.
- A follow-up to an idle target starts a new turn.
- Grants are created in Settings, or by an Assistant request the owner approves on the Mac.
- A message already in flight is delivered even if the Assistant is stopped.
- Knowledge sessions in the source workspace may steer.
- Dev and release builds share grants.

## Disagreements
- Tool surface (`agent_run` ops vs a separate tool): separate tool, because `agent_run` is hidden from delegation leaves and every source agent must be able to steer. Both lanes agreed after one relay round.
- Recheck whether the stopped Assistant's run is current: unresolved after two rounds; the owner chose delivery.
- Request-cancellation check vs instruction: neither lane kept new cancellation plumbing. "Report uncertainty, don't resend" won over "re-read and resend if absent", because saved history can lag.
- Re-scan all windows at acceptance vs pin the target: pinning, which is smaller and still prevents redirection.
- Agent-written reason in the approval prompt: omitted; the app writes all the wording.
- Adding `workspace_id` to `history` list entries: cut, since entries carry `workspace_name` and `list` maps names to IDs.

## Open Questions
- Validate before Step 2: that run policy fills `workspaceID` for every Agent Mode run purpose (Claude, Codex, ACP, headless); if it doesn't, those callers are refused rather than inferred.
- Validate before Step 3: that the Codex bounded-acknowledgement path runs the final predicate synchronously before acceptance.
- Validate before Step 4: whether `WorkspaceApprovalOperation`/`WorkspaceApprovalRequest` (`WorkspaceApprovalTypes.swift`) can carry a no-auto-approve kind without touching existing operations.
- Unverified: the Assistant's own timer. No RepoPrompt tool lets an agent wake itself, and scheduled sends are owner-only and never run while the app is quit.
- Main-agent interpretations (not owner Decisions): the Settings placement, the exact prefix and refusal wording, and omitting stale-binding cleanup for deleted workspaces.
