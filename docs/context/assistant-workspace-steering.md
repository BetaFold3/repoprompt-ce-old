# Assistant workspace steering

Scope: read when the task touches workspace→workspace steering grants, the `workspace_steer` MCP tool, cross-window steering target resolution, or the owner-only grant-request approval.
Authority: Authoritative
Last-verified: 2026-11-02

Implemented, and accepted by the owner in the Dev build on 2026-11-02 with Codex source and target sessions. The design record and step history are in the [steering spec](specs/2026-11-01-assistant-workspace-steering-spec.md) (Reference). Code and tests are the source of truth for behavior.

## Contract
- **Grant.** `WorkspaceSteeringGrant {sourceWorkspaceID, targetWorkspaceID, createdAt}` lives in `scalarPreferences.workspaceSteeringGrants` of the global settings document (`WorkspaceSteeringGrantStore`). A grant is one directed pair, keyed by workspace UUID, so it survives renames. Self-grants are rejected, duplicates are ignored, and grants don't chain or work in reverse. A grant covers every current and future session on both sides. A grant naming a deleted workspace does nothing until it is removed. Checks read the file on every call (`isGranted`, `grantedTargets`) and fail closed when it can't be read.
- **Settings.** Settings → Manage Workspaces → Workspace Steering (`WorkspaceSteeringGrantsSettingsView`, embedded in `ManageWorkspacesView` only when `showsSteeringGrants` is set from Settings). The section lists source → target rows ("unknown workspace" for a deleted one), each with Remove, plus Add with two workspace pickers. Grants change only after a successful save.
- **Tool.** `workspace_steer` (`MCPWorkspaceSteeringToolProvider`, `WorkspaceSteeringMCPToolService`) takes `op` = `list | send | request_grant`. The `.workspaceSteering` capability is granted to every Agent Mode provider policy (`AgentModeMCPToolPolicy`), including delegation leaves, and the tool is in `KnowledgeSessionPolicy.allowedMCPToolNames`. Existing `agent_run` restrictions are unchanged.

## Caller authority
The source workspace comes only from `RequestMetadata.actorRoutedRunTab.workspaceID`, with `runPurpose == .agentModeRun`. The route's window must still exist, must not be closing, and must still show that workspace. Arguments, `_windowID`, `context_id`, selected tabs and client names never set the source. These callers are refused: gateway or paired-device callers (`gatewayRemoteDeviceID`, or a gateway principal connection), calls with no run route, and calls with no recorded workspace. `send` and new grant requests also freeze the calling session identity (`frozenSourceSessionID`), for send attribution and grant-request revalidation. An existing grant returns `already_granted` before this session check. That session must be the uniquely bound live session in the route tab and must still be running the routed run. Every local session qualifies, including workers, explore sessions and Knowledge sessions.

## Target eligibility
`scanTarget` checks only non-closing windows whose active workspace is the target. A session is eligible when `remoteAttentionRootSession` resolves it (a unique live binding, local rather than a remote host, and an attention root with no MCP control) on a compose tab of that workspace, and `mcpDelegationCallerProfile == .standard`. That last check excludes Knowledge sessions, and the exclusion is steering-only, so phone eligibility is unchanged. A session claimed by more than one tab, or bound in more than one window, is ambiguous: `list` leaves it out with a warning and `send` refuses it. A closed target reports `is_open: false` with "Open it, then retry". The app never opens or switches a workspace.

## Dispatch and admission
- `send` runs its entry checks in this order, and a refusal at any of them sends nothing: arguments, the frozen source session, one fresh grant read, then target resolution. It then pins the window, view model and session, and calls `workspaceSteeringDispatchInstruction` on the pinned view model with `SessionInstructionTarget.workspaceGrant(sourceWorkspaceID:)` through `dispatchSessionInstruction`. A running target is steered. An idle target gets a follow-up that starts a new turn. `delivery` is the `MCPInstructionDispatch` raw value (live runs returned `started_run` and `dispatched_codex_turn`).
- **Final predicate.** `sessionInstructionTargetIsReady` runs on both the ordinary and the Codex bounded-acknowledgement paths. It re-resolves `workspaceSteeringGrantedTarget`: the grant must exist for the pinned window's current workspace, and the same session object must still resolve there. It also re-checks `workspaceSteeringDispatchRefusal`, which refuses a pending owner question or approval, an unloaded session, and `/compact`- or `/goal`-style control-plane commands. These are judged on the unattributed message. A revocation, workspace switch or session replacement before admission therefore sends nothing.
- `send` never falls back to MCP control, installs no `mcpControlContext` and changes no lineage. The target keeps its approvals and its Telegram attention alerts. A message admitted before a revocation, or before the source is stopped, is delivered and reported.
- **Attribution.** The submitted text is `[Steer from workspace "<source name>" (<source UUID>), session <source session UUID>]`, then a blank line, then the message. It is saved in the target transcript and visible there. No new transcript fields are added.
- **Retry rule** (in the tool description): a refusal that says "Nothing was sent" may be retried once its cause is fixed. After any other error, or a timeout with an unclear outcome, read the target transcript with `history` and look for the attributed message. If delivery is still uncertain, tell the owner and don't resend, because saved history can lag about 10 s.

