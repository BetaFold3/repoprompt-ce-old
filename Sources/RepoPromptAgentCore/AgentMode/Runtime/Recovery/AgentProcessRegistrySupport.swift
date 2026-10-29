import Darwin
import Foundation
import RepoPromptPlatform

// Value types and injected boundaries of `AgentProcessRegistry` (spec R6).

// MARK: - Qualification

/// Live-qualified evidence for one launch family, recorded for specific actual providers. Nothing
/// here is inferred: production takes its qualification from `AgentRecoveryActivation.production`
/// only. Evidence for one ACP or Claude-compatible backend never qualifies another backend that
/// shares its family.
package struct AgentRuntimeFamilyQualification: Equatable {
    /// The actual providers this evidence was recorded for.
    package var providers: Set<AgentRuntimeProvider>
    /// `RPCE_RUNTIME_ID` reaches the shim, CLI and tools of this family.
    package var markerPropagation: Bool
    /// Same-user inventory plus parent links and markers find every family member (including
    /// reparented and separate-group tools).
    package var completeDiscovery: Bool
    /// Executable basenames of this family's launchers and provider CLIs (writers).
    package var writerExecutableBasenames: Set<String>
    /// Executable basenames positively qualified as non-writing tools of this family. Only an exact
    /// match (with a readable environment) is a tool; every other non-writer stays `unknown`, so an
    /// unfamiliar shim, interpreter or changed executable never releases conversation ownership.
    package var toolExecutableBasenames: Set<String>
    /// Fresh Claude `--session-id` preallocation works through the actual shim (separate gate).
    package var freshSessionID: Bool

    package init(
        providers: Set<AgentRuntimeProvider>,
        markerPropagation: Bool,
        completeDiscovery: Bool,
        writerExecutableBasenames: Set<String>,
        toolExecutableBasenames: Set<String> = [],
        freshSessionID: Bool = false
    ) {
        self.providers = providers
        self.markerPropagation = markerPropagation
        self.completeDiscovery = completeDiscovery
        self.writerExecutableBasenames = writerExecutableBasenames
        self.toolExecutableBasenames = toolExecutableBasenames
        self.freshSessionID = freshSessionID
    }

    var supportsCompleteDiscovery: Bool {
        markerPropagation && completeDiscovery
    }
}

