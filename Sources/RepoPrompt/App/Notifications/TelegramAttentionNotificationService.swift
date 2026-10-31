import Combine
import Foundation
import Observation
import RepoPromptAgentCore
import RepoPromptRemoteWire

// Executing-Mac Telegram configuration for attention notifications
// (docs/context/plans/2026-10-10-telegram-attention-notifications-contract.md, Slice 8).
//
// One app-wide service configures `AttentionNotificationAdmission.shared`: the enable flag and
// chat ID live in global settings JSON, the bot token only in secure storage. The shared
// instance is inert until guarded app launch calls `start(launch:)`; denied launches (UI tests,
// stress, hosted or direct XCTest) never create the secure-storage or HTTP dependencies. All
// sends, including Settings' Send test, go through the admission's single FIFO and one
// service-lifetime pacer. State and messages are sanitized enums and fixed text only.

/// Process facts that decide whether this launch may start Telegram notifications.
struct TelegramAttentionLaunchEnvironment {
    var arguments: [String]
    var environment: [String: String]
    var xctestLoaded: Bool
    var suppressesNonessentialLaunchSideEffects: Bool

    static func current(_ configuration: AppLaunchConfiguration) -> TelegramAttentionLaunchEnvironment {
        TelegramAttentionLaunchEnvironment(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            xctestLoaded: NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil,
            suppressesNonessentialLaunchSideEffects: configuration.suppressesNonessentialLaunchSideEffects
        )
    }

    /// False for UI-test, Agent chat stress, hosted XCTest, and direct XCTest launches.
    var allowsTelegramNotifications: Bool {
        guard !suppressesNonessentialLaunchSideEffects, !xctestLoaded else { return false }
        let deniedArgument = arguments.contains { argument in
            argument == "-RP_UITEST" || argument == "-RP_AGENT_CHAT_STRESS" || argument.hasPrefix("-XCTest")
        }
        return !deniedArgument
            && environment["XCTestConfigurationFilePath"] == nil
            && environment["XCInjectBundleInto"] == nil
    }
}

@MainActor
@Observable
final class TelegramAttentionNotificationService {
    struct Dependencies {
        let tokenStore: TelegramBotTokenStore
        let client: TelegramSendMessageClient

        /// Production secure storage and HTTP. Created only by an allowed `start(launch:)`.
        static func production() -> Dependencies {
            Dependencies(tokenStore: TelegramBotTokenStore(), client: TelegramSendMessageClient())
        }
    }

    enum TokenStatus: Equatable {
        case notLoaded
        case saved
        case missing
        case invalidStoredValue
        case unavailable

        var message: String {
            switch self {
            case .notLoaded: "Telegram notifications are not available in this launch."
            case .saved: "A bot token is saved in secure storage."
            case .missing: "No bot token is saved."
            case .invalidStoredValue: "The saved bot token is not valid. Save a new token."
            case .unavailable: "Secure storage is unavailable without approval, so the bot token cannot be used."
            }
        }
    }

    enum ActionResult: Equatable {
        case enabled
        case disabled
        /// Off now, but saving off failed: the saved setting is still on.
        case offNotSaved
        case chatIDSaved
        case invalidChatID
        case chatIDSaveFailed
        case tokenSaved
        case invalidToken
        case tokenSaveFailed
        case tokenRemoved
        case tokenRemovedOffNotSaved
        case tokenRemoveFailed
        case tokenRemoveFailedOffNotSaved
        case idleThresholdSaved
        case invalidIdleThreshold
        case settingsSaveFailed
        case notConfigured
        /// A failed configuration write suspended delivery until a later save succeeds.
        case deliverySuspended
        case unavailableInThisLaunch
        case testQueued
        case testAlreadyPending

