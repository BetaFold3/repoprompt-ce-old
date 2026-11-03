import Foundation
import os
import RepoPromptAgentCore

/// Persisted (`.notice`) unified-log lines for the two-stage quit / window close (lossless-restart
/// spec F5 observability): one line per phase transition of a shutdown request, every failure
/// prompt requested from the presenter, and the user's answer. Read with
/// `log show --predicate 'subsystem == "com.repoprompt.app" AND category == "LifecycleShutdown" AND process == "RepoPrompt"'`
/// (the app's executable is `RepoPrompt` in both the release and Dev bundles; the process filter
/// excludes identical lines written by test runs).
///
/// Only identifiers, counts, booleans, and fixed tokens are logged (all `.public`). Never blocker
/// text (it carries session titles), draft content, paths, or tokens.
enum AgentLifecycleShutdownDiagnostics {
    private static let logger = Logger(subsystem: "com.repoprompt.app", category: "LifecycleShutdown")

    /// Fixed token for a scope.
    static func scopeToken(_ scope: AgentLifecycleShutdownScope) -> String {
        switch scope {
        case .application: "application"
        case let .window(windowID): "window:\(windowID)"
        }
    }

    /// Fixed token for a phase.
    static func phaseToken(_ phase: AgentLifecycleShutdownPhase) -> String {
        switch phase {
        case .preparing: "preparing"
        case .preparationFailed: "preparation_failed"
        case .tearingDown: "tearing_down"
        case .finalizationFailed: "finalization_failed"
        case .completed: "completed"
        case .cancelled: "cancelled"
        }
    }

    /// Fixed token for a choice.
    static func choiceToken(_ choice: AgentLifecycleShutdownChoice) -> String {
        switch choice {
        case .retry: "retry"
        case .cancel: "cancel"
        case .proceedAnyway: "proceed_anyway"
        case .exitMayReopen: "exit_may_reopen"
        }
    }

    /// Which prompt a failure presents, as a fixed token: the stage, then why (deadline expired,
    /// a blocker, a missing clean-exit acknowledgement, or an unresolved relaunch helper).
    static func dialogStage(_ failure: AgentLifecycleShutdownFailure) -> String {
        let stage = failure.stage == .preparation ? "preparation" : "finalization"
        let cause: String = if failure.relaunchHelperUnresolved {
            failure.offersUncertainRelaunchExit ? "relaunch_unresolved_exit_offered" : "relaunch_unresolved"
        } else if failure.awaitsCleanExitAcknowledgement {
            "clean_exit_unacknowledged"
        } else if failure.timedOut {
            "deadline_expired"
        } else {
            "failure"
        }
        return "\(stage).\(cause)"
    }

    // MARK: Coordinator phase transitions

    static func requested(_ id: UUID, scope: AgentLifecycleShutdownScope, reason: AgentRecoveryShutdownReason, participants: Int) {
        logger.notice(
            "shutdown_requested request=\(id.uuidString, privacy: .public) scope=\(scopeToken(scope), privacy: .public) reason=\(reason.rawValue, privacy: .public) participants=\(participants, privacy: .public)"
        )
    }

    /// A repeated request that joins (or is refused by) the one in progress: it never starts an
    /// attempt or extends the deadline. `current` is `nil` when no request owns the scope.
    static func requestCoalesced(
        current: UUID?,
        scope: AgentLifecycleShutdownScope,
        reason: AgentRecoveryShutdownReason,
        cause: String
    ) {
        logger.notice(
            "shutdown_request_coalesced request=\(current?.uuidString ?? "none", privacy: .public) scope=\(scopeToken(scope), privacy: .public) reason=\(reason.rawValue, privacy: .public) cause=\(cause, privacy: .public)"
        )
    }

