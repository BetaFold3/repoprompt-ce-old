import Foundation

/// Single long-lived consumer of one Claude native controller events stream.
///
/// A Claude process outlives the user-triggered run that started it: after a successful
/// result the CLI can resume on its own (for example when a background task finishes) and
/// keep emitting output. The router keeps reading that stream between runs so received
/// output reaches the transcript immediately instead of waiting for the next user send.
///
/// Every event belongs to the run that was current when the controller emitted it, never to
/// whichever run happens to be consuming when it is dispatched. A run becomes current at its
/// in-band `.marker(attemptID)`, which the runner asks the controller to emit just before
/// sending the run's message; runtimes without markers fall back to the moment the run
/// resolves its start. One processor dispatches strictly in stream order:
/// - an event owned by the consuming run goes to that run's handler;
/// - an event owned by a run whose runner task is alive and not yet released (starting,
///   sending, or finalizing) waits for that run;
/// - an event owned by no live run is between-run output and goes to the idle handler, even if
///   a newer run is already consuming. It is never handled as the newer run's output.
/// - An approval request is never handled idle while the stream is live: it waits, with
///   everything after it, for the next consuming run, which owns approval state. A request
///   cancelled before any run saw it is dropped together with its cancellation, a cancellation
///   follows the run that received its request, and a request still held when the stream ends
///   goes to the idle handler, which discards it with the dead process.
///
/// The stream is never iterated by more than one task, and a run's cancellation never cancels
/// the stream's iterator (which would terminate the stream for every later run).
@MainActor
final class ClaudeNativeEventRouter {
    enum RunEventDisposition {
        case `continue`
        case finish
        /// The run stops consuming without taking this event; it is routed again by ownership.
        case detach
    }

    enum RunResolution {
        /// The run handler returned `.finish` or `.detach`.
        case finished
        /// The stream ended (or the router was already finished) before the run finished.
        case streamEnded
        /// The consuming task was cancelled.
        case cancelled
    }

    typealias RunEventHandler = @MainActor (NativeAgentRuntimeEvent) async -> RunEventDisposition
    typealias IdleEventHandler = @MainActor (NativeAgentRuntimeEvent) async -> Void

    private struct RunSink {
        let token: UUID
        let attemptID: UUID
        let handler: RunEventHandler
        let continuation: CheckedContinuation<RunResolution, Never>
    }

    private struct InboxEntry {
        let sequence: Int
        let event: NativeAgentRuntimeEvent
    }

    private struct RunStart {
        let attemptID: UUID
        let firstSequence: Int
    }

    private struct DrainWaiter {
        let markerID: UUID?
        var targetSequence: Int?
        let continuation: CheckedContinuation<Void, Never>
    }

    private enum Route {
        case run(RunSink)
        case idle
        case wait
    }

    /// Generation of the controller stream this router reads, when the runtime tracks it.
    let streamGeneration: UInt64?
    /// Identifies this stream (one provider launch) as the source of its between-run output.
    let backgroundSourceID: UUID
    private weak var controller: AnyObject?
    private let events: AsyncStream<NativeAgentRuntimeEvent>
    private let idleHandler: IdleEventHandler
    private let isRunTaskAlive: @MainActor (UUID) -> Bool
    private let onFinished: @MainActor (ClaudeNativeEventRouter) -> Void
    /// Called synchronously whenever an approval request is held in the inbox or a held approval
    /// request is dropped with its cancellation, so between-run approvals that appear and disappear
    /// without any delivery are still observed (the delegated idle release restarts its interval).
    /// Other events are not reported: delivered output re-arms through the between-run handler and
    /// undelivered output is fenced at expiry.
    private let onInboxChanged: @MainActor (ClaudeNativeEventRouter) -> Void

