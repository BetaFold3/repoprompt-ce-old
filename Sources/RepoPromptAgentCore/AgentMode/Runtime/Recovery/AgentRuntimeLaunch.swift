import Darwin
import Foundation
import OSLog
import RepoPromptPlatform

/// Everything a managed launch knows about what it is for, captured when the launch is made: the
/// transport family, the actual provider, the managed session (or explicit sessionless work), the
/// worktree, a requested conversation and the requested permission configuration.
package struct AgentRuntimeLaunchContext: Hashable {
    package var family: AgentRuntimeFamily
    package var provider: AgentRuntimeProvider
    package var session: AgentRuntimeSessionScope
    package var worktreePath: String?
    package var conversationID: String?
    package var permission: AgentRuntimePermissionSnapshot

    package init(
        family: AgentRuntimeFamily,
        provider: AgentRuntimeProvider,
        session: AgentRuntimeSessionScope,
        worktreePath: String?,
        conversationID: String? = nil,
        permission: AgentRuntimePermissionSnapshot
    ) {
        self.family = family
        self.provider = provider
        self.session = session
        self.worktreePath = worktreePath
        self.conversationID = conversationID
        self.permission = permission
    }
}

/// R6 operation ownership on reused transports. An operation's OWNER (the run, steering
/// admission, slash command or user action that starts it) captures its managed session scope
/// once, synchronously when it starts the operation (the lane's lifecycle plus the run attempt and
/// process run current at that moment), and binds it for the operation's whole task tree. The
/// value is immutable for that operation: child tasks inherit it, a late callback or retry keeps
/// the scope its owner captured, and nothing is re-read from the session at write time, so an old
/// operation can never be retargeted to whichever run is current when it writes. `Task.detached`
/// work re-binds the value it captured. With no binding, no owner captured a scope: associating
/// writes fail closed (`.unavailable`) under registration.
///
/// Only owner operations associate (launch reservations, thread/session creation and resume, user
/// turns, steering, thread writes, requested permission changes). Callbacks and control writes
/// that create no ownership (interrupts, replies to runtime-initiated requests, live settings)
/// never associate: they only pass the write fence on an already-associated conversation.
package enum AgentRuntimeOperationOwner {
    @TaskLocal package static var session: AgentRuntimeSessionScope?
    /// Optional recheck that the operation's owner (for example a dispatch reservation) still
    /// authorizes execution. A managed transport evaluates it once, after its registry fence awaits
    /// and immediately before the bytes; capturing the owner for attribution is not this check.
    /// The argument is whether the writing transport's own launch is eligible to carry an outbound
    /// user-message identity (evaluated by the transport before the await); the result is the one
    /// verdict the transport acts on.
    @TaskLocal package static var writeAdmission: (@Sendable (_ outboundIdentityEligible: Bool) async -> AgentRuntimeWriteAdmission)?

    /// The owner-captured scope of the running operation, `.unavailable` when none was bound.
    package static var current: AgentRuntimeSessionScope {
        session ?? .unavailable
    }
}

/// Verdict of one operation's `writeAdmission`.
package enum AgentRuntimeWriteAdmission: Equatable {
    /// The owner no longer authorizes the write: zero bytes (a proven non-write).
    case denied
    /// Write. `outboundUserMessageUUID` is non-nil only when this exact admission newly committed a
    /// baseline claiming that UUID (built-in Claude only); every other admitted write omits it.
    case admitted(outboundUserMessageUUID: UUID?)

    /// An ordinary admitted write carrying no outbound identity.
    package static let admittedWithoutIdentity = AgentRuntimeWriteAdmission.admitted(outboundUserMessageUUID: nil)
}