## Grant request
`request_grant` returns `already_granted` without a prompt when the grant exists. It refuses self-grants and unknown targets. Otherwise it queues a `WorkspaceApprovalOperation.workspaceSteeringGrant` request on the caller's window through `WorkspaceApprovalManager`. That operation sets `allowsAutoApproval == false`, so:
- `shouldAutoApprove` ignores Auto Approve All, per-operation settings and stored client policies;
- Always Allow is hidden, and is ignored if passed in;
- Return is not the default action;
- `resolveApproval` ignores any answer without the matching `expectedRequestID`, and the overlay passes the ID of the request it shows;
- Permissions settings list only `autoApprovableCases`.

The app writes all the prompt wording from workspace names and IDs, and the request carries no agent text. After Allow, the service revalidates the caller from the same captured route (same window, workspace and run) and checks that the target still exists. It also checks for cancellation once more before `grantStore().add`. Deny, cancellation, revalidation failure or a save failure write nothing.

**Timeout.** `workspace_steer` keeps the default bounded tool contract (`MCPTimeoutPolicy.boundedToolExecutionDeadline`, 30 s), counted from the call, including time spent queued behind another prompt. A watchdog cancellation resolves the prompt as denied, or the tool returns a timeout error. A timeout isn't the owner's denial, and no grant is written either way. The tool description tells agents not to re-request on their own; the owner can answer a new request or add the grant in Settings. Lengthening this deadline would need a deliberate per-op contract change and tests.

## Compatibility
Nonempty grants require settings schema v6 (`workspaceSteeringGrantsSchemaVersion`). An older build keeps the v6 file, runs on in-memory defaults and can't save. Its block stays latched even after the last grant is removed, so relaunch the older build once the file is back on a schema it supports. Grant writes and every `GlobalSettingsStore` save take a nonblocking `flock` on `globalSettings.json.lock` and use the grants on disk. When the lock is contended, the save fails and can be retried; it doesn't block. Dev and release builds share the file, so they share grants. Details: [settings persistence](../architecture/settings-persistence.md).

## Validation
- Automated suites: `WorkspaceSteeringGrantStoreTests`, `WorkspaceSteeringToolTests`, `WorkspaceSteeringSendTests`, `WorkspaceSteeringGrantRequestTests` (`make dev-test FILTER=<Suite>`). For advertisement or catalog changes, also run `ToolCatalogSnapshotTests`, `MCPBootstrapLeaseTests` and `KnowledgeSessionMCPPolicyTests`.
- Live acceptance (owner, Dev build, 2026-11-02, Codex source and target):
  - `list`;
  - an idle follow-up (`started_run`), then a running steer (`dispatched_codex_turn`);
  - both attribution prefixes in the saved transcript and the UI;
  - a send to a closed target window refused;
  - `request_grant` Allow, and Deny through automated native clicks;
  - Settings list, Add and Remove;
  - Revoke refusing the next send.

## Known limits
- Not run live: the full cross-provider matrix (Claude, ACP and headless callers depend on run-route seeding and are refused when the workspace identity is missing), queued-prompt visibility, Return not approving, and the 30 s watchdog dismissal in the UI. Telegram notification delivery wasn't run either.
- The `delivery` value is the inherited one chosen before admission.
- An already-open Settings page can show stale rows from another process until it reappears, but authorization always reads the file.
- Saved history can lag, so a missing attributed message doesn't prove the send failed.
- The app adds no scheduler or live monitoring. Autonomous periodic wakeups were not validated; scheduled sends remain owner-only.
- Out of scope: Stop, answering questions or approvals, slash commands, MCP-controlled/Knowledge/remote-host targets, and other Macs.
