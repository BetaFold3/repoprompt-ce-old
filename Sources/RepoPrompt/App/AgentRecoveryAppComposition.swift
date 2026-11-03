import Foundation
import RepoPromptAgentCore

/// Lossless-restart production composition (spec R8, Phase 1b final cutover): exactly one recovery
/// store, the shared `AgentSessionDataService` gated by it, one recovery coordinator, and the
/// shared scheduled-send coordinator, injected into every window's Agent Mode view model with
/// mandatory admission before that view model hydrates anything.
///
/// Startup order: the scheduler is created closed (`.awaitingRecovery`) before any host
/// registers; the coordinator captures the previous launch mark, writes this launch's running
/// mark, inventories every workspace, reconciles each session under its DataService gate,
/// publishes results, crash holds, and scoped restrictions, reports ready, and only then is
/// scheduler admission opened. A global failure (unreadable workspace index, launch mark, or
/// discovery) keeps both closed until Retry succeeds. Startup constructs no provider, controller,
/// or view model, never awaits its own barrier, and never replays or resumes anything.
///
/// XCTest processes do not compose production recovery (`AgentRecoveryStore.production` is nil):
/// windows are constructed by the hundreds there and the real workspace index must never be read
/// or rewritten. Tests inject temporary compositions through `init` instead.
@MainActor
final class AgentRecoveryAppComposition {
    typealias InventoryLoader = @Sendable () throws -> AgentRecoveryWorkspaceInventory

    let scheduler: AgentScheduledSendCoordinator
    /// `nil` when composition is inactive or failed.
    let coordinator: AgentRecoveryCoordinator?
    /// Why composition failed; mandatory admission then stays fail-closed (no permissive fallback).
    let failure: String?
    /// Whether this composition selects mandatory recovery for the windows it installs into.
    let isActive: Bool
    /// The one recovery activation (runtime + action qualification) of this composition; its runner
    /// and registry are what every window it installs into uses.
    let activation: AgentRecoveryActivation
    /// The app's single runtime-ownership registry, built from `activation.runtime`.
    let processRegistry: AgentProcessRegistry?
    private var startupTask: Task<Void, Never>?
    /// Every window view model recovery was installed into (weak; a closed window drops out).
    private var installedViewModels: [WeakInstalledViewModel] = []

    private struct WeakInstalledViewModel {
        weak var viewModel: AgentModeViewModel?
    }

    /// - Parameters:
    ///   - store: the single recovery store; `nil` leaves recovery inactive (legacy behavior).
    ///   - dataService: must be configured with `store` (the coordinator validates it).
    ///   - scheduler: the shared scheduler; closed here before any host can register.
    ///   - processRegistry: the app's single runtime-ownership registry (spec R6) over `store`;
    ///     `nil` enforces no runtime records (XCTest compositions that don't exercise R6).
    ///   - activation: the recovery activation the installed runners use (production:
    ///     `AgentRecoveryActivation.production`, the same value the registry was built from).
    init(
        store: AgentRecoveryStore?,
        dataService: AgentSessionDataService,
        scheduler: AgentScheduledSendCoordinator,
        processRegistry: AgentProcessRegistry? = nil,
        activation: AgentRecoveryActivation = AgentRecoveryActivation.production,
        loadInventory: @escaping InventoryLoader
    ) {
        // One activation: the registry (launch ownership) and the runners (actions) read the same one.
        assert(
            processRegistry.map { $0.qualification == activation.runtime } ?? true,
            "The process registry must be built from this composition's activation"
        )
        self.scheduler = scheduler
        self.activation = activation
        self.processRegistry = processRegistry
        guard let store else {
            coordinator = nil
            failure = nil
            isActive = false
            return
        }
        isActive = true
        scheduler.closeStartupAdmission()
        scheduler.dispatchingRecordsRequireTransferResolution = true
        do {
            let composed = try AgentRecoveryCoordinator(
                store: store,
                dataService: dataService,
                reconcile: { report in
                    let inventory = try await Task.detached(priority: .userInitiated) {
                        try loadInventory()
                    }.value
                    return await AgentRecoveryStartupSweep.run(
                        inventory: inventory,
                        entries: report.discovered,
                        dataService: dataService
                    )
                }
            )
            coordinator = composed
            failure = nil
            // R6: existing runtime records are loaded and discovered during startup, before
            // admission opens; sessions are keyed by the windows hosting them.
            if let processRegistry {
                composed.attachProcessRegistry(processRegistry) { [weak self] sessionID in
                    self?.runtimeOwnershipKeys(sessionID: sessionID) ?? []
                }
            }
            // Schedules awaiting explicit confirmation are catalog items too (Phase 2): the shared
            // scheduler's summaries for hosted sessions, and every inventoried workspace's index for
            // sessions no window hosts (closed workspaces included). Hydrated sessions of windows
            // sharing this scheduler are authoritative through the scheduler, never the index.
            composed.attachScheduler(
                scheduler,
                hydratedSessionIDs: { [weak self] in self?.hydratedScheduleSessionIDs() ?? [] },
                indexWorkspaces: {
                    try? await Task.detached(priority: .utility) { try loadInventory() }.value.workspaces
                }
            )
        } catch {
            coordinator = nil
            // F6 / review B R5: plain wording reaches the banner; the raw error is logged privately.
            AgentRecoveryFailureDiagnostics.startupFailed(error)
            let message = AgentRecoveryStorageFailureCause.startupFailureDescription(error, nextStep: "then reopen RepoPrompt")
            failure = message
            scheduler.failStartupAdmission(message)
        }
    }