/// Where managed launch owners obtain launch ownership. Production resolves to
/// `.activationOff` while `AgentRecoveryActivation.production` covers no pair; tests inject a
/// registry with fixture qualification. Not configurable by environment or defaults.
package enum AgentRuntimeLaunchAuthority {
    /// Phase 1/2 behavior: no reservation, marker or fence. Inherited markers are still stripped
    /// at managed launch boundaries.
    case activationOff
    case registry(AgentProcessRegistry)

    package static var production: AgentRuntimeLaunchAuthority {
        guard let registry = AgentProcessRegistry.production, registry.isAnyPairRegistered else { return .activationOff }
        return .registry(registry)
    }

    /// Whether launches of this exact family/provider pair are registered (callers skip gathering
    /// launch context otherwise). An uncovered pair launches unregistered, as before activation.
    package func isRegistrationActive(family: AgentRuntimeFamily, provider: AgentRuntimeProvider) -> Bool {
        guard case let .registry(registry) = self else { return false }
        return registry.isAnyPairRegistered && registry.qualification.covers(family: family, provider: provider)
    }

    /// One launch owner per actual spawn (each replacement or fallback launch gets a new runtime),
    /// or `nil` while registration is off or this pair is not covered (an unregistered launch).
    /// Once a launch owner exists, every later registration, storage, inspection, association or
    /// fence failure refuses the launch or write; nothing falls back to unregistered execution.
    package func makeLaunch(_ context: AgentRuntimeLaunchContext) -> AgentRuntimeLaunch? {
        guard case let .registry(registry) = self,
              isRegistrationActive(family: context.family, provider: context.provider)
        else { return nil }
        return AgentRuntimeLaunch(registry: registry, context: context)
    }

    /// The run-start registration mark (Step 9-activation-b) of a run started with `providerKindRaw`
    /// under this authority: `AgentRecoveryRunAttempt.registeredRuntimeRegistration` only when this
    /// is the registry and every supported family that can serve the run's actual provider is
    /// covered, so whichever route launches the run's processes registers them (fail closed: a
    /// registered launch never falls back to unregistered execution). `nil` while activation is off,
    /// for an uncovered or partially covered provider, and for an unknown provider. The one place the
    /// mark is derived; callers pass the authority their managed launchers use.
    package func runStartRegistrationMark(providerKindRaw: String?) -> String? {
        guard case let .registry(registry) = self, registry.isAnyPairRegistered,
              let providerKindRaw,
              let kind = AgentProviderKind(rawValue: providerKindRaw),
              let provider = AgentRuntimeProvider(agentKind: kind)
        else { return nil }
        let serving = AgentRuntimeQualification.supportedPairs.filter { $0.provider == provider }
        guard !serving.isEmpty,
              serving.allSatisfy({ registry.qualification.covers(family: $0.family, provider: provider) })
        else { return nil }
        return AgentRecoveryRunAttempt.registeredRuntimeRegistration
    }

    /// Whether fresh Claude `--session-id` preallocation is qualified for this actual provider (a
    /// separate gate; never combined with `--resume`).
    package func allowsFreshSessionID(_ family: AgentRuntimeFamily, provider: AgentRuntimeProvider) -> Bool {
        guard case let .registry(registry) = self else { return false }
        return registry.qualification.allowsFreshSessionID(family, provider: provider)
    }

    /// Managed launch environments never inherit a runtime marker from the app's own environment.
    package static func strippingInheritedMarker(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        environment.removeValue(forKey: ProcessLauncher.runtimeMarkerEnvironmentKey)
        return environment
    }
}

