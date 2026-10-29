import Foundation

/// The one activation of lossless-restart recovery (Step 9-activation): runtime registration
/// qualification and recovery-action qualification decided together, so launch ownership, the
/// action runner, row presentation and Restart safely can never disagree. Every production consumer
/// reads `AgentRecoveryActivation.production`; tests inject a value explicitly. Not configurable by
/// environment or defaults: changing `production` is a reviewed source change backed by evidence.
package struct AgentRecoveryActivation: Equatable {
    package var runtime: AgentRuntimeQualification
    package var actions: AgentRecoveryActionQualification

    package init(runtime: AgentRuntimeQualification, actions: AgentRecoveryActionQualification) {
        self.runtime = runtime
        self.actions = actions
    }

    /// Nothing registered, no recovery action executes.
    package static let off = AgentRecoveryActivation(runtime: AgentRuntimeQualification(families: [:]), actions: .init())

    /// O32 (2026-10-26): recovery actions are offered for every provider; Claude Code (standard) and
    /// Codex are the live-qualified ones. A new provider must establish registration, ownership,
    /// history association, dispatch identity and settlement before its actions may execute.
    /// freshClaudeConversation and safeRestart stay off: each needs its own acceptance, and safe
    /// restart cannot prove unregistered families stopped (`verifyAllFamiliesStopped`).
    /// Subset registration is owner choice A (O37, 2026-10-26); production is .claudeAndCodex
    /// since the 9-flip (2026-10-29).
    ///
    /// Writer basenames are what the managed launchers exec; an unlisted basename (for example an
    /// npm-installed Claude running as `node`) stays `unknown` and keeps the runtime a possible
    /// writer. No tool basenames: nothing is positively a harmless tool until live evidence says so.
    package static let claudeAndCodex = AgentRecoveryActivation(
        runtime: AgentRuntimeQualification(families: [
            .claudeNative: claudeStandard,
            .claudeHeadless: claudeStandard,
            .codexAppServer: codex,
            .codexExec: codex
        ]),
        actions: AgentRecoveryActionQualification(sameConversationResume: true, historyReconciliation: true)
    )

    /// The app's activation. Switched on to `.claudeAndCodex` (9-flip, 2026-10-29) after the 9-live
    /// checks passed: Claude in round 4; Codex in rounds 1-3 (Check-confirmed holds, Continue,
    /// Reconcile). Evidence: the lossless-restart spec's Step 9-flip status line.
    package static let production: AgentRecoveryActivation = .claudeAndCodex

    /// Whether every supported family that serves this actual provider is covered (the runner's
    /// provider gate and dispatch-baseline capture): a provider whose runs can launch through an
    /// uncovered family (unregistered) is not covered, since recovery would act without process
    /// ownership of those runs. `nil` (no runtime provider) is never covered.
    package func coversProvider(_ provider: AgentRuntimeProvider?) -> Bool {
        guard let provider else { return false }
        let serving = AgentRuntimeQualification.supportedPairs.filter { $0.provider == provider }
        return !serving.isEmpty && serving.allSatisfy { runtime.covers(family: $0.family, provider: provider) }
    }

    private static let claudeStandard = AgentRuntimeFamilyQualification(
        providers: [.claude(.standard)],
        markerPropagation: true,
        completeDiscovery: true,
        writerExecutableBasenames: ["claude"]
    )

    private static let codex = AgentRuntimeFamilyQualification(
        providers: [.codex],
        markerPropagation: true,
        completeDiscovery: true,
        writerExecutableBasenames: ["codex"]
    )
}
