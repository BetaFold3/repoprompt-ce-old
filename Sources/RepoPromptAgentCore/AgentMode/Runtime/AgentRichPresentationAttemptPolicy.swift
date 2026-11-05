import Foundation

/// The workspace rich-presentation permission captured once for one run attempt
/// (docs/context/specs/2026-11-04-rich-presentation-spec.md, A3).
///
/// Captured synchronously in `AgentTabSession.beginRunAttempt` from the App's committed Settings
/// for the session's exact workspace and carried, unchanged, on `AgentRunOwnership`. It is never
/// persisted: recovery admits a new attempt, which resamples. A Settings edit after admission
/// affects only the next attempt; nothing here observes Settings.
package struct AgentRichPresentationAttemptPolicy: Equatable, Hashable {
    /// The workspace whose Settings were read. Authority checks compare it with the request's
    /// trusted route workspace; it is never taken from tool arguments.
    package let workspaceID: UUID
    /// Whether `present_rich` may create artifacts during this attempt.
    package let enabled: Bool
    /// Canonical exact image hosts approved for this attempt: validated, deduplicated, sorted.
    package let approvedImageHosts: [String]

    private init(workspaceID: UUID, enabled: Bool, approvedImageHosts: [String]) {
        self.workspaceID = workspaceID
        self.enabled = enabled
        self.approvedImageHosts = approvedImageHosts
    }

    /// The captured policy for committed Settings values. Every host must already be a canonical
    /// exact host (`RichPresentationURLPolicy.validateApprovedHost` returns it unchanged); a single
    /// host that is not grants nothing (disabled, no hosts) instead of being repaired or dropped,
    /// so a malformed stored entry can never broaden approval.
    package static func captured(
        workspaceID: UUID,
        enabled: Bool,
        approvedImageHosts: [String]
    ) -> AgentRichPresentationAttemptPolicy {
        var canonicalHosts = Set<String>()
        for host in approvedImageHosts {
            guard case let .success(validated) = RichPresentationURLPolicy.validateApprovedHost(host),
                  validated == host
            else {
                return disabled(workspaceID: workspaceID)
            }
            canonicalHosts.insert(validated)
        }
        return AgentRichPresentationAttemptPolicy(
            workspaceID: workspaceID,
            enabled: enabled,
            approvedImageHosts: canonicalHosts.sorted()
        )
    }

    /// A valid capture whose creation permission is off (the default for every workspace).
    package static func disabled(workspaceID: UUID) -> AgentRichPresentationAttemptPolicy {
        AgentRichPresentationAttemptPolicy(workspaceID: workspaceID, enabled: false, approvedImageHosts: [])
    }

    /// Whether this capture grants the dedicated rich-presentation capability.
    package var grantsCreation: Bool {
        enabled
    }
}

/// Resolves the attempt policy for a session at admission. Installed by the App on each managed
/// Agent Mode session (`AgentTabSession.richPresentationPolicyResolver`); synchronous and
/// MainActor so no suspension separates the binding inspection, the Settings read and the
/// ownership creation. Returns `nil` when the session's exact local workspace binding cannot be
/// established; rich creation then fails closed for the attempt.
package typealias AgentRichPresentationPolicyResolver = @MainActor (AgentTabSession) -> AgentRichPresentationAttemptPolicy?

/// Derives the dedicated rich-presentation tool grant from an attempt's captured ownership.
/// `present_rich` is registered in every window catalog but policy-gated: this grant decides its
/// listing and direct-call admission, and the call-time resolver re-proves the exact attempt.
package enum AgentRichPresentationToolPolicy {
    /// The tool name reserved for the dedicated `.richPresentation` capability.
    package static let toolName = "present_rich"

    /// The rich-presentation tool names granted to a local Agent Mode run attempt: the dedicated
    /// capability's tools when the attempt's captured policy is enabled, otherwise none.
    package static func grantedTools(for ownership: AgentRunOwnership?) -> Set<String> {
        guard ownership?.richPresentationPolicy?.grantsCreation == true else { return [] }
        return MCPToolCapabilities.toolNames(for: [.richPresentation])
    }

    /// The tool names owned by the dedicated capability, granted or not.
    package static var capabilityToolNames: Set<String> {
        MCPToolCapabilities.toolNames(for: [.richPresentation])
    }
}