    /// The app's composition: production store and DataService outside XCTest, inactive inside.
    static let shared = AgentRecoveryAppComposition(
        store: AgentRecoveryStore.production,
        dataService: .shared,
        scheduler: AgentScheduledSendCoordinator(
            startupAdmission: AgentRecoveryStore.production == nil ? .open : .awaitingRecovery
        ),
        processRegistry: AgentProcessRegistry.production,
        activation: AgentRecoveryActivation.production,
        loadInventory: { try WorkspaceManagerViewModel.loadRecoveryWorkspaceInventory() }
    )

    /// The recovery action runner of `activation` over `registry`'s registration (defaults: the
    /// app's one production activation and registry). The view model's default and every
    /// installed window use this, so launch, runner and row presentation share one source.
    static func makeActionRunner(
        activation: AgentRecoveryActivation = AgentRecoveryActivation.production,
        registry: AgentProcessRegistry? = AgentProcessRegistry.production
    ) -> AgentRecoveryActionRunner {
        AgentRecoveryActionRunner(
            activation: activation,
            registrationActive: { registry?.isAnyPairRegistered == true }
        )
    }

    /// Installs recovery into a freshly created view model, before it hydrates any session or
    /// observes its first draft, then starts startup once. Inactive compositions install nothing.
    func install(into viewModel: AgentModeViewModel) {
        guard isActive else { return }
        installedViewModels.removeAll { $0.viewModel == nil || $0.viewModel === viewModel }
        installedViewModels.append(WeakInstalledViewModel(viewModel: viewModel))
        viewModel.recoveryActionRunner = Self.makeActionRunner(activation: activation, registry: processRegistry)
        viewModel.recoveryHistoryRegistry = processRegistry
        if let coordinator {
            viewModel.installRecoveryCoordinator(coordinator, admissionMode: .mandatory)
            viewModel.recoveryStartupRetry = { [weak self] in self?.retryStartup() }
        } else {
            viewModel.failRecoveryComposition(failure ?? "Recovery couldn't start.")
        }
        startIfNeeded()
    }

    func startIfNeeded() {
        guard let coordinator, startupTask == nil else { return }
        coordinator.startIfNeeded()
        startupTask = Task { [weak self] in
            await self?.releaseSchedulerAfterStartup()
        }
    }

    /// Re-runs a failed startup; scheduler admission stays closed until it is ready.
    func retryStartup() {
        guard let coordinator, case .failed = coordinator.startupState else { return }
        scheduler.closeStartupAdmission()
        coordinator.retryStartup()
        startupTask = Task { [weak self] in
            await self?.releaseSchedulerAfterStartup()
        }
    }

    /// Step 6 of the startup order: scheduler admission follows recovery readiness.
    private func releaseSchedulerAfterStartup() async {
        guard let coordinator else { return }
        switch await coordinator.awaitStartup() {
        case .ready:
            scheduler.openStartupAdmission()
        case let .failed(message):
            scheduler.failStartupAdmission(message)
        case .notStarted, .loading:
            break
        }
    }

    /// Sessions hydrated by a window that hosts this composition's scheduler.
    private func hydratedScheduleSessionIDs() -> Set<UUID> {
        var sessionIDs: Set<UUID> = []
        for entry in installedViewModels {
            guard let viewModel = entry.viewModel, viewModel.scheduledSendCoordinator === scheduler else { continue }
            for session in viewModel.sessions.values where session.hasLoadedPersistedState {
                if let sessionID = session.activeAgentSessionID {
                    sessionIDs.insert(sessionID)
                }
            }
        }
        return sessionIDs
    }

    /// What a durable session would touch, from every window hosting it: each native conversation
    /// it knows (Codex thread, Claude/ACP session) with its effective worktree, or the worktree
    /// alone before any conversation is known. Empty when no window hosts the session.
    private func runtimeOwnershipKeys(sessionID: UUID) -> [AgentRuntimeOwnershipKeys] {
        var keys: [AgentRuntimeOwnershipKeys] = []
        for entry in installedViewModels {
            guard let viewModel = entry.viewModel else { continue }
            for session in viewModel.sessions.values where session.activeAgentSessionID == sessionID {
                keys.append(contentsOf: viewModel.runtimeOwnershipKeys(for: session))
            }
        }
        return keys
    }

    /// Test observability: the task releasing the scheduler after startup.
    var startupCompletion: Task<Void, Never>? {
        startupTask
    }
}
