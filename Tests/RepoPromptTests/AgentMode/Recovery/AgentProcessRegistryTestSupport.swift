import Darwin
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptPlatform
import XCTest

/// Scripted process boundaries for `AgentProcessRegistry` fixtures (spec R6): a same-user
/// inventory, per-PID inspection, exit watches fired by the test, and injected Stop actions. Nothing
/// here inspects, watches or signals a real process.
final class ScriptedProcessSystem: @unchecked Sendable {
    static let uid: uid_t = 501
    static let denial = ProcessInspectionFailure(operation: .arguments, reason: .accessDenied)

    final class WatchToken: AgentProcessExitWatchToken {
        private let lock = NSLock()
        private var cancelledFlag = false

        var isCancelled: Bool {
            lock.withLock { cancelledFlag }
        }

        func cancel() {
            lock.withLock { cancelledFlag = true }
        }
    }

    private struct Watcher {
        let pid: pid_t
        let token: WatchToken
        let handler: @Sendable () -> Void
    }

    let bootSessionID = UUID()
    let appPID: pid_t = 90000
    let appProcessGroupID: pid_t = 90000

    private let lock = NSLock()
    private var alive: [pid_t: ProcessObservation] = [:]
    private var denied: Set<pid_t> = []
    private var unwatchable: Set<pid_t> = []
    private var incomplete = false
    private var watchers: [Watcher] = []
    private var inventoryCount = 0
    private var signals: [(group: pid_t, signal: Int32)] = []
    private var sleeps: [TimeInterval] = []
    private var signalErrnoValue: Int32 = 0
    private var survivesTERMValue = false
    private var inventoryHookValue: (@Sendable () async -> Void)?

    // MARK: Scripting

    func add(_ observation: ProcessObservation) {
        lock.withLock { alive[observation.identity.pid] = observation }
    }

    func remove(pid: pid_t) {
        lock.withLock { _ = alive.removeValue(forKey: pid) }
    }

    func deny(pid: pid_t) {
        lock.withLock { _ = denied.insert(pid) }
    }

    func makeUnwatchable(pid: pid_t) {
        lock.withLock { _ = unwatchable.insert(pid) }
    }

    var inventoryIsIncomplete: Bool {
        get { lock.withLock { incomplete } }
        set { lock.withLock { incomplete = newValue } }
    }

    var inventoryCalls: Int {
        lock.withLock { inventoryCount }
    }

    var sentSignals: [(group: pid_t, signal: Int32)] {
        lock.withLock { signals }
    }

    var recordedSleeps: [TimeInterval] {
        lock.withLock { sleeps }
    }

    var signalErrno: Int32 {
        get { lock.withLock { signalErrnoValue } }
        set { lock.withLock { signalErrnoValue = newValue } }
    }

    /// Group members ignore SIGTERM (only SIGKILL removes them).
    var survivesTERM: Bool {
        get { lock.withLock { survivesTERMValue } }
        set { lock.withLock { survivesTERMValue = newValue } }
    }

    /// Runs (and may suspend) at the start of every inventory.
    var inventoryHook: (@Sendable () async -> Void)? {
        get { lock.withLock { inventoryHookValue } }
        set { lock.withLock { inventoryHookValue = newValue } }
    }

    /// Live (uncancelled) watches on `pid`.
    func liveWatchCount(pid: pid_t) -> Int {
        lock.withLock { watchers.count { $0.pid == pid && !$0.token.isCancelled } }
    }

    /// The process exits: it leaves inventory and inspection, then its watches fire (cancelled
    /// tokens never fire). Returns how many handlers fired.
    @discardableResult
    func processExited(pid: pid_t) -> Int {
        let fired: [Watcher] = lock.withLock {
            alive.removeValue(forKey: pid)
            let matching = watchers.filter { $0.pid == pid && !$0.token.isCancelled }
            watchers.removeAll { $0.pid == pid }
            return matching
        }
        fired.forEach { $0.handler() }
        return fired.count
    }

    /// Re-delivers a watch handler captured earlier (a late, stale event).
    func capturedHandlers(pid: pid_t) -> [@Sendable () -> Void] {
        lock.withLock { watchers.filter { $0.pid == pid }.map(\.handler) }
    }

    // MARK: Fixtures

