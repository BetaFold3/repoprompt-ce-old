import AppKit
import Foundation
import RepoPromptAgentCore
import RepoPromptPlatform

// Restart safely relaunch driver (lossless restart Phase 4 §G). Implements R4's relaunch hooks over
// the Platform protocol (`ProcessRelaunchParentSession`) with the EXISTING bundled `repoprompt-mcp`
// in its private mode. Every hook is serialized: `abandon` joins whatever is in flight, so no prompt
// or Quit Anyway can race an arm. Each prepare uses a fresh helper; nothing is reused.
//
// Production composition returns `nil` (gated OFF until O3 live acceptance and an active Phase 3
// registry): R4 then refuses `.safeRestart` and no helper is ever spawned.

@MainActor
final class AppRelaunchCoordinator {
    struct Dependencies {
        /// Spawns one fresh helper process and returns its channel.
        var spawnHelper: @MainActor () throws -> ProcessRelaunchHelperChannel
        /// This process's birth identity (`nil` when it cannot be established: never prepares).
        var parentIdentity: @MainActor () -> ProcessRelaunchParentIdentity?
        /// The exact application bundle to reopen.
        var bundlePath: String
        /// R4 Stage B proof that every provider family and tool stopped.
        var verifyAllStopped: @MainActor () async -> AgentRuntimeAllStoppedProof
        var limits: ProcessRelaunchLimits = .v1
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        /// Monotonic clock of each helper's one absolute cleanup budget.
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    }

    static let helperUnavailableMessage = "RepoPrompt could not start its restart helper."
    static let identityUnavailableMessage = "RepoPrompt could not verify its own process for restarting."
    static let budgetSpentMessage = "RepoPrompt ran out of time to start its restart helper."

    private let dependencies: Dependencies
    private var session: ProcessRelaunchParentSession?
    private var tail: Task<Void, Never>?
    /// Fresh helpers spawned (test observability).
    private(set) var spawnCount = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var hooks: AgentLifecycleRelaunchHooks {
        AgentLifecycleRelaunchHooks(
            prepare: { [weak self] budget in
                guard let self else { return Self.helperUnavailableMessage }
                return await serialized { await self.prepareFresh(budget: budget) }
            },
            verifyAllStopped: { [weak self] in
                guard let self else { return Self.helperUnavailableMessage }
                switch await dependencies.verifyAllStopped() {
                case .allStopped: return nil
                case let .notProven(reason): return reason
                }
            },
            arm: { [weak self] budget in
                guard let self else { return Self.helperUnavailableMessage }
                return await serialized { await self.armCurrent(budget: budget) }
            },
            abandon: { [weak self] in
                guard let self else { return .safe }
                return await serialized { await self.abandonCurrent() }
            },
            cleanupReserve: dependencies.limits.cleanupReserve,
            awaitRetainedHelperStop: { [weak self] in
                guard let self else { return false }
                return await awaitRetainedStop()
            }
        )
    }

    /// Runs `body` after every earlier hook finished (one hook at a time). Every hook is bounded by
    /// its own absolute budget (review R1 A P1-07), and an earlier hook's budget never ends after a
    /// later attempt's, so the wait here never outlasts the caller's final cleanup expiry.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await body()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    private func prepareFresh(budget: AgentLifecycleRelaunchBudget) async -> String? {
        // Review A P1-07: an earlier helper whose stop is unresolved is retained; no fresh helper
        // is spawned while it may still be alive (armed or not).
        switch await abandonCurrent() {
        case .safe:
            break
        case let .unresolved(reason), let .unresolvedUnarmed(reason):
            return reason
        }
        // Recomputed after the earlier helper's cleanup: no fresh helper once the work budget is spent.
        guard dependencies.now() < budget.workExpiry else { return Self.budgetSpentMessage }
        guard let identity = dependencies.parentIdentity() else { return Self.identityUnavailableMessage }
        let channel: ProcessRelaunchHelperChannel
        do {
            channel = try dependencies.spawnHelper()
        } catch {
            return Self.helperUnavailableMessage
        }
        spawnCount += 1
        let fresh = ProcessRelaunchParentSession(
            channel: channel,
            limits: dependencies.limits,
            sleep: dependencies.sleep,
            now: dependencies.now
        )
        session = fresh
        // Absolute instants: identity inspection and spawn above are not renewed (the session
        // recomputes what is left when its timer starts).
        switch await fresh.prepare(
            parent: identity,
            bundlePath: dependencies.bundlePath,
            workExpiry: budget.workExpiry,
            cleanupExpiry: budget.cleanupExpiry
        ) {
        case .ready:
            return nil
        case let .failed(reason):
            session = nil
            return reason
        case let .unresolved(reason):
            // Ownership retained: a later `abandon` retries within what is left of its budget.
            return reason
        }
    }

    private func armCurrent(budget: AgentLifecycleRelaunchBudget) async -> String? {
        guard let current = session else { return "The restart helper is not ready." }
        switch await current.arm(workExpiry: budget.workExpiry, cleanupExpiry: budget.cleanupExpiry) {
        case .armed:
            return nil
        case let .notArmed(reason):
            session = nil
            return reason
        case let .unresolved(reason):
            // Possibly armed: retained, never replaced by a fresh helper.
            return reason
        }
    }

    /// Leaves no ready or armed helper: aborts and waits for a correlated `aborted` or the exact
    /// helper's observed exit, within what is left of that helper's one absolute cleanup budget.
    /// An unresolved stop keeps the session (ownership retained; never reported as stopped); it is
    /// `.unresolvedUnarmed` only when the protocol proves `arm` was never sent (review R1 B N3).
    private func abandonCurrent() async -> AgentLifecycleRelaunchAbandonment {
        guard let current = session else { return .safe }
        switch await current.abort() {
        case .safe:
            if session === current { session = nil }
            return .safe
        case let .unresolved(reason):
            return await current.armWasSent ? .unresolved(reason) : .unresolvedUnarmed(reason)
        }
    }

    /// Lossless restart Step 4b: waits for proof that the helper retained NOW (captured before any
    /// await) stopped, without joining or blocking the serialized hooks, then releases exactly that
    /// session (serialized; a correlated `aborted` or its observed exit is already latched, so the
    /// stop sends and awaits nothing). `false` when no helper is retained, the wait was cancelled,
    /// or another hook already released it. Never spawns, prepares, arms, or renews a budget.
    private func awaitRetainedStop() async -> Bool {
        guard let retained = session else { return false }
        guard await retained.stopProof() != nil, !Task.isCancelled else { return false }
        return await serialized { [weak self] in
            guard let self, session === retained else { return false }
            guard case .safe = await retained.abort() else { return false }
            if session === retained { session = nil }
            return true
        }
    }

    /// Whether a helper is retained (live, or its stop unresolved). Test observability.
    var retainsHelper: Bool {
        session != nil
    }
}

