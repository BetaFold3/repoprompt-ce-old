import Darwin
import Foundation
import RepoPromptPlatform

/// The app's single runtime-ownership authority (spec R6): managed launch reservations, birth
/// registration, conversation association and write fences, family discovery and exit watches,
/// Let finish, and the (injected, production-disabled) Stop engine.
///
/// Durable state lives in `AgentRecoveryStore` runtime files; this actor alone decides it. Records
/// already on disk are enforced whether or not new registration is active, so existing evidence is
/// never ignored when qualification is unavailable. Nothing here polls, retires records or kills
/// anything automatically; root exit, a clean shutdown mark, an absent marker or denied inspection
/// never prove that a family exited.
package actor AgentProcessRegistry {
    /// Whether any supported pair registers (subset activation). Each launch also needs its own pair
    /// covered (`AgentRuntimeLaunchAuthority.isRegistrationActive(family:provider:)`).
    package nonisolated let isAnyPairRegistered: Bool
    package nonisolated let qualification: AgentRuntimeQualification

    private let store: AgentRecoveryStore
    private let system: AgentProcessSystem
    private let stopActions: AgentProcessStopActions?
    private let now: @Sendable () -> Date

    private var records: [UUID: AgentRuntimeRecord] = [:]
    /// Unreadable runtime files: preserved, never written, unknown ownership.
    private var preserved: [UUID: AgentRuntimePreservedBindings?] = [:]
    private var unidentifiedPreservedCount = 0
    private var storageFailure: String?
    /// Records whose latest classification could not be persisted: treated as unresolved.
    private var unpersisted: Set<UUID> = []
    private var hasStarted = false

    /// Current-instance launches still owned by a live launcher (token per runtime).
    private var activeLaunches: [UUID: UUID] = [:]
    /// Launches whose exact root this app reaped (write authority ended). A conversation the
    /// launcher observed in that root's final output may still be recorded for them.
    private var reapedLaunches: [UUID: UUID] = [:]
    /// The exact child each launch reported for its birth commit (set before the commit's awaits).
    /// A rootless reservation can only be resolved by its own launcher's confirmed reap of this pid.
    private var spawnedPIDs: [UUID: pid_t] = [:]
    /// Launches whose birth commit failed: no write authority, but their launcher still owns the
    /// exact child and must report its reap (token per runtime).
    private var uncommittedLaunches: [UUID: UUID] = [:]
    /// Restart safely (review A P1-08): once sealed, no new launch is reserved (sessionless probes
    /// included) for the rest of this process. Taken before the all-stopped proof, at R4 Stage B
    /// (past its point of no return, so Stage A's reversible Cancel never meets a seal); held through
    /// the helper's arm and the process exit. Never released.
    package private(set) var isSealedForSafeRestart = false

    private struct Watch {
        let identity: AgentRuntimeProcessIdentity
        let generation: UInt64
        let token: AgentProcessExitWatchToken
    }

    private var watches: [UUID: [Watch]] = [:]
    private var watchGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestedDuringPass = false
    /// History-lookup refreshes spent on each Claude runtime still missing its home (O42).
    private var homeRefreshAttempts: [UUID: Int] = [:]
    /// Claude runtimes where a pass observed a non-root writer with a readable environment and no
    /// `CLAUDE_CONFIG_DIR`: another refresh can't record a home for them.
    private var homeSettledRuntimeIDs: Set<UUID> = []
    static let maxHomeRefreshesPerRuntime = 3

    private var changeHandler: (@Sendable (AgentRuntimeRestrictionSnapshot) -> Void)?
    private var lastPublished: AgentRuntimeRestrictionSnapshot?

    package init(
        store: AgentRecoveryStore,
        qualification: AgentRuntimeQualification,
        system: AgentProcessSystem,
        stopActions: AgentProcessStopActions? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.qualification = qualification
        isAnyPairRegistered = qualification.activatesRegistration
        self.system = system
        self.stopActions = stopActions
        self.now = now
    }

    /// The production registry over the production store with the runtime qualification of
    /// `AgentRecoveryActivation.production` (while that is `.off`, registration stays off and only
    /// existing runtime records are enforced). `nil` in XCTest.
    package static let production: AgentProcessRegistry? = AgentRecoveryStore.production.map {
        AgentProcessRegistry(store: $0, qualification: AgentRecoveryActivation.production.runtime, system: .live)
    }

    package var isStopEnabled: Bool {
        stopActions != nil
    }

    // MARK: Publication

    /// Receives every changed restriction snapshot (from the registry's executor; hand it off).
    package func setChangeHandler(_ handler: (@Sendable (AgentRuntimeRestrictionSnapshot) -> Void)?) {
        changeHandler = handler
        lastPublished = nil
        if hasStarted { publish() }
    }

    package func restrictionSnapshot() -> AgentRuntimeRestrictionSnapshot {
        guard hasStarted else {
            return AgentRuntimeRestrictionSnapshot(storageFailure: "Runtime ownership has not been checked yet.")
        }
        var restrictions: [AgentRuntimeRestriction] = []
        for record in records.values.sorted(by: { $0.runtimeID.uuidString < $1.runtimeID.uuidString }) {
            let isActive = activeLaunches[record.runtimeID] != nil
            let unresolved = unpersisted.contains(record.runtimeID)
            let kind: AgentRuntimeRestriction.Kind
            let mayHoldWriter = record.state.mayHoldWriter || unresolved
            if mayHoldWriter, !isActive {
                kind = .possibleWriter
            } else if record.state == .toolsRemaining {
                kind = .toolsOnly
            } else {
                continue
            }
            restrictions.append(Self.restriction(
                for: record,
                kind: kind,
                state: unresolved ? .unknown : record.state,
                isPreviousInstance: record.appInstanceID != store.appInstanceID
            ))
        }
        for (runtimeID, bindings) in preserved.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let bindings else { continue }
            restrictions.append(AgentRuntimeRestriction(
                runtimeID: runtimeID,
                kind: .possibleWriter,
                family: nil,
                provider: nil,
                state: .unknown,
                isPreviousInstance: true,
                isUnreadable: true,
                providerHome: nil,
                conversationIDs: bindings.conversationIDs,
                worktreePaths: bindings.worktreePaths,
                sessionIDs: bindings.sessionIDs,
                associations: [],
                rootPID: nil,
                memberCount: 0,
                letFinish: false,
                revision: nil,
                createdAt: nil
            ))
        }
        let unidentified = unidentifiedPreservedCount + preserved.values.count { $0 == nil }
        return AgentRuntimeRestrictionSnapshot(
            restrictions: restrictions,
            unidentifiedRecordCount: unidentified,
            storageFailure: storageFailure
        )
    }

    /// Step 9-activation-b: whether process records prove that nothing an earlier launch started for
    /// `query`'s session can still be running, and that each held run attempt was registered there.
    /// Current-instance records are this launch's own processes (a Codex Reconcile, for example,
    /// associates the held attempt in this launch): they neither block nor count. An earlier-launch
    /// record whose classification could not be persisted counts as not exited.
    package func crashHoldExitProof(_ query: AgentRuntimeCrashHoldExitQuery) -> AgentRuntimeCrashHoldExitProof {
        let current = store.appInstanceID
        guard hasStarted, storageFailure == nil, current == query.currentAppInstanceID,
              unidentifiedPreservedCount == 0, !preserved.values.contains(where: { $0 == nil })
        else { return .ownershipUncertain }
        let earlier = records.values.filter { $0.appInstanceID != current }
        // What the session touches: the caller's keys plus, for every record (any launch) with an
        // association naming this session (any incarnation), that association's keys and the
        // record's own conversations and worktrees (keys set at reservation, before an association
        // carried them).
        var conversations = query.conversationIDs
        var worktrees = query.worktreePaths
        for record in records.values {
            let naming = record.associations.filter { $0.session?.sessionID == query.sessionID }
            guard !naming.isEmpty else { continue }
            conversations.formUnion(naming.compactMap(\.conversationID) + record.conversationIDs)
            worktrees.append(contentsOf: naming.compactMap(\.worktreePath) + record.worktreePaths)
        }
        func touchesSession(conversationIDs: [String], worktreePaths: [String]) -> Bool {
            conversationIDs.contains(where: conversations.contains)
                || worktreePaths.contains { path in worktrees.contains { AgentRuntimePaths.overlap($0, path) } }
        }
        // An unreadable record naming the session or what it touches: its state is unknowable.
        let unreadableTouchesSession = preserved.values.compactMap(\.self).contains { bindings in
            bindings.sessionIDs.contains(query.sessionID)
                || touchesSession(conversationIDs: bindings.conversationIDs, worktreePaths: bindings.worktreePaths)
        }
        if unreadableTouchesSession { return .ownershipUncertain }
        for record in earlier {
            let terminal = (record.state == .exited || record.state == .stopped) && !unpersisted.contains(record.runtimeID)
            guard !terminal else { continue }
            let relevant = record.associations.isEmpty
                || record.associations.contains { $0.session == nil || $0.session?.sessionID == query.sessionID }
                || touchesSession(conversationIDs: record.conversationIDs, worktreePaths: record.worktreePaths)
            if relevant { return .mayBeRunning }
        }
        for runAttemptID in query.runAttemptIDs {
            let named = earlier.contains { record in
                record.associations.contains {
                    $0.session?.sessionID == query.sessionID
                        && $0.session?.incarnationID == query.incarnationID
                        && $0.session?.runAttemptID == runAttemptID
                }
            }
            if !named { return .runNotRecorded }
        }
        return .proven
    }

    private static func restriction(
        for record: AgentRuntimeRecord,
        kind: AgentRuntimeRestriction.Kind,
        state: AgentRuntimeRecord.State,
        isPreviousInstance: Bool
    ) -> AgentRuntimeRestriction {
        AgentRuntimeRestriction(
            runtimeID: record.runtimeID,
            kind: kind,
            family: record.family,
            provider: record.provider,
            state: state,
            isPreviousInstance: isPreviousInstance,
            isUnreadable: false,
            providerHome: record.providerHome,
            conversationIDs: record.conversationIDs,
            worktreePaths: record.worktreePaths,
            sessionIDs: sessionIDs(of: record),
            associations: record.associations,
            rootPID: record.root?.pid,
            writerPID: record.members.first { $0.role == .writer && $0.identity != record.root }?.identity.pid,
            memberCount: record.members.count,
            letFinish: record.letFinish,
            revision: record.revision,
            createdAt: record.createdAt
        )
    }

    /// Managed sessions named by a record's associations, once each, in association order.
    private static func sessionIDs(of record: AgentRuntimeRecord) -> [UUID] {
        var seen: Set<UUID> = []
        return record.associations.compactMap(\.session?.sessionID).filter { seen.insert($0).inserted }
    }

    private func publish() {
        let snapshot = restrictionSnapshot()
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        changeHandler?(snapshot)
    }

    // MARK: Startup and discovery

    /// Loads every runtime record and runs one discovery pass before returning (startup runs this
    /// before recovery admission opens). Idempotent: later calls refresh.
    @discardableResult
    package func start() async -> AgentRuntimeRestrictionSnapshot {
        if !hasStarted {
            loadRecords()
            hasStarted = true
        }
        await refresh()
        return restrictionSnapshot()
    }

    /// Launch admission waits for startup loading (and its first discovery pass) instead of
    /// refusing launches that race recovery startup.
    package func ensureStarted() async {
        guard !hasStarted else { return }
        await start()
    }

    /// The explicit Refresh action: retries a failed runtime-directory read and unreadable records
    /// (merging into, never replacing, in-memory ownership), then runs one discovery pass. Global
    /// uncertainty clears only after a successful read.
    @discardableResult
    package func refreshRetryingStorage() async -> AgentRuntimeRestrictionSnapshot {
        if hasStarted, storageFailure != nil || !preserved.isEmpty || unidentifiedPreservedCount > 0 {
            reloadRecords()
        }
        await refresh()
        return restrictionSnapshot()
    }

    private func reloadRecords() {
        let entries: [AgentRuntimeDiscoveryEntry]
        do {
            entries = try store.discoverRuntimes()
        } catch {
            recordStorageFailure(error)
            publish()
            return
        }
        var nextPreserved: [UUID: AgentRuntimePreservedBindings?] = [:]
        var nextUnidentified = 0
        for entry in entries {
            switch entry {
            case let .supported(record):
                // In-memory records (active launches, newer revisions) stay authoritative.
                if records[record.runtimeID] == nil { records[record.runtimeID] = record }
            case let .preserved(runtimeID, _, bindings):
                if let runtimeID {
                    if records[runtimeID] == nil { nextPreserved[runtimeID] = bindings }
                } else {
                    nextUnidentified += 1
                }
            }
        }
        preserved = nextPreserved
        unidentifiedPreservedCount = nextUnidentified
        storageFailure = nil
    }

    /// Keeps the raw read failure (never shown to the user) and logs it only on a transition: when a
    /// failure first appears or its description changes, not on every failed refresh.
    private func recordStorageFailure(_ error: Error) {
        let next = String(describing: error)
        if next != storageFailure {
            AgentRecoveryFailureDiagnostics.runtimeRecordsUnreadable(error)
        }
        storageFailure = next
    }

    private func loadRecords() {
        do {
            for entry in try store.discoverRuntimes() {
                switch entry {
                case let .supported(record):
                    records[record.runtimeID] = record
                case let .preserved(runtimeID, _, bindings):
                    if let runtimeID {
                        preserved[runtimeID] = bindings
                    } else {
                        unidentifiedPreservedCount += 1
                    }
                }
            }
        } catch {
            recordStorageFailure(error)
        }
    }

    /// One coalesced discovery pass over every unresolved runtime. A request arriving during a
    /// pass schedules exactly one further pass. Callers awaiting it see the pass that covers them.
    package func refresh() async {
        if let running = refreshTask {
            refreshRequestedDuringPass = true
            await running.value
            if let next = refreshTask { await next.value }
            return
        }
        let task = Task { await self.runRefreshPasses() }
        refreshTask = task
        await task.value
    }

    private func requestRefreshFromEvent() {
        if refreshTask != nil {
            refreshRequestedDuringPass = true
            return
        }
        refreshTask = Task { await self.runRefreshPasses() }
    }

    private func runRefreshPasses() async {
        repeat {
            refreshRequestedDuringPass = false
            await discoveryPass()
        } while refreshRequestedDuringPass
        refreshTask = nil
        publish()
    }

    private func discoveryPass() async {
        let candidates = records.values.filter { record in
            switch record.state {
            case .exited, .stopped: false
            case .reserved, .live, .unknown, .detachedAtQuit, .toolsRemaining: true
            }
        }
        guard !candidates.isEmpty else {
            cancelAllWatches(except: [])
            return
        }
        let inventory = await system.inventory()
        var watchedIdentities: [UUID: [AgentRuntimeProcessIdentity]] = [:]
        for candidate in candidates.sorted(by: { $0.runtimeID.uuidString < $1.runtimeID.uuidString }) {
            // Re-read: an awaited step may have changed it.
            guard let record = records[candidate.runtimeID] else { continue }
            let family = await discoverFamily(of: record, inventory: inventory)
            guard let current = records[record.runtimeID], current.revision == record.revision else {
                // Changed while discovering (association, reap, Let finish): the next pass covers it.
                refreshRequestedDuringPass = true
                continue
            }
            if family.observedHomelessWriter { homeSettledRuntimeIDs.insert(current.runtimeID) }
            var next = current
            next.members = family.members
            if next.providerHome == nil { next.providerHome = family.providerHome }
            next.state = classify(current, family: family)
            watchedIdentities[current.runtimeID] = family.aliveIdentities
            persistIfChanged(next, previous: current)
        }
        cancelAllWatches(except: Set(watchedIdentities.keys))
        for (runtimeID, identities) in watchedIdentities {
            await installWatches(runtimeID: runtimeID, identities: identities)
        }
    }

    // MARK: Family discovery and classification

    struct FamilyObservation {
        var members: [AgentRuntimeMember]
        var aliveIdentities: [AgentRuntimeProcessIdentity]
        var rootAlive: Bool?
        /// The root's freshly observed process group (`nil` when unreadable or not observed).
        var rootGroup: Int32?
        var writerAlive: Bool
        var toolAlive: Bool
        var isComplete: Bool
        var providerHome: String?
        /// A Claude family's non-root writer was observed with a readable environment and no home.
        var observedHomelessWriter = false
    }

    private enum Lifetime {
        case alive(ProcessObservation)
        case gone
        case unknown
    }

    private func lifetime(of identity: AgentRuntimeProcessIdentity) async -> Lifetime {
        switch await system.inspect(identity.pid) {
        case .notFound:
            .gone
        case .unavailable:
            .unknown
        case let .observed(observation):
            // A different boot session or a different birth identity proves this lifetime ended
            // (not its family). Supporting fields never decide it.
            Self.identity(of: observation) == identity ? .alive(observation) : .gone
        }
    }

    static func identity(of observation: ProcessObservation) -> AgentRuntimeProcessIdentity {
        AgentRuntimeProcessIdentity(
            bootSessionID: observation.identity.bootSessionID,
            pid: observation.identity.pid,
            startSeconds: observation.identity.startSeconds,
            startMicroseconds: observation.identity.startMicroseconds,
            uid: observation.identity.uid
        )
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func discoverFamily(of record: AgentRuntimeRecord, inventory: ProcessInventorySnapshot) async -> FamilyObservation {
        let familyQualification = qualification.qualification(family: record.family, provider: record.provider)
        var decisive = inventory.isComplete && familyQualification?.supportsCompleteDiscovery == true
        var membersByIdentity: [AgentRuntimeProcessIdentity: (role: AgentRuntimeMember.Role, group: Int32?)] = [:]
        var observationsByIdentity: [AgentRuntimeProcessIdentity: ProcessObservation] = [:]
        var rootAlive: Bool?
        var rootGroup: Int32?

        // 1. Recorded lifetimes: the root (always a writer/launcher) and previously observed members.
        if let root = record.root {
            switch await lifetime(of: root) {
            case let .alive(observation):
                rootAlive = true
                rootGroup = Self.group(of: observation)
                membersByIdentity[root] = (.writer, Self.group(of: observation) ?? record.rootProcessGroupID)
                observationsByIdentity[root] = observation
            case .gone:
                rootAlive = false
            case .unknown:
                decisive = false
                membersByIdentity[root] = (.writer, record.rootProcessGroupID)
            }
        }
        for member in record.members {
            switch await lifetime(of: member.identity) {
            case let .alive(observation):
                membersByIdentity[member.identity] = (member.role, Self.group(of: observation) ?? member.processGroupID)
                observationsByIdentity[member.identity] = observation
            case .gone:
                continue
            case .unknown:
                // Unresolved lifetime keeps its recorded role (a writer is never demoted).
                decisive = false
                membersByIdentity[member.identity] = (member.role, member.processGroupID)
            }
        }

        // 2. New members from one inventory: matching marker, or a child of a known member.
        let observations = inventory.observations.filter { $0.identity.pid != system.appPID }
        var changed = true
        while changed {
            changed = false
            for observation in observations {
                let identity = Self.identity(of: observation)
                guard membersByIdentity[identity] == nil else { continue }
                let markerMatches: Bool = if case let .available(environment) = observation.environment {
                    environment.runtimeID == record.runtimeID
                } else {
                    false
                }
                let parentIsMember = membersByIdentity.keys.contains { parent in
                    parent.pid == observation.parentPID
                        && parent.bootSessionID == identity.bootSessionID
                        && (parent.startSeconds, parent.startMicroseconds) <= (identity.startSeconds, identity.startMicroseconds)
                }
                guard markerMatches || parentIsMember else { continue }
                membersByIdentity[identity] = (classifyNewMember(observation, record: record), Self.group(of: observation))
                observationsByIdentity[identity] = observation
                changed = true
            }
        }
        // An unidentified process whose ownership evidence (its marker) is unreadable may be a
        // reparented member of this family: the inventory saw it, but discovery cannot rule it out.
        // Two exceptions only exclude a non-member; neither is exit evidence for any family member:
        // an unidentified zombie has already exited (its own children are separate observations),
        // and a process born before this family could exist cannot descend from it.
        if decisive, observations.contains(where: { observation in
            guard membersByIdentity[Self.identity(of: observation)] == nil else { return false }
            if case .available = observation.environment { return false }
            if observation.isZombie || predatesFamily(observation, record: record) { return false }
            return true
        }) {
            decisive = false
        }

        // 3. Reclassify observed members: an exec into a writer upgrades a tool or an unknown member;
        // nothing demotes.
        for (identity, entry) in membersByIdentity {
            guard let observation = observationsByIdentity[identity] else { continue }
            let observed = classifyNewMember(observation, record: record)
            if (entry.role == .tool && observed != .tool) || (entry.role == .unknown && observed == .writer) {
                membersByIdentity[identity] = (observed, entry.group)
            }
        }
        let providerHome = Self.isClaude(record.family)
            ? Self.closestWriterHome(
                root: record.root,
                roles: membersByIdentity.mapValues(\.role),
                observations: observationsByIdentity
            )
            : nil
        // Settles the home lookup only for a writer that home attribution would accept (same
        // ancestry rule): a nested or uncertain-ancestry homeless writer never ends the retries.
        let observedHomelessWriter = Self.isClaude(record.family) && Self.rootLinkedWriters(
            root: record.root,
            roles: membersByIdentity.mapValues(\.role),
            observations: observationsByIdentity
        ).contains { writer in
            guard case let .available(environment) = writer.observation.environment else { return false }
            return (environment.claudeConfigDirectory ?? "").isEmpty
        }

        let root = record.root
        let members = membersByIdentity
            .filter { $0.key != root }
            .map { AgentRuntimeMember(identity: $0.key, processGroupID: $0.value.group, role: $0.value.role) }
            .sorted { ($0.identity.pid, $0.identity.startSeconds) < ($1.identity.pid, $1.identity.startSeconds) }
        // Keep extras of members that persist.
        let mergedMembers = members.map { member -> AgentRuntimeMember in
            guard let previous = record.members.first(where: { $0.identity == member.identity }) else { return member }
            var merged = member
            merged.extras = previous.extras
            return merged
        }
        return FamilyObservation(
            members: mergedMembers,
            aliveIdentities: Array(membersByIdentity.keys),
            rootAlive: rootAlive,
            rootGroup: rootGroup,
            writerAlive: membersByIdentity.values.contains { $0.role != .tool },
            toolAlive: membersByIdentity.values.contains { $0.role == .tool },
            isComplete: decisive,
            providerHome: providerHome,
            observedHomelessWriter: observedHomelessWriter
        )
    }

    /// Wall-clock allowance for birth ordering: process start times and `createdAt` are both wall
    /// clock, which can step. Only a process started more than this before the anchor counts.
    static let birthOrderingMarginSeconds: UInt64 = 300

    /// A process born (same boot) more than the margin before this family could exist: before the
    /// committed root's birth, or, for a rootless reservation made by this app instance (hence this
    /// boot), before the reservation's `createdAt`. It cannot be a descendant of this family. This only
    /// excludes a non-member from discovery; it never proves any lifetime or the family exited.
    private func predatesFamily(_ observation: ProcessObservation, record: AgentRuntimeRecord) -> Bool {
        let anchorSeconds: UInt64
        if let root = record.root {
            guard observation.identity.bootSessionID == root.bootSessionID else { return false }
            anchorSeconds = root.startSeconds
        } else {
            guard record.appInstanceID == store.appInstanceID, record.createdAt.millisecondsSince1970 > 0 else { return false }
            anchorSeconds = UInt64(record.createdAt.millisecondsSince1970 / 1000)
        }
        guard anchorSeconds > Self.birthOrderingMarginSeconds else { return false }
        return observation.identity.startSeconds < anchorSeconds - Self.birthOrderingMarginSeconds
    }

    private func classifyNewMember(_ observation: ProcessObservation, record: AgentRuntimeRecord) -> AgentRuntimeMember.Role {
        guard let familyQualification = qualification.qualification(family: record.family, provider: record.provider),
              case let .available(path) = observation.executablePath
        else { return .unknown }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        if familyQualification.writerExecutableBasenames.contains(basename) { return .writer }
        // O42: the native-installer Claude CLI runs from `…/claude/versions/<version>` (basename is the
        // version). Only in a Claude family and only with this family's own marker, so a non-Claude
        // descendant at a similar path never becomes a writer.
        if Self.isClaude(record.family), Self.isClaudeNativeInstallerExecutable(path),
           case let .available(environment) = observation.environment, environment.runtimeID == record.runtimeID
        {
            return .writer
        }
        // Only explicit, qualified tool evidence makes a tool; anything unmatched stays unknown.
        guard familyQualification.toolExecutableBasenames.contains(basename), case .available = observation.environment else {
            return .unknown
        }
        return .tool
    }

    /// The `CLAUDE_CONFIG_DIR` of the writer closest to the root (O42): the root's own, else that of
    /// the earliest-born writer whose nearest writer ancestor, following observed parent links, is
    /// the root (the CLI a shim starts). A writer under another non-root writer (a nested `claude`
    /// a tool ran) never supplies it, nor does one whose parent chain doesn't reach the root.
    static func closestWriterHome(
        root: AgentRuntimeProcessIdentity?,
        roles: [AgentRuntimeProcessIdentity: AgentRuntimeMember.Role],
        observations: [AgentRuntimeProcessIdentity: ProcessObservation]
    ) -> String? {
        func home(_ observation: ProcessObservation) -> String? {
            guard case let .available(environment) = observation.environment,
                  let directory = environment.claudeConfigDirectory, !directory.isEmpty
            else { return nil }
            return directory
        }
        guard let root else { return nil }
        if let observation = observations[root], let directory = home(observation) { return directory }
        return rootLinkedWriters(root: root, roles: roles, observations: observations)
            .lazy.compactMap { home($0.observation) }
            .first
    }

    /// Observed non-root writers whose nearest writer ancestor, following observed parent links, is
    /// the root, earliest-born first. Only a positively qualified tool is traversed on the way up.
    static func rootLinkedWriters(
        root: AgentRuntimeProcessIdentity?,
        roles: [AgentRuntimeProcessIdentity: AgentRuntimeMember.Role],
        observations: [AgentRuntimeProcessIdentity: ProcessObservation]
    ) -> [(identity: AgentRuntimeProcessIdentity, observation: ProcessObservation)] {
        guard let root else { return [] }
        func parent(of identity: AgentRuntimeProcessIdentity) -> AgentRuntimeProcessIdentity? {
            guard let observation = observations[identity] else { return nil }
            return roles.keys.first { candidate in
                candidate != identity && candidate.pid == observation.parentPID
                    && candidate.bootSessionID == identity.bootSessionID
                    && (candidate.startSeconds, candidate.startMicroseconds) <= (identity.startSeconds, identity.startMicroseconds)
            }
        }
        func nearestWriterAncestorIsRoot(_ identity: AgentRuntimeProcessIdentity) -> Bool {
            var current = identity
            for _ in 0 ..< roles.count {
                guard let next = parent(of: current) else { return false }
                if next == root { return true }
                // A writer or an unknown member (possibly the real CLI, still unreadable) between
                // it and the root: ancestry is uncertain, so no home is attributed (the locator
                // handles it). Only a positively qualified tool is traversed.
                if roles[next] != .tool { return false }
                current = next
            }
            return false
        }
        return observations
            .filter { $0.key != root && roles[$0.key] == .writer && nearestWriterAncestorIsRoot($0.key) }
            .sorted { ($0.key.startSeconds, $0.key.startMicroseconds, $0.key.pid) < ($1.key.startSeconds, $1.key.startMicroseconds, $1.key.pid) }
            .map { (identity: $0.key, observation: $0.value) }
    }

    /// `…/claude/versions/<version>`: the last two parent components are `claude/versions`.
    static func isClaudeNativeInstallerExecutable(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 3 else { return false }
        return components[components.count - 2] == "versions" && components[components.count - 3] == "claude"
    }

    private static func group(of observation: ProcessObservation) -> Int32? {
        if case let .available(group) = observation.processGroupID { return group }
        return nil
    }

    private static func isClaude(_ family: AgentRuntimeFamily) -> Bool {
        family == .claudeNative || family == .claudeHeadless
    }

    /// Ownership state from one family observation. An active launch keeps its launch state; a
    /// reservation without a committed root, an incomplete inventory or an unqualified family (or
    /// provider) never becomes `exited`. A runtime detached at quit stays detached while it may still
    /// hold a writer.
    private func classify(_ record: AgentRuntimeRecord, family: FamilyObservation) -> AgentRuntimeRecord.State {
        if activeLaunches[record.runtimeID] != nil {
            return record.state
        }
        let state = classifyObservation(record, family: family)
        return record.state == .detachedAtQuit && state.mayHoldWriter ? .detachedAtQuit : state
    }

    private func classifyObservation(_ record: AgentRuntimeRecord, family: FamilyObservation) -> AgentRuntimeRecord.State {
        // A reservation whose birth identity was never committed (crash or failed commit between
        // spawn and registration) can only be found by its marker; an absent marker never proves
        // that a spawned child exited, so ownership stays unresolved, unless its own launcher
        // confirmed reaping the exact child (`rootReaped`). Then only complete, qualified discovery
        // (below) can resolve it.
        guard record.root != nil || record.rootReaped else { return .unknown }
        if family.writerAlive {
            return family.isComplete ? .live : .unknown
        }
        guard family.isComplete else { return .unknown }
        return family.toolAlive ? .toolsRemaining : .exited
    }

    // MARK: Watches

    private func installWatches(runtimeID: UUID, identities: [AgentRuntimeProcessIdentity]) async {
        var existing = watches[runtimeID] ?? []
        existing.removeAll { watch in
            guard identities.contains(watch.identity) else {
                watch.token.cancel()
                return true
            }
            return false
        }
        watches[runtimeID] = existing
        for identity in identities where !existing.contains(where: { $0.identity == identity }) {
            watchGeneration &+= 1
            let generation = watchGeneration
            guard let token = system.watchExit(identity.pid, { [weak self] in
                Task { await self?.watchFired(runtimeID: runtimeID, identity: identity, generation: generation) }
            }) else {
                // Not watchable: a later event cannot be relied on, so the runtime stays unresolved
                // until an explicit Refresh.
                markUnresolved(runtimeID)
                continue
            }
            watches[runtimeID, default: []].append(Watch(identity: identity, generation: generation, token: token))
            // The watch may have been installed after the exit (or on a reused PID): re-verify.
            if case .alive = await lifetime(of: identity) { continue }
            requestRefreshFromEvent()
        }
    }

    private func watchFired(runtimeID: UUID, identity: AgentRuntimeProcessIdentity, generation: UInt64) {
        guard var current = watches[runtimeID],
              let index = current.firstIndex(where: { $0.identity == identity && $0.generation == generation })
        else { return } // Stale: replaced or disposed.
        current.remove(at: index)
        watches[runtimeID] = current
        requestRefreshFromEvent()
    }

    private func cancelAllWatches(except keep: Set<UUID>) {
        for (runtimeID, list) in watches where !keep.contains(runtimeID) {
            list.forEach { $0.token.cancel() }
            watches[runtimeID] = nil
        }
    }

    /// Disposes every watch (registry teardown in tests).
    package func disposeWatches() {
        cancelAllWatches(except: [])
    }

    private func markUnresolved(_ runtimeID: UUID) {
        guard var record = records[runtimeID], record.state != .unknown, record.state != .detachedAtQuit,
              activeLaunches[runtimeID] == nil
        else { return }
        let previous = record
        record.state = .unknown
        persistIfChanged(record, previous: previous)
    }

    // MARK: Persistence

    private func persistIfChanged(_ next: AgentRuntimeRecord, previous: AgentRuntimeRecord) {
        guard next != previous else {
            return
        }
        do {
            records[next.runtimeID] = try store.writeRuntime(next, expectedRevision: previous.revision)
            unpersisted.remove(next.runtimeID)
        } catch {
            unpersisted.insert(next.runtimeID)
        }
    }

    // MARK: Launch lifecycle

    /// Conflicts with a new writer for `keys`: global uncertainty, any other possible writer of the
    /// conversation or the same managed session (active or not, so two launches for one session
    /// conflict before either knows its conversation; distinct known providers never collide), or a
    /// non-active possible writer unassociated on the worktree. Only the exact runtime being
    /// associated is exempt.
    private func writerConflict(for keys: AgentRuntimeOwnershipKeys, excluding runtimeID: UUID?) -> AgentProcessRegistryError? {
        let snapshot = restrictionSnapshot()
        if snapshot.hasGlobalUncertainty { return .ownershipUnknown }
        for record in records.values where record.runtimeID != runtimeID {
            guard record.state.mayHoldWriter || unpersisted.contains(record.runtimeID) else { continue }
            let restriction = Self.restriction(for: record, kind: .possibleWriter, state: record.state, isPreviousInstance: false)
            if restriction.overlapsConversation(keys) || restriction.overlapsSession(keys) {
                return .ownershipConflict(runtimeID: record.runtimeID)
            }
            if activeLaunches[record.runtimeID] == nil, restriction.blocksSend(keys) {
                return .ownershipConflict(runtimeID: record.runtimeID)
            }
        }
        for restriction in snapshot.restrictions where restriction.isUnreadable && restriction.runtimeID != runtimeID {
            if restriction.blocksSend(keys) { return .ownershipConflict(runtimeID: restriction.runtimeID) }
        }
        return nil
    }

    /// Commits a `reserved` record before any spawn, carrying the actual provider and the launch's
    /// initial association (managed session and run attempt, or explicitly none; requested
    /// permission). Throws (and nothing may be spawned) when registration is inactive, an Agent Mode
    /// launch lacks its session context, ownership conflicts or the reservation cannot be written.
    package func reserveLaunch(_ context: AgentRuntimeLaunchContext) throws -> (runtimeID: UUID, launchToken: UUID) {
        guard isAnyPairRegistered else { throw AgentProcessRegistryError.registrationInactive }
        guard !isSealedForSafeRestart else { throw AgentProcessRegistryError.launchesSealed }
        guard qualification.covers(family: context.family, provider: context.provider) else {
            throw AgentProcessRegistryError.unqualifiedProvider
        }
        guard hasStarted else { throw AgentProcessRegistryError.ownershipUnknown }
        let session: AgentRuntimeSessionAssociation?
        switch context.session {
        case .unavailable: throw AgentProcessRegistryError.sessionContextUnavailable
        case .sessionless: session = nil
        case let .session(association): session = association
        }
        let worktree = context.worktreePath.map(AgentRuntimePaths.standardized)
        // Sessionless work (model listing, auth, Oracle print mode) writes no managed session's
        // conversation: only conversation overlap applies to it, never the unassociated-worktree rule.
        let keys = AgentRuntimeOwnershipKeys(
            sessionID: session?.sessionID,
            conversationID: context.conversationID,
            provider: context.provider,
            worktreePath: session == nil ? nil : worktree
        )
        if let conflict = writerConflict(for: keys, excluding: nil) { throw conflict }
        let timestamp = AgentRecoveryTimestamp(now())
        let reserved = AgentRuntimeRecord(
            runtimeID: UUID(),
            revision: .make(),
            appInstanceID: store.appInstanceID,
            family: context.family,
            provider: context.provider,
            state: .reserved,
            associations: [AgentRuntimeAssociation(
                session: session,
                conversationID: context.conversationID,
                worktreePath: worktree,
                permission: context.permission
            )],
            conversationIDs: context.conversationID.map { [$0] } ?? [],
            worktreePaths: worktree.map { [$0] } ?? [],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let written: AgentRuntimeRecord
        do {
            written = try store.writeRuntime(reserved, expectedRevision: nil)
        } catch {
            throw AgentProcessRegistryError.storage(String(describing: error))
        }
        records[written.runtimeID] = written
        let token = UUID()
        activeLaunches[written.runtimeID] = token
        publish()
        return (written.runtimeID, token)
    }

    private func requireActive(_ runtimeID: UUID, token: UUID) throws -> AgentRuntimeRecord {
        guard activeLaunches[runtimeID] == token, let record = records[runtimeID] else {
            throw AgentProcessRegistryError.staleLaunch
        }
        return record
    }

    /// The spawn failed after its reservation: no child exists, so this lifetime is exited.
    package func spawnFailed(runtimeID: UUID, launchToken: UUID) {
        guard let record = try? requireActive(runtimeID, token: launchToken) else { return }
        activeLaunches[runtimeID] = nil
        var next = record
        next.state = .exited
        persistIfChanged(next, previous: record)
        publish()
    }

    /// Commits the spawned root's birth identity (`live`) before any protocol or user write. On
    /// failure the launch is no longer authorized; the reservation stays unresolved and the caller
    /// must terminate and reap the exact child it still owns.
    package func registerSpawn(runtimeID: UUID, launchToken: UUID, pid: pid_t, processGroupID: pid_t?) async throws {
        _ = try requireActive(runtimeID, token: launchToken)
        spawnedPIDs[runtimeID] = pid
        let inspection = await system.inspect(pid)
        // Revalidate after the await: the launch may have been superseded meanwhile. The only way to
        // lose this race is this launch's own `rootReaped`: a confirmed exact-child report already
        // consumed `spawnedPIDs`; an unconfirmed one deliberately keeps it for the launcher's late
        // confirmed reap of the same child (`isLateReport`).
        let record = try requireActive(runtimeID, token: launchToken)
        guard case let .observed(observation) = inspection, observation.identity.pid == pid else {
            activeLaunches[runtimeID] = nil
            uncommittedLaunches[runtimeID] = launchToken
            var next = record
            next.state = .unknown
            persistIfChanged(next, previous: record)
            publish()
            throw AgentProcessRegistryError.identityUnavailable
        }
        var next = record
        next.root = Self.identity(of: observation)
        next.rootProcessGroupID = Self.group(of: observation) ?? processGroupID
        next.state = .live
        if next.providerHome == nil, Self.isClaude(record.family), case let .available(environment) = observation.environment {
            next.providerHome = environment.claudeConfigDirectory
        }
        do {
            records[runtimeID] = try store.writeRuntime(next, expectedRevision: record.revision)
        } catch {
            activeLaunches[runtimeID] = nil
            uncommittedLaunches[runtimeID] = launchToken
            unpersisted.insert(runtimeID)
            publish()
            throw AgentProcessRegistryError.storage(String(describing: error))
        }
        spawnedPIDs[runtimeID] = nil // The committed root identity is the evidence from here on.
        if let root = next.root {
            await installWatches(runtimeID: runtimeID, identities: [root])
        }
        publish()
    }

    /// Associates one operation with an active runtime before its write: its managed session and run
    /// attempt, the native conversation it reaches, its worktree and requested permission. A match
    /// (same session lifetime with a compatible attempt, conversation and worktree) is completed in
    /// place; anything else is appended, so a reused transport keeps every attempt and thread.
    /// Refuses a conversation or session another possible writer holds.
    /// `replacingPermission`: the operation explicitly requests `association.permission`; otherwise
    /// a matched association keeps its own and only a new one starts from the given fallback.
    package func associate(
        runtimeID: UUID,
        launchToken: UUID,
        association: AgentRuntimeAssociation,
        replacingPermission: Bool = true
    ) throws {
        try apply(association, to: requireActive(runtimeID, token: launchToken), replacingPermission: replacingPermission)
    }

    /// Records a conversation a launcher observed in its runtime's output (a headless CLI's final
    /// result), even when the exact root was already reaped: evidence only, never write authority.
    package func recordObservedConversation(runtimeID: UUID, launchToken: UUID, association: AgentRuntimeAssociation) throws {
        guard activeLaunches[runtimeID] == launchToken || reapedLaunches[runtimeID] == launchToken,
              let record = records[runtimeID]
        else { throw AgentProcessRegistryError.staleLaunch }
        try apply(association, to: record, replacingPermission: false)
    }

    private func apply(_ association: AgentRuntimeAssociation, to record: AgentRuntimeRecord, replacingPermission: Bool) throws {
        let runtimeID = record.runtimeID
        let newConversation = association.conversationID.map { !record.conversationIDs.contains($0) } ?? false
        let newSession = association.session.map { session in
            !record.associations.contains { $0.session?.sessionID == session.sessionID }
        } ?? false
        if newConversation || newSession {
            let keys = AgentRuntimeOwnershipKeys(
                sessionID: newSession ? association.session?.sessionID : nil,
                conversationID: newConversation ? association.conversationID : nil,
                provider: record.provider,
                providerHome: record.providerHome,
                worktreePath: nil
            )
            if let conflict = writerConflict(for: keys, excluding: runtimeID) { throw conflict }
        }
        var next = record
        Self.merge(association, into: &next, replacingPermission: replacingPermission)
        guard next != record else { return }
        do {
            records[runtimeID] = try store.writeRuntime(next, expectedRevision: record.revision)
        } catch {
            throw AgentProcessRegistryError.storage(String(describing: error))
        }
        publish()
    }

    static func merge(_ association: AgentRuntimeAssociation, into record: inout AgentRuntimeRecord, replacingPermission: Bool) {
        if let index = record.associations.firstIndex(where: { Self.matches($0, association) }) {
            var existing = record.associations[index]
            if let lhs = existing.session, let rhs = association.session {
                existing.session = AgentRuntimeSessionAssociation(
                    sessionID: lhs.sessionID,
                    incarnationID: lhs.incarnationID,
                    transcriptResetGeneration: lhs.transcriptResetGeneration,
                    runAttemptID: lhs.runAttemptID ?? rhs.runAttemptID,
                    processRunID: lhs.processRunID ?? rhs.processRunID
                )
            }
            existing.conversationID = existing.conversationID ?? association.conversationID
            existing.worktreePath = existing.worktreePath ?? association.worktreePath
            if replacingPermission || existing.permission == .unavailable {
                existing.permission = association.permission
            }
            record.associations[index] = existing
        } else {
            record.associations.append(association)
        }
        if let conversationID = association.conversationID, !record.conversationIDs.contains(conversationID) {
            record.conversationIDs.append(conversationID)
        }
        if let worktreePath = association.worktreePath, !record.worktreePaths.contains(worktreePath) {
            record.worktreePaths.append(worktreePath)
        }
    }

    /// The same operation scope: the same session lifetime (or both sessionless) whose recorded run
    /// attempt and process run are absent or equal, and compatible conversation and worktree.
    private static func matches(_ existing: AgentRuntimeAssociation, _ new: AgentRuntimeAssociation) -> Bool {
        let sessionMatches: Bool = switch (existing.session, new.session) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.sessionID == rhs.sessionID
                && lhs.incarnationID == rhs.incarnationID
                && lhs.transcriptResetGeneration == rhs.transcriptResetGeneration
                && (lhs.runAttemptID == nil || rhs.runAttemptID == nil || lhs.runAttemptID == rhs.runAttemptID)
                && (lhs.processRunID == nil || rhs.processRunID == nil || lhs.processRunID == rhs.processRunID)
        default:
            false
        }
        guard sessionMatches else { return false }
        if let lhs = existing.conversationID, let rhs = new.conversationID, lhs != rhs { return false }
        if let lhs = existing.worktreePath, let rhs = new.worktreePath, lhs != rhs { return false }
        return true
    }

    /// Write fence: the launch is current, committed `live`, and (when given) serves the conversation.
    package func authorizeWrite(runtimeID: UUID, launchToken: UUID, conversationID: String?) throws {
        let record = try requireActive(runtimeID, token: launchToken)
        guard record.state == .live, record.root != nil else { throw AgentProcessRegistryError.staleLaunch }
        if let conversationID, !record.conversationIDs.contains(conversationID) {
            throw AgentProcessRegistryError.ownershipConflict(runtimeID: nil)
        }
    }

    /// The launcher stopped waiting on the exact root it spawned (captured launch event, not the
    /// current controller), including a launch whose birth commit failed. Ends write authority and
    /// rediscovers the family; it never marks it exited. Only a `confirmed` reap of the exact child
    /// (the launcher's own `waitpid` returned it) is recorded as evidence: an `ECHILD`, a swallowed
    /// wait error or an expired grace period ends authority without proving anything.
    package func rootReaped(runtimeID: UUID, launchToken: UUID, pid: pid_t, confirmed: Bool) async {
        let isActive = activeLaunches[runtimeID] == launchToken
        let isUncommitted = uncommittedLaunches[runtimeID] == launchToken
        // A concurrent waiter of the same launch may report (unconfirmed, `ECHILD`) before the waiter
        // that actually reaped: the late confirmed report of the same launch is still evidence.
        let isLateReport = reapedLaunches[runtimeID] == launchToken
        guard isActive || isUncommitted || isLateReport, let record = records[runtimeID] else { return }
        activeLaunches[runtimeID] = nil
        uncommittedLaunches[runtimeID] = nil
        reapedLaunches[runtimeID] = launchToken
        let exactChild = record.root.map { $0.pid == pid } ?? (spawnedPIDs[runtimeID] == pid)
        let recordsEvidence = confirmed && exactChild && !record.rootReaped
        guard isActive || isUncommitted || recordsEvidence else { return }
        if recordsEvidence {
            spawnedPIDs[runtimeID] = nil
            var next = record
            next.rootReaped = true
            persistIfChanged(next, previous: record)
        }
        await refresh()
    }

    // MARK: Survivor actions

    /// Persists Let finish for a runtime (it keeps restricting and being watched).
    package func letFinish(runtimeID: UUID, expectedRevision: AgentRecoveryRecordRevision) throws {
        guard let record = records[runtimeID] else { throw AgentProcessRegistryError.staleLaunch }
        guard record.revision == expectedRevision else {
            throw AgentProcessRegistryError.storage("The process changed; refresh and try again.")
        }
        guard !record.letFinish else { return }
        var next = record
        next.letFinish = true
        do {
            records[runtimeID] = try store.writeRuntime(next, expectedRevision: record.revision)
        } catch {
            throw AgentProcessRegistryError.storage(String(describing: error))
        }
        publish()
    }

    /// Fresh discovery preview of what Stop would signal.
    package func previewStop(runtimeID: UUID) async -> AgentRuntimeStopPreview? {
        guard records[runtimeID] != nil else { return nil }
        await refresh()
        guard let record = records[runtimeID] else { return nil }
        let inventory = await system.inventory()
        let family = await discoverFamily(of: record, inventory: inventory)
        return AgentRuntimeStopPreview(
            runtimeID: runtimeID,
            revision: record.revision,
            members: Self.previewMembers(record: record, family: family),
            isComplete: family.isComplete
        )
    }

    private static func previewMembers(record: AgentRuntimeRecord, family: FamilyObservation) -> [AgentRuntimeStopPreview.Member] {
        var members = family.members.map {
            AgentRuntimeStopPreview.Member(identity: $0.identity, processGroupID: $0.processGroupID, role: $0.role)
        }
        if let root = record.root, family.aliveIdentities.contains(root) {
            // The root's freshly observed group, never its persisted one.
            members.insert(.init(identity: root, processGroupID: family.rootGroup, role: .writer), at: 0)
        }
        return members
    }

    /// Stop engine. Revalidates the record revision and the whole membership against `preview`,
    /// then, immediately before each group signal, re-enumerates processes and verifies that group
    /// afresh: the inventory is complete, every process's group is readable, every process in the
    /// group is a verified, classified member, and every expected member of the group is either gone
    /// or still present with the same identity and group. SIGTERM, waits 3 s (injected), repeats all
    /// validation, SIGKILL, then a fresh discovery decides.
    ///
    /// POSIX limitation: inspection followed by `kill(-pgid, …)` is not atomic; a process can join a
    /// group (or identifiers can change) between the last check and the signal. These checks narrow
    /// that window to one inventory; they do not close it. No PID-signal substitution is made;
    /// production supplies no actions, so recovered Stop stays disabled.
    package func stop(preview: AgentRuntimeStopPreview) async -> AgentRuntimeStopResult {
        guard let actions = stopActions else { return .disabled }
        guard records[preview.runtimeID]?.revision == preview.revision, activeLaunches[preview.runtimeID] == nil else {
            return .changed
        }
        guard preview.isComplete, !preview.members.isEmpty else { return .refusedUnsafeGroup }
        // The groups the user reviewed: a member observed in any other group is a changed family.
        let previewGroups = Dictionary(preview.members.map { ($0.identity, $0.processGroupID) }, uniquingKeysWith: { lhs, _ in lhs })

        for (index, signal) in [SIGTERM, SIGKILL].enumerated() {
            if index > 0 { await actions.sleep(3) }
            // After SIGTERM, exit events legitimately rewrite the record; membership decides then.
            guard let current = records[preview.runtimeID],
                  index > 0 || current.revision == preview.revision
            else { return .changed }
            let inventory = await system.inventory()
            let family = await discoverFamily(of: current, inventory: inventory)
            let alive = Self.previewMembers(record: current, family: family)
            if index == 0 {
                guard Set(alive.map(\.identity)) == Set(preview.members.map(\.identity)) else { return .changed }
            } else {
                // Only members from the preview may remain; anything new means the family changed.
                guard Set(alive.map(\.identity)).isSubset(of: Set(preview.members.map(\.identity))) else { return .changed }
                if alive.isEmpty { break }
            }
            guard alive.allSatisfy({ previewGroups[$0.identity] == $0.processGroupID }) else { return .changed }
            guard family.isComplete, inventory.isComplete else { return .unresolved }
            let groups = Set(alive.compactMap(\.processGroupID))
            guard alive.allSatisfy({ $0.processGroupID != nil }) else { return .refusedUnsafeGroup }
            let roles = Dictionary(alive.map { ($0.identity, $0.role) }, uniquingKeysWith: { lhs, _ in lhs })
            for group in groups.sorted() {
                guard group > 1, group != system.appProcessGroupID else { return .refusedUnsafeGroup }
                // Re-enumerate immediately before this signal; nothing decided earlier is reused.
                guard records[preview.runtimeID] != nil, activeLaunches[preview.runtimeID] == nil else { return .changed }
                let fresh = await system.inventory()
                guard fresh.isComplete else { return .unresolved }
                // Unreadable group membership anywhere means the group's members cannot be known
                // (an already-exited zombie cannot be harmed or survive the signal).
                var inGroup: [ProcessObservation] = []
                for observation in fresh.observations {
                    guard case let .available(observedGroup) = observation.processGroupID else {
                        if observation.isZombie { continue }
                        return .refusedUnsafeGroup
                    }
                    if observedGroup == group { inGroup.append(observation) }
                }
                // Every process now in the group is a verified, classified member of this family.
                for observation in inGroup {
                    guard observation.identity.pid != system.appPID,
                          let role = roles[Self.identity(of: observation)], role != .unknown
                    else { return .refusedUnsafeGroup }
                }
                // Every expected member of the group is gone or unchanged (same identity, same group).
                for member in alive where member.processGroupID == group {
                    guard let observation = fresh.observations.first(where: { Self.identity(of: $0) == member.identity }) else { continue }
                    guard case let .available(observedGroup) = observation.processGroupID, observedGroup == group else { return .changed }
                }
                if actions.signalProcessGroup(group, signal) != 0 {
                    return .unresolved
                }
            }
        }

        await refresh()
        guard var final = records[preview.runtimeID] else { return .unresolved }
        let inventory = await system.inventory()
        let family = await discoverFamily(of: final, inventory: inventory)
        guard family.isComplete, family.aliveIdentities.isEmpty else { return .unresolved }
        let previous = final
        final.state = .stopped
        final.members = []
        persistIfChanged(final, previous: previous)
        publish()
        return unpersisted.contains(final.runtimeID) ? .unresolved : .stopped
    }
}