    func identity(pid: pid_t, start: UInt64 = 100) -> AgentRuntimeProcessIdentity {
        AgentRuntimeProcessIdentity(
            bootSessionID: bootSessionID,
            pid: pid,
            startSeconds: start,
            startMicroseconds: 0,
            uid: Self.uid
        )
    }

    // swiftlint:disable:next function_parameter_count
    func observation(
        pid: pid_t,
        start: UInt64 = 100,
        parent: pid_t = 1,
        executable: String? = "/opt/fixture/bin/claude",
        group: pid_t? = nil,
        marker: UUID? = nil,
        environmentAvailable: Bool = true,
        home: String? = nil,
        zombie: Bool = false
    ) -> ProcessObservation {
        ProcessObservation(
            identity: ProcessBirthIdentity(
                bootSessionID: bootSessionID,
                pid: pid,
                startSeconds: start,
                startMicroseconds: 0,
                uid: Self.uid
            ),
            parentPID: parent,
            isZombie: zombie,
            executablePath: executable.map { .available($0) } ?? .unavailable(Self.denial),
            processGroupID: group.map { .available($0) } ?? .unavailable(Self.denial),
            environment: environmentAvailable
                ? .available(ProcessEnvironmentIdentity(runtimeID: marker, claudeConfigDirectory: home))
                : .unavailable(Self.denial)
        )
    }

    // MARK: Boundaries

    var system: AgentProcessSystem {
        AgentProcessSystem(
            inventory: { [self] in
                if let hook = inventoryHook { await hook() }
                return snapshot()
            },
            inspect: { [self] pid in inspect(pid) },
            watchExit: { [self] pid, handler in watch(pid: pid, handler: handler) },
            appPID: appPID,
            appProcessGroupID: appProcessGroupID
        )
    }

    var stopActions: AgentProcessStopActions {
        AgentProcessStopActions(
            signalProcessGroup: { [self] group, signal in signalGroup(group, signal) },
            sleep: { [self] seconds in lock.withLock { sleeps.append(seconds) } }
        )
    }

    private func snapshot() -> ProcessInventorySnapshot {
        lock.withLock {
            inventoryCount += 1
            let observations = alive.values.sorted { $0.identity.pid < $1.identity.pid }
            return ProcessInventorySnapshot(
                observations: observations,
                incompleteness: incomplete ? [.truncated] : []
            )
        }
    }

    private func inspect(_ pid: pid_t) -> ProcessInspectionResult {
        lock.withLock {
            if denied.contains(pid) { return .unavailable(Self.denial) }
            if let observation = alive[pid] { return .observed(observation) }
            return .notFound
        }
    }

    private func watch(pid: pid_t, handler: @escaping @Sendable () -> Void) -> AgentProcessExitWatchToken? {
        lock.withLock {
            guard !unwatchable.contains(pid) else { return nil }
            let token = WatchToken()
            watchers.append(Watcher(pid: pid, token: token, handler: handler))
            return token
        }
    }

    private func signalGroup(_ group: pid_t, _ signal: Int32) -> Int32 {
        lock.withLock {
            signals.append((group, signal))
            guard signalErrnoValue == 0 else { return signalErrnoValue }
            guard signal == SIGKILL || !survivesTERMValue else { return 0 }
            for (pid, observation) in alive {
                if case let .available(observedGroup) = observation.processGroupID, observedGroup == group {
                    alive.removeValue(forKey: pid)
                }
            }
            return 0
        }
    }
}

enum AgentProcessRegistryFixtures {
    /// The actual providers each family serves.
    static func providers(for family: AgentRuntimeFamily) -> Set<AgentRuntimeProvider> {
        switch family {
        case .claudeNative: [.claude(.standard)]
        case .claudeCompatible: [.claude(.glm), .claude(.kimi), .claude(.customCompatible)]
        case .claudeHeadless: [.claude(.standard), .claude(.glm), .claude(.kimi), .claude(.customCompatible)]
        case .codexAppServer, .codexExec: [.codex]
        case .acp: [.acp(.cursor), .acp(.openCode), .acp(.ohMyPi)]
        }
    }

    /// The provider a seeded record of `family` names by default.
    static func defaultProvider(for family: AgentRuntimeFamily) -> AgentRuntimeProvider {
        switch family {
        case .claudeNative, .claudeHeadless: .claude(.standard)
        case .claudeCompatible: .claude(.glm)
        case .codexAppServer, .codexExec: .codex
        case .acp: .acp(.cursor)
        }
    }