// MARK: - Production composition (gated OFF)

extension AppRelaunchCoordinator {
    /// `nil` unless Restart safely is qualified, Phase 3 registration is active, and the bundled
    /// helper resolves inside this exact bundle. The app's one activation
    /// (`AgentRecoveryActivation.production`) never qualifies it: safe restart has its own acceptance,
    /// and subset registration can't prove unregistered families stopped.
    static func production(
        qualification: AgentRecoveryActionQualification = AgentRecoveryActivation.production.actions,
        registry: AgentProcessRegistry? = AgentProcessRegistry.production
    ) -> AppRelaunchCoordinator? {
        guard qualification.safeRestart, let registry, registry.isAnyPairRegistered else { return nil }
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        // The ONLY helper resolver: the bundled auxiliary executable.
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.standardizedFileURL,
              helperURL.deletingLastPathComponent().path == bundleURL.appendingPathComponent("Contents/MacOS").path
        else { return nil }
        return AppRelaunchCoordinator(dependencies: Dependencies(
            spawnHelper: { try AppRelaunchHelperProcess.spawn(executableURL: helperURL) },
            parentIdentity: {
                guard case let .observed(observation) = ProcessInspection.inspect(pid: getpid()) else { return nil }
                return ProcessRelaunchParentIdentity(observation.identity)
            },
            bundlePath: bundleURL.path,
            verifyAllStopped: { await registry.verifyAllFamiliesStopped() }
        ))
    }
}

/// The real helper child: stdin/stdout pipes, exact-child exit via `Process` termination.
enum AppRelaunchHelperProcess {
    static func spawn(executableURL: URL) throws -> ProcessRelaunchHelperChannel {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [ProcessRelaunchInvocation.v1Argument]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let (inbound, inboundContinuation) = AsyncStream<ProcessRelaunchInbound>.makeStream()
        let exit = AppRelaunchExitLatch()
        let decoderBox = AppRelaunchDecoderBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                inboundContinuation.yield(decoderBox.finish())
                inboundContinuation.finish()
                return
            }
            for event in decoderBox.append(data) {
                inboundContinuation.yield(event)
            }
        }
        process.terminationHandler = { _ in exit.signal() }
        let writer = input.fileHandleForWriting
        // Writing to a helper that already exited fails with EPIPE instead of raising SIGPIPE
        // (the existing Platform mechanism, independent of the process-wide signal disposition).
        FDWriteSupport.configureNoSigPipe(fd: writer.fileDescriptor)
        try process.run()
        return ProcessRelaunchHelperChannel(
            send: { data in
                do {
                    try FDWriteSupport.writeAll(data, to: writer.fileDescriptor)
                    return true
                } catch {
                    return false
                }
            },
            inbound: inbound,
            waitForExit: { await exit.wait() },
            terminate: {
                // Exact child: `Process` has not reaped it while `isRunning`. SIGKILL is the bounded
                // last resort. Its delivery is not exit proof (review A P1-07): the parent session
                // waits for the observed exit (`waitForExit`) or a correlated `aborted`.
                guard process.isRunning else { return .notRunning }
                let pid = process.processIdentifier
                guard pid > 0 else { return .failed("its process identity is unknown") }
                guard kill(pid, SIGKILL) == 0 else {
                    return .failed(String(cString: strerror(errno)))
                }
                return .signalSent
            }
        )
    }
}

private final class AppRelaunchDecoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = ProcessRelaunchFrameDecoder()

    func append(_ data: Data) -> [ProcessRelaunchInbound] {
        lock.lock()
        defer { lock.unlock() }
        return decoder.append(data)
    }

    func finish() -> ProcessRelaunchInbound {
        lock.lock()
        defer { lock.unlock() }
        return decoder.finish()
    }
}

private final class AppRelaunchExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        exited = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