package struct AgentRuntimeQualification: Equatable {
    package var families: [AgentRuntimeFamily: AgentRuntimeFamilyQualification]

    package init(families: [AgentRuntimeFamily: AgentRuntimeFamilyQualification]) {
        self.families = families
    }

    /// Every managed family/provider pair the app can launch: Claude native serves the standard
    /// provider, Claude-compatible native serves every compatible backend, headless Claude serves
    /// every variant, both Codex families serve Codex, and ACP serves every ACP backend.
    package static var supportedPairs: [(family: AgentRuntimeFamily, provider: AgentRuntimeProvider)] {
        let claudeVariants = ClaudeCodeRuntimeVariant.allCases
        return claudeVariants.filter { $0 == .standard }.map { (AgentRuntimeFamily.claudeNative, AgentRuntimeProvider.claude($0)) }
            + claudeVariants.filter { $0 != .standard }.map { (AgentRuntimeFamily.claudeCompatible, AgentRuntimeProvider.claude($0)) }
            + claudeVariants.map { (AgentRuntimeFamily.claudeHeadless, AgentRuntimeProvider.claude($0)) }
            + [(AgentRuntimeFamily.codexAppServer, AgentRuntimeProvider.codex), (AgentRuntimeFamily.codexExec, AgentRuntimeProvider.codex)]
            + ACPProviderID.allCases.map { (AgentRuntimeFamily.acp, AgentRuntimeProvider.acp($0)) }
    }

    /// Subset activation (Step 9-activation, O32; replaces phase3-registry-plan's coupled
    /// "Activation clarification"): registration is active once any supported pair is qualified for
    /// complete discovery. Only covered pairs register, carry the marker and are fenced; every
    /// uncovered pair launches unregistered exactly as before activation. Evidence for one ACP or
    /// compatible backend never covers another.
    package var activatesRegistration: Bool {
        Self.supportedPairs.contains { covers(family: $0.family, provider: $0.provider) }
    }

    /// Whether every supported pair is covered: only then can registry evidence speak for the whole
    /// app (an unregistered family can never be proven stopped).
    package var coversAllSupportedPairs: Bool {
        Self.supportedPairs.allSatisfy { covers(family: $0.family, provider: $0.provider) }
    }

    /// Whether this exact family/provider pair has complete-discovery qualification. Launch
    /// authority makes no launch for an uncovered pair (it runs unregistered); `reserveLaunch` still
    /// refuses one as a defence against a direct caller.
    package func covers(family: AgentRuntimeFamily, provider: AgentRuntimeProvider) -> Bool {
        qualification(family: family, provider: provider)?.supportsCompleteDiscovery == true
    }

    /// The evidence that applies to a runtime: its family's qualification only when it was recorded
    /// for this actual provider. An unknown provider (an earlier draft record) is never qualified.
    package func qualification(family: AgentRuntimeFamily, provider: AgentRuntimeProvider?) -> AgentRuntimeFamilyQualification? {
        guard let provider, let qualification = families[family], qualification.providers.contains(provider) else { return nil }
        return qualification
    }

    package func allowsFreshSessionID(_ family: AgentRuntimeFamily, provider: AgentRuntimeProvider) -> Bool {
        activatesRegistration && qualification(family: family, provider: provider)?.freshSessionID == true
    }
}

// MARK: - OS boundaries

/// A cancellable exit watch on one process lifetime.
package protocol AgentProcessExitWatchToken: AnyObject {
    func cancel()
}

extension ProcessExitWatch: AgentProcessExitWatchToken {}

/// Read-only process boundaries of the registry. Production uses Platform inventory, inspection
/// and Dispatch exit watches; tests script them. Nothing here signals.
package struct AgentProcessSystem {
    package var inventory: @Sendable () async -> ProcessInventorySnapshot
    package var inspect: @Sendable (pid_t) async -> ProcessInspectionResult
    /// Installs an exit watch; `nil` when it could not be installed (discovery stays incomplete).
    package var watchExit: @Sendable (pid_t, @escaping @Sendable () -> Void) -> AgentProcessExitWatchToken?
    /// This app's own PID and process group; never a family member and never signalled.
    package var appPID: pid_t
    package var appProcessGroupID: pid_t

    package init(
        inventory: @escaping @Sendable () async -> ProcessInventorySnapshot,
        inspect: @escaping @Sendable (pid_t) async -> ProcessInspectionResult,
        watchExit: @escaping @Sendable (pid_t, @escaping @Sendable () -> Void) -> AgentProcessExitWatchToken?,
        appPID: pid_t,
        appProcessGroupID: pid_t
    ) {
        self.inventory = inventory
        self.inspect = inspect
        self.watchExit = watchExit
        self.appPID = appPID
        self.appProcessGroupID = appProcessGroupID
    }

    package static let live = AgentProcessSystem(
        inventory: {
            await Task.detached(priority: .utility) { ProcessInventory.snapshot() }.value
        },
        inspect: { pid in
            await Task.detached(priority: .utility) { ProcessInspection.inspect(pid: pid) }.value
        },
        watchExit: { pid, handler in ProcessExitWatch(pid: pid, handler: handler) },
        appPID: getpid(),
        appProcessGroupID: getpgrp()
    )
}