// MARK: - Restart safely Stage B proof (lossless restart Phase 4 §G)

/// Whether every registered provider family and tool is proven gone. Only `.allStopped` lets
/// Restart safely arm its relaunch helper; anything else keeps the helper unarmed.
package enum AgentRuntimeAllStoppedProof: Equatable {
    case allStopped
    case notProven(String)
}

package extension AgentProcessRegistry {
    /// Seals new launches for Restart safely (see `isSealedForSafeRestart`), then runs one discovery
    /// pass and proves that no family, tool, launch, reservation, or unreadable record remains. The
    /// seal is taken synchronously on the registry's executor before any await, so no launch can be
    /// reserved between the proof and the helper's arm or the exit. Never signals anything; absence
    /// of evidence is not proof.
    func verifyAllFamiliesStopped() async -> AgentRuntimeAllStoppedProof {
        guard isAnyPairRegistered else { return .notProven("Runtime registration is not active.") }
        // Subset activation: an unregistered family can never be proven stopped, so no whole-app proof.
        guard qualification.coversAllSupportedPairs else {
            return .notProven("Some providers' processes aren't tracked, so they can't be proven stopped.")
        }
        isSealedForSafeRestart = true
        guard hasStarted else { return .notProven("Runtime ownership has not been checked yet.") }
        await refresh()
        // F6: `storageFailure` is a raw error string (logged when recorded); it is never shown.
        if storageFailure != nil { return .notProven("Runtime records are unreadable.") }
        if !preserved.isEmpty || unidentifiedPreservedCount > 0 {
            return .notProven("Some runtime records could not be read.")
        }
        if !activeLaunches.isEmpty || !uncommittedLaunches.isEmpty {
            return .notProven("A provider launch is still in progress.")
        }
        if !unpersisted.isEmpty { return .notProven("A runtime's latest state could not be saved.") }
        for record in records.values {
            switch record.state {
            case .exited, .stopped:
                continue
            case .toolsRemaining:
                return .notProven("Tools started by an agent are still running.")
            case .reserved, .live, .unknown, .detachedAtQuit:
                return .notProven("An agent process may still be running.")
            }
        }
        return .allStopped
    }

    /// History reconciliation (Phase 4 §D): the Claude configuration directories this registry
    /// recorded for runtimes associated with `conversationID`, from the runtime's own observed
    /// environment. Registry knowledge only — never the app's environment or the selected profile.
    /// A runtime without a recorded directory contributes nothing (unknown is not the default).
    func claudeProviderHomes(conversationID: String) -> [String] {
        let homes = records.values
            .filter { Self.isClaude($0.family) && $0.conversationIDs.contains(conversationID) }
            .compactMap(\.providerHome)
            .filter { !$0.isEmpty }
        return Array(Set(homes)).sorted()
    }

    /// `claudeProviderHomes(conversationID:)`, after one discovery pass when none is recorded yet and
    /// a spawned, still-unresolved Claude runtime of this conversation may still reveal its home: no
    /// pass has observed its root-linked writer without one (`homeSettledRuntimeIDs`), and fewer
    /// than `maxHomeRefreshesPerRuntime` lookups refreshed for it. Each lookup runs at most one pass;
    /// a runtime gets at most that many over its lifetime. Discovery has no timer and no spawn
    /// event, so a pass that saw only the shim must not end the retries.
    func claudeProviderHomesRefreshingIfPending(conversationID: String) async -> [String] {
        let recorded = claudeProviderHomes(conversationID: conversationID)
        guard recorded.isEmpty else { return recorded }
        let pending = records.values.filter { record in
            guard Self.isClaude(record.family), record.conversationIDs.contains(conversationID), record.providerHome == nil,
                  !homeSettledRuntimeIDs.contains(record.runtimeID),
                  homeRefreshAttempts[record.runtimeID, default: 0] < Self.maxHomeRefreshesPerRuntime
            else { return false }
            switch record.state {
            case .exited, .stopped, .reserved: return false
            case .live, .unknown, .detachedAtQuit, .toolsRemaining: return true
            }
        }
        guard !pending.isEmpty else { return [] }
        for record in pending {
            homeRefreshAttempts[record.runtimeID, default: 0] += 1
        }
        await refresh()
        return claudeProviderHomes(conversationID: conversationID)
    }

    /// Every Claude configuration directory recorded on any Claude runtime (any conversation): the
    /// recorded candidates of the history locator's fallback search (O42).
    func allClaudeProviderHomes() -> [String] {
        let homes = records.values
            .filter { Self.isClaude($0.family) }
            .compactMap(\.providerHome)
            .filter { !$0.isEmpty }
        return Array(Set(homes)).sorted()
    }
}
