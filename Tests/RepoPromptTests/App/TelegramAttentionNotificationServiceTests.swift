import CoreGraphics
import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Executing-Mac Telegram service (Telegram attention contract, Slice 8). Every dependency is
/// injected: temporary settings JSON and defaults, `TestSecureStorageBackend`, the stub HTTP
/// client and manual pacing clock from `TelegramPacedAttentionDeliveryTests`. No Keychain,
/// network, real settings, sleeps, or app lifecycle.
@MainActor
final class TelegramAttentionNotificationServiceTests: XCTestCase {
    private static let allowedLaunch = TelegramAttentionLaunchEnvironment(
        arguments: [],
        environment: [:],
        xctestLoaded: false,
        suppressesNonessentialLaunchSideEffects: false
    )

    // MARK: - Persistence

    func testOldSettingsDecodeOffAndTelegramGroupRoundTripsWithoutSecrets() throws {
        let old = try JSONDecoder().decode(
            GlobalScalarPreferences.self,
            from: Data(#"{"telemetry":{"enabled":false}}"#.utf8)
        )
        XCTAssertNil(old.telegram)

        let fixture = try makeFixture(chatID: nil)
        XCTAssertFalse(fixture.settings.telegramNotificationsEnabled(), "Off by default")
        XCTAssertNil(fixture.settings.telegramChatID())

        fixture.service.start(launch: Self.allowedLaunch)
        XCTAssertTrue(fixture.service.saveChatID("  -1001  "))
        XCTAssertTrue(fixture.service.saveToken(PacedTelegramTestSupport.replacementToken))
        XCTAssertTrue(fixture.service.setEnabled(true))

        let reloaded = GlobalSettingsStore(defaults: fixture.defaults, fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL))
        XCTAssertTrue(reloaded.telegramNotificationsEnabled())
        XCTAssertEqual(reloaded.telegramChatID(), "-1001")
        let persisted = try GlobalSettingsFileStore(fileURL: fixture.fileURL).load()
        XCTAssertEqual(
            persisted.scalarPreferences?.telegram,
            GlobalScalarPreferences.TelegramSettings(enabled: true, chatID: "-1001")
        )

        let json = try String(contentsOf: fixture.fileURL, encoding: .utf8)
        let defaultsText = String(describing: fixture.defaults.dictionaryRepresentation())
        for secret in [PacedTelegramTestSupport.syntheticSecret, "SYNTHETIC_REPLACEMENT_TOKEN", "434343:"] {
            XCTAssertFalse(json.contains(secret))
            XCTAssertFalse(defaultsText.contains(secret))
        }
        XCTAssertEqual(
            fixture.backend.value(for: .telegramAttentionBotToken),
            PacedTelegramTestSupport.replacementToken,
            "The token lives only in secure storage"
        )
    }

    func testSettingsOrTokenWriteFailureNeitherActivatesNorReusesOldCredentials() throws {
        let fixture = try makeFixture()
        fixture.service.start(launch: Self.allowedLaunch)
        XCTAssertTrue(fixture.service.isDeliveryConfigured)

        fixture.fileStore.failSaves = true
        XCTAssertFalse(fixture.service.setEnabled(true))
        XCTAssertEqual(fixture.service.lastAction, .settingsSaveFailed)
        XCTAssertFalse(fixture.service.isEnabled)
        XCTAssertFalse(fixture.admission.isEnabled)
        XCTAssertFalse(fixture.settings.telegramNotificationsEnabled(), "An unsaved value is not kept")

        XCTAssertFalse(fixture.service.saveChatID("8"))
        XCTAssertEqual(fixture.service.lastAction, .chatIDSaveFailed)
        XCTAssertTrue(
            ActionResult.chatIDSaveFailed.message.contains("suspended until a configuration save succeeds"),
            ActionResult.chatIDSaveFailed.message
        )
        XCTAssertEqual(fixture.settings.telegramChatID(), "7")
        XCTAssertEqual(fixture.service.chatID, "7")
        XCTAssertFalse(fixture.service.isDeliveryConfigured, "The old configuration is not silently reused")
        XCTAssertNil(fixture.admission.delivery)
        XCTAssertFalse(fixture.service.sendTest())
        XCTAssertEqual(fixture.service.lastAction, .deliverySuspended, "Suspension does not claim credentials are missing")

        fixture.fileStore.failSaves = false
        XCTAssertTrue(fixture.service.saveChatID("8"))
        XCTAssertTrue(fixture.service.isDeliveryConfigured)

        fixture.backend.saveErrors[.telegramAttentionBotToken] = .unexpectedStatus(-1)
        XCTAssertFalse(fixture.service.saveToken(PacedTelegramTestSupport.replacementToken))
        XCTAssertEqual(fixture.service.lastAction, .tokenSaveFailed)
        XCTAssertEqual(fixture.service.tokenStatus, .unavailable)
        XCTAssertFalse(fixture.service.isDeliveryConfigured, "The previous token is not reused")
        XCTAssertNil(fixture.admission.delivery)
        XCTAssertFalse(fixture.service.sendTest())

        XCTAssertFalse(fixture.service.saveChatID("not a chat"))
        XCTAssertEqual(fixture.service.lastAction, .invalidChatID)
        XCTAssertFalse(fixture.service.saveToken("not a token"))
        XCTAssertEqual(fixture.service.lastAction, .invalidToken)
        XCTAssertEqual(fixture.http.requestCount, 0)
    }

    /// The toggle shows the saved preference: on with a missing or unreadable token it reads on
    /// with a fixed paused notice. An explicit off is saved, and a later token save does not turn
    /// automatic notifications back on. Temporary secure storage is reported.
    func testPersistedOnWithoutUsableTokenShowsPreferenceAndExplicitOffSurvivesTokenSave() async throws {
        let cases: [(name: String, getFails: Bool, ephemeral: Bool, status: TokenStatus)] = [
            ("missing", false, false, .missing),
            ("unavailable", true, false, .unavailable),
            ("ephemeral missing", false, true, .missing)
        ]
        for item in cases {
            let fixture = try makeFixture(token: nil, enabled: true, ephemeral: item.ephemeral)
            if item.getFails {
                fixture.backend.getErrors[.telegramAttentionBotToken] = .unexpectedStatus(-1)
            }
            fixture.service.start(launch: Self.allowedLaunch)
            XCTAssertEqual(fixture.service.tokenStatus, item.status, item.name)
            XCTAssertTrue(fixture.service.isEnabled, "\(item.name): the toggle shows the saved preference")
            XCTAssertFalse(fixture.service.isDeliveryConfigured, item.name)
            XCTAssertFalse(fixture.service.automaticNotificationsActive, item.name)
            XCTAssertFalse(fixture.admission.isEnabled, item.name)
            var expected: [Notice] = [.enabledButNotDelivering]
            if item.ephemeral {
                expected.append(.temporaryTokenStorage)
            }
            XCTAssertEqual(fixture.service.notices, expected, item.name)

            XCTAssertTrue(fixture.service.setEnabled(false), item.name)
            XCTAssertEqual(fixture.service.lastAction, .disabled, item.name)
            XCTAssertFalse(fixture.settings.telegramNotificationsEnabled(), item.name)
            XCTAssertEqual(fixture.service.notices, item.ephemeral ? [.temporaryTokenStorage] : [], item.name)

            fixture.backend.getErrors = [:]
            XCTAssertTrue(fixture.service.saveToken(PacedTelegramTestSupport.replacementToken), item.name)
            XCTAssertTrue(fixture.service.isDeliveryConfigured, item.name)
            XCTAssertFalse(fixture.service.isEnabled, "\(item.name): a token save never turns notifications on")
            XCTAssertFalse(fixture.admission.isEnabled, item.name)
            XCTAssertFalse(fixture.settings.telegramNotificationsEnabled(), item.name)
            let event = completionEvent(text: "automatic")
            fixture.admission.submit(fixture.admission.makeCapture(event: event, isStillCurrent: { true }))
            let record = try await waitForRecord(fixture.admission, event.key)
            XCTAssertEqual(record, .suppressed(.disabled), item.name)
            XCTAssertEqual(fixture.http.requestCount, 0, item.name)
        }
    }