    /// `deadlineMilliseconds`: the attempt's effective work budget (`expiry - start`), i.e. the
    /// deadline minus Restart safely's cleanup reserve; `shutdown_deadline_fired` follows it.
    static func stageAStarted(_ id: UUID, attempt: UUID, attemptNumber: Int, participants: Int, deadlineMilliseconds: Int64) {
        logger.notice(
            "shutdown_stage_a_started request=\(id.uuidString, privacy: .public) attempt=\(attempt.uuidString, privacy: .public) attempt_number=\(attemptNumber, privacy: .public) participants=\(participants, privacy: .public) deadline_ms=\(deadlineMilliseconds, privacy: .public)"
        )
    }

    /// A Stage A step is entered (`step` is a fixed token; `index`/`count` for participants).
    static func stageAStep(_ id: UUID, attempt: UUID, step: String, index: Int? = nil, count: Int? = nil) {
        let position = index.map { " index=\($0 + 1)/\(count ?? 0)" } ?? ""
        logger.notice(
            "shutdown_stage_a_step request=\(id.uuidString, privacy: .public) attempt=\(attempt.uuidString, privacy: .public) step=\(step, privacy: .public)\(position, privacy: .public)"
        )
    }

    static func stageFinished(_ id: UUID, attempt: UUID, stage: AgentLifecycleShutdownStage, blockers: Int, timedOut: Bool) {
        let event = stage == .preparation ? "shutdown_stage_a_finished" : "shutdown_stage_b_finished"
        logger.notice(
            "\(event, privacy: .public) request=\(id.uuidString, privacy: .public) attempt=\(attempt.uuidString, privacy: .public) outcome=\(blockers == 0 ? "ready" : "blocked", privacy: .public) blockers=\(blockers, privacy: .public) timed_out=\(timedOut, privacy: .public)"
        )
    }

    /// A completion of an attempt that is no longer current (timed out, retried, cancelled): fenced.
    static func staleCompletionIgnored(_ id: UUID, attempt: UUID, stage: AgentLifecycleShutdownStage, phase: AgentLifecycleShutdownPhase) {
        logger.notice(
            "shutdown_stale_completion_ignored request=\(id.uuidString, privacy: .public) attempt=\(attempt.uuidString, privacy: .public) stage=\(stage == .preparation ? "preparation" : "finalization", privacy: .public) phase=\(phaseToken(phase), privacy: .public)"
        )
    }

    static func deadlineFired(_ id: UUID, attempt: UUID, phase: AgentLifecycleShutdownPhase) {
        logger.notice(
            "shutdown_deadline_fired request=\(id.uuidString, privacy: .public) attempt=\(attempt.uuidString, privacy: .public) phase=\(phaseToken(phase), privacy: .public)"
        )
    }

    static func vetoed(_ id: UUID) {
        logger.notice("shutdown_vetoed request=\(id.uuidString, privacy: .public)")
    }

    static func stageBStarted(_ id: UUID, participants: Int) {
        logger.notice(
            "shutdown_stage_b_started request=\(id.uuidString, privacy: .public) participants=\(participants, privacy: .public)"
        )
    }

    static func teardownFinished(_ id: UUID) {
        logger.notice("shutdown_teardown_finished request=\(id.uuidString, privacy: .public)")
    }

    /// `freshDeadlineMilliseconds`: the effective work budget of a deadline armed by this attempt
    /// (an explicit Retry); `nil` when it continues the deadline Stage A armed.
    static func finalizationStarted(_ id: UUID, attempt: UUID, attemptNumber: Int, freshDeadlineMilliseconds: Int64?) {
        let deadline = freshDeadlineMilliseconds.map { "fresh_deadline=true deadline_ms=\($0)" } ?? "fresh_deadline=false"
        logger.notice(
            "shutdown_finalization_started request=\(id.uuidString, privacy: .public) attempt=\(attempt.uuidString, privacy: .public) attempt_number=\(attemptNumber, privacy: .public) \(deadline, privacy: .public)"
        )
    }

    /// Logged immediately before the prompt is requested from the presenter (`presentFailure`): it
    /// means "requested", not "confirmed visible". A sheet that never appears or is hidden logs the
    /// same line.
    static func dialogPresented(_ failure: AgentLifecycleShutdownFailure, attempt: UUID, presentation: UUID) {
        logger.notice(
            "shutdown_dialog_presented request=\(failure.requestID.uuidString, privacy: .public) attempt=\(attempt.uuidString, privacy: .public) presentation=\(presentation.uuidString, privacy: .public) scope=\(scopeToken(failure.scope), privacy: .public) stage=\(dialogStage(failure), privacy: .public) timed_out=\(failure.timedOut, privacy: .public) blockers=\(failure.messages.count, privacy: .public)"
        )
    }