/// Signalling and waiting used only by the Stop engine. Production supplies none: recovered Stop
/// stays disabled until it is qualified and its group-signalling policy is approved.
package struct AgentProcessStopActions {
    /// Sends `signal` to process group `processGroupID`; returns 0 or the errno.
    package var signalProcessGroup: @Sendable (_ processGroupID: pid_t, _ signal: Int32) -> Int32
    package var sleep: @Sendable (_ seconds: TimeInterval) async -> Void

    package init(
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Int32,
        sleep: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        self.signalProcessGroup = signalProcessGroup
        self.sleep = sleep
    }
}

// MARK: - Restrictions

/// What a session would touch: its managed session, native conversation (with its provider when
/// known) and worktree. An unknown provider overlaps conservatively. A provider home is carried as
/// evidence only: it comes from a shim or compatible backend that cannot be trusted to name the real
/// home, so it never separates conversations.
package struct AgentRuntimeOwnershipKeys: Equatable {
    package var sessionID: UUID?
    package var conversationID: String?
    package var provider: AgentRuntimeProvider?
    package var providerHome: String?
    package var worktreePath: String?

    package init(
        sessionID: UUID? = nil,
        conversationID: String?,
        provider: AgentRuntimeProvider? = nil,
        providerHome: String? = nil,
        worktreePath: String?
    ) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.provider = provider
        self.providerHome = providerHome
        self.worktreePath = worktreePath
    }
}

/// One runtime that restricts work, as projected for admission, scheduling and the recovery list.
package struct AgentRuntimeRestriction: Equatable, Identifiable {
    package enum Kind: Equatable {
        /// A possible conversation writer (reserved, live or unresolved) not owned by an active
        /// launch of this app.
        case possibleWriter
        /// Only positively identified tools remain: the worktree stays busy for automatic work.
        case toolsOnly
    }

    package let runtimeID: UUID
    package let kind: Kind
    /// `nil` for preserved (unreadable) records.
    package let family: AgentRuntimeFamily?
    /// `nil` when unknown (unreadable or earlier draft records): overlaps conservatively.
    package let provider: AgentRuntimeProvider?
    package let state: AgentRuntimeRecord.State
    package let isPreviousInstance: Bool
    package let isUnreadable: Bool
    package let providerHome: String?
    package let conversationIDs: [String]
    package let worktreePaths: [String]
    /// Managed sessions associated with the runtime (any run attempt, incarnation or reset).
    package let sessionIDs: [UUID]
    /// Operation-bound associations (sessions, attempts, conversations, requested permissions);
    /// empty for unreadable records.
    package let associations: [AgentRuntimeAssociation]
    package let rootPID: Int32?
    /// 9-live S5: the first recorded writer member that isn't the root (the CLI under a launcher
    /// shim), so the item can name the agent's own PID; `nil` when unknown or equal to the root.
    package let writerPID: Int32?
    package let memberCount: Int
    package let letFinish: Bool
    package let revision: AgentRecoveryRecordRevision?
    package let createdAt: AgentRecoveryTimestamp?

    package var id: UUID {
        runtimeID
    }

    package init(
        runtimeID: UUID,
        kind: Kind,
        family: AgentRuntimeFamily?,
        provider: AgentRuntimeProvider?,
        state: AgentRuntimeRecord.State,
        isPreviousInstance: Bool,
        isUnreadable: Bool,
        providerHome: String?,
        conversationIDs: [String],
        worktreePaths: [String],
        sessionIDs: [UUID],
        associations: [AgentRuntimeAssociation],
        rootPID: Int32?,
        writerPID: Int32? = nil,
        memberCount: Int,
        letFinish: Bool,
        revision: AgentRecoveryRecordRevision?,
        createdAt: AgentRecoveryTimestamp?
    ) {
        self.runtimeID = runtimeID
        self.kind = kind
        self.family = family
        self.provider = provider
        self.state = state
        self.isPreviousInstance = isPreviousInstance
        self.isUnreadable = isUnreadable
        self.providerHome = providerHome
        self.conversationIDs = conversationIDs
        self.worktreePaths = worktreePaths
        self.sessionIDs = sessionIDs
        self.associations = associations
        self.rootPID = rootPID
        self.writerPID = writerPID == rootPID ? nil : writerPID
        self.memberCount = memberCount
        self.letFinish = letFinish
        self.revision = revision
        self.createdAt = createdAt
    }

    func overlapsConversation(_ keys: AgentRuntimeOwnershipKeys) -> Bool {
        guard let conversationID = keys.conversationID, conversationIDs.contains(conversationID) else { return false }
        // Distinct known providers are distinct conversation keys; unknown ones overlap. Provider homes
        // are untrusted evidence and never separate conversations.
        if let provider, let other = keys.provider, provider != other { return false }
        return true
    }

    /// The same managed session, whatever its run attempt, incarnation or transcript reset: a reset
    /// never evades a still-unresolved owner.
    func overlapsSession(_ keys: AgentRuntimeOwnershipKeys) -> Bool {
        guard let sessionID = keys.sessionID else { return false }
        return sessionIDs.contains(sessionID)
    }

    func overlapsWorktree(_ keys: AgentRuntimeOwnershipKeys) -> Bool {
        guard let path = keys.worktreePath else { return false }
        return worktreePaths.contains { AgentRuntimePaths.overlap($0, path) }
    }

    /// Blocks every send to the session: a possible writer of its conversation or associated with the
    /// session itself (even before a native conversation is known), or an unassociated possible
    /// writer on its worktree (its conversation is not yet known).
    func blocksSend(_ keys: AgentRuntimeOwnershipKeys) -> Bool {
        guard kind == .possibleWriter else { return false }
        if overlapsConversation(keys) || overlapsSession(keys) { return true }
        return conversationIDs.isEmpty && overlapsWorktree(keys)
    }

    /// Blocks automatic (scheduled) work: any send block, or any restricting runtime on the worktree.
    func blocksAutomaticWork(_ keys: AgentRuntimeOwnershipKeys) -> Bool {
        blocksSend(keys) || overlapsWorktree(keys)
    }
}

