import Foundation

// Lossless-restart Phase 3 runtime record model (spec R6).
//
// One record per managed provider process lifetime lives at
// `AgentRecovery/v1/runtimes/<runtimeID>.json`, written only by `AgentRecoveryStore` on behalf of
// `AgentProcessRegistry`. It never holds argument vectors or environments: only the runtime marker
// identity, birth identities, process groups, member roles, provider home evidence and ownership
// associations. Like session records, unknown additive members are preserved, and an unreadable or
// future record is preserved byte-for-byte, never written, and treated as unknown ownership.

/// The managed launch family a runtime belongs to (transport mechanics). Qualification is keyed by
/// family plus the actual provider (`AgentRuntimeProvider`).
package enum AgentRuntimeFamily: String, CaseIterable {
    /// Claude native stream-json controller (standard Claude Code).
    case claudeNative
    /// Claude-compatible native backends (GLM, Kimi, custom compatible).
    case claudeCompatible
    /// Headless Claude Code CLI runs (`CLIProcessRunner`).
    case claudeHeadless
    /// The central Codex app-server client (models, auth, control, sessionless and thread work).
    case codexAppServer
    /// Headless `codex exec` runs (`CLIProcessRunner`).
    case codexExec
    /// Generic ACP agents (Cursor, OMP, OpenCode and other ACP backends).
    case acp
}

/// The actual provider behind a runtime, from existing provider identifiers (never a display name,
/// command basename, credential or configuration object). Native and headless routes of the same
/// provider share one identity. A record without one (an earlier draft) is unknown: conservative.
package enum AgentRuntimeProvider: Hashable {
    case claude(ClaudeCodeRuntimeVariant)
    case codex
    case acp(ACPProviderID)

    /// The provider of an Agent Mode provider kind; `nil` for none.
    package init?(agentKind: AgentProviderKind) {
        if let variant = agentKind.claudeRuntimeVariant {
            self = .claude(variant)
        } else if agentKind == .codexExec {
            self = .codex
        } else if let providerID = agentKind.acpProviderID {
            self = .acp(providerID)
        } else {
            return nil
        }
    }

    package var rawValue: String {
        switch self {
        case let .claude(variant): "claude." + variant.rawValue
        case .codex: "codex"
        case let .acp(providerID): "acp." + providerID.rawValue
        }
    }

    package init?(rawValue: String) {
        if rawValue == "codex" {
            self = .codex
        } else if rawValue.hasPrefix("claude."), let variant = ClaudeCodeRuntimeVariant(rawValue: String(rawValue.dropFirst(7))) {
            self = .claude(variant)
        } else if rawValue.hasPrefix("acp."), let providerID = ACPProviderID(rawValue: String(rawValue.dropFirst(4))) {
            self = .acp(providerID)
        } else {
            return nil
        }
    }
}

/// The requested permission configuration of one operation, from existing policy values. It records
/// what was requested, not a claim that the provider applied it; `unavailable` (not applicable or
/// unknown) is never interpreted as permissive.
package enum AgentRuntimePermissionSnapshot: Hashable {
    case unavailable
    /// Claude native/headless: the configured permission mode.
    case claude(permissionMode: String?)
    /// Codex: the requested approval policy and sandbox policy.
    case codex(approvalPolicy: String?, sandbox: String?)
    /// ACP: the selected session mode and the auto-approve setting.
    case acp(sessionModeID: String?, autoApproveAllToolPermissions: Bool)
}

/// A runtime's managed Agent Mode session: its durable lifecycle binding plus, when they already
/// exist, the logical run attempt and the process run. Never invented: an attempt is attached
/// when it exists.
package struct AgentRuntimeSessionAssociation: Hashable {
    package let sessionID: UUID
    package let incarnationID: UUID
    package let transcriptResetGeneration: UInt64
    package let runAttemptID: UUID?
    package let processRunID: UUID?

    package init(
        sessionID: UUID,
        incarnationID: UUID,
        transcriptResetGeneration: UInt64,
        runAttemptID: UUID?,
        processRunID: UUID?
    ) {
        self.sessionID = sessionID
        self.incarnationID = incarnationID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.runAttemptID = runAttemptID
        self.processRunID = processRunID
    }

    package init(lifecycle: AgentRecoveryLifecycleBinding, runAttemptID: UUID?, processRunID: UUID?) {
        self.init(
            sessionID: lifecycle.sessionID,
            incarnationID: lifecycle.incarnationID,
            transcriptResetGeneration: lifecycle.transcriptResetGeneration,
            runAttemptID: runAttemptID,
            processRunID: processRunID
        )
    }
}

