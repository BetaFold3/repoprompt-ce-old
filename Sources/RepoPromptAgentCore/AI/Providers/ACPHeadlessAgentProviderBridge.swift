import Foundation

/// Shared one-shot ACP stream bridge for headless discovery/delegate providers.
///
/// Agent Mode owns the long-lived ACP runner; this bridge keeps the smaller
/// `HeadlessAgentProvider` lifecycle used by discovery/delegate-edit paths while
/// centralizing cancellation, controller registration, prompt forwarding, and
/// approval fallback handling for ACP-backed providers.
final class ACPHeadlessAgentProviderBridge: HeadlessAgentProvider {
    enum ApprovalPolicy {
        case declineUnsupported
        case acceptForSession
    }

    typealias ProviderFactory = () -> any ACPAgentProvider
    typealias RequestFactory = (_ message: AgentMessage, _ runID: UUID) -> ACPRunRequest
    typealias ControllerFactory = (
        _ provider: any ACPAgentProvider,
        _ request: ACPRunRequest,
        _ diagnosticSink: ACPAgentSessionController.DiagnosticSink?
    ) throws -> ACPAgentSessionController
    typealias BeforePrompt = (_ controller: ACPAgentSessionController, _ request: ACPRunRequest, _ runID: UUID) async throws -> Void

    private let providerName: String
    private let makeProvider: ProviderFactory
    private let makeRequest: RequestFactory
    private let makeController: ControllerFactory
    private let beforePrompt: BeforePrompt
    private let approvalPolicy: ApprovalPolicy
    private let lifecycle = ACPHeadlessProviderLifecycle()

    init(
        providerName: String,
        makeProvider: @escaping ProviderFactory,
        makeRequest: @escaping RequestFactory,
        makeController: @escaping ControllerFactory,
        beforePrompt: @escaping BeforePrompt = { _, _, _ in },
        approvalPolicy: ApprovalPolicy
    ) {
        self.providerName = providerName
        self.makeProvider = makeProvider
        self.makeRequest = makeRequest
        self.makeController = makeController
        self.beforePrompt = beforePrompt
        self.approvalPolicy = approvalPolicy
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let actualRunID = runID ?? UUID()
        let request = makeRequest(message, actualRunID)
        let provider = makeProvider()

        await lifecycle.waitForDisposalIfNeeded()

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [lifecycle] termination in
                guard case .cancelled = termination else { return }
                Task { await lifecycle.dispose() }
            }

            let generation = lifecycle.startStreamTask { generation in
                Task { [self] in
                    await runACPStream(
                        message: message,
                        request: request,
                        provider: provider,
                        runID: actualRunID,
                        generation: generation,
                        continuation: continuation
                    )
                }
            }

            if generation == nil {
                continuation.finish(throwing: CancellationError())
            }
        }
    }

    func dispose() async {
        await lifecycle.dispose()
    }

    private func runACPStream(
        message: AgentMessage,
        request: ACPRunRequest,
        provider: any ACPAgentProvider,
        runID: UUID,
        generation: UInt64,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    ) async {
        defer { lifecycle.clearStreamTask(generation: generation) }

        do {
            let support = try await provider.support(for: request)
            guard support == .supported else {
                throw AIProviderError.invalidConfiguration(
                    detail: support.reason ?? "\(providerName) ACP is not available."
                )
            }
            try Task.checkCancellation()

            let controller = try makeController(provider, request, nil)
            let handleID = UUID()
            let registered = lifecycle.setActiveController(
                ACPHeadlessProviderLifecycle.ControllerHandle(id: handleID) {
                    await controller.cancelPrompt()
                    await controller.shutdown()
                },
                generation: generation
            )
            guard registered else {
                await controller.cancelPrompt()
                await controller.shutdown()
                continuation.finish(throwing: CancellationError())
                return
            }
            defer { lifecycle.clearActiveController(id: handleID, generation: generation) }

            await controller.setExpectedMCPRunID(runID)
            let events = await controller.currentEventsStream()
            let forwardTask = Task {
                await Self.forwardEvents(
                    events,
                    controller: controller,
                    providerName: providerName,
                    approvalPolicy: approvalPolicy,
                    to: continuation
                )
            }

            do {
                _ = try await controller.bootstrap()
                try await Self.performPromptAfterBarrier(
                    // R6: pre-prompt owner writes (requested mode) carry the request's captured scope.
                    beforePrompt: {
                        try await AgentRuntimeOperationOwner.$session.withValue(request.runtimeSession) {
                            try await beforePrompt(controller, request, runID)
                        }
                    },
                    sendPrompt: { try await controller.prompt(message, request: request) }
                )
                await controller.shutdown()
                await forwardTask.value
            } catch {
                forwardTask.cancel()
                let processLost = await controller.providerProcessWasLost()
                await controller.shutdown()
                let normalized = await controller.normalizeError(error)
                // Review A F06: the provider process exited under the prompt (not our shutdown).
                if processLost, !(normalized is CancellationError) {
                    throw HeadlessProviderProcessLostError(message: normalized.localizedDescription)
                }
                throw normalized
            }
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: Self.outerStreamError(error, normalize: provider.normalizeError))
        }
    }

    /// The stream's terminal error. A typed process loss passes through unnormalized so the runner
    /// can still attribute it (review R1, A F06 follow-up): provider normalization may rewrap it.
    static func outerStreamError(_ error: Error, normalize: (Error) -> Error) -> Error {
        if error is HeadlessProviderProcessLostError { return error }
        return normalize(error)
    }

    static func performPromptAfterBarrier(
        beforePrompt: () async throws -> Void,
        sendPrompt: () async throws -> Void
    ) async throws {
        try await beforePrompt()
        try await sendPrompt()
    }

    private static func forwardEvents(
        _ events: AsyncStream<NormalizedAgentRuntimeEvent>,
        controller: ACPAgentSessionController,
        providerName: String,
        approvalPolicy: ApprovalPolicy,
        to continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    ) async {
        var terminalError: String?
        for await event in events {
            switch event {
            case let .stream(result):
                continuation.yield(result)
            case let .terminal(state, errorText):
                if state == .failed {
                    terminalError = errorText ?? "\(providerName) ACP run failed."
                }
            case let .approvalRequested(request):
                switch approvalPolicy {
                case .acceptForSession:
                    await controller.respondToPermissionRequest(
                        id: request.requestID.displayValue,
                        decision: .acceptForSession
                    )
                case .declineUnsupported:
                    let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = reason.isEmpty
                        ? "\(providerName) requested tool approval, which is not supported in headless discovery runs."
                        : "\(providerName) requested tool approval during headless discovery: \(reason)"
                    await controller.respondToPermissionRequest(id: request.requestID.displayValue, decision: .decline)
                    await controller.cancelPrompt()
                    continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: message))
                    return
                }
            case .approvalCancelled:
                break
            }
        }

        if Task.isCancelled {
            return
        }
        if let terminalError {
            // Review A F06: a failure the controller reported because its process exited.
            if await controller.providerProcessWasLost() {
                continuation.finish(throwing: HeadlessProviderProcessLostError(message: terminalError))
            } else {
                continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: terminalError))
            }
        } else {
            continuation.finish()
        }
    }
}
