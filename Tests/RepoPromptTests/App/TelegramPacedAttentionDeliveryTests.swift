import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Paced Telegram delivery joined to attention admission (Telegram attention contract, Slice 4).
/// Every request goes to `PacedStubHTTPClient` and every pacing wait to `ManualPacingClock`: no
/// network, no secure storage, no sleeps.
@MainActor
final class TelegramPacedAttentionDeliveryTests: XCTestCase {
    // MARK: - Multipart, ordering, and pacing

    func testMultipartEventsPostExactRendererPartsContiguouslyWithPacing() async throws {
        let clock = ManualPacingClock()
        let http = PacedStubHTTPClient(clock: clock)
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(clock)))
        let longText = (0 ..< 400).map { "line \($0) of the final assistant reply" }.joined(separator: "\n")
        let completion = makeEvent(.turnCompleted(sessionID: UUID(), attemptID: UUID()), content: .turnCompleted(finalAssistantText: longText))
        let question = makeEvent(questionKey(), content: .question(contentLines: ["Questions:", "1. Which option?"]))
        let completionParts = TelegramAttentionMessageRenderer.render(completion).map(\.text)
        let questionParts = TelegramAttentionMessageRenderer.render(question).map(\.text)
        XCTAssertEqual(completionParts.count, 3)

        admission.submit(capture(admission, completion))
        admission.submit(capture(admission, question))
        XCTAssertEqual(admission.pendingEventKeys, [completion.key, question.key])
        XCTAssertEqual(admission.activeEventKey, completion.key)
        try await waitForRecord(admission, question.key) { $0 == .delivered(.sent) }

        XCTAssertEqual(admission.records[completion.key], .delivered(.sent))
        XCTAssertEqual(http.texts, completionParts + questionParts, "Exact renderer parts, never interleaved")
        XCTAssertEqual(http.chatIDs, Array(repeating: 7, count: 4))
        for request in http.requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "api.telegram.org")
            XCTAssertEqual(request.url?.path, "/bot\(PacedTelegramTestSupport.syntheticToken)/sendMessage")
        }
        XCTAssertEqual(http.requestTimes, [.zero, .seconds(1), .seconds(2), .seconds(3)])
        XCTAssertEqual(clock.waits, [.seconds(1), .seconds(1), .seconds(1)])
        XCTAssertTrue(admission.pendingEventKeys.isEmpty)
        XCTAssertNil(admission.activeEventKey)
    }

    /// The snapshotted browser origin adds one Open session button to part 1 only; texts, part
    /// count, pacing, and outcomes are the renderer's and admission's, unchanged.
    func testBrowserOriginAddsSessionLinkButtonToPartOneOnly() async throws {
        let origin = try RemoteGatewayOrigin(string: "https://mac.example.ts.net:8443")
        let clock = ManualPacingClock()
        let http = PacedStubHTTPClient(clock: clock)
        let token = try XCTUnwrap(TelegramBotToken(PacedTelegramTestSupport.syntheticToken))
        let delivery = TelegramPacedAttentionDelivery(
            token: token,
            chatID: .numeric(7),
            client: TelegramSendMessageClient(httpClient: http),
            pacer: pacer(clock),
            browserOrigin: { origin }
        )
        let admission = makeAdmission(delivery)
        let completionSession = UUID()
        let questionSession = UUID()
        let longText = (0 ..< 400).map { "line \($0) of the final assistant reply" }.joined(separator: "\n")
        let completion = makeEvent(
            .turnCompleted(sessionID: completionSession, attemptID: UUID()),
            content: .turnCompleted(finalAssistantText: longText)
        )
        let question = makeEvent(
            .question(sessionID: questionSession, interactionID: UUID()),
            content: .question(contentLines: ["Questions:", "1. Which option?"])
        )
        let completionParts = TelegramAttentionMessageRenderer.render(completion).map(\.text)
        let questionParts = TelegramAttentionMessageRenderer.render(question).map(\.text)
        XCTAssertEqual(completionParts.count, 3)

        admission.submit(capture(admission, completion))
        admission.submit(capture(admission, question))
        let testKey = admission.submitManualTest { true }
        try await waitForRecord(admission, testKey) { $0 == .delivered(.sent) }
        XCTAssertEqual(admission.records[completion.key], .delivered(.sent))
        XCTAssertEqual(admission.records[question.key], .delivered(.sent))

        XCTAssertEqual(
            http.texts,
            completionParts + questionParts + [TelegramAttentionMessageRenderer.testMessage],
            "Exact renderer parts"
        )
        XCTAssertEqual(http.requestTimes, (0 ... completionParts.count + questionParts.count).map { Duration.seconds($0) })
        let completionLink = "https://mac.example.ts.net:8443/?session_id=\(completionSession.uuidString)"
        let questionLink = "https://mac.example.ts.net:8443/?session_id=\(questionSession.uuidString)"
        XCTAssertEqual(
            http.requests.map(sessionLinkButtonURL),
            [completionLink, nil, nil, questionLink, nil],
            "Part 1 of each session event only; never the Send test"
        )
        XCTAssertEqual(
            TelegramPacedAttentionDelivery.openSessionURL(origin: origin, key: completion.key)?.absoluteString,
            completionLink
        )
    }

    /// Review S3-01: the origin is read once when an admitted attempt starts and kept for all of
    /// its parts, even if it changes mid-attempt; the next attempt reads it again; the Send test
    /// never reads it.
    func testOriginIsSnapshottedOncePerAdmittedAttemptAcrossParts() async throws {
        let first = try RemoteGatewayOrigin(string: "https://mac.example.ts.net:8443")
        let second = try RemoteGatewayOrigin(string: "https://mac.example.ts.net:9443")
        let origins = OriginSequence([first, second, nil])
        let clock = ManualPacingClock(holdsWaits: true)
        let http = PacedStubHTTPClient(clock: clock)
        let token = try XCTUnwrap(TelegramBotToken(PacedTelegramTestSupport.syntheticToken))
        let delivery = TelegramPacedAttentionDelivery(
            token: token,
            chatID: .numeric(7),
            client: TelegramSendMessageClient(httpClient: http),
            pacer: pacer(clock),
            browserOrigin: { origins.next() }
        )
        let admission = makeAdmission(delivery)
        let longText = (0 ..< 400).map { "line \($0) of the final assistant reply" }.joined(separator: "\n")
        let multipart = makeEvent(
            .turnCompleted(sessionID: UUID(), attemptID: UUID()),
            content: .turnCompleted(finalAssistantText: longText)
        )
        let next = makeEvent(questionKey(), content: .question(contentLines: ["Questions:", "1. Which option?"]))
        let last = makeEvent(questionKey(), content: .question(contentLines: ["Questions:", "2. Another?"]))
        XCTAssertEqual(TelegramAttentionMessageRenderer.render(multipart).count, 3)

        admission.submit(capture(admission, multipart))
        try await waitUntil("part 1 sent and part 2 pacing") { http.requestCount == 1 && clock.waits.count == 1 }
        XCTAssertEqual(origins.reads, 1)
        clock.releaseWaits()
        try await waitForRecord(admission, multipart.key) { $0 == .delivered(.sent) }
        XCTAssertEqual(origins.reads, 1, "Parts 2 and 3 reuse the attempt's snapshot")

        let testKey = admission.submitManualTest { true }
        try await waitForRecord(admission, testKey) { $0 == .delivered(.sent) }
        XCTAssertEqual(origins.reads, 1, "The Send test does not read the origin")
        admission.submit(capture(admission, next))
        try await waitForRecord(admission, next.key) { $0 == .delivered(.sent) }
        admission.submit(capture(admission, last))
        try await waitForRecord(admission, last.key) { $0 == .delivered(.sent) }
        XCTAssertEqual(origins.reads, 3)

        XCTAssertEqual(
            http.requests.map(sessionLinkButtonURL),
            [
                TelegramPacedAttentionDelivery.openSessionURL(origin: first, key: multipart.key)?.absoluteString,
                nil,
                nil,
                nil,
                TelegramPacedAttentionDelivery.openSessionURL(origin: second, key: next.key)?.absoluteString,
                nil
            ],
            "Snapshot per attempt: first origin for the multipart alert, then the second, then none"
        )
    }

    func testWithoutBrowserOriginEveryPartIsTextOnly() async throws {
        let http = PacedStubHTTPClient()
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(ManualPacingClock())))
        let event = makeEvent(questionKey(), content: .question(contentLines: Array(repeating: String(repeating: "q", count: 100), count: 50)))
        admission.submit(capture(admission, event))
        try await waitForRecord(admission, event.key) { $0 == .delivered(.sent) }

        XCTAssertEqual(http.requestCount, 2)
        XCTAssertEqual(http.requests.map(sessionLinkButtonURL), [nil, nil])
        for request in http.requests {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["chat_id", "text"])
        }
        let plainHTTPOrigin = try RemoteGatewayOrigin(string: "http://100.64.0.8:47391")
        XCTAssertNil(
            TelegramPacedAttentionDelivery.openSessionURL(origin: plainHTTPOrigin, key: event.key),
            "Only an HTTPS origin produces a link"
        )
    }

    func testPacingIsMarkedAtRequestInitiationNotResponse() async throws {
        let clock = ManualPacingClock()
        let http = PacedStubHTTPClient(replies: [.hang(then: .ok)], clock: clock)
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(clock)))
        let event = makeEvent(questionKey(), content: .question(contentLines: Array(repeating: String(repeating: "q", count: 100), count: 50)))
        XCTAssertEqual(TelegramAttentionMessageRenderer.render(event).count, 2)

        admission.submit(capture(admission, event))
        try await waitUntil("the first part to hang") { http.requestCount == 1 }
        clock.advance(by: .seconds(5))
        http.releaseHangs()
        try await waitForRecord(admission, event.key) { $0 == .delivered(.sent) }

        XCTAssertEqual(http.requestTimes, [.zero, .seconds(5)])
        XCTAssertEqual(clock.waits, [], "The slow response already covered the spacing")
    }

    func testGroupChatSpacingAndPacerSurviveConfigurationReplacement() async throws {
        let clock = ManualPacingClock()
        let groupHTTP = PacedStubHTTPClient(clock: clock)
        let privateHTTP = PacedStubHTTPClient(clock: clock)
        let shared = pacer(clock)
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: groupHTTP, pacer: shared, chatID: .numeric(-100_123)))

        let first = makeEvent(questionKey(), content: .question(contentLines: ["first"]))
        admission.submit(capture(admission, first))
        try await waitForRecord(admission, first.key) { $0 == .delivered(.sent) }

        admission.setDeliveryConfiguration(PacedTelegramTestSupport.delivery(
            http: privateHTTP,
            pacer: shared,
            token: PacedTelegramTestSupport.replacementToken
        ))
        let second = makeEvent(questionKey(), content: .question(contentLines: ["second"]))
        admission.submit(capture(admission, second))
        try await waitForRecord(admission, second.key) { $0 == .delivered(.sent) }

        XCTAssertEqual(groupHTTP.chatIDs, [-100_123])
        XCTAssertEqual(groupHTTP.requestTimes, [.zero])
        XCTAssertEqual(privateHTTP.requestTimes, [.seconds(3)], "Replacement keeps the group spacing already owed")
        XCTAssertEqual(clock.waits, [.seconds(3)])
        XCTAssertEqual(privateHTTP.requests.first?.url?.path, "/bot\(PacedTelegramTestSupport.replacementToken)/sendMessage")
    }

    // MARK: - Kill: configuration or enable changes while queued

    func testQueuedCaptureNeverPostsAfterConfigurationOrEnableChanges() async throws {
        enum Change: String, CaseIterable {
            case replaced, removed, disabled, disabledAndReenabled
        }
        for change in Change.allCases {
            let clock = ManualPacingClock()
            let original = PacedStubHTTPClient()
            let replacement = PacedStubHTTPClient()
            let shared = pacer(clock)
            let fence = PacedAdmissionFence()
            let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: original, pacer: shared), fence: fence)
            let event = makeEvent(questionKey(), content: .question(contentLines: ["queued"]))
            admission.submit(capture(admission, event))
            try await waitUntil("\(change): the head to reach the fence") { fence.pauseCount == 1 }

            var expected = AttentionNotificationSuppression.configurationChanged
            switch change {
            case .replaced:
                admission.setDeliveryConfiguration(PacedTelegramTestSupport.delivery(
                    http: replacement,
                    pacer: shared,
                    token: PacedTelegramTestSupport.replacementToken
                ))
            case .removed:
                admission.setDeliveryConfiguration(nil)
            case .disabled:
                admission.setEnabled(false)
                expected = .enableChanged
            case .disabledAndReenabled:
                admission.setEnabled(false)
                admission.setEnabled(true)
                expected = .enableChanged
            }
            fence.release()

            let record = try await waitForRecord(admission, event.key)
            XCTAssertEqual(record, .suppressed(expected), change.rawValue)
            XCTAssertEqual(original.requestCount, 0, change.rawValue)
            XCTAssertEqual(replacement.requestCount, 0, "\(change): an old capture never switches credentials")
            XCTAssertTrue(admission.pendingEventKeys.isEmpty, change.rawValue)

            if change == .replaced {
                let fresh = makeEvent(questionKey(), content: .question(contentLines: ["fresh"]))
                admission.submit(capture(admission, fresh))
                try await waitForRecord(admission, fresh.key) { $0 == .delivered(.sent) }
                XCTAssertEqual(original.requestCount, 0)
                XCTAssertEqual(replacement.requests.map { $0.url?.path }, ["/bot\(PacedTelegramTestSupport.replacementToken)/sendMessage"])
            }
        }
    }

    // MARK: - Configuration or enable changes after admission

    /// An admitted multipart attempt keeps its immutable credential snapshot: replacing or removing
    /// the configuration, or disabling, while its first POST hangs or while the next part's pacing
    /// wait is held never interrupts or re-routes the remaining parts. Captures queued behind it are
    /// fenced by the configuration they were taken under (OracleA S4-01, OracleB S4-2). Continuing
    /// after admission is the contract's "before send admission" scope, not a withdrawal promise.
    func testAdmittedMultipartAttemptKeepsItsCredentialsAcrossLaterChanges() async throws {
        enum Change: String, CaseIterable {
            case replaced, removed, disabled
        }
        enum Trigger: String, CaseIterable {
            case firstPostHangs, nextPartPacingHeld
        }
        let longText = (0 ..< 400).map { "line \($0) of the final assistant reply" }.joined(separator: "\n")
        for change in Change.allCases {
            for trigger in Trigger.allCases {
                let name = "\(change.rawValue)/\(trigger.rawValue)"
                let clock = ManualPacingClock(holdsWaits: trigger == .nextPartPacingHeld)
                let original = PacedStubHTTPClient(
                    replies: trigger == .firstPostHangs ? [.hang(then: .ok)] : [],
                    clock: clock
                )
                let replacement = PacedStubHTTPClient(clock: clock)
                addTeardownBlock {
                    original.releaseHangs()
                    clock.releaseWaits()
                }
                let shared = pacer(clock)
                let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: original, pacer: shared))
                let event = makeEvent(
                    .turnCompleted(sessionID: UUID(), attemptID: UUID()),
                    content: .turnCompleted(finalAssistantText: longText)
                )
                let parts = TelegramAttentionMessageRenderer.render(event).map(\.text)
                XCTAssertEqual(parts.count, 3, name)

                admission.submit(capture(admission, event))
                switch trigger {
                case .firstPostHangs:
                    try await waitUntil("\(name): the first POST to hang") { original.requestCount == 1 }
                case .nextPartPacingHeld:
                    try await waitUntil("\(name): the part-2 pacing wait") { clock.waits.count == 1 }
                }
                XCTAssertEqual(admission.records[event.key], .admitted, name)
                XCTAssertEqual(original.requestCount, 1, name)

                // Taken under the admitted configuration, queued behind the active attempt.
                let stale = makeEvent(questionKey(), content: .question(contentLines: ["stale"]))
                admission.submit(capture(admission, stale))

                var staleExpected = AttentionNotificationSuppression.configurationChanged
                var freshExpected = AttentionNotificationAdmission.Record.suppressed(.disabled)
                switch change {
                case .replaced:
                    admission.setDeliveryConfiguration(PacedTelegramTestSupport.delivery(
                        http: replacement,
                        pacer: shared,
                        token: PacedTelegramTestSupport.replacementToken
                    ))
                    freshExpected = .delivered(.sent)
                case .removed:
                    admission.setDeliveryConfiguration(nil)
                case .disabled:
                    admission.setEnabled(false)
                    staleExpected = .enableChanged
                }
                let fresh = makeEvent(questionKey(), content: .question(contentLines: ["fresh"]))
                admission.submit(capture(admission, fresh))
                XCTAssertEqual(admission.activeEventKey, event.key, name)
                XCTAssertEqual(admission.pendingEventKeys, [event.key, stale.key, fresh.key], name)

                switch trigger {
                case .firstPostHangs: original.releaseHangs()
                case .nextPartPacingHeld: clock.releaseWaits()
                }
                try await waitForRecord(admission, event.key) { $0 != .admitted }
                try await waitForRecord(admission, fresh.key) { $0 != .admitted }

                XCTAssertEqual(admission.records[event.key], .delivered(.sent), name)
                XCTAssertEqual(original.texts, parts, "\(name): every part, in order, on the original client")
                XCTAssertEqual(original.chatIDs, [7, 7, 7], name)
                XCTAssertEqual(
                    original.requests.map { $0.url?.path },
                    Array(repeating: "/bot\(PacedTelegramTestSupport.syntheticToken)/sendMessage", count: 3),
                    name
                )
                XCTAssertEqual(original.requestTimes, [.zero, .seconds(1), .seconds(2)], "\(name): still paced")

                XCTAssertEqual(admission.records[stale.key], .suppressed(staleExpected), name)
                XCTAssertEqual(admission.records[fresh.key], freshExpected, name)
                if change == .replaced {
                    XCTAssertEqual(replacement.texts, TelegramAttentionMessageRenderer.render(fresh).map(\.text), name)
                    XCTAssertEqual(
                        replacement.requests.map { $0.url?.path },
                        ["/bot\(PacedTelegramTestSupport.replacementToken)/sendMessage"],
                        name
                    )
                    XCTAssertEqual(replacement.requestTimes, [.seconds(3)], "\(name): the shared pacer spaces the next event")
                } else {
                    XCTAssertEqual(replacement.requestCount, 0, name)
                }
                XCTAssertTrue(admission.pendingEventKeys.isEmpty, name)
                XCTAssertNil(admission.activeEventKey, name)
            }
        }
    }

    // MARK: - Queue ownership

    func testDuplicateQueuedAndReplayedKeysPostOnceWithoutStallingTheQueue() async throws {
        let http = PacedStubHTTPClient()
        let fence = PacedAdmissionFence()
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(ManualPacingClock())), fence: fence)
        let first = makeEvent(questionKey(), content: .question(contentLines: ["first"]))
        let second = makeEvent(.turnCompleted(sessionID: UUID(), attemptID: UUID()), content: .turnCompleted(finalAssistantText: "second"))
        let firstCapture = capture(admission, first)
        let secondCapture = capture(admission, second)

        admission.submit(firstCapture)
        admission.submit(firstCapture)
        admission.submit(secondCapture)
        admission.submit(firstCapture)
        XCTAssertEqual(admission.pendingEventKeys, [first.key, second.key])
        XCTAssertEqual(admission.activeEventKey, first.key)
        try await waitUntil("the head to reach the fence") { fence.pauseCount == 1 }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(fence.pauseCount, 1, "Only the head prepares; duplicates never reach the fence")
        fence.release()
        try await waitForRecord(admission, second.key) { $0 == .delivered(.sent) }
        XCTAssertEqual(fence.pauseCount, 2)

        admission.submit(firstCapture)
        admission.submit(secondCapture)
        XCTAssertTrue(admission.pendingEventKeys.isEmpty, "Replays after outcomes are never queued")
        let third = makeEvent(questionKey(), content: .question(contentLines: ["third"]))
        admission.submit(capture(admission, third))
        try await waitForRecord(admission, third.key) { $0 == .delivered(.sent) }

        let expected = [first, second, third].flatMap { TelegramAttentionMessageRenderer.render($0).map(\.text) }
        XCTAssertEqual(http.texts, expected)
        XCTAssertEqual(fence.pauseCount, 3)
    }

    func testSuppressedHeadReleasesTheNextAndDistinctQuestionsAreNotCollapsed() async throws {
        let http = PacedStubHTTPClient()
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(ManualPacingClock())))
        let sessionID = UUID()
        let events = (0 ..< 3).map { index in
            makeEvent(
                .question(sessionID: sessionID, interactionID: UUID()),
                content: .question(contentLines: ["question \(index)"])
            )
        }
        admission.submit(capture(admission, events[0], isStillCurrent: { false }))
        admission.submit(capture(admission, events[1]))
        admission.submit(capture(admission, events[2]))

        try await waitForRecord(admission, events[2].key) { $0 == .delivered(.sent) }
        XCTAssertEqual(admission.records[events[0].key], .suppressed(.eventNoLongerCurrent))
        XCTAssertEqual(admission.records[events[1].key], .delivered(.sent))
        XCTAssertEqual(http.texts, events[1 ... 2].flatMap { TelegramAttentionMessageRenderer.render($0).map(\.text) })
    }

    // MARK: - Event-time idle

    func testIdleIsReadAtEventTimeWithUnreadableFallbackAndThreshold() async throws {
        let cases: [(atEvent: TimeInterval?, later: TimeInterval?, expected: AttentionNotificationAdmission.Record)] = [
            (nil, 0, .delivered(.sent)),
            (299, 1000, .suppressed(.userActive)),
            (300, 0, .delivered(.sent))
        ]
        for testCase in cases {
            let http = PacedStubHTTPClient()
            let idle = IdleBox(testCase.atEvent)
            let admission = makeAdmission(
                PacedTelegramTestSupport.delivery(http: http, pacer: pacer(ManualPacingClock())),
                idleSeconds: { idle.value }
            )
            let event = makeEvent(questionKey(), content: .question(contentLines: ["idle"]))
            let eventCapture = capture(admission, event)
            idle.value = testCase.later
            admission.submit(eventCapture)
            let record = try await waitForRecord(admission, event.key) { $0 != .admitted }
            XCTAssertEqual(record, testCase.expected, "idle \(String(describing: testCase.atEvent))")
            XCTAssertEqual(http.requestCount, testCase.expected == .delivered(.sent) ? 1 : 0)
        }
    }

    // MARK: - Failing, hanging, and partial delivery

    func testFailingRequestRecordsOneFailedAttemptWithoutRetry() async throws {
        let http = PacedStubHTTPClient(replies: [.respond(status: 400, body: Data(#"{"ok":false,"error_code":400}"#.utf8))])
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(ManualPacingClock())))
        let failing = makeEvent(questionKey(), content: .question(contentLines: ["failing"]))
        let next = makeEvent(questionKey(), content: .question(contentLines: ["next"]))
        admission.submit(capture(admission, failing))
        admission.submit(capture(admission, next))

        try await waitForRecord(admission, next.key) { $0 == .delivered(.sent) }
        XCTAssertEqual(admission.records[failing.key], .delivered(.failed))
        XCTAssertEqual(http.texts, [failing, next].flatMap { TelegramAttentionMessageRenderer.render($0).map(\.text) })
    }

    func testHangingRequestHoldsOnlyLaterNotificationsUntilItsSingleAttemptEnds() async throws {
        let http = PacedStubHTTPClient(replies: [.hang(then: .fail(PacedTelegramTestSupport.leakyURLError(.timedOut)))])
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(ManualPacingClock())))
        let hanging = makeEvent(questionKey(), content: .question(contentLines: ["hanging"]))
        let later = makeEvent(questionKey(), content: .question(contentLines: ["later"]))
        admission.submit(capture(admission, hanging))
        admission.submit(capture(admission, later))

        try await waitUntil("the head's request to hang") { http.requestCount == 1 }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(admission.records[hanging.key], .admitted)
        XCTAssertEqual(admission.activeEventKey, hanging.key)
        XCTAssertEqual(admission.pendingEventKeys, [hanging.key, later.key])
        XCTAssertNil(admission.records[later.key])
        XCTAssertEqual(http.requestCount, 1)

        http.releaseHangs()
        try await waitForRecord(admission, later.key) { $0 == .delivered(.sent) }
        XCTAssertEqual(admission.records[hanging.key], .delivered(.unknown))
        XCTAssertEqual(http.requestCount, 2, "One attempt for the hanging event, never retried")
    }

    func testMultipartOutcomesStopAtTheFirstUnconfirmedPartAndAggregateConservatively() async throws {
        let rejected = PacedStubHTTPClient.Reply.respond(status: 400, body: Data(#"{"ok":false,"error_code":400}"#.utf8))
        let serverError = PacedStubHTTPClient.Reply.respond(status: 500, body: Data())
        let notConnected = PacedStubHTTPClient.Reply.fail(PacedTelegramTestSupport.leakyURLError(.cannotFindHost))
        let cases: [(replies: [PacedStubHTTPClient.Reply], outcome: AttentionNotificationDeliveryOutcome, requests: Int)] = [
            ([.ok, .ok, .ok], .sent, 3),
            ([rejected], .failed, 1),
            ([notConnected], .failed, 1),
            ([serverError], .unknown, 1),
            ([.ok, rejected], .unknown, 2),
            ([.ok, notConnected], .unknown, 2),
            ([.ok, .ok, serverError], .unknown, 3),
            ([.ok, .fail(PacedTelegramTestSupport.leakyURLError(.networkConnectionLost))], .unknown, 2)
        ]
        let longText = (0 ..< 400).map { "line \($0) of the final assistant reply" }.joined(separator: "\n")
        for (index, testCase) in cases.enumerated() {
            let http = PacedStubHTTPClient(replies: testCase.replies)
            let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(ManualPacingClock())))
            let event = makeEvent(.turnCompleted(sessionID: UUID(), attemptID: UUID()), content: .turnCompleted(finalAssistantText: longText))
            admission.submit(capture(admission, event))
            let record = try await waitForRecord(admission, event.key) { $0 != .admitted }
            XCTAssertEqual(record, .delivered(testCase.outcome), "case \(index)")
            XCTAssertEqual(http.requestCount, testCase.requests, "case \(index)")
            XCTAssertEqual(
                http.texts,
                Array(TelegramAttentionMessageRenderer.render(event).map(\.text).prefix(testCase.requests)),
                "case \(index)"
            )
        }
    }

    // MARK: - Diagnostics

    func testRecordsAndDiagnosticsNeverCarryTokenURLContentOrRawErrors() async throws {
        let echoed = Data(#"{"ok":false,"error_code":401,"description":"bad \#(PacedTelegramTestSupport.syntheticToken) api.telegram.org"}"#.utf8)
        let http = PacedStubHTTPClient(replies: [
            .fail(PacedLeakyError()),
            .respond(status: 401, body: echoed),
            .fail(PacedTelegramTestSupport.leakyURLError(.timedOut))
        ])
        let admission = makeAdmission(PacedTelegramTestSupport.delivery(http: http, pacer: pacer(ManualPacingClock())))
        let contentSentinel = "SYNTHETIC_CONTENT_SENTINEL"
        let events = (0 ..< 4).map { _ in
            makeEvent(questionKey(), content: .question(contentLines: [contentSentinel]))
        }
        for event in events.prefix(3) {
            admission.submit(capture(admission, event))
        }
        admission.submit(capture(admission, events[3], isStillCurrent: { false }))
        try await waitForRecord(admission, events[3].key)
        XCTAssertEqual(events.prefix(3).map { admission.records[$0.key] }, [.delivered(.unknown), .delivered(.failed), .delivered(.unknown)])

        // Everything the admission retains except its configured sender: records, last results,
        // and the (now empty) queue of captures.
        var surfaces = [
            String(reflecting: admission.records),
            String(reflecting: admission.lastDeliveryOutcome),
            String(reflecting: admission.lastSuppression)
        ]
        for child in Mirror(reflecting: admission).children where child.label != "delivery" {
            var dumped = ""
            dump(child.value, to: &dumped)
            surfaces.append(dumped)
        }
        for surface in surfaces {
            XCTAssertFalse(surface.contains(PacedTelegramTestSupport.syntheticSecret), surface)
            XCTAssertFalse(surface.contains("api.telegram.org"), surface)
            XCTAssertFalse(surface.contains("sendMessage"), surface)
            XCTAssertFalse(surface.contains(contentSentinel), surface)
        }
        XCTAssertEqual(http.requestCount, 3)
    }

    /// The configured delivery snapshot and a queued capture holding it dump without the token or
    /// endpoint. The HTTP stub records nothing, so any secret in a dump comes from the snapshot
    /// itself (OracleB S4-3).
    func testConfiguredDeliveryAndQueuedCaptureDumpWithoutTokenOrEndpoint() async throws {
        let http = CountingHTTPClient()
        let token = try XCTUnwrap(TelegramBotToken(PacedTelegramTestSupport.syntheticToken))
        let delivery = TelegramPacedAttentionDelivery(
            token: token,
            chatID: .numeric(7),
            client: TelegramSendMessageClient(httpClient: http),
            pacer: pacer(ManualPacingClock())
        )
        let fence = PacedAdmissionFence()
        let admission = makeAdmission(delivery, fence: fence)
        let head = makeEvent(questionKey(), content: .question(contentLines: ["head"]))
        let queued = makeEvent(questionKey(), content: .question(contentLines: ["queued"]))
        let queuedCapture = capture(admission, queued)
        admission.submit(capture(admission, head))
        admission.submit(queuedCapture)
        try await waitUntil("the head to reach the fence") { fence.pauseCount == 1 }

        var surfaces = [String(describing: delivery), String(reflecting: delivery), String(reflecting: queuedCapture)]
        for value in [delivery, queuedCapture, admission] as [Any] {
            var dumped = ""
            dump(value, to: &dumped)
            surfaces.append(dumped)
        }
        XCTAssertTrue(surfaces.last?.contains("queuedCaptures") == true, "The admission dump includes its queued capture")
        for surface in surfaces {
            XCTAssertFalse(surface.contains(PacedTelegramTestSupport.syntheticSecret), surface)
            XCTAssertFalse(surface.contains("api.telegram.org"), surface)
            XCTAssertFalse(surface.contains("sendMessage"), surface)
        }

        fence.release()
        try await waitForRecord(admission, queued.key) { $0 == .delivered(.sent) }
        XCTAssertEqual(http.requestCount, 2)
    }

    // MARK: - Helpers

    private func pacer(_ clock: ManualPacingClock) -> TelegramAttentionPacer {
        TelegramAttentionPacer(clock: clock.pacingClock)
    }

    /// The single Open session button URL in a request, or nil when it has no reply markup.
    private func sessionLinkButtonURL(_ request: URLRequest) -> String? {
        guard let data = request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let markup = body["reply_markup"] as? [String: Any]
        else { return nil }
        let rows = markup["inline_keyboard"] as? [[[String: String]]]
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?.count, 1)
        XCTAssertEqual(rows?.first?.first?["text"], "Open session")
        return rows?.first?.first?["url"]
    }

    private func makeAdmission(
        _ delivery: TelegramPacedAttentionDelivery,
        fence: PacedAdmissionFence? = nil,
        idleSeconds: @escaping @MainActor () -> TimeInterval? = { nil }
    ) -> AttentionNotificationAdmission {
        let admission = AttentionNotificationAdmission(environment: .init(
            delivery: delivery,
            idleSeconds: idleSeconds,
            beforeAdmission: { _ in await fence?.pause() }
        ))
        admission.setEnabled(true)
        addTeardownBlock { @MainActor in
            fence?.release()
        }
        return admission
    }

    private func questionKey() -> AttentionNotificationEventKey {
        .question(sessionID: UUID(), interactionID: UUID())
    }

    private func makeEvent(
        _ key: AttentionNotificationEventKey,
        content: AttentionNotificationEvent.Content
    ) -> AttentionNotificationEvent {
        AttentionNotificationEvent(key: key, workspaceName: "Workspace", sessionName: "Root", content: content)
    }

    private func capture(
        _ admission: AttentionNotificationAdmission,
        _ event: AttentionNotificationEvent,
        isStillCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> AttentionNotificationCapture {
        admission.makeCapture(event: event, isStillCurrent: isStillCurrent)
    }

    /// Bounded, cancellation-aware wait (main-actor yields, no sleeps).
    private func waitUntil(
        _ description: @autoclosure () -> String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await !condition() {
            if Task.isCancelled || clock.now >= deadline {
                XCTFail("\(Task.isCancelled ? "Cancelled" : "Timed out") waiting for \(description())", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    @discardableResult
    private func waitForRecord(
        _ admission: AttentionNotificationAdmission,
        _ key: AttentionNotificationEventKey,
        file: StaticString = #filePath,
        line: UInt = #line,
        matching: (AttentionNotificationAdmission.Record) -> Bool = { _ in true }
    ) async throws -> AttentionNotificationAdmission.Record {
        var last: AttentionNotificationAdmission.Record?
        try await waitUntil("admission record \(key); last \(String(describing: last))", file: file, line: line) {
            last = admission.records[key]
            return last.map(matching) ?? false
        }
        return try XCTUnwrap(last, file: file, line: line)
    }
}

// MARK: - Shared test support (also used by AttentionNotificationAdmissionTests)

/// Synthetic, test-only credentials shaped like bot tokens. Not real credentials.
enum PacedTelegramTestSupport {
    static let syntheticToken = "424242:SYNTHETIC_PACED_TOKEN_SENTINEL-not-real"
    static let syntheticSecret = "SYNTHETIC_PACED_TOKEN_SENTINEL"
    static let replacementToken = "434343:SYNTHETIC_REPLACEMENT_TOKEN-not-real"

    static func delivery(
        http: PacedStubHTTPClient,
        pacer: TelegramAttentionPacer,
        token: String = syntheticToken,
        chatID: TelegramChatID = .numeric(7)
    ) -> TelegramPacedAttentionDelivery {
        TelegramPacedAttentionDelivery(
            token: TelegramBotToken(token)!,
            chatID: chatID,
            client: TelegramSendMessageClient(httpClient: http),
            pacer: pacer
        )
    }

    static func leakyURLError(_ code: URLError.Code) -> URLError {
        let url = "https://api.telegram.org/bot\(syntheticToken)/sendMessage"
        return URLError(code, userInfo: [
            NSURLErrorFailingURLStringErrorKey: url,
            NSURLErrorFailingURLErrorKey: URL(string: url)!,
            NSLocalizedDescriptionKey: "The request to \(url) failed"
        ])
    }
}

private struct PacedLeakyError: LocalizedError, CustomStringConvertible {
    var errorDescription: String? {
        "POST https://api.telegram.org/bot\(PacedTelegramTestSupport.syntheticToken)/sendMessage failed"
    }

    var description: String {
        "token \(PacedTelegramTestSupport.syntheticToken)"
    }
}

/// Manual monotonic pacing clock. Waits are recorded and advance time by the requested amount;
/// with `holdsWaits`, each wait suspends until `releaseWaits()`.
final class ManualPacingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var holding: Bool
    private var held: [CheckedContinuation<Void, Never>] = []
    private var requested: [Duration] = []

    init(holdsWaits: Bool = false) {
        holding = holdsWaits
    }

    var now: Duration {
        lock.withLock { elapsed }
    }

    /// Every wait the pacer requested, in order.
    var waits: [Duration] {
        lock.withLock { requested }
    }

    var pacingClock: TelegramAttentionPacingClock {
        TelegramAttentionPacingClock(now: { self.now }, wait: { await self.wait($0) })
    }

    func advance(by duration: Duration) {
        lock.withLock { elapsed += duration }
    }

    /// Resumes held waits; later waits pass straight through.
    func releaseWaits() {
        let resumed = lock.withLock {
            holding = false
            defer { held.removeAll() }
            return held
        }
        resumed.forEach { $0.resume() }
    }

    private func wait(_ duration: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                requested.append(duration)
                guard holding else { return true }
                held.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
        advance(by: duration)
    }
}

/// Scripted stub `HTTPClient`: one reply per request in order (then `defaultReply`). Hanging
/// replies suspend until `releaseHangs()`. Records each request and the pacing time it started.
final class PacedStubHTTPClient: HTTPClient, @unchecked Sendable {
    indirect enum Reply {
        case respond(status: Int, body: Data)
        case fail(any Error)
        case hang(then: Reply)

        static let ok = Reply.respond(status: 200, body: Data(#"{"ok":true,"result":{}}"#.utf8))
    }

    private let lock = NSLock()
    private let clock: ManualPacingClock?
    private let defaultReply: Reply
    private var replies: [Reply]
    private var recorded: [(request: URLRequest, time: Duration?)] = []
    private var hung: [CheckedContinuation<Void, Never>] = []
    private var hangsReleased = false

    init(replies: [Reply] = [], defaultReply: Reply = .ok, clock: ManualPacingClock? = nil) {
        self.replies = replies
        self.defaultReply = defaultReply
        self.clock = clock
    }

    var requests: [URLRequest] {
        lock.withLock { recorded.map(\.request) }
    }

    var requestCount: Int {
        requests.count
    }

    /// Pacing-clock time at which each request started (empty without a clock).
    var requestTimes: [Duration] {
        lock.withLock { recorded.compactMap(\.time) }
    }

    var texts: [String] {
        requests.compactMap { Self.body($0)?["text"] as? String }
    }

    var chatIDs: [Int64] {
        requests.compactMap { (Self.body($0)?["chat_id"] as? NSNumber)?.int64Value }
    }

    func releaseHangs() {
        let resumed = lock.withLock {
            hangsReleased = true
            defer { hung.removeAll() }
            return hung
        }
        resumed.forEach { $0.resume() }
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let time = clock?.now
        let reply = lock.withLock {
            recorded.append((request, time))
            return replies.isEmpty ? defaultReply : replies.removeFirst()
        }
        return try await respond(reply, to: request)
    }

    func bytes(for _: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
        XCTFail("Telegram transport must not stream")
        throw URLError(.unsupportedURL)
    }

    private func respond(_ reply: Reply, to request: URLRequest) async throws -> HTTPResponse {
        switch reply {
        case let .respond(status, body):
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return HTTPResponse(data: body, http: http)
        case let .fail(error):
            throw error
        case let .hang(then):
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    guard !hangsReleased else { return true }
                    hung.append(continuation)
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
            return try await respond(then, to: request)
        }
    }

    private static func body(_ request: URLRequest) -> [String: Any]? {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// Deterministic pre-admission fence: holds the head after pacing and before admission until
/// released; once released, later heads pass straight through.
@MainActor
private final class PacedAdmissionFence {
    private var paused: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var pauseCount = 0

    func pause() async {
        pauseCount += 1
        if !isReleased {
            await withCheckedContinuation { paused.append($0) }
        }
    }

    func release() {
        isReleased = true
        paused.forEach { $0.resume() }
        paused.removeAll()
    }
}

/// HTTP stub that answers `ok` and retains nothing from any request (only a count).
private final class CountingHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int {
        lock.withLock { count }
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { count += 1 }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return HTTPResponse(data: Data(#"{"ok":true}"#.utf8), http: http)
    }

    func bytes(for _: URLRequest) async throws -> (bytes: URLSession.AsyncBytes, http: HTTPURLResponse) {
        XCTFail("Telegram transport must not stream")
        throw URLError(.unsupportedURL)
    }
}

@MainActor
private final class IdleBox {
    var value: TimeInterval?

    init(_ value: TimeInterval?) {
        self.value = value
    }
}

/// Scripted browser origins, one per read (then nil), with a read count.
private final class OriginSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [RemoteGatewayOrigin?]
    private var count = 0

    init(_ origins: [RemoteGatewayOrigin?]) {
        remaining = origins
    }

    var reads: Int {
        lock.withLock { count }
    }

    func next() -> RemoteGatewayOrigin? {
        lock.withLock {
            count += 1
            return remaining.isEmpty ? nil : remaining.removeFirst()
        }
    }
}