/// Ownership of one managed spawn: reservation before the spawn, birth commit before any write,
/// conversation association, write fences, and the captured root-reap event. Late callbacks
/// always refer to this exact runtime and launch token, never to whichever controller currently
/// serves the session.
package actor AgentRuntimeLaunch: ProcessLaunchOwnership {
    private let registry: AgentProcessRegistry
    package nonisolated let context: AgentRuntimeLaunchContext
    /// The most recently requested permission configuration (launch, then explicit changes).
    private var permission: AgentRuntimePermissionSnapshot
    private var reservation: (runtimeID: UUID, launchToken: UUID)?
    private var prepared = false

    init(registry: AgentProcessRegistry, context: AgentRuntimeLaunchContext) {
        self.registry = registry
        self.context = context
        permission = context.permission
    }

    package nonisolated var family: AgentRuntimeFamily {
        context.family
    }

    package var runtimeID: UUID? {
        reservation?.runtimeID
    }

    package func prepareSpawn() async throws -> UUID {
        guard !prepared else { throw AgentProcessRegistryError.staleLaunch }
        prepared = true
        // Admission waits for startup loading instead of refusing launches that race it.
        await registry.ensureStarted()
        let reserved = try await registry.reserveLaunch(context)
        reservation = reserved
        return reserved.runtimeID
    }

    package func spawnFailed() async {
        guard let reservation else { return }
        await registry.spawnFailed(runtimeID: reservation.runtimeID, launchToken: reservation.launchToken)
    }

    package func commitSpawn(pid: pid_t, processGroupID: pid_t?) async throws {
        guard let reservation else { throw AgentProcessRegistryError.staleLaunch }
        try await registry.registerSpawn(
            runtimeID: reservation.runtimeID,
            launchToken: reservation.launchToken,
            pid: pid,
            processGroupID: processGroupID
        )
    }

    package func rootReaped(pid: pid_t, confirmed: Bool) async {
        guard let reservation else { return }
        await registry.rootReaped(
            runtimeID: reservation.runtimeID,
            launchToken: reservation.launchToken,
            pid: pid,
            confirmed: confirmed
        )
    }

    /// Associates a native conversation of the launch's own session before any write to it; throws
    /// on a conflicting writer.
    package func associate(conversationID: String) async throws {
        try await associate(session: context.session, conversationID: conversationID)
    }

    /// Associates one operation on this (possibly reused) runtime before its write: the operation's
    /// own managed session and run attempt, the conversation it reaches (when known), its worktree
    /// and, when it requests one, a permission configuration (persisted before the request that
    /// changes it). An Agent Mode operation without session context is refused, never recorded as
    /// sessionless. Throws on a conflicting writer or when the association cannot be persisted.
    package func associate(
        session: AgentRuntimeSessionScope,
        conversationID: String? = nil,
        worktreePath: String? = nil,
        permission requested: AgentRuntimePermissionSnapshot? = nil
    ) async throws {
        guard let reservation else { throw AgentProcessRegistryError.staleLaunch }
        // A multi-thread transport (the Codex app server) never lends one thread's requested
        // permission to another: its unrequested fallback stays the launch's own.
        let fallback = context.family == .codexAppServer ? context.permission : permission
        try await registry.associate(
            runtimeID: reservation.runtimeID,
            launchToken: reservation.launchToken,
            association: association(
                session: session,
                conversationID: conversationID,
                worktreePath: worktreePath,
                permission: requested ?? fallback
            ),
            replacingPermission: requested != nil
        )
        if let requested { permission = requested }
    }

    /// Records the conversation a headless launcher observed in its runtime's final output (for
    /// example a fresh Claude `session_id`) for the launch's own session, even after the exact root
    /// was reaped. Never changes the run's outcome: a failure is reported here and returned.
    @discardableResult
    package func recordObservedConversation(_ conversationID: String) async -> Bool {
        guard let reservation else { return false }
        do {
            try await registry.recordObservedConversation(
                runtimeID: reservation.runtimeID,
                launchToken: reservation.launchToken,
                association: association(
                    session: context.session,
                    conversationID: conversationID,
                    worktreePath: nil,
                    permission: permission
                )
            )
            return true
        } catch {
            Self.logger.error(
                "Runtime \(reservation.runtimeID.uuidString, privacy: .public) could not record its observed conversation: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "AgentRuntimeLaunch")

    private func association(
        session: AgentRuntimeSessionScope,
        conversationID: String?,
        worktreePath: String?,
        permission: AgentRuntimePermissionSnapshot
    ) throws -> AgentRuntimeAssociation {
        let sessionAssociation: AgentRuntimeSessionAssociation?
        switch session {
        case .unavailable: throw AgentProcessRegistryError.sessionContextUnavailable
        case .sessionless: sessionAssociation = nil
        case let .session(association): sessionAssociation = association
        }
        return AgentRuntimeAssociation(
            session: sessionAssociation,
            conversationID: conversationID,
            worktreePath: (worktreePath ?? context.worktreePath).map(AgentRuntimePaths.standardized),
            permission: permission
        )
    }

    /// Fence before an outgoing protocol or user write.
    package func authorizeWrite(conversationID: String? = nil) async throws {
        guard let reservation else { throw AgentProcessRegistryError.staleLaunch }
        try await registry.authorizeWrite(
            runtimeID: reservation.runtimeID,
            launchToken: reservation.launchToken,
            conversationID: conversationID
        )
    }
}