        var message: String {
            switch self {
            case .enabled: "Automatic notifications are on."
            case .disabled: "Automatic notifications are off."
            case .offNotSaved: "Automatic notifications are off for this launch only. The off setting could not be saved, so they may resume next launch."
            case .chatIDSaved: "Chat ID saved."
            case .invalidChatID: "Enter a numeric chat ID or an @channel name. Nothing was changed."
            case .chatIDSaveFailed: "Could not save the chat ID. Telegram delivery is suspended until a configuration save succeeds."
            case .tokenSaved: "Bot token saved."
            case .invalidToken: "That is not a valid bot token. Nothing was changed."
            case .tokenSaveFailed: "Could not save the bot token. Telegram delivery is off for this launch; a previously saved token may be used next launch."
            case .tokenRemoved: "Bot token removed. Automatic notifications are off."
            case .tokenRemovedOffNotSaved: "Bot token removed. Automatic notifications are off for this launch only: the off setting could not be saved."
            case .tokenRemoveFailed: "Could not remove the bot token. Automatic notifications are off, and delivery is suspended until a token is saved."
            case .tokenRemoveFailedOffNotSaved: "Could not remove the bot token or save the off setting. Automatic notifications are off for this launch only and may resume next launch."
            case .idleThresholdSaved: "Idle setting saved."
            case .invalidIdleThreshold: "Enter whole minutes, 0 or more. Nothing was changed."
            case .settingsSaveFailed: "Could not save settings. The change was not applied."
            case .notConfigured: "Save a bot token and chat ID first."
            case .deliverySuspended: "Telegram delivery is suspended until a configuration save succeeds."
            case .unavailableInThisLaunch: "Telegram notifications are not available in this launch."
            case .testQueued: "Test message queued."
            case .testAlreadyPending: "A test message is already pending."
            }
        }
    }

    /// Fixed notes about the current state, shown in Settings.
    enum Notice: Hashable {
        /// The saved preference is on, but nothing can be delivered.
        case enabledButNotDelivering
        /// Off for this launch, but the saved preference is still on.
        case offNotSaved
        case temporaryTokenStorage

        var message: String {
            switch self {
            case .enabledButNotDelivering: "Automatic notifications are on but paused: nothing is sent until a bot token and chat ID are saved successfully."
            case .offNotSaved: "The saved automatic-notification setting is still on."
            case .temporaryTokenStorage: "Secure storage is temporary in this build: a saved token is lost when the app quits."
            }
        }
    }

    /// Fixed Settings hint while alerts carry no Open session button.
    static let sessionLinkUnavailableHint = "Alerts are text-only. To add an Open session button, turn on Remote Control and set its browser HTTPS port in Remote Control settings."

    /// App-wide instance: inert (no settings, storage, or HTTP access) until `start(launch:)`.
    static let shared = TelegramAttentionNotificationService()

    private(set) var isStarted = false
    /// The automatic-notification preference; admission is enabled only when also configured.
    private(set) var isEnabled = false
    private(set) var chatID: String?
    /// The adopted saved idle threshold for automatic notifications; 0 means always notify.
    private(set) var idleThresholdMinutes = GlobalScalarPreferences.TelegramSettings.defaultIdleThresholdMinutes
    private(set) var tokenStatus: TokenStatus = .notLoaded
    private(set) var storagePersistsAcrossLaunches = true
    /// A bot token and chat ID are configured and delivery is installed.
    private(set) var isDeliveryConfigured = false
    private(set) var lastAction: ActionResult?
    private(set) var lastTestKey: AttentionNotificationEventKey?
    /// The gateway's active browser origin as last observed (drives the Settings hint only;
    /// each delivery attempt reads the origin itself). nil means alerts are text-only.
    private(set) var activeBrowserOrigin: RemoteGatewayOrigin?

    @ObservationIgnored let admission: AttentionNotificationAdmission
    @ObservationIgnored private let settingsOverride: GlobalSettingsStore?
    @ObservationIgnored private let gatewayStatusOverride: RemoteGatewayStatusStore?
    @ObservationIgnored private var gatewayStatus: RemoteGatewayStatusStore?
    @ObservationIgnored private var gatewayStatusObservation: AnyCancellable?
    @ObservationIgnored private let pacer: TelegramAttentionPacer
    @ObservationIgnored private let makeDependencies: @MainActor () -> Dependencies
    @ObservationIgnored private var settings: GlobalSettingsStore?
    @ObservationIgnored private var dependencies: Dependencies?
    @ObservationIgnored private var token: TelegramBotToken?
    /// Set after a failed configuration write: delivery stays removed until a later successful
    /// configuration change, so earlier credentials are never silently reused.
    @ObservationIgnored private var deliverySuspended = false
    /// The settings values this service last read or wrote, to tell reloads from its own writes.
    /// `observedEnabled` stays observable: it drives `offIsUnsaved`.
    private var observedEnabled = false
    @ObservationIgnored private var observedChatID: String?
    /// The settings idle-policy revision adopted with `idleThresholdMinutes`.
    @ObservationIgnored private var observedIdlePolicyRevision: UInt64 = 0
    @ObservationIgnored private var settingsObservation: AnyCancellable?

