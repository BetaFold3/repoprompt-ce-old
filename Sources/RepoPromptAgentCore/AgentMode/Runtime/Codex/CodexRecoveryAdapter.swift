import Foundation

// Lossless restart Phase 4 §E: the thin facade over `CodexSessionControlling.observeRecovery`.
// It forwards the controller-owned observation and normalizes it for history-only reconciliation.
// It owns no client, process, cache, or rollout reader, and never resumes, starts, steers, or
// interrupts a thread (the normal send path owns `thread/resume` and the single `turn/start` of an
// explicit continuation).

package struct CodexRecoveryObservation: Equatable {
    package enum Terminal: String, Equatable {
        case completed
        case interrupted
        case failed
        /// The expected turn was not found within the bounded observation, or has no terminal status.
        case unconfirmed
    }

    package enum Source: String, Equatable {
        case turnsList
        case threadRead
    }

    package struct Item: Equatable {
        package enum Kind: String, Equatable {
            case agentMessage
            /// RepoPrompt-originated input: recorded in the ledger, never projected.
            case userMessage
        }

        package let nativeItemID: String
        package let kind: Kind
        package let text: String?

        package init(nativeItemID: String, kind: Kind, text: String?) {
            self.nativeItemID = nativeItemID
            self.kind = kind
            self.text = text
        }
    }

    package let threadID: String
    /// The expected native turn, when the observation found exactly that turn.
    package let turnID: String?
    package let terminal: Terminal
    /// Native abort/failure detail exactly as supplied (bounded); never synthesized.
    package let abortDetail: String?
    /// Supported item subset of the expected turn; `nil` when unavailable or unsupported.
    package let items: [Item]?
    package let source: Source
    package let transportGeneration: UInt64

    package init(
        threadID: String,
        turnID: String?,
        terminal: Terminal,
        abortDetail: String?,
        items: [Item]?,
        source: Source,
        transportGeneration: UInt64
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.terminal = terminal
        self.abortDetail = abortDetail
        self.items = items
        self.source = source
        self.transportGeneration = transportGeneration
    }
}

package enum CodexRecoveryObservationError: Error, Equatable {
    /// The controller does not implement observation (test doubles, legacy controllers).
    case unsupported
    /// Observation may start the transport, so it requires Phase 3 registration. Fails closed.
    case registeredTransportRequired
    case missingIdentity
    /// The transport changed while observing; the result cannot be attributed.
    case staleTransportGeneration
    /// The session, its lane/target, its controller or its captured workspace/policy changed during
    /// the observation transaction (or an existing controller is incompatible): nothing is usable.
    case staleContext
    /// The session is busy (a run is active), so no observation transport is acquired.
    case sessionBusy
}

package enum CodexRecoveryAdapter {
    /// Forwards one observation to the existing controller.
    package static func observe(
        controller: any CodexSessionControlling,
        threadID: String,
        expectedTurnID: String,
        timeout: TimeInterval?
    ) async throws -> CodexRecoveryObservation {
        try await controller.observeRecovery(threadID: threadID, expectedTurnID: expectedTurnID, timeout: timeout)
    }

    /// The observation did not find exactly the expected turn.
    package static let noMatchingTurnText = "Codex has no matching record of the interrupted turn."
    /// The expected turn was found, but its items are unavailable or outside the importable subset
    /// (9-live R2). Reason-neutral: a found turn with no readable items gives the same observation.
    package static let unsupportedTurnItemsText =
        "Codex's record of the interrupted turn was found, but its items couldn't be imported; nothing was imported."

    /// Why `historyObservation` found nothing usable in `observation`: no turn with the expected ID,
    /// or that turn found with items that can't be imported. Both are unconfirmed observations.
    package static func unusableObservationText(_ observation: CodexRecoveryObservation) -> String {
        observation.turnID == nil ? noMatchingTurnText : unsupportedTurnItemsText
    }

    /// Normalizes an observation for the import planner. `nil` when nothing is usable: the expected
    /// turn was not found (or was ambiguous), or its items are unavailable/unsupported and it is not
    /// verifiably completed. Completion is confirmed only by the expected turn's own `completed`
    /// status, and is kept even when its item subset cannot be projected (zero rows, completion
    /// confirmed), so a verified completion always suppresses a redispatch.
    package static func historyObservation(_ observation: CodexRecoveryObservation) -> AgentProviderHistoryObservation? {
        guard let turnID = observation.turnID else { return nil }
        let items: [CodexRecoveryObservation.Item]
        if let observedItems = observation.items {
            items = observedItems
        } else if observation.terminal == .completed {
            items = []
        } else {
            return nil
        }
        let provider = AgentRecoveryHistoryProvider.codex.rawValue
        let rows = items.map { item -> AgentProviderHistoryRow in
            let chatItem: AgentChatItem? = switch item.kind {
            case .agentMessage:
                item.text.map { text in
                    AgentChatItem.assistant(text).replacingID(ClaudeSessionHistoryReader.deterministicUUID(
                        namespace: "rpce-codex-history-row-v1",
                        components: [provider, observation.threadID, turnID, item.nativeItemID, item.kind.rawValue, "0"]
                    ))
                }
            case .userMessage:
                nil
            }
            return AgentProviderHistoryRow(
                nativeSessionID: observation.threadID,
                nativeEntryID: "\(turnID)/\(item.nativeItemID)",
                rowKindRaw: item.kind.rawValue,
                ordinal: 0,
                item: chatItem
            )
        }
        return AgentProviderHistoryObservation(
            provider: .codex,
            conversationID: observation.threadID,
            rows: rows,
            file: nil,
            completeLineOffset: 0,
            completionConfirmed: observation.terminal == .completed
        )
    }
}
