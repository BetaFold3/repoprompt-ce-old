@testable import RepoPromptWorkspace

#if DEBUG
    import Foundation
    import MCP
    @testable import RepoPromptAgentCore
    @testable import RepoPromptPlatform
    @testable import RepoPromptUI
    import XCTest
    @_spi(TestSupport) @testable import RepoPromptApp

    @MainActor
    final class AgentToolCorrelationIndexTests: XCTestCase {
        func testIncrementalMutationAndFullReplacementKeepCorrelationIndexesAligned() throws {
            let session = AgentTabSession(tabID: UUID())
            let priorInvocationID = UUID()
            let activeInvocationID = UUID()
            let pendingArgs = #"{"path":"Sources/Active.swift"}"#
            let pendingSignature = AgentTabSession.canonicalToolInvocationSignature(
                toolName: "read_file",
                argsJSON: pendingArgs
            )
            session.setItemsSilently([
                .user("prior", sequenceIndex: 0),
                .toolResult(
                    name: "read_file",
                    invocationID: priorInvocationID,
                    resultJSON: "prior",
                    isError: false,
                    sequenceIndex: 1
                ),
                .user("active", sequenceIndex: 2),
                .toolCall(
                    name: "read_file",
                    invocationID: activeInvocationID,
                    argsJSON: pendingArgs,
                    sequenceIndex: 3
                )
            ], reason: .persistedSessionHydration)

            XCTAssertTrue(session.indexedToolItemIndices(invocationID: priorInvocationID).isEmpty)
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: activeInvocationID), [3])
            XCTAssertEqual(session.indexedToolItemIndices(signature: pendingSignature, pendingCallsOnly: true), [3])
            XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))

            let activeItemID = session.items[3].id
            var completed = session.items[3]
            completed.kind = .toolResult
            completed.toolResultJSON = #"{"status":"success"}"#
            completed.text = completed.toolResultJSON ?? ""
            session.replaceItem(at: 3, with: completed)

            XCTAssertEqual(session.items[3].id, activeItemID)
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: activeInvocationID), [3])
            XCTAssertTrue(session.indexedToolItemIndices(signature: pendingSignature, pendingCallsOnly: true).isEmpty)
            XCTAssertEqual(session.indexedToolItemIndices(signature: pendingSignature), [3])
            XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))

            _ = try XCTUnwrap(session.removeItem(at: 3))
            XCTAssertTrue(session.indexedToolItemIndices(invocationID: activeInvocationID).isEmpty)
            XCTAssertFalse(session.liveItemIDs.contains(activeItemID))

            let replacementInvocationID = UUID()
            session.setItemsSilently([
                .user("replacement", sequenceIndex: 10),
                .toolCall(
                    name: "file_search",
                    invocationID: replacementInvocationID,
                    argsJSON: #"{"pattern":"needle"}"#,
                    sequenceIndex: 11
                )
            ], reason: .retentionCompaction)

            XCTAssertEqual(session.indexedToolItemIndices(invocationID: replacementInvocationID), [1])
            XCTAssertEqual(session.liveItemIDs, Set(session.items.map(\.id)))
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        func testActiveTurnPrefixRetentionPreservesToolCorrelationBoundary() {
            let session = AgentTabSession(tabID: UUID())
            let firstActiveInvocationID = UUID()
            let secondActiveInvocationID = UUID()
            session.setItemsSilently([
                .user("historical", sequenceIndex: 0),
                .assistant("historical response", sequenceIndex: 1),
                .user("active", sequenceIndex: 2),
                .toolCall(
                    name: "read_file",
                    invocationID: firstActiveInvocationID,
                    argsJSON: #"{"path":"Sources/First.swift"}"#,
                    sequenceIndex: 3
                )
            ], reason: .testOverride)
            session.runState = .running
            session.appendItem(.user("steering", sequenceIndex: session.nextSequenceIndex))
            session.appendItem(.toolCall(
                name: "file_search",
                invocationID: secondActiveInvocationID,
                argsJSON: #"{"pattern":"needle"}"#,
                sequenceIndex: session.nextSequenceIndex
            ))

            session.setItemsSilently(Array(session.items.dropFirst(2)), reason: .retentionCompaction)

            XCTAssertEqual(session.indexedToolItemIndices(invocationID: firstActiveInvocationID), [1])
            XCTAssertEqual(session.indexedToolItemIndices(invocationID: secondActiveInvocationID), [3])
            let activeCalls = session.activeTurnToolItemIndices { $0.kind == .toolCall }
            XCTAssertEqual(activeCalls.indices, [1, 3])
            XCTAssertEqual(activeCalls.scannedItemCount, 3)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        func testClaudeCompletionObserverUsesConstantWorkInvocationIndex() throws {
            let handler = ClaudeAgentToolTrackingHandler(mcpHost: ServerNetworkManager.shared)
            let short = makeSession(priorTurnCount: 1)
            let long = makeSession(priorTurnCount: 2000)

            let shortAttribution = try claudeCompletionAttribution(
                handler: handler,
                session: short.session,
                invocationID: short.invocationID
            )
            let longAttribution = try claudeCompletionAttribution(
                handler: handler,
                session: long.session,
                invocationID: long.invocationID
            )

            XCTAssertEqual(shortAttribution.correlationPath, "invocation_id")
            XCTAssertEqual(longAttribution.correlationPath, "invocation_id")
            XCTAssertEqual(shortAttribution.scannedItemCount, 1)
            XCTAssertEqual(longAttribution.scannedItemCount, 1)
        }

        func testRunningSteeringUserItemPreservesInFlightToolCorrelation() {
            let handler = ClaudeAgentToolTrackingHandler(mcpHost: ServerNetworkManager.shared)
            let session = AgentTabSession(tabID: UUID())
            let invocationID = UUID()
            session.setItemsSilently([
                .user("active", sequenceIndex: 0),
                .toolCall(
                    name: "read_file",
                    invocationID: invocationID,
                    argsJSON: #"{"path":"Sources/Active.swift"}"#,
                    sequenceIndex: 1
                )
            ], reason: .testOverride)
            session.runState = .running

            session.appendItem(.user("steering", sequenceIndex: session.nextSequenceIndex))

            XCTAssertEqual(session.indexedToolItemIndices(invocationID: invocationID), [1])

            handler.handleTrackerToolResult(
                invocationID: invocationID,
                toolName: "read_file",
                args: nil,
                resultJSON: #"{"content":"ok"}"#,
                isError: false,
                session: session
            )

            XCTAssertEqual(session.items.count, 3)
            XCTAssertEqual(session.items[1].kind, .toolResult)
            XCTAssertEqual(session.items[1].toolInvocationID, invocationID)
            XCTAssertEqual(session.items[2].kind, .user)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        // MARK: - Claude ask_user dual-source correlation

        /// Tracker completion arguments survive when no call row can be correlated.
        func testUnmatchedTrackerCompletionPreservesAvailableArguments() throws {
            let (handler, session) = makeAskUserHarness()
            let trackerID = UUID()

            try trackerResult(handler, session, id: trackerID, args: askArgsJSON(["scope", "risk"]), answers: ["scope": "UI", "risk": "Low"])

            let rows = toolRows(session)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.kind, .toolResult)
            XCTAssertEqual(rows.first?.toolInvocationID, trackerID)
            XCTAssertEqual(questionIDs(rows.first?.toolArgsJSON), ["scope", "risk"])
            XCTAssertEqual(answerValues(rows.first?.toolResultJSON), ["scope": "UI", "risk": "Low"])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// Incident-shaped mechanism (not a claimed historical chronology): exchange A completes without
        /// arguments, then a distinct exchange B arrives. B's events must never attach B's questions to A.
        func testLaterExchangeCannotRewriteCompletedExchangeMissingArguments() throws {
            let (handler, session) = makeAskUserHarness()
            let trackerA = UUID()
            let providerB = UUID()
            let trackerB = UUID()
            let argsB = askArgsJSON(["stop_blocks_send", "notice"])

            try trackerResult(handler, session, id: trackerA, args: nil, answers: ["actions": "Ship"])
            providerCall(handler, session, id: providerB, args: argsB)
            try trackerCall(handler, session, id: trackerB, args: argsB)
            try trackerResult(handler, session, id: trackerB, args: argsB, answers: ["stop_blocks_send": "Yes", "notice": "Banner"])
            providerResult(handler, session, id: providerB, answers: ["stop_blocks_send": "Yes", "notice": "Banner"])

            let rows = toolRows(session)
            XCTAssertEqual(rows.count, 2)
            guard rows.count == 2 else { return }
            XCTAssertEqual(rows[0].toolInvocationID, trackerA)
            XCTAssertNil(rows[0].toolArgsJSON, "A keeps its honest missing-arguments state")
            XCTAssertEqual(answerValues(rows[0].toolResultJSON), ["actions": "Ship"])
            XCTAssertEqual(rows[1].kind, .toolResult)
            XCTAssertEqual(rows[1].toolInvocationID, providerB)
            XCTAssertEqual(questionIDs(rows[1].toolArgsJSON), ["stop_blocks_send", "notice"])
            XCTAssertEqual(answerValues(rows[1].toolResultJSON), ["stop_blocks_send": "Yes", "notice": "Banner"])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// A completed exchange whose arguments are present is never rewritten by a different later call.
        func testLaterExchangeCannotRewriteCompletedExchangeArguments() throws {
            let (handler, session) = makeAskUserHarness()
            let providerA = UUID()
            let trackerA = UUID()
            let providerB = UUID()
            let argsA = askArgsJSON(["actions"])
            let argsB = askArgsJSON(["stop_blocks_send"])

            providerCall(handler, session, id: providerA, args: argsA)
            try trackerCall(handler, session, id: trackerA, args: argsA)
            try trackerResult(handler, session, id: trackerA, args: argsA, answers: ["actions": "Ship"])
            providerResult(handler, session, id: providerA, answers: ["actions": "Ship"])
            providerCall(handler, session, id: providerB, args: argsB)

            let rows = toolRows(session)
            XCTAssertEqual(rows.count, 2)
            guard rows.count == 2 else { return }
            XCTAssertEqual(questionIDs(rows[0].toolArgsJSON), ["actions"])
            XCTAssertEqual(answerValues(rows[0].toolResultJSON), ["actions": "Ship"])
            XCTAssertEqual(rows[1].kind, .toolCall)
            XCTAssertEqual(rows[1].toolInvocationID, providerB)
            XCTAssertEqual(questionIDs(rows[1].toolArgsJSON), ["stop_blocks_send"])
        }

        /// Identical questions asked twice stay two exchanges, each with its own answers, in both normal
        /// provider-first and tracker-first arrival orders.
        func testRepeatedIdenticalSignaturesKeepDistinctExchanges() throws {
            for trackerFirst in [false, true] {
                let label = trackerFirst ? "tracker-first" : "provider-first"
                let (handler, session) = makeAskUserHarness()
                let args = askArgsJSON(["proceed"])
                let exchanges = [(UUID(), UUID(), "first"), (UUID(), UUID(), "second")]
                for (providerID, trackerID, answer) in exchanges {
                    if trackerFirst {
                        try trackerCall(handler, session, id: trackerID, args: args)
                        providerCall(handler, session, id: providerID, args: args)
                    } else {
                        providerCall(handler, session, id: providerID, args: args)
                        try trackerCall(handler, session, id: trackerID, args: args)
                    }
                    try trackerResult(handler, session, id: trackerID, args: args, answers: ["proceed": answer])
                    providerResult(handler, session, id: providerID, answers: ["proceed": answer])
                }

                let rows = toolRows(session)
                XCTAssertEqual(rows.count, 2, label)
                XCTAssertEqual(rows.map(\.kind), [.toolResult, .toolResult], label)
                XCTAssertEqual(rows.map(\.toolInvocationID), exchanges.map(\.0), label)
                XCTAssertEqual(rows.map { answerValues($0.toolResultJSON)["proceed"] }, ["first", "second"], label)
                XCTAssertEqual(rows.map { questionIDs($0.toolArgsJSON) }, [["proceed"], ["proceed"]], label)
                session.testAssertSourceItemDerivedStateIsConsistent()
            }
        }

        /// A duplicate completion for exchange A resolves to A and cannot terminalize a later identical B.
        func testDuplicateCompletionCannotTerminalizeLaterSameSignaturePendingCall() throws {
            let (handler, session) = makeAskUserHarness()
            let args = askArgsJSON(["proceed"])
            let providerA = UUID()
            let trackerA = UUID()
            let providerB = UUID()
            let trackerB = UUID()

            providerCall(handler, session, id: providerA, args: args)
            try trackerCall(handler, session, id: trackerA, args: args)
            try trackerResult(handler, session, id: trackerA, args: args, answers: ["proceed": "first"])
            providerResult(handler, session, id: providerA, answers: ["proceed": "first"])
            providerCall(handler, session, id: providerB, args: args)
            try trackerCall(handler, session, id: trackerB, args: args)
            try trackerResult(handler, session, id: trackerA, args: args, answers: ["proceed": "first"])

            var rows = toolRows(session)
            XCTAssertEqual(rows.count, 2)
            guard rows.count == 2 else { return }
            XCTAssertEqual(answerValues(rows[0].toolResultJSON), ["proceed": "first"])
            XCTAssertEqual(rows[1].kind, .toolCall, "B remains pending after A's duplicate completion")
            XCTAssertEqual(rows[1].toolInvocationID, providerB)

            try trackerResult(handler, session, id: trackerB, args: args, answers: ["proceed": "second"])
            rows = toolRows(session)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.map { answerValues($0.toolResultJSON)["proceed"] }, ["first", "second"])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// Legitimate late events for an established invocation enrich it once; terminal rows never reopen
        /// and a provider result never supersedes the tracker result.
        func testLateSameInvocationEventsEnrichOnceWithoutDuplicating() throws {
            let args = askArgsJSON(["proceed"])

            // Tracker first; provider call and result arrive after completion.
            do {
                let (handler, session) = makeAskUserHarness()
                let providerID = UUID()
                let trackerID = UUID()
                try trackerCall(handler, session, id: trackerID, args: args)
                try trackerResult(handler, session, id: trackerID, args: args, answers: ["proceed": "tracker"])
                providerCall(handler, session, id: providerID, args: args)
                providerCall(handler, session, id: providerID, args: args)
                providerResult(handler, session, id: providerID, answers: ["proceed": "provider"])

                let rows = toolRows(session)
                XCTAssertEqual(rows.count, 1, "late provider events")
                XCTAssertEqual(rows.first?.kind, .toolResult)
                XCTAssertEqual(answerValues(rows.first?.toolResultJSON), ["proceed": "tracker"])
                XCTAssertEqual(questionIDs(rows.first?.toolArgsJSON), ["proceed"])
            }

            // Provider terminalizes first; the established tracker completion still wins.
            do {
                let (handler, session) = makeAskUserHarness()
                let providerID = UUID()
                let trackerID = UUID()
                providerCall(handler, session, id: providerID, args: args)
                try trackerCall(handler, session, id: trackerID, args: args)
                try trackerCall(handler, session, id: trackerID, args: args)
                providerResult(handler, session, id: providerID, answers: ["proceed": "provider"])
                XCTAssertEqual(answerValues(toolRows(session).first?.toolResultJSON), ["proceed": "provider"])
                try trackerResult(handler, session, id: trackerID, args: args, answers: ["proceed": "tracker"])
                providerResult(handler, session, id: providerID, answers: ["proceed": "provider"])

                let rows = toolRows(session)
                XCTAssertEqual(rows.count, 1, "provider-terminalized")
                XCTAssertEqual(rows.first?.toolInvocationID, providerID)
                XCTAssertEqual(answerValues(rows.first?.toolResultJSON), ["proceed": "tracker"])
                session.testAssertSourceItemDerivedStateIsConsistent()
            }
        }

        /// Tradeoff: a provider call arriving after an unpaired completed tracker exchange with identical
        /// arguments is treated as that exchange's late provider event (provider streams order each call
        /// before later calls). The completed exchange is never rewritten, and a genuinely new call still
        /// gets its own row from its tracker events.
        func testProviderCallAfterUnpairedCompletedTrackerExchangeNeverRewritesIt() throws {
            let (handler, session) = makeAskUserHarness()
            let args = askArgsJSON(["proceed"])
            let trackerA = UUID()
            let providerB = UUID()
            let trackerB = UUID()

            try trackerCall(handler, session, id: trackerA, args: args)
            try trackerResult(handler, session, id: trackerA, args: args, answers: ["proceed": "first"])
            providerCall(handler, session, id: providerB, args: args)
            try trackerCall(handler, session, id: trackerB, args: args)
            try trackerResult(handler, session, id: trackerB, args: args, answers: ["proceed": "second"])
            providerResult(handler, session, id: providerB, answers: ["proceed": "second"])

            let rows = toolRows(session)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.map { answerValues($0.toolResultJSON)["proceed"] }, ["first", "second"])
            XCTAssertEqual(rows.map { questionIDs($0.toolArgsJSON) }, [["proceed"], ["proceed"]])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// Tradeoff: identical concurrent calls cannot be paired by signature, so observations stay separate
        /// rather than guessing which provider call a tracker call belongs to.
        func testAmbiguousIdenticalPendingCallsStaySeparate() throws {
            let (handler, session) = makeAskUserHarness()
            let args = askArgsJSON(["proceed"])
            let provider1 = UUID()
            let provider2 = UUID()
            let tracker1 = UUID()

            providerCall(handler, session, id: provider1, args: args)
            providerCall(handler, session, id: provider2, args: args)
            try trackerCall(handler, session, id: tracker1, args: args)
            try trackerResult(handler, session, id: tracker1, args: args, answers: ["proceed": "first"])

            let rows = toolRows(session)
            XCTAssertEqual(rows.map(\.toolInvocationID), [provider1, provider2, tracker1])
            XCTAssertEqual(rows.map(\.kind), [.toolCall, .toolCall, .toolResult])
            XCTAssertEqual(answerValues(rows.last?.toolResultJSON), ["proceed": "first"])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// A steering message appended while the run waits for the human answer keeps in-flight correlation,
        /// including the turn reset that Claude native dispatch performs for the steering send.
        func testWaitingForQuestionSteeringPreservesPendingAskUserCorrelation() throws {
            let (handler, session) = makeAskUserHarness()
            let args = askArgsJSON(["proceed"])
            let providerID = UUID()
            let trackerID = UUID()

            providerCall(handler, session, id: providerID, args: args)
            try trackerCall(handler, session, id: trackerID, args: args)
            session.runState = .waitingForQuestion
            session.appendItem(.user("steering while waiting", sequenceIndex: session.nextSequenceIndex))
            // `sendClaudeNativeMessage` marks the run running and resets turn state before sending.
            session.runState = .running
            handler.resetTurnState(for: session)
            try trackerResult(handler, session, id: trackerID, args: args, answers: ["proceed": "yes"])
            providerResult(handler, session, id: providerID, answers: ["proceed": "yes"])

            var rows = toolRows(session)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.kind, .toolResult)
            XCTAssertEqual(rows.first?.toolInvocationID, providerID)
            XCTAssertEqual(answerValues(rows.first?.toolResultJSON), ["proceed": "yes"])
            XCTAssertEqual(session.items.last?.kind, .user)

            // After steering, a duplicate old completion stays with its exchange and a new identical
            // question gets its own row.
            let providerB = UUID()
            let trackerB = UUID()
            providerCall(handler, session, id: providerB, args: args)
            try trackerCall(handler, session, id: trackerB, args: args)
            try trackerResult(handler, session, id: trackerID, args: args, answers: ["proceed": "yes"])
            try trackerResult(handler, session, id: trackerB, args: args, answers: ["proceed": "no"])
            rows = toolRows(session)
            XCTAssertEqual(rows.map(\.toolInvocationID), [providerID, providerB])
            XCTAssertEqual(rows.map { answerValues($0.toolResultJSON)["proceed"] }, ["yes", "no"])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// Review R1: provider A completes and provider B starts with identical arguments before A's delayed
        /// tracker events arrive. A completed unclaimed provider exchange competes with pending B, so the
        /// ambiguity keeps observations separate. B must never receive A's answer.
        /// Tradeoff: tracker events stay in their own rows (duplicate cards) rather than guessing.
        func testDelayedTrackerEventsNeverCrossWireIntoLaterSameSignatureProviderCall() throws {
            let (handler, session) = makeAskUserHarness()
            let args = askArgsJSON(["proceed"])
            let providerA = UUID()
            let trackerA = UUID()
            let providerB = UUID()
            let trackerB = UUID()

            providerCall(handler, session, id: providerA, args: args)
            providerResult(handler, session, id: providerA, answers: ["proceed": "first"])
            providerCall(handler, session, id: providerB, args: args)
            try trackerCall(handler, session, id: trackerA, args: args)
            try trackerResult(handler, session, id: trackerA, args: args, answers: ["proceed": "first"])

            XCTAssertNotEqual(
                answerValues(toolRows(session).first { $0.toolInvocationID == providerB }?.toolResultJSON)["proceed"],
                "first",
                "B must never be terminalized with A's answer"
            )

            try trackerCall(handler, session, id: trackerB, args: args)
            try trackerResult(handler, session, id: trackerB, args: args, answers: ["proceed": "second"])
            providerResult(handler, session, id: providerB, answers: ["proceed": "second"])

            let rows = toolRows(session)
            XCTAssertEqual(rows.map(\.toolInvocationID), [providerA, providerB, trackerA, trackerB])
            XCTAssertEqual(rows.map(\.kind), [.toolResult, .toolResult, .toolResult, .toolResult])
            XCTAssertEqual(
                rows.map { answerValues($0.toolResultJSON)["proceed"] },
                ["first", "second", "first", "second"]
            )
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// Review R1 inverse: tracker A completes and tracker B is pending before A's delayed provider call.
        /// The completed unclaimed tracker exchange competes with pending B, so the provider call stays
        /// separate and A's provider identity never terminalizes B.
        func testDelayedProviderCallNeverCrossWiresIntoLaterSameSignatureTrackerCall() throws {
            let (handler, session) = makeAskUserHarness()
            let args = askArgsJSON(["proceed"])
            let providerA = UUID()
            let trackerA = UUID()
            let providerB = UUID()
            let trackerB = UUID()

            try trackerCall(handler, session, id: trackerA, args: args)
            try trackerResult(handler, session, id: trackerA, args: args, answers: ["proceed": "first"])
            try trackerCall(handler, session, id: trackerB, args: args)
            providerCall(handler, session, id: providerA, args: args)
            providerCall(handler, session, id: providerB, args: args)
            try trackerResult(handler, session, id: trackerB, args: args, answers: ["proceed": "second"])
            providerResult(handler, session, id: providerA, answers: ["proceed": "first"])
            providerResult(handler, session, id: providerB, answers: ["proceed": "second"])

            let rows = toolRows(session)
            XCTAssertEqual(rows.map(\.toolInvocationID), [trackerA, trackerB, providerA, providerB])
            XCTAssertEqual(rows.map(\.kind), [.toolResult, .toolResult, .toolResult, .toolResult])
            XCTAssertEqual(
                rows.map { answerValues($0.toolResultJSON)["proceed"] },
                ["first", "second", "first", "second"]
            )
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// Review R2: an empty-error completion removes A's pending row. Duplicate callbacks for removed A
        /// must neither recreate a row nor claim and remove a later same-signature call B.
        func testRemovedEmptyErrorInvocationIgnoresDuplicateCallbacks() throws {
            let (handler, session) = makeAskUserHarness()
            let args = askArgsJSON(["proceed"])
            let providerA = UUID()
            let trackerA = UUID()
            let providerB = UUID()
            let trackerB = UUID()

            providerCall(handler, session, id: providerA, args: args)
            try trackerCall(handler, session, id: trackerA, args: args)
            try trackerEmptyError(handler, session, id: trackerA, args: args)
            XCTAssertTrue(toolRows(session).isEmpty)

            try trackerCall(handler, session, id: trackerA, args: args)
            XCTAssertTrue(toolRows(session).isEmpty, "a duplicate call for removed A creates no row")
            providerCall(handler, session, id: providerB, args: args)
            try trackerEmptyError(handler, session, id: trackerA, args: args)
            XCTAssertEqual(toolRows(session).map(\.toolInvocationID), [providerB], "duplicate A error keeps B")

            try trackerCall(handler, session, id: trackerB, args: args)
            try trackerResult(handler, session, id: trackerB, args: args, answers: ["proceed": "second"])
            let rows = toolRows(session)
            XCTAssertEqual(rows.map(\.toolInvocationID), [providerB])
            XCTAssertEqual(rows.first?.kind, .toolResult)
            XCTAssertEqual(answerValues(rows.first?.toolResultJSON), ["proceed": "second"])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// Ordinary RepoPrompt tools pair one-to-one under the same rules, in both arrival orders.
        func testReadFileProviderAndTrackerEventsPairIntoOneRow() throws {
            let args = #"{"path":"Sources/Active.swift"}"#
            for trackerFirst in [false, true] {
                let label = trackerFirst ? "tracker-first" : "provider-first"
                let (handler, session) = makeAskUserHarness()
                let providerID = UUID()
                let trackerID = UUID()
                if trackerFirst {
                    try readFileTrackerCall(handler, session, id: trackerID, args: args)
                    readFileProviderCall(handler, session, id: providerID, args: args)
                } else {
                    readFileProviderCall(handler, session, id: providerID, args: args)
                    try readFileTrackerCall(handler, session, id: trackerID, args: args)
                }
                try readFileTrackerResult(handler, session, id: trackerID, args: args, content: "tracker")
                readFileProviderResult(handler, session, id: providerID, content: "provider")

                let rows = toolRows(session)
                XCTAssertEqual(rows.count, 1, label)
                XCTAssertEqual(rows.first?.kind, .toolResult, label)
                XCTAssertEqual(rows.first?.toolInvocationID, providerID, label)
                XCTAssertEqual(rows.first?.toolResultJSON, #"{"content":"tracker"}"#, label)
                XCTAssertEqual(readFilePath(rows.first?.toolArgsJSON), "Sources/Active.swift", label)
                session.testAssertSourceItemDerivedStateIsConsistent()
            }
        }

        /// A provider call without a tool-use ID still pairs with its unique tracker invocation and keeps the
        /// tracker identity for the row.
        func testNilProviderInvocationIDPairsWithUniqueTrackerInvocation() throws {
            let args = #"{"path":"Sources/Active.swift"}"#
            let (handler, session) = makeAskUserHarness()
            let trackerID = UUID()

            readFileProviderCall(handler, session, id: nil, args: args)
            try readFileTrackerCall(handler, session, id: trackerID, args: args)
            try readFileTrackerResult(handler, session, id: trackerID, args: args, content: "tracker")

            let rows = toolRows(session)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.kind, .toolResult)
            XCTAssertEqual(rows.first?.toolInvocationID, trackerID)
            XCTAssertEqual(rows.first?.toolResultJSON, #"{"content":"tracker"}"#)
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        /// A new idle user turn ends the previous turn's correlation: an identical call in the new turn gets
        /// its own row and never resolves to the completed row from the earlier turn.
        func testNewIdleTurnDoesNotReusePreviousTurnBindings() throws {
            let args = #"{"path":"Sources/Active.swift"}"#
            let (handler, session) = makeAskUserHarness()
            let providerA = UUID()
            let trackerA = UUID()
            readFileProviderCall(handler, session, id: providerA, args: args)
            try readFileTrackerCall(handler, session, id: trackerA, args: args)
            try readFileTrackerResult(handler, session, id: trackerA, args: args, content: "first")

            session.runState = .completed
            session.appendItem(.user("next turn", sequenceIndex: session.nextSequenceIndex))
            session.runState = .running
            handler.resetTurnState(for: session)

            let providerB = UUID()
            let trackerB = UUID()
            readFileProviderCall(handler, session, id: providerB, args: args)
            try readFileTrackerCall(handler, session, id: trackerB, args: args)
            try readFileTrackerResult(handler, session, id: trackerA, args: args, content: "stale duplicate")
            XCTAssertEqual(
                toolRows(session).first { $0.toolInvocationID == providerB }?.kind,
                .toolCall,
                "an old-turn duplicate never completes B"
            )
            try readFileTrackerResult(handler, session, id: trackerB, args: args, content: "second")

            let rows = toolRows(session).filter { $0.toolInvocationID != trackerA }
            XCTAssertEqual(rows.map(\.toolInvocationID), [providerA, providerB])
            XCTAssertEqual(rows.map(\.toolResultJSON), [#"{"content":"first"}"#, #"{"content":"second"}"#])
            session.testAssertSourceItemDerivedStateIsConsistent()
        }

        private static let providerReadFileToolName = "mcp__RepoPromptCE__read_file"

        private func readFilePath(_ argsJSON: String?) -> String? {
            guard let data = argsJSON?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["path"] as? String
        }

        private func readFileProviderCall(
            _ handler: ClaudeAgentToolTrackingHandler,
            _ session: AgentTabSession,
            id: UUID?,
            args: String
        ) {
            handler.handleProviderToolEvent(
                .toolCall(.init(toolName: Self.providerReadFileToolName, invocationID: id, argsJSON: args)),
                session: session
            )
        }

        private func readFileProviderResult(
            _ handler: ClaudeAgentToolTrackingHandler,
            _ session: AgentTabSession,
            id: UUID?,
            content: String
        ) {
            handler.handleProviderToolEvent(
                .toolResult(.init(
                    toolName: Self.providerReadFileToolName,
                    invocationID: id,
                    argsJSON: nil,
                    resultJSON: #"{"content":"\#(content)"}"#,
                    isError: false
                )),
                session: session
            )
        }

        private func readFileTrackerCall(
            _ handler: ClaudeAgentToolTrackingHandler,
            _ session: AgentTabSession,
            id: UUID,
            args: String
        ) throws {
            try handler.handleTrackerToolCall(
                invocationID: id,
                toolName: "read_file",
                args: trackerArgs(args),
                session: session
            )
        }

        private func readFileTrackerResult(
            _ handler: ClaudeAgentToolTrackingHandler,
            _ session: AgentTabSession,
            id: UUID,
            args: String,
            content: String
        ) throws {
            try handler.handleTrackerToolResult(
                invocationID: id,
                toolName: "read_file",
                args: trackerArgs(args),
                resultJSON: #"{"content":"\#(content)"}"#,
                isError: false,
                session: session
            )
        }

        private func trackerEmptyError(
            _ handler: ClaudeAgentToolTrackingHandler,
            _ session: AgentTabSession,
            id: UUID,
            args: String?
        ) throws {
            try handler.handleTrackerToolResult(
                invocationID: id,
                toolName: Self.trackerAskUserToolName,
                args: args.map(trackerArgs),
                resultJSON: "",
                isError: true,
                session: session
            )
        }

        private static let providerAskUserToolName = "mcp__RepoPromptCE__ask_user"
        private static let trackerAskUserToolName = "ask_user"

        private func makeAskUserHarness() -> (ClaudeAgentToolTrackingHandler, AgentTabSession) {
            let handler = ClaudeAgentToolTrackingHandler(mcpHost: ServerNetworkManager.shared)
            let session = AgentTabSession(tabID: UUID())
            session.selectedAgent = .claudeCode
            session.setItemsSilently([.user("interview me", sequenceIndex: 0)], reason: .testOverride)
            session.runState = .running
            handler.resetTurnState(for: session)
            return (handler, session)
        }

        private func askArgsJSON(_ ids: [String]) -> String {
            let questions = ids.map { #"{"id":"\#($0)","question":"Decide \#($0)?","options":["Yes","No"]}"# }
            return #"{"questions":[\#(questions.joined(separator: ","))]}"#
        }

        private func answersJSON(_ answers: [String: String]) -> String {
            let entries = answers.keys.sorted().map { key -> String in
                let value = answers[key] ?? ""
                return #""\#(key)":{"answers":["\#(value)"]}"#
            }
            return #"{"answers":{\#(entries.joined(separator: ","))}}"#
        }

        private func providerCall(_ handler: ClaudeAgentToolTrackingHandler, _ session: AgentTabSession, id: UUID?, args: String?) {
            handler.handleProviderToolEvent(
                .toolCall(.init(toolName: Self.providerAskUserToolName, invocationID: id, argsJSON: args)),
                session: session
            )
        }

        private func providerResult(
            _ handler: ClaudeAgentToolTrackingHandler,
            _ session: AgentTabSession,
            id: UUID?,
            answers: [String: String]
        ) {
            handler.handleProviderToolEvent(
                .toolResult(.init(
                    toolName: Self.providerAskUserToolName,
                    invocationID: id,
                    argsJSON: nil,
                    resultJSON: answersJSON(answers),
                    isError: false
                )),
                session: session
            )
        }

        private func trackerCall(_ handler: ClaudeAgentToolTrackingHandler, _ session: AgentTabSession, id: UUID, args: String?) throws {
            try handler.handleTrackerToolCall(
                invocationID: id,
                toolName: Self.trackerAskUserToolName,
                args: args.map(trackerArgs),
                session: session
            )
        }

        private func trackerResult(
            _ handler: ClaudeAgentToolTrackingHandler,
            _ session: AgentTabSession,
            id: UUID,
            args: String?,
            answers: [String: String]
        ) throws {
            try handler.handleTrackerToolResult(
                invocationID: id,
                toolName: Self.trackerAskUserToolName,
                args: args.map(trackerArgs),
                resultJSON: answersJSON(answers),
                isError: false,
                session: session
            )
        }

        private func trackerArgs(_ json: String) throws -> [String: Value] {
            try JSONDecoder().decode([String: Value].self, from: Data(json.utf8))
        }

        private func toolRows(_ session: AgentTabSession) -> [AgentChatItem] {
            session.items.filter { $0.kind == .toolCall || $0.kind == .toolResult }
        }

        private func questionIDs(_ argsJSON: String?) -> [String] {
            guard let data = argsJSON?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let questions = object["questions"] as? [[String: Any]]
            else { return [] }
            return questions.compactMap { $0["id"] as? String }
        }

        private func answerValues(_ resultJSON: String?) -> [String: String] {
            guard let data = resultJSON?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = object["answers"] as? [String: [String: Any]]
            else { return [:] }
            return answers.compactMapValues { ($0["answers"] as? [String])?.first }
        }

        private func claudeCompletionAttribution(
            handler: ClaudeAgentToolTrackingHandler,
            session: AgentTabSession,
            invocationID: UUID
        ) throws -> MCPToolObserverAttribution {
            let recorder = MCPToolObserverAttributionRecorder()
            MCPToolObserverAttributionContext.$recorder.withValue(recorder) {
                handler.handleTrackerToolResult(
                    invocationID: invocationID,
                    toolName: "read_file",
                    args: nil,
                    resultJSON: #"{"content":"ok"}"#,
                    isError: false,
                    session: session
                )
            }
            XCTAssertEqual(session.items.last?.kind, .toolResult)
            return try XCTUnwrap(recorder.snapshot())
        }

        func testActiveTurnFallbackScanCostDoesNotScaleWithHistoricalTranscriptLength() {
            let short = makeSession(priorTurnCount: 1)
            let long = makeSession(priorTurnCount: 2000)

            let shortScan = short.session.activeTurnToolItemIndices(where: { $0.toolName == "missing" })
            let longScan = long.session.activeTurnToolItemIndices(where: { $0.toolName == "missing" })

            XCTAssertEqual(shortScan.scannedItemCount, 1)
            XCTAssertEqual(longScan.scannedItemCount, 1)
            XCTAssertEqual(short.session.indexedToolItemIndices(invocationID: short.invocationID).count, 1)
            XCTAssertEqual(long.session.indexedToolItemIndices(invocationID: long.invocationID).count, 1)
        }

        private func makeSession(priorTurnCount: Int) -> (
            session: AgentTabSession,
            invocationID: UUID
        ) {
            var items: [AgentChatItem] = []
            items.reserveCapacity(priorTurnCount * 2 + 2)
            var sequenceIndex = 0
            for turn in 0 ..< priorTurnCount {
                items.append(.user("historical user \(turn)", sequenceIndex: sequenceIndex))
                sequenceIndex += 1
                items.append(.assistant("historical assistant \(turn)", sequenceIndex: sequenceIndex))
                sequenceIndex += 1
            }
            items.append(.user("active user", sequenceIndex: sequenceIndex))
            sequenceIndex += 1
            let invocationID = UUID()
            items.append(.toolCall(
                name: "read_file",
                invocationID: invocationID,
                argsJSON: #"{"path":"Sources/Active.swift"}"#,
                sequenceIndex: sequenceIndex
            ))
            let session = AgentTabSession(tabID: UUID())
            session.setItemsSilently(items, reason: .testOverride)
            return (session, invocationID)
        }
    }
#endif