/// Which managed session an operation belongs to. Genuinely sessionless work (model, auth, control,
/// polling, discovery, Oracle, Context Builder) says so explicitly; an Agent Mode operation whose
/// durable context could not be established is `unavailable`, and registration refuses it rather
/// than infer a sessionless operation.
package enum AgentRuntimeSessionScope: Hashable {
    case sessionless
    case session(AgentRuntimeSessionAssociation)
    case unavailable
}

/// One operation-bound association of a runtime: the managed session (if any), the native
/// conversation it reached (once known), its worktree and the requested permission configuration.
/// A reused transport accumulates one per run attempt or thread; earlier ones are retained.
package struct AgentRuntimeAssociation: Equatable {
    package var session: AgentRuntimeSessionAssociation?
    package var conversationID: String?
    package var worktreePath: String?
    package var permission: AgentRuntimePermissionSnapshot
    package var extras: AgentRecoveryExtras

    package init(
        session: AgentRuntimeSessionAssociation?,
        conversationID: String?,
        worktreePath: String?,
        permission: AgentRuntimePermissionSnapshot,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.session = session
        self.conversationID = conversationID
        self.worktreePath = worktreePath
        self.permission = permission
        self.extras = extras
    }
}

/// One process lifetime: boot session, PID, start time and UID. Executable path and process group
/// are supporting evidence only.
package struct AgentRuntimeProcessIdentity: Hashable {
    package let bootSessionID: UUID
    package let pid: Int32
    package let startSeconds: UInt64
    package let startMicroseconds: UInt64
    package let uid: UInt32

    package init(bootSessionID: UUID, pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64, uid: UInt32) {
        self.bootSessionID = bootSessionID
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.uid = uid
    }
}

/// An observed descendant of a runtime root.
package struct AgentRuntimeMember: Equatable {
    package enum Role: String, CaseIterable {
        /// A possible conversation writer or launcher (shim, CLI).
        case writer
        /// A positively identified tool-only process under a qualified family.
        case tool
        /// Anything not positively classified. Treated as a possible writer.
        case unknown
    }

    package var identity: AgentRuntimeProcessIdentity
    package var processGroupID: Int32?
    package var role: Role
    package var extras: AgentRecoveryExtras

    package init(identity: AgentRuntimeProcessIdentity, processGroupID: Int32?, role: Role, extras: AgentRecoveryExtras = [:]) {
        self.identity = identity
        self.processGroupID = processGroupID
        self.role = role
        self.extras = extras
    }
}

