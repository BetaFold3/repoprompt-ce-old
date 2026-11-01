import Foundation
import JSONSchema
import MCP
import RepoPromptAgentCore

/// `workspace_steer` (docs/context/specs/2026-11-01-assistant-workspace-steering-spec.md).
@MainActor
final class MCPWorkspaceSteeringToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .workspaceSteering

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [workspaceSteerTool()]
    }

    private func workspaceSteerTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.workspaceSteer,
            freshnessPolicy: .none,
            description: """
            List and steer top-level sessions in other workspaces that the owner has granted to this session's workspace. A grant is one-way (source workspace → target workspace) and is created only by the owner, in Settings or by approving `request_grant` on this Mac.

            **Operations**: list | send | request_grant

            - `list`: Returns `{workspaces:[{workspace_id, name, is_open, sessions:[{session_id, name, run_state}], warnings}]}` for granted target workspaces. Pass `target_workspace_id` to list one; an ungranted target is an error. A target that is not open in any window on this Mac reports `is_open: false` and lists no sessions. Only top-level sessions the owner started on this Mac are listed; sessions bound to more than one tab or window are omitted with a warning.
            - `send`: Steers a running session, or sends a follow-up that starts a new turn in an idle one. Pass `target_workspace_id`, a `session_id` from `list` and a nonempty `message`. The app puts `[Steer from workspace "<name>" (<workspace id>), session <your session id>]` and a blank line before the message. Returns `{workspace_id, session_id, delivery}`. It is refused, and nothing is sent, when the target workspace is not open, the grant was removed, the session is not listed, not loaded, or waiting on a question or approval (those stay with the owner), or the message is a session command such as `/compact` or `/goal`.
            - `request_grant`: Asks the owner, on this Mac, to grant this session's workspace access to `target_workspace_id` (works without an existing grant). The app writes the whole prompt from workspace names and IDs; no agent text is shown. The call waits for the owner and returns `{status}`: `granted` after the owner allows it, `already_granted` without asking when the grant exists, or `denied` when the owner denies it or the prompt is cancelled. The owner has about 30 seconds to answer, counted from your call even while the prompt waits behind another one; after that the call ends with `denied` or a tool timeout error. A timeout is not the owner's denial, but nothing is written either way. Do not send the request again on your own after a denial or timeout: tell the owner, who can answer a new request when asked or add the grant in Settings.

            **Retry rule for send:** a refusal that says nothing was sent can be retried once its cause is fixed. After any other error or a timeout whose outcome is unclear, read the target transcript with `history` and look for your attributed message. If delivery is still uncertain, tell the owner and do not resend: saved history can lag by about 10 seconds, so a missing message does not prove it was not delivered.

            The source workspace is always the workspace of the Agent Mode session making the call; arguments cannot choose it. Use the `history` tool to read target transcripts.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                description: """
                Provide `op` plus operation-specific fields.

                **list**: target_workspace_id?
                **send**: target_workspace_id, session_id, message
                **request_grant**: target_workspace_id
                """,
                properties: [
                    "op": .string(description: "Operation.", enum: ["list", "send", "request_grant"]),
                    "target_workspace_id": .string(description: "[list, send, request_grant] Target workspace UUID. Optional for list (omitted lists every granted workspace)."),
                    "session_id": .string(description: "[send] Target session UUID from list."),
                    "message": .string(description: "[send] Message to steer or follow up with.")
                ],
                required: ["op"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executeWorkspaceSteer(args)
        }
    }
}