    init(
        admission: AttentionNotificationAdmission? = nil,
        settings: GlobalSettingsStore? = nil,
        gatewayStatus: RemoteGatewayStatusStore? = nil,
        pacer: TelegramAttentionPacer = TelegramAttentionPacer(),
        makeDependencies: @escaping @MainActor () -> Dependencies = { Dependencies.production() }
    ) {
        self.admission = admission ?? .shared
        settingsOverride = settings
        gatewayStatusOverride = gatewayStatus
        self.pacer = pacer
        self.makeDependencies = makeDependencies
    }

    /// Automatic notifications will actually be admitted.
    var automaticNotificationsActive: Bool {
        isEnabled && isDeliveryConfigured
    }

    /// Off in this launch while the saved preference is still on (a failed off save). Retry with
    /// `setEnabled(false)`.
    var offIsUnsaved: Bool {
        isStarted && !isEnabled && observedEnabled
    }

    var notices: [Notice] {
        guard isStarted else { return [] }
        var notices: [Notice] = []
        if isEnabled, !isDeliveryConfigured {
            notices.append(.enabledButNotDelivering)
        }
        if offIsUnsaved {
            notices.append(.offNotSaved)
        }
        if !storagePersistsAcrossLaunches {
            notices.append(.temporaryTokenStorage)
        }
        return notices
    }

    /// Shown in Settings while alerts would be sent without an Open session button.
    var sessionLinkHint: String? {
        isStarted && activeBrowserOrigin == nil ? Self.sessionLinkUnavailableHint : nil
    }

    var isTestPending: Bool {
        lastTestKey.map { admission.pendingEventKeys.contains($0) } ?? false
    }

    var lastTestRecord: AttentionNotificationAdmission.Record? {
        lastTestKey.flatMap { admission.records[$0] }
    }

    // MARK: - Startup