package struct AgentRuntimeRecord: Equatable {
    package static let currentSchemaVersion = 1

    package enum State: String, CaseIterable {
        /// Committed before the spawn; the process may or may not exist.
        case reserved
        /// Birth identity committed; the family may still hold writers.
        case live
        /// The writers are proven gone; positively identified tools remain (worktree-busy only).
        case toolsRemaining
        /// The whole family is proven gone under a qualified family.
        case exited
        /// The Stop engine verified the family gone after signalling.
        case stopped
        /// Ownership could not be resolved; treated as a possible live writer.
        case unknown
        /// Left running at quit by an explicit detach (compatible schema variant: nothing produces it
        /// yet). A possible writer until discovery proves otherwise.
        case detachedAtQuit

        /// A possible conversation writer, launcher or reservation remains.
        package var mayHoldWriter: Bool {
            switch self {
            case .reserved, .live, .unknown, .detachedAtQuit: true
            case .toolsRemaining, .exited, .stopped: false
            }
        }
    }

    package let runtimeID: UUID
    package internal(set) var revision: AgentRecoveryRecordRevision
    /// The app instance that reserved this runtime.
    package let appInstanceID: UUID
    package let family: AgentRuntimeFamily
    /// The actual provider; `nil` (an earlier draft record) is unknown and overlaps conservatively.
    package let provider: AgentRuntimeProvider?
    /// Provider home learned from actual evidence (an observed writer's Claude config directory);
    /// `nil` while unresolved, never an assumed default.
    package var providerHome: String?
    package var state: State
    /// Birth identity of the direct child; `nil` while only reserved.
    package var root: AgentRuntimeProcessIdentity?
    package var rootProcessGroupID: Int32?
    /// The exact root was reaped by this app (root-lifetime evidence only, never family exit).
    package var rootReaped: Bool
    /// Observed descendants (never the root).
    package var members: [AgentRuntimeMember]
    /// Operation-bound associations (sessions, run attempts, conversations, permissions).
    package var associations: [AgentRuntimeAssociation]
    /// Native conversation IDs this runtime serves (Claude session, Codex thread, ACP session): the
    /// registry-maintained conservative union of `associations` (and of earlier draft records).
    package var conversationIDs: [String]
    /// Standardized worktree paths this runtime may write to (registry-maintained union).
    package var worktreePaths: [String]
    /// The user chose Let finish for this surviving runtime (persisted decision; it keeps watching).
    package var letFinish: Bool
    package let createdAt: AgentRecoveryTimestamp
    package var updatedAt: AgentRecoveryTimestamp
    package var extras: AgentRecoveryExtras

    package init(
        runtimeID: UUID,
        revision: AgentRecoveryRecordRevision,
        appInstanceID: UUID,
        family: AgentRuntimeFamily,
        provider: AgentRuntimeProvider?,
        providerHome: String? = nil,
        state: State,
        root: AgentRuntimeProcessIdentity? = nil,
        rootProcessGroupID: Int32? = nil,
        rootReaped: Bool = false,
        members: [AgentRuntimeMember] = [],
        associations: [AgentRuntimeAssociation] = [],
        conversationIDs: [String] = [],
        worktreePaths: [String] = [],
        letFinish: Bool = false,
        createdAt: AgentRecoveryTimestamp,
        updatedAt: AgentRecoveryTimestamp,
        extras: AgentRecoveryExtras = [:]
    ) {
        self.runtimeID = runtimeID
        self.revision = revision
        self.appInstanceID = appInstanceID
        self.family = family
        self.provider = provider
        self.providerHome = providerHome
        self.state = state
        self.root = root
        self.rootProcessGroupID = rootProcessGroupID
        self.rootReaped = rootReaped
        self.members = members
        self.associations = associations
        self.conversationIDs = conversationIDs
        self.worktreePaths = worktreePaths
        self.letFinish = letFinish
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.extras = extras
    }
}

package enum AgentRuntimeRecordState: Equatable {
    case absent
    case supported(AgentRuntimeRecord)
    /// Unreadable or future data. Never modified, never writable; treated as unknown ownership.
    case preserved(AgentRecoveryUnreadableReason)
}

/// Ownership bindings recovered leniently from an unreadable runtime record, so its uncertainty can
/// be scoped to the conversations and worktrees it names. Absent when they cannot be established.
package struct AgentRuntimePreservedBindings: Equatable {
    package let conversationIDs: [String]
    package let worktreePaths: [String]
    /// Managed sessions named by the record's associations.
    package let sessionIDs: [UUID]

    package init(conversationIDs: [String], worktreePaths: [String], sessionIDs: [UUID] = []) {
        self.conversationIDs = conversationIDs
        self.worktreePaths = worktreePaths
        self.sessionIDs = sessionIDs
    }
}

package enum AgentRuntimeDiscoveryEntry: Equatable {
    case supported(AgentRuntimeRecord)
    /// `runtimeID` is `nil` when the file name is not a runtime UUID; `bindings` is `nil` when the
    /// record's ownership cannot be established (a global uncertainty).
    case preserved(runtimeID: UUID?, reason: AgentRecoveryUnreadableReason, bindings: AgentRuntimePreservedBindings?)
}
