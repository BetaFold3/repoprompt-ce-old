import Foundation

/// Correlates MCP-initiated Codex dispatch attempts with their explicit submit path.
///
/// Attempts are independent: dispatch authorization, delivery resolution, timeout, and
/// cancellation are all keyed by attempt ID. Terminal attempts remain tombstoned so a late
/// provider result cannot be buffered for, or accidentally resolve, a newer attempt.
///
/// The acknowledgement is bounded; the submission operation is not. Once the caller marks the
/// operation started (`markOperationStarted`), it may still save, queue, or deliver the input after
/// its caller stops waiting, so the acknowledgement deadline or caller cancellation then settles as
/// non-retryable `deliveryUnknown` (never `timedOut`/`cancelled`) and leaves the operation's dispatch
/// authorization intact. Before the operation starts they settle as `timedOut`/`cancelled` and the
/// operation never begins.
@MainActor
package final class CodexSteerAckTracker {
    nonisolated static let defaultTimeoutSeconds: TimeInterval = 2.5
    private var terminalStateTimeoutSeconds = CodexSteerAckTracker.defaultTimeoutSeconds

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func cancel() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    package enum TerminalState: Equatable {
        case steerAccepted
        case startAccepted
        case controlAccepted
        /// Held in the Codex fallback queue under its store-issued queue receipt (restart-held, not
        /// provider-accepted). The queue ID is the receipt's recovery intent ID.
        case durablyQueued(receipt: AgentRecoveryQueueReceipt)
        /// The handoff began but its result is not proven (or its durable evidence could not be
        /// written). Never retried automatically; the caller must not resend.
        case deliveryUnknown(message: String)
        case failed(message: String)
        case cancelled
        case stale(reason: String)
        case timedOut

        var confirmsInstructionDeliveryOrDurableQueue: Bool {
            switch self {
            case .steerAccepted, .startAccepted, .controlAccepted, .durablyQueued:
                true
            case .deliveryUnknown, .failed, .cancelled, .stale, .timedOut:
                false
            }
        }

        package var queueID: UUID? {
            if case let .durablyQueued(receipt) = self {
                return receipt.intent.intentID
            }
            return nil
        }

        package var failureDescriptionForMCP: String? {
            switch self {
            case .steerAccepted, .startAccepted, .controlAccepted, .durablyQueued:
                nil
            case let .deliveryUnknown(message):
                message.isEmpty
                    ? "Codex may have received this message, but delivery could not be confirmed. Do not resend it; recovery keeps it for review."
                    : message
            case let .failed(message):
                message.isEmpty
                    ? "Codex steer failed before reaching the active run."
                    : message
            case .cancelled:
                "Codex steer was cancelled before it reached the active run."
            case let .stale(reason):
                reason.isEmpty
                    ? "Codex steer was dropped because the active run changed before delivery."
                    : reason
            case .timedOut:
                "Codex did not start this instruction before the acknowledgement deadline; it was not submitted."
            }
        }
    }

    /// Acknowledgement expiry or caller cancellation after the submission operation started.
    package nonisolated static let unconfirmedOutcomeMessage =
        "The submission outcome could not be confirmed before the acknowledgement deadline. It may still be saved, queued, or delivered. Do not resend it automatically; inspect recovery."

    private struct AttemptRecord {
        let cancellationFlag = CancellationFlag()
        /// Set immediately before the submission operation's first potentially committing await.
        var operationMayComplete = false
        var isDispatchAuthorized = false
        var dispatchContinuation: CheckedContinuation<Bool, Never>?
        var terminalState: TerminalState?
        var terminalContinuation: CheckedContinuation<TerminalState, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private var attempts: [UUID: AttemptRecord] = [:]
    private var terminalAttemptOrder: [UUID] = []
    private let maxTerminalTombstones = 512
    #if DEBUG
        private(set) var test_latestAttemptID: UUID?

        var test_openAttemptIDs: [UUID] {
            attempts.compactMap { attemptID, record in
                record.terminalState == nil ? attemptID : nil
            }
        }

        @discardableResult
        func test_cancelOpenAttempts() -> [UUID] {
            let attemptIDs = test_openAttemptIDs
            for attemptID in attemptIDs {
                cancel(attemptID: attemptID)
            }
            return attemptIDs
        }

        func test_setTerminalStateTimeoutSeconds(_ timeoutSeconds: TimeInterval) {
            terminalStateTimeoutSeconds = timeoutSeconds
        }

        var test_terminalStateTimeoutSeconds: TimeInterval {
            terminalStateTimeoutSeconds
        }

        /// Deterministic deadlines for tests: no wall-clock timer is armed; an attempt's deadline
        /// fires only through `test_fireDeadline`.
        private var usesManualDeadlines = false

        func test_useManualDeadlines() {
            usesManualDeadlines = true
        }

        func test_fireDeadline(attemptID: UUID) {
            expireDeadline(attemptID: attemptID)
        }
    #endif

    private var armsWallClockDeadlines: Bool {
        #if DEBUG
            !usesManualDeadlines
        #else
            true
        #endif
    }

    package func beginAttempt() -> UUID {
        let attemptID = UUID()
        attempts[attemptID] = AttemptRecord()
        #if DEBUG
            test_latestAttemptID = attemptID
        #endif
        return attemptID
    }

    /// Marks the submission operation started, before its first potentially committing await.
    /// Returns false for a missing, terminal, or cancelled attempt; the caller must then submit nothing.
    /// This makes no claim that the provider received anything.
    package func markOperationStarted(attemptID: UUID) -> Bool {
        guard var record = attempts[attemptID],
              record.terminalState == nil
        else { return false }
        if record.cancellationFlag.isCancelled {
            resolve(attemptID: attemptID, state: .cancelled)
            return false
        }
        record.operationMayComplete = true
        attempts[attemptID] = record
        return true
    }

    /// A started operation keeps its authorization even after its acknowledgement settled as
    /// uncertain: neither the deadline nor caller cancellation withdraws an admitted submission.
    package func authorizeDispatch(attemptID: UUID) {
        guard var record = attempts[attemptID],
              !record.isDispatchAuthorized,
              record.terminalState == nil || record.operationMayComplete
        else { return }
        if record.cancellationFlag.isCancelled, !record.operationMayComplete {
            resolve(attemptID: attemptID, state: .cancelled)
            return
        }
        record.isDispatchAuthorized = true
        let continuation = record.dispatchContinuation
        record.dispatchContinuation = nil
        attempts[attemptID] = record
        continuation?.resume(returning: true)
    }

    package func awaitDispatchAuthorization(attemptID: UUID) async -> Bool {
        guard let cancellationFlag = attempts[attemptID]?.cancellationFlag else {
            return false
        }
        if Task.isCancelled {
            cancellationFlag.cancel()
            cancel(attemptID: attemptID)
            return false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var record = attempts[attemptID] else {
                    continuation.resume(returning: false)
                    return
                }
                if record.isDispatchAuthorized {
                    continuation.resume(returning: true)
                    return
                }
                guard record.terminalState == nil || record.operationMayComplete else {
                    continuation.resume(returning: false)
                    return
                }
                record.dispatchContinuation = continuation
                attempts[attemptID] = record
            }
        } onCancel: {
            cancellationFlag.cancel()
            Task { @MainActor [weak self] in
                self?.cancel(attemptID: attemptID)
                // The cancelled dispatch waiter itself never proceeds, even for a started operation.
                self?.releaseDispatchWait(attemptID: attemptID)
            }
        }
    }

    private func releaseDispatchWait(attemptID: UUID) {
        guard var record = attempts[attemptID],
              let continuation = record.dispatchContinuation
        else { return }
        record.dispatchContinuation = nil
        attempts[attemptID] = record
        continuation.resume(returning: false)
    }

    /// The first terminal state is permanent. A caller-cancellation flag never overwrites a producer's
    /// result: cancellation settles only through `cancel(attemptID:)`, in main-actor order.
    package func resolve(attemptID: UUID, state: TerminalState) {
        guard var record = attempts[attemptID],
              record.terminalState == nil
        else { return }
        record.terminalState = state
        record.timeoutTask?.cancel()
        record.timeoutTask = nil
        // A started operation that has not been authorized yet keeps waiting for its own
        // authorization; only an operation that cannot proceed is released as unauthorized.
        let dispatchContinuation = record.operationMayComplete ? nil : record.dispatchContinuation
        if !record.operationMayComplete {
            record.dispatchContinuation = nil
        }
        let terminalContinuation = record.terminalContinuation
        record.terminalContinuation = nil
        attempts[attemptID] = record
        terminalAttemptOrder.append(attemptID)
        pruneTerminalTombstonesIfNeeded()
        dispatchContinuation?.resume(returning: false)
        terminalContinuation?.resume(returning: state)
    }

    /// Caller cancellation: `.cancelled` before the operation starts, non-retryable uncertainty after.
    package func cancel(attemptID: UUID) {
        guard let record = attempts[attemptID] else { return }
        record.cancellationFlag.cancel()
        let state: TerminalState = record.operationMayComplete
            ? .deliveryUnknown(message: Self.unconfirmedOutcomeMessage)
            : .cancelled
        resolve(attemptID: attemptID, state: state)
    }

    /// Acknowledgement deadline: `.timedOut` (nothing submitted) before the operation starts,
    /// non-retryable uncertainty after. Never stales or withdraws the operation itself.
    private func expireDeadline(attemptID: UUID) {
        guard let record = attempts[attemptID] else { return }
        let state: TerminalState = record.operationMayComplete
            ? .deliveryUnknown(message: Self.unconfirmedOutcomeMessage)
            : .timedOut
        resolve(attemptID: attemptID, state: state)
    }

    func markStale(attemptID: UUID, reason: String) {
        resolve(attemptID: attemptID, state: .stale(reason: reason))
    }

    package func awaitTerminalState(
        attemptID: UUID,
        timeoutSeconds: TimeInterval? = nil
    ) async -> TerminalState {
        guard let cancellationFlag = attempts[attemptID]?.cancellationFlag else {
            return .stale(reason: "Codex dispatch attempt was not registered.")
        }
        if Task.isCancelled {
            cancellationFlag.cancel()
            cancel(attemptID: attemptID)
            return attempts[attemptID]?.terminalState ?? .cancelled
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var record = attempts[attemptID] else {
                    continuation.resume(returning: .stale(
                        reason: "Codex dispatch attempt was not registered."
                    ))
                    return
                }
                if let terminalState = record.terminalState {
                    continuation.resume(returning: terminalState)
                    return
                }
                record.terminalContinuation = continuation
                if armsWallClockDeadlines {
                    let timeout = max(0.1, timeoutSeconds ?? terminalStateTimeoutSeconds)
                    record.timeoutTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self?.expireDeadline(attemptID: attemptID)
                    }
                }
                attempts[attemptID] = record
            }
        } onCancel: {
            cancellationFlag.cancel()
            Task { @MainActor [weak self] in
                self?.cancel(attemptID: attemptID)
            }
        }
    }

    private func pruneTerminalTombstonesIfNeeded() {
        var index = 0
        while terminalAttemptOrder.count > maxTerminalTombstones, index < terminalAttemptOrder.count {
            let expiredID = terminalAttemptOrder[index]
            if let record = attempts[expiredID],
               record.terminalState == nil
               || record.dispatchContinuation != nil
               || record.terminalContinuation != nil
            {
                // Keep attempts with live waiters tracked so a later prune can still remove them.
                index += 1
                continue
            }
            attempts.removeValue(forKey: expiredID)
            terminalAttemptOrder.remove(at: index)
        }
    }
}