    /// Loads the configuration once, only when `launch` allows it. The guard runs before any
    /// settings, secure-storage, or HTTP dependency is touched.
    func start(launch: TelegramAttentionLaunchEnvironment) {
        guard !isStarted, launch.allowsTelegramNotifications else { return }
        isStarted = true
        let dependencies = makeDependencies()
        self.dependencies = dependencies
        let settings = settingsOverride ?? .shared
        self.settings = settings
        let gatewayStatus = gatewayStatusOverride ?? .shared
        self.gatewayStatus = gatewayStatus
        activeBrowserOrigin = gatewayStatus.activeBrowserOrigin
        storagePersistsAcrossLaunches = dependencies.tokenStore.persistsAcrossLaunches
        observedEnabled = settings.telegramNotificationsEnabled()
        observedChatID = settings.telegramChatID()
        isEnabled = observedEnabled
        chatID = observedChatID
        adoptSavedIdlePolicy()
        switch dependencies.tokenStore.read() {
        case let .token(stored):
            token = stored
            tokenStatus = .saved
        case .missing:
            tokenStatus = .missing
        case .invalidStoredValue:
            tokenStatus = .invalidStoredValue
        case .unavailable:
            tokenStatus = .unavailable
        }
        installDelivery()
        // Settings reload, recovery, and import replace values in place; adopt their result.
        settingsObservation = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileWithSettings() }
            }
        // Hint only: the origin is link metadata and never reinstalls delivery, so a gateway
        // refresh, restart, or loss cannot invalidate queued alerts. The published value is the
        // new origin (delivered before the property is updated).
        gatewayStatusObservation = gatewayStatus.$activeBrowserOrigin
            .dropFirst()
            .sink { [weak self] origin in
                MainActor.assumeIsolated { self?.activeBrowserOrigin = origin }
            }
    }

    // MARK: - Settings actions

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let settings else { return finish(.unavailableInThisLaunch, false) }
        if !enabled {
            // Off takes effect at once, even if saving fails; the saved value stays observed as
            // on, so only a later successful save or an external change updates it.
            isEnabled = false
            applyEnablement()
            guard settings.setTelegramNotificationsEnabled(false) else { return finish(.offNotSaved, false) }
            observedEnabled = false
            return finish(.disabled, true)
        }
        guard isDeliveryConfigured else { return finish(notConfiguredResult, false) }
        guard settings.setTelegramNotificationsEnabled(true) else { return finish(.settingsSaveFailed, false) }
        observedEnabled = true
        isEnabled = true
        applyEnablement()
        return finish(.enabled, true)
    }

    @discardableResult
    func saveChatID(_ draft: String) -> Bool {
        guard let settings else { return finish(.unavailableInThisLaunch, false) }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TelegramChatID(trimmed) != nil else { return finish(.invalidChatID, false) }
        invalidateDelivery()
        guard settings.setTelegramChatID(trimmed) else {
            deliverySuspended = true
            return finish(.chatIDSaveFailed, false)
        }
        observedChatID = settings.telegramChatID()
        chatID = observedChatID
        deliverySuspended = false
        installDelivery()
        return finish(.chatIDSaved, true)
    }

    /// Saves the automatic-notification idle threshold in whole minutes (0 = always notify).
    /// Changes only the automatic idle policy: the sender, pacer, token, and pending manual
    /// tests are untouched; pending automatic events are not sent under the old policy.
    @discardableResult
    func saveIdleThresholdMinutes(_ draft: String) -> Bool {
        guard let settings else { return finish(.unavailableInThisLaunch, false) }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ Self.asciiDigits.contains($0) }),
              let minutes = Int(trimmed)
        else { return finish(.invalidIdleThreshold, false) }
        guard settings.setTelegramIdleThresholdMinutes(minutes) else { return finish(.settingsSaveFailed, false) }
        adoptSavedIdlePolicy()
        return finish(.idleThresholdSaved, true)
    }

    /// Saves a new bot token. A blank or invalid draft changes nothing.
    @discardableResult
    func saveToken(_ draft: String) -> Bool {
        guard let dependencies else { return finish(.unavailableInThisLaunch, false) }
        guard let newToken = TelegramBotToken(draft) else { return finish(.invalidToken, false) }
        invalidateDelivery()
        token = nil
        guard dependencies.tokenStore.save(newToken) == .succeeded else {
            tokenStatus = .unavailable
            deliverySuspended = true
            return finish(.tokenSaveFailed, false)
        }
        token = newToken
        tokenStatus = .saved
        deliverySuspended = false
        installDelivery()
        return finish(.tokenSaved, true)
    }

    /// Removes the saved bot token and turns automatic notifications off. Delivery and the
    /// runtime enable flag are off before either write; off is saved whether or not the delete
    /// succeeds, and the result reports both writes.
    @discardableResult
    func removeToken() -> Bool {
        guard let dependencies, let settings else { return finish(.unavailableInThisLaunch, false) }
        invalidateDelivery()
        token = nil
        isEnabled = false
        applyEnablement()
        let deleted = dependencies.tokenStore.delete() == .succeeded
        if deleted {
            tokenStatus = .missing
            deliverySuspended = false
            installDelivery()
        } else {
            tokenStatus = .unavailable
            deliverySuspended = true
        }
        let offSaved = !settings.telegramNotificationsEnabled() || settings.setTelegramNotificationsEnabled(false)
        if offSaved {
            observedEnabled = false
        }
        let result: ActionResult = switch (deleted, offSaved) {
        case (true, true): .tokenRemoved
        case (true, false): .tokenRemovedOffNotSaved
        case (false, true): .tokenRemoveFailed
        case (false, false): .tokenRemoveFailedOffNotSaved
        }
        return finish(result, deleted && offSaved)
    }

    /// Queues the fixed test message through the shared admission queue. Works while automatic
    /// notifications are off; never sends directly.
    @discardableResult
    func sendTest() -> Bool {
        guard isStarted else { return finish(.unavailableInThisLaunch, false) }
        guard !isTestPending else { return finish(.testAlreadyPending, false) }
        guard isDeliveryConfigured else { return finish(notConfiguredResult, false) }
        lastTestKey = admission.submitManualTest { [weak self] in
            guard let self else { return false }
            return isStarted && isDeliveryConfigured
        }
        return finish(.testQueued, true)
    }

    // MARK: - Fixed result text

    static func message(for record: AttentionNotificationAdmission.Record) -> String {
        switch record {
        case .admitted: "Sending…"
        case let .delivered(outcome): message(for: outcome)
        case let .suppressed(reason): message(for: reason)
        }
    }

    static func message(for outcome: AttentionNotificationDeliveryOutcome) -> String {
        switch outcome {
        case .sent: "Sent."
        case .failed: "Not sent: Telegram or the network rejected the message. It was not retried."
        case .unknown: "Delivery unknown: Telegram did not confirm the message. It was not retried."
        }
    }

    static func message(for suppression: AttentionNotificationSuppression) -> String {
        switch suppression {
        case .disabled: "Not sent: automatic notifications were off."
        case .enableChanged: "Not sent: automatic notification settings (on/off or idle) changed before sending."
        case .configurationChanged: "Not sent: notification settings changed before sending."
        case .ineligibleSession: "Not sent: the session was not a root session you drive."
        case .successorTookOver: "Not sent: a follow-up continued the session."
        case .eventNoLongerCurrent: "Not sent: the turn or question was no longer current."
        case .userActive: "Not sent: you were using this Mac."
        }
    }

    // MARK: - Private

    private static let asciiDigits: ClosedRange<Unicode.Scalar> = "0" ... "9"

    private var notConfiguredResult: ActionResult {
        deliverySuspended ? .deliverySuspended : .notConfigured
    }

    private func finish(_ result: ActionResult, _ succeeded: Bool) -> Bool {
        lastAction = result
        return succeeded
    }

    private func invalidateDelivery() {
        admission.setDeliveryConfiguration(nil)
        isDeliveryConfigured = false
        applyEnablement()
    }

    /// Installs one immutable sender for the current token and chat ID (or none). Every call
    /// starts a new configuration generation, so events captured earlier never use it. Final
    /// admission also re-reads the saved chat ID (and, for automatic events, the saved enable
    /// flag and idle policy), so a reload not yet reconciled by the asynchronous observer
    /// cannot send through this sender or under an idle policy it has not adopted.
    private func installDelivery() {
        var delivery: TelegramPacedAttentionDelivery?
        if !deliverySuspended, let dependencies, let token, let chat = chatID.flatMap(TelegramChatID.init) {
            let gatewayStatus = gatewayStatus
            delivery = TelegramPacedAttentionDelivery(
                token: token,
                chatID: chat,
                client: dependencies.client,
                pacer: pacer,
                browserOrigin: { await gatewayStatus?.activeBrowserOrigin }
            )
        }
        let installedChatID = chatID
        admission.setDeliveryConfiguration(delivery) { [weak self] policy in
            guard let self, let settings, settings.telegramChatID() == installedChatID else { return false }
            return policy == .manualTest || (settings.telegramNotificationsEnabled() && savedIdlePolicyIsAdopted(settings))
        }
        isDeliveryConfigured = delivery != nil
        applyEnablement()
    }

    private func applyEnablement() {
        admission.setEnabled(automaticNotificationsActive)
    }

    /// The saved idle threshold and its revision equal the adopted pair (a change and revert not
    /// yet observed differs by revision).
    private func savedIdlePolicyIsAdopted(_ settings: GlobalSettingsStore) -> Bool {
        settings.telegramIdleThresholdMinutes() == idleThresholdMinutes
            && settings.telegramIdlePolicyRevision == observedIdlePolicyRevision
    }

    /// Adopts the saved idle threshold and revision into this service and the admission. No-op
    /// when unchanged.
    private func adoptSavedIdlePolicy() {
        guard let settings, !savedIdlePolicyIsAdopted(settings) else { return }
        idleThresholdMinutes = settings.telegramIdleThresholdMinutes()
        observedIdlePolicyRevision = settings.telegramIdlePolicyRevision
        admission.setIdlePolicy(minutes: idleThresholdMinutes, sourceRevision: observedIdlePolicyRevision)
    }

    /// Adopts settings values replaced outside this service (reload, recovery, import). Values
    /// restored after this service's own failed write match what it last observed and are ignored.
    private func reconcileWithSettings() {
        guard let settings else { return }
        let savedChatID = settings.telegramChatID()
        if savedChatID != observedChatID {
            observedChatID = savedChatID
            chatID = savedChatID
            deliverySuspended = false
            installDelivery()
        }
        let savedEnabled = settings.telegramNotificationsEnabled()
        if savedEnabled != observedEnabled {
            observedEnabled = savedEnabled
            isEnabled = savedEnabled
            applyEnablement()
        }
        adoptSavedIdlePolicy()
    }
}