/// Main-actor-readable projection of the registry's current restrictions.
package struct AgentRuntimeRestrictionSnapshot: Equatable {
    package var restrictions: [AgentRuntimeRestriction]
    /// Unreadable runtime records whose ownership cannot be scoped.
    package var unidentifiedRecordCount: Int
    /// The runtime directory could not be listed.
    package var storageFailure: String?

    package init(restrictions: [AgentRuntimeRestriction] = [], unidentifiedRecordCount: Int = 0, storageFailure: String? = nil) {
        self.restrictions = restrictions
        self.unidentifiedRecordCount = unidentifiedRecordCount
        self.storageFailure = storageFailure
    }

    package static let empty = AgentRuntimeRestrictionSnapshot()

    /// Ownership is unknowable for every conversation: a visible global warning, and no
    /// ownership-dependent work is admitted.
    package var hasGlobalUncertainty: Bool {
        unidentifiedRecordCount > 0 || storageFailure != nil
    }

    package func sendRestriction(for keys: AgentRuntimeOwnershipKeys) -> AgentRuntimeRestriction? {
        restrictions.first { $0.blocksSend(keys) }
    }

    package func blocksSend(_ keys: AgentRuntimeOwnershipKeys) -> Bool {
        hasGlobalUncertainty || sendRestriction(for: keys) != nil
    }

    package func blocksAutomaticWork(_ keys: AgentRuntimeOwnershipKeys) -> Bool {
        hasGlobalUncertainty || restrictions.contains { $0.blocksAutomaticWork(keys) }
    }
}

// MARK: - Crash-hold exit proof (Step 9-activation-b)