    private var inbox: [InboxEntry] = []
    private var inboxHead = 0
    private var nextSequence = 0
    /// Resolved run starts in stream order; an event belongs to the last start not after it.
    private var runStarts: [RunStart] = []
    /// Runs registered on this router whose start marker has not been read yet. They own nothing.
    private var pendingRunStarts: Set<UUID> = []
    /// Runs that will not consume again although their task is still alive.
    private var releasedRuns: Set<UUID> = []
    /// Positions of non-run markers that were read, keyed by marker ID, until a drain claims them.
    private var markerSequences: [UUID: Int] = [:]
    private var drainWaiters: [DrainWaiter] = []
    private var streamEndWaiters: [CheckedContinuation<Void, Never>] = []
    /// Approval requests dispatched to a run, keyed by Claude control request ID.
    private var approvalRecipients: [String: UUID] = [:]
    private var sink: RunSink?
    private var inFlightSequence: Int?
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var processorTask: Task<Void, Never>?
    /// The underlying stream reported its end. A finished stream is never reused for a new run.
    private(set) var hasStreamEnded = false
    /// The processor stopped; no further events will be dispatched.
    private(set) var isFinished = false

    /// - Parameters:
    ///   - initialOwner: the run that owns events read before any run start resolves on this
    ///     router, or `nil` when such events are between-run output.
    ///   - isRunTaskAlive: whether the runner task of a run attempt has not yet returned.
    init(
        controller: AnyObject,
        streamGeneration: UInt64?,
        backgroundSourceID: UUID = UUID(),
        events: AsyncStream<NativeAgentRuntimeEvent>,
        initialOwner: UUID?,
        idleHandler: @escaping IdleEventHandler,
        isRunTaskAlive: @escaping @MainActor (UUID) -> Bool,
        onFinished: @escaping @MainActor (ClaudeNativeEventRouter) -> Void = { _ in },
        onInboxChanged: @escaping @MainActor (ClaudeNativeEventRouter) -> Void = { _ in }
    ) {
        self.controller = controller
        self.streamGeneration = streamGeneration
        self.backgroundSourceID = backgroundSourceID
        self.events = events
        self.idleHandler = idleHandler
        self.isRunTaskAlive = isRunTaskAlive
        self.onFinished = onFinished
        self.onInboxChanged = onInboxChanged
        if let initialOwner {
            runStarts = [RunStart(attemptID: initialOwner, firstSequence: 0)]
        }
    }

    func isBound(to controller: AnyObject) -> Bool {
        self.controller === controller
    }