    /// The user's answer (or a dismissal's sentinel); `stale` when it answers a superseded prompt
    /// or attempt and is ignored.
    static func dialogChoice(
        _ failure: AgentLifecycleShutdownFailure,
        presentation: UUID,
        choice: AgentLifecycleShutdownChoice,
        stale: Bool
    ) {
        logger.notice(
            "shutdown_dialog_choice request=\(failure.requestID.uuidString, privacy: .public) presentation=\(presentation.uuidString, privacy: .public) stage=\(dialogStage(failure), privacy: .public) choice=\(choiceToken(choice), privacy: .public) stale=\(stale, privacy: .public)"
        )
    }

    /// The request ended: `completed` (the app may terminate / the window may close), `cancelled`,
    /// or `superseded`; `reply` is what its completion was given.
    static func ended(_ id: UUID, outcome: String, reply: Bool) {
        logger.notice(
            "shutdown_ended request=\(id.uuidString, privacy: .public) outcome=\(outcome, privacy: .public) reply=\(reply, privacy: .public)"
        )
    }

    // MARK: App termination entry (AppDelegate)

    /// `applicationShouldTerminate` was asked; `decision` is a fixed token.
    static func terminateRequested(decision: String, phase: String, reason: AgentRecoveryShutdownReason, current: UUID?) {
        logger.notice(
            "app_terminate_requested decision=\(decision, privacy: .public) phase=\(phase, privacy: .public) reason=\(reason.rawValue, privacy: .public) request=\(current?.uuidString ?? "none", privacy: .public)"
        )
    }

    /// The quit confirmation's answer (`quit`, `cancel`, or `stale` when ignored).
    static func quitConfirmationAnswered(_ answer: String) {
        logger.notice("app_quit_confirmation_answered answer=\(answer, privacy: .public)")
    }

    /// `beginTermination` was entered; `started` is whether it started a shutdown request. `cause`:
    /// `started`, `refused` (Restart safely unavailable, or admission sealed), `joined_in_progress`,
    /// or `already_terminating`.
    static func terminationBegan(started: Bool, current: UUID?, cause: String) {
        logger.notice(
            "app_termination_began started=\(started, privacy: .public) request=\(current?.uuidString ?? "none", privacy: .public) cause=\(cause, privacy: .public)"
        )
    }

    static func terminateReply(_ shouldTerminate: Bool, current: UUID?) {
        logger.notice(
            "app_terminate_reply should_terminate=\(shouldTerminate, privacy: .public) request=\(current?.uuidString ?? "none", privacy: .public)"
        )
    }

    // MARK: Stage A inside one window (AgentModeViewModel)

    /// Stage A is joining a session's pending composer preparation (unbounded; F5 stall lead).
    /// `stillPending` (finished only): the obligation outlived its preparation (a Stage A blocker).
    static func composerPreparationWait(request: UUID?, tabID: UUID, finished: Bool, stillPending: Bool = false) {
        let event = finished ? "finished still_pending=\(stillPending)" : "waiting"
        logger.notice(
            "shutdown_stage_a_composer_preparation request=\(request?.uuidString ?? "none", privacy: .public) tab=\(tabID.uuidString, privacy: .public) event=\(event, privacy: .public)"
        )
    }

    /// Stage A wrote no lane evidence for a session (no live recovery lane).
    static func sessionSkippedWithoutLane(request: UUID?, tabID: UUID, hasActiveRun: Bool) {
        logger.notice(
            "shutdown_stage_a_session_skipped request=\(request?.uuidString ?? "none", privacy: .public) tab=\(tabID.uuidString, privacy: .public) cause=no_live_lane has_active_run=\(hasActiveRun, privacy: .public)"
        )
    }
}