    /// Every managed family qualified (fixture-only coupled activation) for every provider it
    /// serves, unless `providers` narrows a family's recorded providers.
    static func qualified(
        freshSessionID: Bool = false,
        providers overrides: [AgentRuntimeFamily: Set<AgentRuntimeProvider>] = [:]
    ) -> AgentRuntimeQualification {
        AgentRuntimeQualification(families: Dictionary(uniqueKeysWithValues: AgentRuntimeFamily.allCases.map { family in
            (family, AgentRuntimeFamilyQualification(
                providers: overrides[family] ?? providers(for: family),
                markerPropagation: true,
                completeDiscovery: true,
                writerExecutableBasenames: ["claude", "codex"],
                // Explicit positive tool evidence only (R6): the fixture tool executable.
                toolExecutableBasenames: ["node"],
                freshSessionID: freshSessionID && family == .claudeNative
            ))
        }))
    }

    /// A managed session scope for fixture lane `sessionID` (fresh incarnation unless given).
    static func session(
        _ sessionID: UUID = UUID(),
        incarnationID: UUID = UUID(),
        resetGeneration: UInt64 = 0,
        runAttemptID: UUID? = UUID(),
        processRunID: UUID? = nil
    ) -> AgentRuntimeSessionAssociation {
        AgentRuntimeSessionAssociation(
            sessionID: sessionID,
            incarnationID: incarnationID,
            transcriptResetGeneration: resetGeneration,
            runAttemptID: runAttemptID,
            processRunID: processRunID
        )
    }

    /// A launch context of `family` with its default provider (sessionless unless given).
    static func context(
        _ family: AgentRuntimeFamily,
        provider: AgentRuntimeProvider? = nil,
        session: AgentRuntimeSessionScope = .sessionless,
        worktreePath: String?,
        conversationID: String? = nil,
        permission: AgentRuntimePermissionSnapshot = .unavailable
    ) -> AgentRuntimeLaunchContext {
        AgentRuntimeLaunchContext(
            family: family,
            provider: provider ?? defaultProvider(for: family),
            session: session,
            worktreePath: worktreePath,
            conversationID: conversationID,
            permission: permission
        )
    }

    /// Writes a runtime record as an earlier app instance would have left it.
    @discardableResult
    static func seed(
        rootURL: URL,
        family: AgentRuntimeFamily = .claudeNative,
        provider: AgentRuntimeProvider? = nil,
        unknownProvider: Bool = false,
        state: AgentRuntimeRecord.State = .live,
        root: AgentRuntimeProcessIdentity?,
        rootGroup: Int32? = nil,
        members: [AgentRuntimeMember] = [],
        associations: [AgentRuntimeAssociation] = [],
        conversationIDs: [String] = [],
        worktreePaths: [String] = []
    ) throws -> AgentRuntimeRecord {
        let previous = AgentRecoveryStore(rootURL: rootURL, appInstanceID: UUID())
        let timestamp = AgentRecoveryTimestamp(Date())
        return try previous.writeRuntime(
            AgentRuntimeRecord(
                runtimeID: UUID(),
                revision: .make(),
                appInstanceID: previous.appInstanceID,
                family: family,
                provider: unknownProvider ? nil : (provider ?? defaultProvider(for: family)),
                state: state,
                root: root,
                rootProcessGroupID: rootGroup,
                members: members,
                associations: associations,
                conversationIDs: conversationIDs,
                worktreePaths: worktreePaths,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            expectedRevision: nil
        )
    }

    static func runtimeFileCount(rootURL: URL) -> Int {
        let directory = rootURL.appendingPathComponent("runtimes", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
    }

    static func record(_ store: AgentRecoveryStore, _ runtimeID: UUID) -> AgentRuntimeRecord? {
        if case let .supported(record) = store.readRuntime(runtimeID: runtimeID) { return record }
        return nil
    }

    /// Bounded wait for asynchronous watch/refresh effects (no fixed sleeps in assertions).
    static func eventually(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

/// Suspends the first inventory until released (coalescing fixtures).
actor InventoryGate {
    private var blocked = true
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrivals += 1
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        guard blocked else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForArrival() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    /// Whether anything reached the gate (for bounded waits that must not hang).
    var hasArrived: Bool {
        arrivals > 0
    }

    func open() {
        blocked = false
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