    /// A failed off save turns notifications off at once for this launch, with a specific warning
    /// and a direct retry. Nothing re-enables them asynchronously, and a successful retry stays
    /// off across a reload and a later startup.
    func testOffSaveFailureIsOffNowWithRetryAndStaysOffAfterReload() async throws {
        let fixture = try makeFixture(enabled: true)
        fixture.service.start(launch: Self.allowedLaunch)
        XCTAssertTrue(fixture.admission.isEnabled)

        fixture.fileStore.failSaves = true
        XCTAssertFalse(fixture.service.setEnabled(false))
        XCTAssertEqual(fixture.service.lastAction, .offNotSaved)
        let warning = ActionResult.offNotSaved.message
        XCTAssertTrue(warning.contains("this launch only") && warning.contains("next launch"), warning)
        XCTAssertFalse(fixture.service.isEnabled)
        XCTAssertFalse(fixture.admission.isEnabled)
        XCTAssertTrue(fixture.settings.telegramNotificationsEnabled(), "The saved setting is still on")
        XCTAssertTrue(fixture.service.offIsUnsaved)
        XCTAssertEqual(fixture.service.notices, [.offNotSaved])
        let event = completionEvent(text: "automatic")
        fixture.admission.submit(fixture.admission.makeCapture(event: event, isStillCurrent: { true }))
        let record = try await waitForRecord(fixture.admission, event.key)
        XCTAssertEqual(record, .suppressed(.disabled))

        // A reload of the still-on file is observed (the chat ID change proves the observer ran)
        // and does not turn notifications back on.
        let writerSuite = "TelegramServiceWriter.\(UUID().uuidString)"
        let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: writerSuite))
        addTeardownBlock { writerDefaults.removePersistentDomain(forName: writerSuite) }
        let writer = GlobalSettingsStore(defaults: writerDefaults, fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL))
        XCTAssertTrue(writer.setTelegramChatID("9"))
        XCTAssertTrue(fixture.settings.reloadFromDisk())
        try await waitUntil("reconciliation") { fixture.service.chatID == "9" }
        XCTAssertTrue(fixture.settings.telegramNotificationsEnabled())
        XCTAssertFalse(fixture.service.isEnabled, "No asynchronous re-enable")
        XCTAssertFalse(fixture.admission.isEnabled)
        XCTAssertTrue(fixture.service.offIsUnsaved)

        fixture.fileStore.failSaves = false
        XCTAssertTrue(fixture.service.setEnabled(false), "Retry uses the same off action")
        XCTAssertEqual(fixture.service.lastAction, .disabled)
        XCTAssertFalse(fixture.service.offIsUnsaved)
        XCTAssertEqual(fixture.service.notices, [])
        XCTAssertTrue(fixture.settings.reloadFromDisk())
        XCTAssertFalse(fixture.settings.telegramNotificationsEnabled())
        XCTAssertFalse(fixture.service.isEnabled)
        let restarted = restartedService(fixture)
        XCTAssertFalse(restarted.isEnabled, "A later startup stays off")
        XCTAssertFalse(restarted.admission.isEnabled)
    }

    /// Removal disables runtime delivery before either write, always saves off, and reports both
    /// write results. A failed delete with a saved off stays off at the next startup even though
    /// the old token is still readable.
    func testTokenRemovalAlwaysTurnsOffAndReportsDeleteAndOffSaveOutcomes() throws {
        let cases: [(enabled: Bool, deleteFails: Bool, offSaveFails: Bool, result: ActionResult)] = [
            (true, false, false, .tokenRemoved),
            (true, false, true, .tokenRemovedOffNotSaved),
            (true, true, false, .tokenRemoveFailed),
            (true, true, true, .tokenRemoveFailedOffNotSaved),
            (false, false, true, .tokenRemoved),
            (false, true, true, .tokenRemoveFailed)
        ]
        for item in cases {
            let name = "enabled \(item.enabled), delete fails \(item.deleteFails), off save fails \(item.offSaveFails)"
            let fixture = try makeFixture(enabled: item.enabled)
            fixture.service.start(launch: Self.allowedLaunch)
            XCTAssertEqual(fixture.admission.isEnabled, item.enabled, name)
            let offSaveNeeded = item.enabled && item.offSaveFails
            if item.deleteFails {
                fixture.backend.deleteErrors[.telegramAttentionBotToken] = .unexpectedStatus(-1)
            }
            fixture.fileStore.failSaves = item.offSaveFails

            XCTAssertEqual(fixture.service.removeToken(), !item.deleteFails && !offSaveNeeded, name)
            XCTAssertEqual(fixture.service.lastAction, item.result, name)
            XCTAssertEqual(fixture.backend.calls.map(\.operation), [.get, .delete], name)
            XCTAssertFalse(fixture.service.isEnabled, name)
            XCTAssertFalse(fixture.admission.isEnabled, name)
            XCTAssertNil(fixture.admission.delivery, name)
            XCTAssertFalse(fixture.service.isDeliveryConfigured, name)
            XCTAssertEqual(fixture.settings.telegramNotificationsEnabled(), offSaveNeeded, name)
            XCTAssertEqual(fixture.service.offIsUnsaved, offSaveNeeded, "\(name): retry offered")
            XCTAssertEqual(fixture.backend.value(for: .telegramAttentionBotToken) != nil, item.deleteFails, name)
            XCTAssertEqual(fixture.service.tokenStatus, item.deleteFails ? .unavailable : .missing, name)
            if !item.deleteFails, offSaveNeeded {
                let message = item.result.message
                XCTAssertTrue(message.hasPrefix("Bot token removed.") && message.contains("could not be saved"), message)
            }
            XCTAssertFalse(fixture.service.sendTest(), name)
            XCTAssertEqual(fixture.service.lastAction, item.deleteFails ? .deliverySuspended : .notConfigured, name)

            if offSaveNeeded {
                fixture.fileStore.failSaves = false
                XCTAssertTrue(fixture.service.setEnabled(false), name)
                XCTAssertFalse(fixture.service.offIsUnsaved, name)
            }
            fixture.backend.deleteErrors = [:]
            let restarted = restartedService(fixture)
            XCTAssertFalse(restarted.isEnabled, name)
            XCTAssertFalse(restarted.admission.isEnabled, name)
            XCTAssertEqual(restarted.tokenStatus, item.deleteFails ? .saved : .missing, "\(name): old token readable")
            XCTAssertEqual(restarted.isDeliveryConfigured, item.deleteFails, name)
            XCTAssertEqual(fixture.http.requestCount, 0, name)
        }
    }

    // MARK: - Launch guard

    func testDeniedLaunchesCreateNoDependenciesReadNoTokenAndSendNothing() throws {
        XCTAssertFalse(
            TelegramAttentionLaunchEnvironment.current(.current).allowsTelegramNotifications,
            "This XCTest process is denied"
        )
        XCTAssertFalse(TelegramAttentionNotificationService.shared.isStarted)
        XCTAssertNil(AttentionNotificationAdmission.shared.delivery)
        XCTAssertFalse(AttentionNotificationAdmission.shared.isEnabled)

        let denied: [(String, TelegramAttentionLaunchEnvironment)] = [
            ("UI test", launch(arguments: ["-RP_UITEST"])),
            ("stress", launch(arguments: ["-RP_AGENT_CHAT_STRESS"])),
            ("XCTest argument", launch(arguments: ["-XCTestScopeFile"])),
            ("hosted XCTest", launch(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"])),
            ("injected XCTest", launch(environment: ["XCInjectBundleInto": "/tmp/App"])),
            ("direct XCTest", launch(xctestLoaded: true)),
            ("nonessential side effects suppressed", launch(suppressesNonessential: true))
        ]
        for (name, environment) in denied {
            let fixture = try makeFixture(enabled: true)
            fixture.service.start(launch: environment)
            XCTAssertFalse(fixture.service.isStarted, name)
            XCTAssertEqual(fixture.factory.calls, 0, "\(name): no secure-storage or HTTP dependency")
            XCTAssertFalse(fixture.service.sendTest(), name)
            XCTAssertFalse(fixture.service.saveToken(PacedTelegramTestSupport.replacementToken), name)
            XCTAssertFalse(fixture.service.setEnabled(true), name)
            XCTAssertEqual(fixture.service.lastAction, .unavailableInThisLaunch, name)
            XCTAssertTrue(fixture.backend.calls.isEmpty, "\(name): no token read or write")
            XCTAssertNil(fixture.admission.delivery, name)
            XCTAssertFalse(fixture.admission.isEnabled, name)
            XCTAssertEqual(fixture.http.requestCount, 0, name)
        }
    }

    // MARK: - Manual test and automatic events

    func testAllowedStartLoadsOnceAndSendTestPostsFixedMessageWhileAutomaticIsOff() async throws {
        let fixture = try makeFixture(idle: 10)
        fixture.service.start(launch: Self.allowedLaunch)
        fixture.service.start(launch: Self.allowedLaunch)
        XCTAssertEqual(fixture.factory.calls, 1)
        XCTAssertEqual(fixture.backend.calls.map(\.operation), [.get])
        XCTAssertEqual(fixture.service.tokenStatus, .saved)
        XCTAssertTrue(fixture.service.isDeliveryConfigured)
        XCTAssertFalse(fixture.service.automaticNotificationsActive)
        XCTAssertFalse(fixture.admission.isEnabled)

        XCTAssertTrue(fixture.service.sendTest())
        let key = try XCTUnwrap(fixture.service.lastTestKey)
        guard case .test = key else { return XCTFail("A dedicated test key") }
        XCTAssertTrue(fixture.service.isTestPending)
        XCTAssertFalse(fixture.service.sendTest(), "Send test is disabled while its key is pending")
        XCTAssertEqual(fixture.service.lastAction, .testAlreadyPending)
        try await waitForRecord(fixture.admission, key) { $0 == .delivered(.sent) }
        XCTAssertFalse(fixture.service.isTestPending)
        XCTAssertEqual(fixture.http.texts, [TelegramAttentionMessageRenderer.testMessage])
        XCTAssertEqual(fixture.http.chatIDs, [7])
        XCTAssertEqual(fixture.idle.reads, 0, "Send test ignores idle")

        let automatic = completionEvent(text: "automatic")
        fixture.admission.submit(fixture.admission.makeCapture(event: automatic, isStillCurrent: { true }))
        let record = try await waitForRecord(fixture.admission, automatic.key)
        XCTAssertEqual(record, .suppressed(.disabled), "Automatic events stay off")
        XCTAssertEqual(fixture.idle.reads, 1)
        XCTAssertEqual(fixture.http.requestCount, 1)
    }

    func testConfigurationChangesBeforeAdmissionNeverPostTheQueuedTest() async throws {
        enum Change: String, CaseIterable {
            case chatReplaced, tokenReplaced, tokenRemoved
        }
        for change in Change.allCases {
            let fixture = try makeFixture(enabled: true)
            fixture.service.start(launch: Self.allowedLaunch)
            fixture.fence.holds = true
            XCTAssertTrue(fixture.service.sendTest())
            let key = try XCTUnwrap(fixture.service.lastTestKey)
            try await waitUntil("\(change): the test to reach the fence") { fixture.fence.pauseCount == 1 }

            switch change {
            case .chatReplaced:
                XCTAssertTrue(fixture.service.saveChatID("8"))
            case .tokenReplaced:
                XCTAssertTrue(fixture.service.saveToken(PacedTelegramTestSupport.replacementToken))
            case .tokenRemoved:
                XCTAssertTrue(fixture.service.removeToken())
                XCTAssertFalse(fixture.settings.telegramNotificationsEnabled(), "Removal turns automatic notifications off")
                XCTAssertEqual(fixture.service.tokenStatus, .missing)
            }
            fixture.fence.release()

            let record = try await waitForRecord(fixture.admission, key)
            XCTAssertEqual(record, .suppressed(.configurationChanged), change.rawValue)
            XCTAssertEqual(fixture.http.requestCount, 0, change.rawValue)

            if change == .chatReplaced {
                XCTAssertTrue(fixture.service.sendTest())
                try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 == .delivered(.sent) }
                XCTAssertEqual(fixture.http.chatIDs, [8])
            }
        }
    }

    /// A settings reload replaces saved values at once, but the service adopts them on a later
    /// main-queue turn. An event released from the fence in the same turn as the reload is admitted
    /// before that observer runs (the recorded service chat ID proves it), and still never posts.
    func testSettingsReloadBeforeObserverRunsNeverPostsThroughStaleDelivery() async throws {
        enum Reload: String, CaseIterable {
            case chatChangedAutomatic, disabledAutomatic, chatChangedTest
        }
        for reload in Reload.allCases {
            let fixture = try makeFixture(enabled: true)
            fixture.service.start(launch: Self.allowedLaunch)
            XCTAssertTrue(fixture.admission.isEnabled)
            fixture.fence.holds = true
            var chatIDAtAdmission: String??
            fixture.fence.onPass = { chatIDAtAdmission = .some(fixture.service.chatID) }

            let key: AttentionNotificationEventKey
            if reload == .chatChangedTest {
                XCTAssertTrue(fixture.service.sendTest())
                key = try XCTUnwrap(fixture.service.lastTestKey)
            } else {
                let event = completionEvent(text: "automatic")
                fixture.admission.submit(fixture.admission.makeCapture(event: event, isStillCurrent: { true }))
                key = event.key
            }
            try await waitUntil("\(reload): the event to reach the fence") { fixture.fence.pauseCount == 1 }

            // Another writer changes the saved file; this store reloads it.
            let writerSuite = "TelegramServiceWriter.\(UUID().uuidString)"
            let writerDefaults = try XCTUnwrap(UserDefaults(suiteName: writerSuite))
            addTeardownBlock { writerDefaults.removePersistentDomain(forName: writerSuite) }
            let writer = GlobalSettingsStore(
                defaults: writerDefaults,
                fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL)
            )
            if reload == .disabledAutomatic {
                XCTAssertTrue(writer.setTelegramNotificationsEnabled(false))
            } else {
                XCTAssertTrue(writer.setTelegramChatID("9"))
            }
            fixture.fence.release()
            XCTAssertTrue(fixture.settings.reloadFromDisk())
            XCTAssertEqual(fixture.service.chatID, "7", "\(reload): the observer has not run yet")

            let record = try await waitForRecord(fixture.admission, key)
            XCTAssertEqual(record, .suppressed(.configurationChanged), reload.rawValue)
            XCTAssertEqual(chatIDAtAdmission, .some("7"), "\(reload): admitted before the observer adopted the reload")
            XCTAssertEqual(fixture.http.requestCount, 0, reload.rawValue)

            if reload == .disabledAutomatic {
                try await waitUntil("\(reload): reconciliation") { !fixture.service.isEnabled }
                XCTAssertFalse(fixture.admission.isEnabled)
            } else {
                try await waitUntil("\(reload): reconciliation") { fixture.service.chatID == "9" }
                XCTAssertTrue(fixture.service.isDeliveryConfigured)
                XCTAssertTrue(fixture.service.sendTest())
                try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 == .delivered(.sent) }
                XCTAssertEqual(fixture.http.chatIDs, [9])
            }
        }
    }

    func testAutomaticAndTestShareOneQueueAndOnePacerAcrossReplacement() async throws {
        let fixture = try makeFixture(enabled: true)
        fixture.service.start(launch: Self.allowedLaunch)
        let longText = (0 ..< 400).map { "line \($0) of the final assistant reply" }.joined(separator: "\n")
        let completion = completionEvent(text: longText)
        let parts = TelegramAttentionMessageRenderer.render(completion).map(\.text)
        XCTAssertGreaterThan(parts.count, 1)

        fixture.admission.submit(fixture.admission.makeCapture(event: completion, isStillCurrent: { true }))
        XCTAssertTrue(fixture.service.sendTest())
        try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 == .delivered(.sent) }
        XCTAssertEqual(fixture.admission.records[completion.key], .delivered(.sent))
        XCTAssertEqual(fixture.http.texts, parts + [TelegramAttentionMessageRenderer.testMessage], "Never interleaved")
        XCTAssertEqual(fixture.http.requestTimes, (0 ... parts.count).map { Duration.seconds($0) })

        XCTAssertTrue(fixture.service.saveChatID("-100123"))
        XCTAssertTrue(fixture.service.sendTest())
        try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 == .delivered(.sent) }
        XCTAssertTrue(fixture.service.sendTest())
        try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 == .delivered(.sent) }
        XCTAssertEqual(Array(fixture.http.chatIDs.suffix(2)), [-100_123, -100_123])
        XCTAssertEqual(
            Array(fixture.http.requestTimes.suffix(2)),
            [.seconds(parts.count + 1), .seconds(parts.count + 4)],
            "Replacement keeps the pacer: 1 s owed from the last private send, then 3 s for the group"
        )
    }

    // MARK: - Session links

    /// Review S3-01: the browser origin is per-attempt link metadata. Gateway status changes
    /// (an unchanged-origin refresh, or a real gateway loss) never replace the delivery, so
    /// queued and pending alerts, including a queued Send test, are still sent; each attempt
    /// carries the button only if an origin is active when it starts.
    func testSessionLinkIsPerAttemptMetadataAndNeverInvalidatesQueuedAlerts() async throws {
        let gatewayStatus = RemoteGatewayStatusStore()
        let fixture = try makeFixture(enabled: true, gatewayStatus: gatewayStatus)
        fixture.service.start(launch: Self.allowedLaunch)
        XCTAssertNil(fixture.service.activeBrowserOrigin)
        XCTAssertEqual(fixture.service.sessionLinkHint, TelegramAttentionNotificationService.sessionLinkUnavailableHint)
        XCTAssertEqual(fixture.service.notices, [], "The link hint is not a delivery notice")

        let gatewayOrigin = try RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.8", channel: .debug)
        let browserOrigin = try RemoteGatewayOrigin(string: "https://mac.example.ts.net:8443")
        let generation = fixture.admission.deliveryGeneration
        gatewayStatus.publish(.resolvingTailscale, generation: 1)
        gatewayStatus.publish(.starting(gatewayOrigin), browserOrigin: browserOrigin, generation: 1)
        XCTAssertNil(fixture.service.activeBrowserOrigin, "A starting gateway is not active")
        gatewayStatus.publish(.discoverable(gatewayOrigin), browserOrigin: browserOrigin, generation: 1)
        XCTAssertEqual(fixture.service.activeBrowserOrigin, browserOrigin)
        XCTAssertNil(fixture.service.sessionLinkHint)
        XCTAssertEqual(fixture.admission.deliveryGeneration, generation, "Link metadata is not configuration")

        let sessionID = UUID()
        let linked = AttentionNotificationEvent(
            key: .turnCompleted(sessionID: sessionID, attemptID: UUID()),
            workspaceName: "Workspace",
            sessionName: "Root",
            content: .turnCompleted(finalAssistantText: "done")
        )
        fixture.admission.submit(fixture.admission.makeCapture(event: linked, isStillCurrent: { true }))
        try await waitForRecord(fixture.admission, linked.key) { $0 == .delivered(.sent) }
        XCTAssertEqual(fixture.http.texts, TelegramAttentionMessageRenderer.render(linked).map(\.text))
        XCTAssertEqual(
            sessionLinkButtonURLs(fixture.http),
            ["https://mac.example.ts.net:8443/?session_id=\(sessionID.uuidString)"]
        )

        // An unchanged-origin refresh while one alert is at the fence and another is queued
        // behind it with a Send test.
        fixture.fence.holds = true
        let pending = completionEvent(text: "pending through refresh")
        let queued = completionEvent(text: "queued through refresh")
        fixture.admission.submit(fixture.admission.makeCapture(event: pending, isStillCurrent: { true }))
        try await waitUntil("the pending event to reach the fence") { fixture.fence.pauseCount == 2 }
        fixture.admission.submit(fixture.admission.makeCapture(event: queued, isStillCurrent: { true }))
        XCTAssertTrue(fixture.service.sendTest())
        let refreshTestKey = try XCTUnwrap(fixture.service.lastTestKey)
        gatewayStatus.publish(.resolvingTailscale, generation: 2)
        XCTAssertEqual(fixture.service.sessionLinkHint, TelegramAttentionNotificationService.sessionLinkUnavailableHint)
        gatewayStatus.publish(.starting(gatewayOrigin), browserOrigin: browserOrigin, generation: 2)
        gatewayStatus.publish(.discoverable(gatewayOrigin), browserOrigin: browserOrigin, generation: 2)
        XCTAssertEqual(fixture.admission.deliveryGeneration, generation)
        fixture.fence.release()
        try await waitForRecord(fixture.admission, pending.key) { $0 == .delivered(.sent) }
        try await waitForRecord(fixture.admission, queued.key) { $0 == .delivered(.sent) }
        try await waitForRecord(fixture.admission, refreshTestKey) { $0 == .delivered(.sent) }
        XCTAssertEqual(
            Array(sessionLinkButtonURLs(fixture.http).suffix(3)),
            [sessionLink(browserOrigin, pending), sessionLink(browserOrigin, queued), nil],
            "Each attempt reads the active origin; the Send test never has a link"
        )

        // A real gateway loss while an alert is at the fence and a Send test is queued: both are
        // still sent, the alert text-only.
        fixture.fence.holds = true
        let pauses = fixture.fence.pauseCount
        let lost = completionEvent(text: "pending through gateway loss")
        fixture.admission.submit(fixture.admission.makeCapture(event: lost, isStillCurrent: { true }))
        try await waitUntil("the event to reach the fence") { fixture.fence.pauseCount == pauses + 1 }
        XCTAssertTrue(fixture.service.sendTest())
        let lossTestKey = try XCTUnwrap(fixture.service.lastTestKey)
        gatewayStatus.publish(.unavailable("Gateway process exited."), generation: 3)
        XCTAssertNil(fixture.service.activeBrowserOrigin)
        XCTAssertEqual(fixture.service.sessionLinkHint, TelegramAttentionNotificationService.sessionLinkUnavailableHint)
        XCTAssertTrue(fixture.service.isDeliveryConfigured, "Alerts continue text-only")
        XCTAssertEqual(fixture.admission.deliveryGeneration, generation)
        fixture.fence.release()
        try await waitForRecord(fixture.admission, lost.key) { $0 == .delivered(.sent) }
        try await waitForRecord(fixture.admission, lossTestKey) { $0 == .delivered(.sent) }
        XCTAssertEqual(Array(sessionLinkButtonURLs(fixture.http).suffix(2)), [nil, nil])
        XCTAssertEqual(
            Array(fixture.http.texts.suffix(2)),
            [TelegramAttentionMessageRenderer.render(lost).map(\.text).first, TelegramAttentionMessageRenderer.testMessage]
        )
    }

    func testFailingTestRecordsOneAttemptWithFixedResultText() async throws {
        let echoed = Data(#"{"ok":false,"error_code":401,"description":"bad \#(PacedTelegramTestSupport.syntheticToken) https://api.telegram.org/bot"}"#.utf8)
        let fixture = try makeFixture(replies: [
            .respond(status: 401, body: echoed),
            .fail(PacedTelegramTestSupport.leakyURLError(.timedOut))
        ])
        fixture.service.start(launch: Self.allowedLaunch)

        var messages: [String] = []
        for expected in [AttentionNotificationDeliveryOutcome.failed, .unknown] {
            XCTAssertTrue(fixture.service.sendTest())
            let record = try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 != .admitted }
            XCTAssertEqual(record, .delivered(expected))
            messages.append(TelegramAttentionNotificationService.message(for: record))
        }
        XCTAssertEqual(fixture.http.requestCount, 2, "One attempt each, never retried")
        XCTAssertNil(fixture.admission.lastDeliveryOutcome, "Manual tests never set the automatic diagnostics")
        messages += [
            fixture.service.lastAction?.message ?? "",
            fixture.service.tokenStatus.message,
            String(describing: fixture.service.lastTestRecord),
            String(describing: fixture.admission.records)
        ]
        for message in messages {
            XCTAssertFalse(message.contains(PacedTelegramTestSupport.syntheticSecret), message)
            XCTAssertFalse(message.contains("api.telegram.org"), message)
            XCTAssertFalse(message.contains("bad "), message)
        }
    }

    /// Last automatic delivery and suppression describe automatic events only: manual tests that
    /// are sent, fail, or are suppressed keep their own records and never overwrite them, and
    /// each still releases the queue.
    func testManualTestsRetainAutomaticDiagnostics() async throws {
        let fixture = try makeFixture(enabled: true, replies: [
            .ok,
            .respond(status: 401, body: Data(#"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8))
        ])
        fixture.service.start(launch: Self.allowedLaunch)
        let sent = completionEvent(text: "sent")
        fixture.admission.submit(fixture.admission.makeCapture(event: sent, isStillCurrent: { true }))
        try await waitForRecord(fixture.admission, sent.key) { $0 == .delivered(.sent) }
        let stale = completionEvent(text: "stale")
        fixture.admission.submit(fixture.admission.makeCapture(event: stale, isStillCurrent: { false }))
        try await waitForRecord(fixture.admission, stale.key)
        XCTAssertEqual(fixture.admission.lastDeliveryOutcome, .sent)
        XCTAssertEqual(fixture.admission.lastSuppression, .eventNoLongerCurrent)

        XCTAssertTrue(fixture.service.sendTest())
        try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 == .delivered(.failed) }
        XCTAssertTrue(fixture.service.sendTest())
        try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 == .delivered(.sent) }
        fixture.fence.holds = true
        XCTAssertTrue(fixture.service.sendTest())
        try await waitUntil("the test to reach the fence") { fixture.fence.pauseCount == 5 }
        XCTAssertTrue(fixture.service.saveChatID("8"))
        fixture.fence.release()
        let suppressed = try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey))
        XCTAssertEqual(suppressed, .suppressed(.configurationChanged))
        XCTAssertEqual(fixture.service.lastTestRecord, suppressed)
        XCTAssertEqual(
            TelegramAttentionNotificationService.message(for: suppressed),
            "Not sent: notification settings changed before sending."
        )

        XCTAssertEqual(fixture.admission.lastDeliveryOutcome, .sent, "Automatic delivery is retained")
        XCTAssertEqual(fixture.admission.lastSuppression, .eventNoLongerCurrent, "Automatic suppression is retained")
        XCTAssertFalse(fixture.service.isTestPending)
        XCTAssertNil(fixture.admission.activeEventKey, "The queue was released")
        XCTAssertTrue(fixture.admission.pendingEventKeys.isEmpty)
        XCTAssertEqual(fixture.http.requestCount, 3)
    }

    // MARK: - Idle policy (Slice 12)

    /// An automatic event held before admission is never sent under an idle policy other than
    /// the one it was captured under: explicit saves (including change-and-revert) fence it by
    /// the automatic generation, and saved changes not yet adopted by the asynchronous observer
    /// (including change-and-revert) fence it at the final saved-source check.
    func testIdlePolicyChangesBeforeAdmissionNeverPostPendingAutomaticEvents() async throws {
        enum Change: String, CaseIterable {
            case explicitAlwaysFromDefault, explicitIncrease, explicitChangeAndRevert
            case externalReload, externalChangeAndRevert
        }
        for change in Change.allCases {
            let startMinutes = change == .explicitAlwaysFromDefault ? 5 : 0
            let fixture = try makeFixture(enabled: true, idle: 10, idleMinutes: startMinutes)
            fixture.service.start(launch: Self.allowedLaunch)
            XCTAssertEqual(fixture.service.idleThresholdMinutes, startMinutes, change.rawValue)
            XCTAssertEqual(fixture.admission.idleThresholdMinutes, startMinutes, change.rawValue)
            let deliveryGeneration = fixture.admission.deliveryGeneration
            fixture.fence.holds = true
            var minutesAtAdmission: Int?
            fixture.fence.onPass = { minutesAtAdmission = fixture.service.idleThresholdMinutes }
            let event = completionEvent(text: "automatic")
            fixture.admission.submit(fixture.admission.makeCapture(event: event, isStillCurrent: { true }))
            try await waitUntil("\(change): the event to reach the fence") { fixture.fence.pauseCount == 1 }

            let expected: AttentionNotificationSuppression
            let finalMinutes: Int
            switch change {
            case .explicitAlwaysFromDefault:
                XCTAssertTrue(fixture.service.saveIdleThresholdMinutes("0"))
                (expected, finalMinutes) = (.enableChanged, 0)
            case .explicitIncrease:
                XCTAssertTrue(fixture.service.saveIdleThresholdMinutes("15"))
                (expected, finalMinutes) = (.enableChanged, 15)
            case .explicitChangeAndRevert:
                XCTAssertTrue(fixture.service.saveIdleThresholdMinutes("5"))
                XCTAssertTrue(fixture.service.saveIdleThresholdMinutes("0"))
                (expected, finalMinutes) = (.enableChanged, 0)
            case .externalReload, .externalChangeAndRevert:
                fixture.fence.release()
                let writer = try externalWriter(fixture)
                XCTAssertTrue(writer.setTelegramIdleThresholdMinutes(5))
                XCTAssertTrue(fixture.settings.reloadFromDisk())
                if change == .externalChangeAndRevert {
                    XCTAssertTrue(writer.setTelegramIdleThresholdMinutes(0))
                    XCTAssertTrue(fixture.settings.reloadFromDisk())
                }
                XCTAssertEqual(fixture.service.idleThresholdMinutes, 0, "\(change): the observer has not run yet")
                (expected, finalMinutes) = (.configurationChanged, change == .externalReload ? 5 : 0)
            }
            fixture.fence.release()

            let record = try await waitForRecord(fixture.admission, event.key)
            XCTAssertEqual(record, .suppressed(expected), change.rawValue)
            if change == .externalReload || change == .externalChangeAndRevert {
                XCTAssertEqual(minutesAtAdmission, 0, "\(change): admitted before the observer adopted the reload")
            }
            XCTAssertEqual(fixture.http.requestCount, 0, change.rawValue)

            try await waitUntil("\(change): reconciliation") {
                fixture.admission.idlePolicySourceRevision == fixture.settings.telegramIdlePolicyRevision
            }
            XCTAssertEqual(fixture.service.idleThresholdMinutes, finalMinutes, change.rawValue)
            XCTAssertEqual(fixture.admission.idleThresholdMinutes, finalMinutes, change.rawValue)
            XCTAssertEqual(fixture.admission.deliveryGeneration, deliveryGeneration, "\(change): sender kept")
            XCTAssertEqual(fixture.factory.calls, 1, change.rawValue)
            XCTAssertEqual(fixture.backend.calls.map(\.operation), [.get], "\(change): no token reread")
        }
    }

    /// Invalid drafts, saves of the current effective value, unchanged reloads, and failed saves
    /// change neither the policy nor its revision, and a held automatic event stays valid and is
    /// sent (released before the settings observer runs).
    func testInvalidUnchangedAndFailedIdleSavesKeepPolicyAndPendingEvents() async throws {
        let fixture = try makeFixture(enabled: true, idle: 10, idleMinutes: 0)
        fixture.service.start(launch: Self.allowedLaunch)
        let revision = fixture.settings.telegramIdlePolicyRevision
        let enableGeneration = fixture.admission.enableGeneration
        let deliveryGeneration = fixture.admission.deliveryGeneration
        fixture.fence.holds = true
        let event = completionEvent(text: "automatic")
        fixture.admission.submit(fixture.admission.makeCapture(event: event, isStillCurrent: { true }))
        try await waitUntil("the event to reach the fence") { fixture.fence.pauseCount == 1 }

        for draft in ["", "  ", "-1", "+5", "1.5", "1e3", "5 min", "\u{0663}", "99999999999999999999999"] {
            XCTAssertFalse(fixture.service.saveIdleThresholdMinutes(draft), draft)
            XCTAssertEqual(fixture.service.lastAction, .invalidIdleThreshold, draft)
        }
        XCTAssertFalse(fixture.settings.setTelegramIdleThresholdMinutes(-1), "The store rejects negatives")
        XCTAssertTrue(fixture.service.saveIdleThresholdMinutes("0"))
        XCTAssertTrue(fixture.service.saveIdleThresholdMinutes(" 00 "))
        XCTAssertEqual(fixture.service.lastAction, .idleThresholdSaved)
        XCTAssertTrue(fixture.settings.reloadFromDisk())
        fixture.fileStore.failSaves = true
        XCTAssertFalse(fixture.service.saveIdleThresholdMinutes("5"))
        XCTAssertEqual(fixture.service.lastAction, .settingsSaveFailed)
        fixture.fence.release()

        XCTAssertEqual(fixture.settings.telegramIdleThresholdMinutes(), 0, "The failed value was rolled back")
        XCTAssertEqual(fixture.settings.telegramIdlePolicyRevision, revision)
        XCTAssertEqual(fixture.service.idleThresholdMinutes, 0)
        XCTAssertEqual(fixture.admission.idleThresholdMinutes, 0)
        XCTAssertEqual(fixture.admission.enableGeneration, enableGeneration)
        XCTAssertEqual(fixture.admission.deliveryGeneration, deliveryGeneration)
        XCTAssertTrue(fixture.service.isDeliveryConfigured)
        XCTAssertTrue(fixture.service.automaticNotificationsActive)
        try await waitForRecord(fixture.admission, event.key) { $0 == .delivered(.sent) }
        XCTAssertEqual(fixture.http.requestCount, 1)

        fixture.fileStore.failSaves = false
        XCTAssertTrue(fixture.service.saveIdleThresholdMinutes("007"))
        XCTAssertEqual(fixture.service.idleThresholdMinutes, 7, "Leading zeroes normalize")
        XCTAssertEqual(fixture.settings.telegramIdlePolicyRevision, revision + 1)
    }

    /// Idle-only changes (explicit saves and an unobserved reload) never touch the sender, the
    /// pacer, or the token, and never drop a held Send test; Send test ignores idle.
    func testManualTestSurvivesIdleOnlyChangesWithSameSenderAndPacer() async throws {
        let fixture = try makeFixture(idle: 10)
        fixture.service.start(launch: Self.allowedLaunch)
        let deliveryGeneration = fixture.admission.deliveryGeneration
        fixture.fence.holds = true
        XCTAssertTrue(fixture.service.sendTest())
        let key = try XCTUnwrap(fixture.service.lastTestKey)
        try await waitUntil("the test to reach the fence") { fixture.fence.pauseCount == 1 }

        XCTAssertTrue(fixture.service.saveIdleThresholdMinutes("0"))
        XCTAssertTrue(fixture.service.saveIdleThresholdMinutes("30"))
        XCTAssertTrue(fixture.service.isTestPending)
        let writer = try externalWriter(fixture)
        XCTAssertTrue(writer.setTelegramIdleThresholdMinutes(3))
        fixture.fence.release()
        XCTAssertTrue(fixture.settings.reloadFromDisk())

        try await waitForRecord(fixture.admission, key) { $0 == .delivered(.sent) }
        XCTAssertEqual(fixture.http.texts, [TelegramAttentionMessageRenderer.testMessage])
        try await waitUntil("reconciliation") { fixture.service.idleThresholdMinutes == 3 }
        XCTAssertTrue(fixture.service.sendTest())
        try await waitForRecord(fixture.admission, XCTUnwrap(fixture.service.lastTestKey)) { $0 == .delivered(.sent) }
        XCTAssertEqual(fixture.http.requestTimes, [.zero, .seconds(1)], "The same pacer")
        XCTAssertEqual(fixture.admission.deliveryGeneration, deliveryGeneration, "The same sender")
        XCTAssertEqual(fixture.factory.calls, 1)
        XCTAssertEqual(fixture.backend.calls.map(\.operation), [.get], "No token reread")
        XCTAssertEqual(fixture.idle.reads, 0, "Send test never reads idle")
    }

    func testIdleThresholdPersistsWithDefaultAndTracksAcceptedTransitionsOnly() throws {
        let fixture = try makeFixture()
        let settings = fixture.settings
        let initial = try savedTelegram(fixture)
        XCTAssertNil(initial?.idleThresholdMinutes)
        XCTAssertEqual(settings.telegramIdleThresholdMinutes(), 5, "Missing means the default")
        XCTAssertEqual(GlobalScalarPreferences.TelegramSettings.effectiveIdleThresholdMinutes(nil), 5)
        let negative = try JSONDecoder().decode(
            GlobalScalarPreferences.self,
            from: Data(#"{"telegram":{"enabled":true,"chatID":"7","idleThresholdMinutes":-3}}"#.utf8)
        )
        XCTAssertEqual(negative.telegram?.idleThresholdMinutes, -3, "Decoded as stored; the document still loads")
        XCTAssertEqual(GlobalScalarPreferences.TelegramSettings.effectiveIdleThresholdMinutes(negative.telegram), 5)

        let start = settings.telegramIdlePolicyRevision
        XCTAssertTrue(settings.setTelegramIdleThresholdMinutes(5))
        let afterDefaultSave = try savedTelegram(fixture)
        XCTAssertNil(afterDefaultSave?.idleThresholdMinutes, "Saving the effective default writes nothing")
        XCTAssertTrue(settings.setTelegramChatID("8"))
        XCTAssertTrue(settings.setTelegramNotificationsEnabled(true))
        XCTAssertEqual(settings.telegramIdlePolicyRevision, start, "Other Telegram settings never advance it")

        for (minutes, revision) in [(0, start + 1), (5, start + 2), (0, start + 3), (Int.max, start + 4), (42, start + 5)] {
            XCTAssertTrue(settings.setTelegramIdleThresholdMinutes(minutes))
            XCTAssertEqual(settings.telegramIdlePolicyRevision, revision, "\(minutes)")
            let reloaded = GlobalSettingsStore(defaults: fixture.defaults, fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL))
            XCTAssertEqual(reloaded.telegramIdleThresholdMinutes(), minutes, "\(minutes) round-trips")
        }

        fixture.fileStore.failSaves = true
        XCTAssertFalse(settings.setTelegramIdleThresholdMinutes(9))
        XCTAssertEqual(settings.telegramIdleThresholdMinutes(), 42)
        XCTAssertEqual(settings.telegramIdlePolicyRevision, start + 5, "A failed save never advances it")
        fixture.fileStore.failSaves = false
        XCTAssertTrue(settings.reloadFromDisk())
        XCTAssertEqual(settings.telegramIdlePolicyRevision, start + 5, "An unchanged reload never advances it")

        let saved = try savedTelegram(fixture)
        XCTAssertEqual(saved, GlobalScalarPreferences.TelegramSettings(enabled: true, chatID: "8", idleThresholdMinutes: 42))
    }

    // MARK: - Idle

    func testIdleReadingIsSanitizedAndThresholdedAtEventTime() async throws {
        XCTAssertNotNil(CGEventType(rawValue: ~0), "The any-input sentinel is constructible")
        let raws: [(Double, TimeInterval?, AttentionNotificationAdmission.Record)] = [
            (.nan, nil, .delivered(.sent)),
            (.infinity, nil, .delivered(.sent)),
            (-1, nil, .delivered(.sent)),
            (299, 299, .suppressed(.userActive)),
            (300, 300, .delivered(.sent))
        ]
        for (raw, sanitized, expected) in raws {
            XCTAssertEqual(TelegramAttentionIdleReader.sanitized(raw), sanitized, "\(raw)")
            let http = PacedStubHTTPClient()
            let admission = AttentionNotificationAdmission(environment: .init(
                delivery: PacedTelegramTestSupport.delivery(http: http, pacer: TelegramAttentionPacer(clock: ManualPacingClock().pacingClock)),
                idleSeconds: { TelegramAttentionIdleReader.sanitized(raw) }
            ))
            admission.setEnabled(true)
            let event = completionEvent(text: "idle")
            admission.submit(admission.makeCapture(event: event, isStillCurrent: { true }))
            let record = try await waitForRecord(admission, event.key) { $0 != .admitted }
            XCTAssertEqual(record, expected, "\(raw)")
        }
    }

    // MARK: - Helpers

    private typealias ActionResult = TelegramAttentionNotificationService.ActionResult
    private typealias Notice = TelegramAttentionNotificationService.Notice
    private typealias TokenStatus = TelegramAttentionNotificationService.TokenStatus

    private struct Fixture {
        let service: TelegramAttentionNotificationService
        let admission: AttentionNotificationAdmission
        let settings: GlobalSettingsStore
        let fileStore: SwitchableSettingsFileStore
        let fileURL: URL
        let defaults: UserDefaults
        let backend: TestSecureStorageBackend
        /// The secure storage the service uses: `backend`, or a process-local ephemeral store.
        let storage: any SecureKeyValueStorageBackend
        let http: PacedStubHTTPClient
        let factory: FactoryCounter
        let fence: ServiceAdmissionFence
        let idle: IdleCounter
    }

    private func makeFixture(
        token: String? = PacedTelegramTestSupport.syntheticToken,
        chatID: String? = "7",
        enabled: Bool = false,
        idle: TimeInterval? = nil,
        idleMinutes: Int? = nil,
        ephemeral: Bool = false,
        replies: [PacedStubHTTPClient.Reply] = [],
        gatewayStatus: RemoteGatewayStatusStore? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelegramAttentionNotificationServiceTests-\(UUID().uuidString)")
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let suiteName = "TelegramAttentionNotificationServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let fileStore = SwitchableSettingsFileStore(base: GlobalSettingsFileStore(fileURL: fileURL))
        let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        if let chatID {
            XCTAssertTrue(settings.setTelegramChatID(chatID))
        }
        XCTAssertTrue(settings.setTelegramNotificationsEnabled(enabled))
        if let idleMinutes {
            XCTAssertTrue(settings.setTelegramIdleThresholdMinutes(idleMinutes))
        }

        let backend = TestSecureStorageBackend(values: token.map { [.telegramAttentionBotToken: $0] } ?? [:])
        let storage: any SecureKeyValueStorageBackend = ephemeral ? EphemeralSecureKeyValueStore() : backend
        let clock = ManualPacingClock()
        let http = PacedStubHTTPClient(replies: replies, clock: clock)
        let fence = ServiceAdmissionFence()
        let idleCounter = IdleCounter(value: idle)
        let admission = AttentionNotificationAdmission(environment: .init(
            idleSeconds: { idleCounter.read() },
            beforeAdmission: { _ in await fence.pause() }
        ))
        let factory = FactoryCounter()
        let service = TelegramAttentionNotificationService(
            admission: admission,
            settings: settings,
            // Isolated by default: the shared store would let an unrelated gateway publication
            // reach this fixture.
            gatewayStatus: gatewayStatus ?? RemoteGatewayStatusStore(),
            pacer: TelegramAttentionPacer(clock: clock.pacingClock),
            makeDependencies: {
                factory.calls += 1
                return .init(
                    tokenStore: TelegramBotTokenStore(secureStorage: SecureKeysService(secureStorage: storage)),
                    client: TelegramSendMessageClient(httpClient: http)
                )
            }
        )
        addTeardownBlock { @MainActor in
            fence.release()
            http.releaseHangs()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            service: service,
            admission: admission,
            settings: settings,
            fileStore: fileStore,
            fileURL: fileURL,
            defaults: defaults,
            backend: backend,
            storage: storage,
            http: http,
            factory: factory,
            fence: fence,
            idle: idleCounter
        )
    }

    /// The Open session link for `event` under `origin`.
    private func sessionLink(_ origin: RemoteGatewayOrigin, _ event: AttentionNotificationEvent) -> String? {
        TelegramPacedAttentionDelivery.openSessionURL(origin: origin, key: event.key)?.absoluteString
    }

    /// Each request's Open session button URL, or nil for a text-only request.
    private func sessionLinkButtonURLs(_ http: PacedStubHTTPClient) -> [String?] {
        http.requests.map { request in
            guard let data = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let markup = body["reply_markup"] as? [String: Any],
                  let rows = markup["inline_keyboard"] as? [[[String: String]]]
            else { return nil }
            return rows.first?.first?["url"]
        }
    }

    /// A later startup: a fresh service, admission, and settings store over the same saved file
    /// and secure storage.
    private func restartedService(_ fixture: Fixture) -> TelegramAttentionNotificationService {
        let service = TelegramAttentionNotificationService(
            admission: AttentionNotificationAdmission(),
            settings: GlobalSettingsStore(defaults: fixture.defaults, fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL)),
            gatewayStatus: RemoteGatewayStatusStore(),
            pacer: TelegramAttentionPacer(clock: ManualPacingClock().pacingClock),
            makeDependencies: {
                .init(
                    tokenStore: TelegramBotTokenStore(secureStorage: SecureKeysService(secureStorage: fixture.storage)),
                    client: TelegramSendMessageClient(httpClient: fixture.http)
                )
            }
        )
        service.start(launch: Self.allowedLaunch)
        return service
    }

    /// The Telegram group as saved on disk.
    private func savedTelegram(_ fixture: Fixture) throws -> GlobalScalarPreferences.TelegramSettings? {
        try GlobalSettingsFileStore(fileURL: fixture.fileURL).load().scalarPreferences?.telegram
    }

    /// Another settings writer over the same saved file (its own defaults suite).
    private func externalWriter(_ fixture: Fixture) throws -> GlobalSettingsStore {
        let suite = "TelegramServiceWriter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL))
    }

    private func launch(
        arguments: [String] = [],
        environment: [String: String] = [:],
        xctestLoaded: Bool = false,
        suppressesNonessential: Bool = false
    ) -> TelegramAttentionLaunchEnvironment {
        TelegramAttentionLaunchEnvironment(
            arguments: arguments,
            environment: environment,
            xctestLoaded: xctestLoaded,
            suppressesNonessentialLaunchSideEffects: suppressesNonessential
        )
    }

    private func completionEvent(text: String) -> AttentionNotificationEvent {
        AttentionNotificationEvent(
            key: .turnCompleted(sessionID: UUID(), attemptID: UUID()),
            workspaceName: "Workspace",
            sessionName: "Root",
            content: .turnCompleted(finalAssistantText: text)
        )
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

/// Real settings file store whose saves can be made to fail.
private final class SwitchableSettingsFileStore: GlobalSettingsFileStoring {
    let base: GlobalSettingsFileStore
    var failSaves = false

    init(base: GlobalSettingsFileStore) {
        self.base = base
    }

    var fileURL: URL {
        base.fileURL
    }

    var blockReason: GlobalSettingsPersistenceBlockReason? {
        base.blockReason
    }

    func load() throws -> GlobalSettingsDocument {
        try base.load()
    }

    func loadOrCreateDefault() -> GlobalSettingsDocument {
        base.loadOrCreateDefault()
    }

    func save(_ document: GlobalSettingsDocument) throws {
        if failSaves {
            throw CocoaError(.fileWriteNoPermission)
        }
        try base.save(document)
    }

    func performUserInitiatedRecovery(replacementDocument: GlobalSettingsDocument) -> Bool {
        base.performUserInitiatedRecovery(replacementDocument: replacementDocument)
    }

    func performUserInitiatedCompatibleImport() -> Bool {
        base.performUserInitiatedCompatibleImport()
    }
}

@MainActor
private final class FactoryCounter {
    var calls = 0
}

@MainActor
private final class IdleCounter {
    var value: TimeInterval?
    private(set) var reads = 0

    init(value: TimeInterval?) {
        self.value = value
    }

    func read() -> TimeInterval? {
        reads += 1
        return value
    }
}

/// Pre-admission fence: passes straight through unless `holds`; `onPass` runs right before the
/// synchronous admission.
@MainActor
private final class ServiceAdmissionFence {
    var holds = false
    var onPass: (() -> Void)?
    private(set) var pauseCount = 0
    private var paused: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        pauseCount += 1
        if holds {
            await withCheckedContinuation { paused.append($0) }
        }
        onPass?()
    }

    func release() {
        holds = false
        paused.forEach { $0.resume() }
        paused.removeAll()
    }
}