/// What Check and resolve asks the registry before it confirms one crash hold from process records:
/// the held session, the held run attempts, and what the session touches (from the windows hosting
/// it; the registry adds every conversation and worktree its own associations name for the session).
package struct AgentRuntimeCrashHoldExitQuery: Equatable {
    package var sessionID: UUID
    package var incarnationID: UUID
    package var runAttemptIDs: Set<UUID>
    package var conversationIDs: Set<String>
    package var worktreePaths: [String]
    /// The recovery store's app instance (this launch): every record of another instance is an
    /// earlier launch's. A registry over a store of another instance cannot answer (F8).
    package var currentAppInstanceID: UUID

    package init(
        sessionID: UUID,
        incarnationID: UUID,
        runAttemptIDs: Set<UUID>,
        conversationIDs: Set<String>,
        worktreePaths: [String],
        currentAppInstanceID: UUID
    ) {
        self.sessionID = sessionID
        self.incarnationID = incarnationID
        self.runAttemptIDs = runAttemptIDs
        self.conversationIDs = conversationIDs
        self.worktreePaths = worktreePaths
        self.currentAppInstanceID = currentAppInstanceID
    }
}

/// The registry's answer to `AgentRuntimeCrashHoldExitQuery`, checked in this order. Only `.proven`
/// lets Check confirm the hold. `.exited` and `.stopped` are terminal and never re-examined, so a
/// stale answer can only refuse, never confirm.
package enum AgentRuntimeCrashHoldExitProof: Equatable {
    /// Every earlier-launch record that could belong to the session is exited or stopped, and each
    /// held run attempt is named by at least one earlier-launch record.
    case proven
    /// Ownership can't be read: not started, storage failure, unidentified records, an unreadable
    /// record naming the session or what it touches, or a store of another app instance.
    case ownershipUncertain
    /// An earlier-launch record that names the session (any incarnation), names no session, or shares
    /// one of the session's conversations or worktrees is not exited or stopped (tools included).
    case mayBeRunning
    /// A held run attempt is named by no earlier-launch record.
    case runNotRecorded
}

enum AgentRuntimePaths {
    static func standardized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// Equal, ancestor or descendant paths overlap.
    static func overlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = standardized(lhs)
        let right = standardized(rhs)
        if left == right { return true }
        return left.hasPrefix(right == "/" ? "/" : right + "/") || right.hasPrefix(left == "/" ? "/" : left + "/")
    }
}

// MARK: - Errors and results

package enum AgentProcessRegistryError: Error, Equatable {
    /// Phase 3 registration is not active (no launch should have reached the registry).
    case registrationInactive
    /// Another possible writer holds this conversation, or ownership is unknowable.
    case ownershipConflict(runtimeID: UUID?)
    /// Runtime ownership cannot be established (unreadable store, global uncertainty).
    case ownershipUnknown
    /// An Agent Mode operation's durable session context could not be established; it is never
    /// registered as sessionless.
    case sessionContextUnavailable
    /// The launch token is no longer current (superseded, reaped or failed).
    case staleLaunch
    /// The spawned child's birth identity could not be established.
    case identityUnavailable
    /// This family/provider pair has no complete-discovery qualification: the launch is refused
    /// before its spawn (no unregistered fallback).
    case unqualifiedProvider
    /// Restart safely sealed new launches before proving every family stopped (held to exit).
    case launchesSealed
    case storage(String)
}

package struct AgentRuntimeStopPreview: Equatable {
    package struct Member: Equatable {
        package let identity: AgentRuntimeProcessIdentity
        package let processGroupID: Int32?
        package let role: AgentRuntimeMember.Role
    }

    package let runtimeID: UUID
    package let revision: AgentRecoveryRecordRevision
    package let members: [Member]
    package let isComplete: Bool
}

package enum AgentRuntimeStopResult: Equatable {
    /// Recovered Stop is disabled (no qualified signalling actions).
    case disabled
    /// The family was verified gone after signalling.
    case stopped
    /// The runtime or its membership changed since the preview; nothing (further) was signalled.
    case changed
    /// A group contained an unknown/unowned member, the app itself, or had no verified group.
    case refusedUnsafeGroup
    /// Signalling failed (`EPERM`) or survivors/uncertainty remain.
    case unresolved
}