    func start() {
        guard readerTask == nil else { return }
        let events = events
        readerTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                enqueue(event)
            }
            self?.markStreamEnded()
        }
        processorTask = Task { [weak self] in
            await self?.runProcessor()
        }
    }

    /// Registers a run whose start marker will be read from this stream. Until then the run owns
    /// nothing. Call synchronously when the run begins, after its user row exists.
    func noteRunStarted(attemptID: UUID) {
        guard !runStarts.contains(where: { $0.attemptID == attemptID }) else { return }
        pendingRunStarts.insert(attemptID)
    }

    /// Resolves a registered run's start at the current read position, for runs whose start
    /// marker could not be emitted. Events read from now on belong to it.
    func resolveRunStart(attemptID: UUID) {
        guard pendingRunStarts.remove(attemptID) != nil else { return }
        appendRunStart(attemptID)
        signal()
    }

    /// Marks a run that will not consume again although its task is still alive (it is
    /// finalizing). Events it owns become between-run output.
    func release(attemptID: UUID) {
        guard releasedRuns.insert(attemptID).inserted else { return }
        signal()
    }

    /// Forgets a run whose task ended. Its events are no longer held for it.
    func noteRunEnded(attemptID: UUID) {
        pendingRunStarts.remove(attemptID)
        releasedRuns.remove(attemptID)
        approvalRecipients = approvalRecipients.filter { $0.value != attemptID }
        pruneRunStarts()
        signal()
    }

    /// Returns once the reader reached the end of the stream. Only call it for a stream the
    /// controller already finished; the wait then only covers events still buffered in it.
    func waitUntilStreamEnded() async {
        guard !hasStreamEnded else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            streamEndWaiters.append(continuation)
        }
    }

    /// Whether any read event is not yet dispatched, or one is being dispatched now (held approvals
    /// included). The delegated idle release never retires a runtime with such output.
    var hasUndeliveredEvents: Bool {
        !isFinished && (inboxHead < inbox.count || inFlightSequence != nil)
    }

    /// Whether any undelivered event belongs to `attemptID`.
    func holdsUndeliveredEvents(ownedBy attemptID: UUID) -> Bool {
        guard !isFinished, inboxHead < inbox.count else { return false }
        return inbox[inboxHead...].contains { owner(forSequence: $0.sequence) == attemptID }
    }

    /// Delivers the events owned by `attemptID` to `handler` until it returns `.finish` or
    /// `.detach`, the stream ends, or the calling task is cancelled.
    /// Cancellation detaches this run only; the stream keeps being read for later runs and idle
    /// delivery.
    func consumeRun(attemptID: UUID, _ handler: @escaping RunEventHandler) async -> RunResolution {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RunResolution, Never>) in
                guard !isFinished else {
                    continuation.resume(returning: .streamEnded)
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                if let previous = sink {
                    sink = nil
                    previous.continuation.resume(returning: .cancelled)
                }
                sink = RunSink(token: token, attemptID: attemptID, handler: handler, continuation: continuation)
                signal()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveSink(token: token, with: .cancelled)
            }
        }
    }

    /// Releases `attemptID` (it will not consume again) and returns once every event read before
    /// the marker `markerID` was dispatched, or, without a marker, every event read so far. It
    /// also returns when the remaining events cannot progress (they wait for another live run
    /// or hold an approval for the next run) or the router finishes.
    func drain(releasing attemptID: UUID?, throughMarker markerID: UUID?) async {
        // A run whose task already ended owns nothing that waits; recording it would never be pruned.
        if let attemptID, isRunTaskAlive(attemptID) {
            releasedRuns.insert(attemptID)
        }
        let target: Int? = if let markerID {
            markerSequences.removeValue(forKey: markerID)
        } else {
            nextSequence
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainWaiters.append(DrainWaiter(markerID: markerID, targetSequence: target, continuation: continuation))
            signal()
            checkDrainWaiters()
        }
    }

    /// Re-evaluates waiting events after a run task ended.
    func signal() {
        guard let continuation = wakeContinuation else { return }
        wakeContinuation = nil
        continuation.resume()
    }

    #if DEBUG
        /// Events read but not dispatched yet.
        var test_undeliveredEventCount: Int {
            inbox.count - inboxHead
        }

        /// The processor is suspended: its inbox is empty or its head waits.
        var test_isProcessorWaiting: Bool {
            wakeContinuation != nil
        }

        /// Drains that have not returned yet.
        var test_pendingDrainCount: Int {
            drainWaiters.count
        }
    #endif

    // MARK: - Private

    private func enqueue(_ event: NativeAgentRuntimeEvent) {
        if case let .marker(id) = event {
            // A live run's marker starts it even when the run registered on another router (or
            // before this one existed). Drain markers are fresh IDs, never run attempts.
            let isRunStart = pendingRunStarts.remove(id) != nil
                || (isRunTaskAlive(id) && !runStarts.contains { $0.attemptID == id })
            if isRunStart {
                appendRunStart(id)
            } else {
                // Unclaimed markers stay bounded.
                if markerSequences.count >= 64,
                   let oldest = markerSequences.min(by: { $0.value < $1.value })?.key
                {
                    markerSequences.removeValue(forKey: oldest)
                }
                markerSequences[id] = nextSequence
            }
            checkDrainWaiters()
            signal()
            return
        }
        if case let .approvalCancelled(requestID) = event,
           let index = undispatchedApprovalRequestIndex(requestID: requestID)
        {
            // No run has seen the request, so neither it nor its cancellation has an effect.
            inbox.remove(at: index)
            signal()
            onInboxChanged(self)
            return
        }
        inbox.append(InboxEntry(sequence: nextSequence, event: event))
        nextSequence += 1
        signal()
        if case .approvalRequest = event {
            onInboxChanged(self)
        }
    }

    private func appendRunStart(_ attemptID: UUID) {
        runStarts.append(RunStart(attemptID: attemptID, firstSequence: nextSequence))
        pruneRunStarts()
    }

    private func undispatchedApprovalRequestIndex(requestID: String) -> Int? {
        guard inboxHead < inbox.count else { return nil }
        return inbox[inboxHead...].firstIndex { entry in
            guard case let .approvalRequest(request) = entry.event else { return false }
            return request.requestID == .claudeControl(requestID)
        }
    }

    private func markStreamEnded() {
        hasStreamEnded = true
        let waiters = streamEndWaiters
        streamEndWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        signal()
        checkDrainWaiters()
    }

    private func resolveSink(token: UUID, with resolution: RunResolution) {
        guard let sink, sink.token == token else { return }
        self.sink = nil
        sink.continuation.resume(returning: resolution)
        signal()
    }

    private var oldestPendingSequence: Int {
        inboxHead < inbox.count ? inbox[inboxHead].sequence : nextSequence
    }

    private func ownerIndex(forSequence sequence: Int) -> Int? {
        runStarts.lastIndex { $0.firstSequence <= sequence }
    }

    private func owner(forSequence sequence: Int) -> UUID? {
        ownerIndex(forSequence: sequence).map { runStarts[$0].attemptID }
    }

    private func isLive(_ attemptID: UUID) -> Bool {
        !releasedRuns.contains(attemptID) && isRunTaskAlive(attemptID)
    }

    private func route(for entry: InboxEntry) -> Route {
        if case let .approvalCancelled(requestID) = entry.event,
           let recipient = approvalRecipients[requestID]
        {
            // A cancellation follows the run that received its request.
            if let sink, sink.attemptID == recipient {
                return .run(sink)
            }
            return isLive(recipient) ? .wait : .idle
        }
        let ownerIndex = ownerIndex(forSequence: entry.sequence)
        let owner = ownerIndex.map { runStarts[$0].attemptID }
        let isApprovalRequest = if case .approvalRequest = entry.event { true } else { false }
        if let sink {
            if owner == sink.attemptID {
                return .run(sink)
            }
            let sinkIndex = runStarts.lastIndex { $0.attemptID == sink.attemptID }
            if sinkIndex == nil, !pendingRunStarts.contains(sink.attemptID) {
                // Unregistered run: keep the pre-router behavior of handing everything to it.
                return .run(sink)
            }
            if let ownerIndex, let sinkIndex, ownerIndex > sinkIndex {
                // Owned by a newer run: wait for it while it can still consume, otherwise it is
                // between-run output. It is never the older consuming run's.
                return isLive(runStarts[ownerIndex].attemptID) ? .wait : .idle
            }
            // Emitted before the consuming run started, so it is not that run's output.
            if isApprovalRequest {
                // Approval state belongs to whichever run consumes next.
                return .run(sink)
            }
            if let owner, isLive(owner) {
                return .wait
            }
            return .idle
        }
        if let owner, isLive(owner) {
            return .wait
        }
        if isApprovalRequest, !hasStreamEnded {
            return .wait
        }
        return .idle
    }

    private func runProcessor() async {
        while true {
            if inboxHead < inbox.count {
                let entry = inbox[inboxHead]
                switch route(for: entry) {
                case let .run(sink):
                    consumeHead()
                    inFlightSequence = entry.sequence
                    let disposition = await sink.handler(entry.event)
                    inFlightSequence = nil
                    switch disposition {
                    case .continue:
                        recordDispatchedApproval(entry.event, recipient: sink.attemptID)
                    case .finish:
                        recordDispatchedApproval(entry.event, recipient: sink.attemptID)
                        resolveSink(token: sink.token, with: .finished)
                    case .detach:
                        restoreHead(entry)
                        resolveSink(token: sink.token, with: .finished)
                    }
                    pruneRunStarts()
                    checkDrainWaiters()
                    continue
                case .idle:
                    consumeHead()
                    if case let .approvalCancelled(requestID) = entry.event {
                        approvalRecipients.removeValue(forKey: requestID)
                    }
                    inFlightSequence = entry.sequence
                    await idleHandler(entry.event)
                    inFlightSequence = nil
                    pruneRunStarts()
                    checkDrainWaiters()
                    continue
                case .wait:
                    break
                }
            } else if hasStreamEnded {
                break
            }
            checkDrainWaiters()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wakeContinuation = continuation
            }
        }
        isFinished = true
        inbox.removeAll()
        inboxHead = 0
        if let sink {
            self.sink = nil
            sink.continuation.resume(returning: .streamEnded)
        }
        checkDrainWaiters()
        onFinished(self)
    }

    private func recordDispatchedApproval(_ event: NativeAgentRuntimeEvent, recipient: UUID) {
        switch event {
        case let .approvalRequest(request):
            if case let .claudeControl(requestID) = request.requestID {
                // Entries are dropped when the recipient run ends (`noteRunEnded`).
                approvalRecipients[requestID] = recipient
            }
        case let .approvalCancelled(requestID):
            approvalRecipients.removeValue(forKey: requestID)
        default:
            break
        }
    }

    /// Resolves drains whose events were all dispatched, or that cannot progress.
    private func checkDrainWaiters() {
        guard !drainWaiters.isEmpty else { return }
        let stopped = isFinished
        let frontier = inFlightSequence ?? oldestPendingSequence
        let stalled = isHeadWaiting
        var remaining: [DrainWaiter] = []
        for var waiter in drainWaiters {
            if waiter.targetSequence == nil, let markerID = waiter.markerID,
               let sequence = markerSequences.removeValue(forKey: markerID)
            {
                waiter.targetSequence = sequence
            }
            let isDone = if stopped {
                true
            } else if let target = waiter.targetSequence {
                frontier >= target || stalled
            } else {
                // The marker was not read yet; it cannot arrive after the stream ended.
                hasStreamEnded
            }
            if isDone {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        drainWaiters = remaining
    }

    /// Whether the undelivered head cannot be dispatched now: it waits for another live run or
    /// holds an approval for the next run. Evaluated against the current state, because a
    /// cancellation or release read since the processor last ran may have unblocked it.
    private var isHeadWaiting: Bool {
        guard inFlightSequence == nil, inboxHead < inbox.count else { return false }
        if case .wait = route(for: inbox[inboxHead]) {
            return true
        }
        return false
    }

    private func consumeHead() {
        inboxHead += 1
        if inboxHead == inbox.count {
            inbox.removeAll(keepingCapacity: true)
            inboxHead = 0
        } else if inboxHead > 64, inboxHead >= inbox.count / 2 {
            inbox.removeFirst(inboxHead)
            inboxHead = 0
        }
    }

    /// Puts a dispatched-but-declined event back at the head of the inbox.
    private func restoreHead(_ entry: InboxEntry) {
        if inboxHead > 0 {
            inboxHead -= 1
            inbox[inboxHead] = entry
        } else {
            inbox.insert(entry, at: 0)
        }
    }

    /// Drops run starts that no longer own any undelivered event, keeping the latest start and
    /// the start of every run that is consuming or alive (it may still consume).
    private func pruneRunStarts() {
        let oldestPendingSequence = oldestPendingSequence
        while runStarts.count >= 2,
              runStarts[1].firstSequence <= oldestPendingSequence,
              runStarts[0].attemptID != sink?.attemptID,
              !isRunTaskAlive(runStarts[0].attemptID)
        {
            runStarts.removeFirst()
        }
    }
}
