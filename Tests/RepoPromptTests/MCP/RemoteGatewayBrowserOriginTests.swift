import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptGateway
@testable import RepoPromptPlatform
import RepoPromptRemoteWire
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Browser HTTPS origin for the paired phone remote: the optional port setting, origin
/// derivation from Tailscale's Self DNS name, the Serve command, the gateway status publication,
/// and the launch configuration. Temporary settings files and fixture JSON only; no Tailscale CLI,
/// gateway process, or app lifecycle.
@MainActor
final class RemoteGatewayBrowserOriginTests: XCTestCase {
    func testBrowserHTTPSPortIsOptionalPersistedAndRejects443AndOutOfRange() throws {
        let old = try JSONDecoder().decode(
            GlobalScalarPreferences.self,
            from: Data(#"{"mcp":{"remoteGatewayEnabled":true}}"#.utf8)
        )
        XCTAssertNil(old.mcp?.remoteGatewayBrowserHTTPSPort, "Existing settings decode with the port unset")

        let fixture = try makeSettings()
        XCTAssertNil(fixture.settings.mcpRemoteGatewayBrowserHTTPSPort(), "Unset by default")
        XCTAssertEqual(GlobalScalarPreferences.MCPSettings.suggestedBrowserHTTPSPort, 8443)

        XCTAssertTrue(fixture.settings.setMCPRemoteGatewayBrowserHTTPSPort(8443))
        XCTAssertEqual(fixture.settings.mcpRemoteGatewayBrowserHTTPSPort(), 8443)
        let reloaded = GlobalSettingsStore(defaults: fixture.defaults, fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL))
        XCTAssertEqual(reloaded.mcpRemoteGatewayBrowserHTTPSPort(), 8443)
        XCTAssertEqual(
            try GlobalSettingsFileStore(fileURL: fixture.fileURL).load().scalarPreferences?.mcp?.remoteGatewayBrowserHTTPSPort,
            8443
        )

        for invalid in [443, 0, -1, 65536] {
            XCTAssertFalse(GlobalScalarPreferences.MCPSettings.isValidBrowserHTTPSPort(invalid), "\(invalid)")
            XCTAssertFalse(fixture.settings.setMCPRemoteGatewayBrowserHTTPSPort(invalid), "\(invalid) is rejected")
            XCTAssertEqual(fixture.settings.mcpRemoteGatewayBrowserHTTPSPort(), 8443, "\(invalid) leaves the saved port")
        }
        XCTAssertEqual(
            try GlobalSettingsFileStore(fileURL: fixture.fileURL).load().scalarPreferences?.mcp?.remoteGatewayBrowserHTTPSPort,
            8443,
            "Rejected values are not written"
        )
        XCTAssertTrue(fixture.settings.setMCPRemoteGatewayBrowserHTTPSPort(9443))
        XCTAssertTrue(fixture.settings.setMCPRemoteGatewayBrowserHTTPSPort(nil))
        XCTAssertNil(fixture.settings.mcpRemoteGatewayBrowserHTTPSPort())

        let edited = try JSONDecoder().decode(
            GlobalScalarPreferences.self,
            from: Data(#"{"mcp":{"remoteGatewayBrowserHTTPSPort":443}}"#.utf8)
        )
        XCTAssertEqual(edited.mcp?.remoteGatewayBrowserHTTPSPort, 443, "A hand-edited 443 decodes")
        XCTAssertFalse(GlobalScalarPreferences.MCPSettings.isValidBrowserHTTPSPort(443), "but is read as unset")
    }

    /// Review S3-03: the setter reports a failed save and restores the previous value, so Save
    /// Port reports success and relaunches only after a durable write.
    func testFailedSaveReportsFailureAndKeepsThePreviousPort() throws {
        let fixture = try makeSettings(failableSaves: true)
        XCTAssertTrue(fixture.settings.setMCPRemoteGatewayBrowserHTTPSPort(8443))

        fixture.fileStore?.failSaves = true
        XCTAssertFalse(fixture.settings.setMCPRemoteGatewayBrowserHTTPSPort(9443))
        XCTAssertEqual(fixture.settings.mcpRemoteGatewayBrowserHTTPSPort(), 8443, "In memory: restored")
        XCTAssertFalse(fixture.settings.setMCPRemoteGatewayBrowserHTTPSPort(nil))
        XCTAssertEqual(fixture.settings.mcpRemoteGatewayBrowserHTTPSPort(), 8443)
        XCTAssertEqual(
            try GlobalSettingsFileStore(fileURL: fixture.fileURL).load().scalarPreferences?.mcp?.remoteGatewayBrowserHTTPSPort,
            8443,
            "On disk: unchanged"
        )

        fixture.fileStore?.failSaves = false
        XCTAssertTrue(fixture.settings.setMCPRemoteGatewayBrowserHTTPSPort(9443))
        XCTAssertEqual(fixture.settings.mcpRemoteGatewayBrowserHTTPSPort(), 9443)
    }

    /// Review S3-05: the production chain (Tailscale status, then `selfDNSName`, then `derive`)
    /// yields exactly what the gateway's launch parser accepts, and it becomes the extra Host
    /// authority.
    func testDerivedBrowserOriginRoundTripsThroughGatewayConfiguration() throws {
        let snapshot = try TailscaleStatusClient.decode(Data(#"""
        {"BackendState":"Running","Self":{"ID":"self","DNSName":"Mac.Example-Tailnet.ts.net.","TailscaleIPs":["100.64.0.8"]}}
        """#.utf8))
        let origin = try XCTUnwrap(
            RemoteGatewayBrowserOrigin.derive(selfDNSName: snapshot.selfDNSName, port: 8443)
        )
        let configuration = try GatewayConfiguration.parse(
            arguments: [],
            environment: [GatewayConfiguration.EnvironmentKey.browserOrigin: origin.string]
        )
        XCTAssertEqual(configuration.browserOriginAuthority, "mac.example-tailnet.ts.net:8443")
        let unset = try GatewayConfiguration.parse(
            arguments: [],
            environment: [GatewayConfiguration.EnvironmentKey.browserOrigin: ""]
        )
        XCTAssertNil(unset.browserOriginAuthority, "The launch always sets the key; empty means unset")
    }

    func testOriginDerivesFromSelfDNSNameAndPortOnly() throws {
        let snapshot = try TailscaleStatusClient.decode(Data(#"""
        {"BackendState":"Running","Self":{"ID":"self","HostName":"Mac","DNSName":"Mac.Example-Tailnet.ts.net.","TailscaleIPs":["100.64.0.8","fd7a::1"]}}
        """#.utf8))
        XCTAssertEqual(snapshot.selfDNSName, "mac.example-tailnet.ts.net")
        let withoutDNS = try TailscaleStatusClient.decode(Data(#"""
        {"BackendState":"Running","Self":{"ID":"self","DNSName":"","TailscaleIPs":["100.64.0.8"]}}
        """#.utf8))
        XCTAssertNil(withoutDNS.selfDNSName)

        XCTAssertEqual(
            RemoteGatewayBrowserOrigin.derive(selfDNSName: snapshot.selfDNSName, port: 8443)?.string,
            "https://mac.example-tailnet.ts.net:8443"
        )
        XCTAssertNil(RemoteGatewayBrowserOrigin.derive(selfDNSName: snapshot.selfDNSName, port: nil), "Unset port")
        XCTAssertNil(RemoteGatewayBrowserOrigin.derive(selfDNSName: snapshot.selfDNSName, port: 443))
        XCTAssertNil(RemoteGatewayBrowserOrigin.derive(selfDNSName: nil, port: 8443), "No MagicDNS name")
        XCTAssertNil(RemoteGatewayBrowserOrigin.derive(selfDNSName: "bad host/name", port: 8443))
    }

    func testServeCommandTargetsThisBuildsDirectGatewayOrigin() throws {
        let debugOrigin = try RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.8", channel: .debug)
        let releaseOrigin = try RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.8", channel: .release)
        XCTAssertEqual(
            RemoteGatewayBrowserOrigin.serveCommand(browserPort: 8443, gatewayOrigin: debugOrigin),
            "tailscale serve --bg --https=8443 http://100.64.0.8:47392"
        )
        XCTAssertEqual(
            RemoteGatewayBrowserOrigin.serveCommand(browserPort: 8443, gatewayOrigin: releaseOrigin),
            "tailscale serve --bg --https=8443 http://100.64.0.8:47391"
        )
    }

    func testStatusPublishesBrowserOriginAndActiveOnlyWhileDiscoverable() throws {
        let store = RemoteGatewayStatusStore()
        let gatewayOrigin = try RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.8", channel: .debug)
        let browserOrigin = try RemoteGatewayOrigin(string: "https://mac.example.ts.net:8443")

        store.publish(.starting(gatewayOrigin), browserOrigin: browserOrigin, generation: 1)
        XCTAssertEqual(store.browserOrigin, browserOrigin)
        XCTAssertNil(store.activeBrowserOrigin)
        store.publish(.discoverable(gatewayOrigin), browserOrigin: browserOrigin, generation: 1)
        XCTAssertEqual(store.activeBrowserOrigin, browserOrigin)
        store.publish(.discoverable(gatewayOrigin), browserOrigin: nil, generation: 1)
        XCTAssertNil(store.activeBrowserOrigin, "Port unset")
        store.publish(.discoverable(gatewayOrigin), browserOrigin: browserOrigin, generation: 1)
        for inactive: RemoteGatewayStatusStore.Status in [.disabled, .resolvingTailscale, .unavailable("x"), .failed("y")] {
            store.publish(inactive, browserOrigin: browserOrigin, generation: 1)
            XCTAssertNil(store.browserOrigin, "\(inactive)")
            XCTAssertNil(store.activeBrowserOrigin, "\(inactive)")
        }
    }

    /// Review S3-02: publications are fenced by activation-gate generation, and a stop withdraws
    /// the link without claiming Remote Control was turned off.
    func testPublicationIsGenerationFencedAndStopWithdrawsTheLink() throws {
        let store = RemoteGatewayStatusStore()
        let gatewayOrigin = try RemoteGatewayOrigin(tailscaleIPv4: "100.64.0.8", channel: .debug)
        let browserOrigin = try RemoteGatewayOrigin(string: "https://mac.example.ts.net:8443")

        XCTAssertTrue(store.publishStop(.stopped(reason: "Stopped."), generation: 1))
        XCTAssertEqual(store.status, .disabled, "Never enabled: stays disabled")

        XCTAssertTrue(store.publish(.discoverable(gatewayOrigin), browserOrigin: browserOrigin, generation: 3))
        XCTAssertFalse(store.publish(.failed("late"), generation: 2), "Older generation")
        XCTAssertEqual(store.status, .discoverable(gatewayOrigin))
        XCTAssertEqual(store.activeBrowserOrigin, browserOrigin)

        XCTAssertTrue(store.publishStop(.stopped(reason: "Stopped."), generation: 4))
        XCTAssertEqual(store.status, .unavailable("Stopped."))
        XCTAssertNil(store.activeBrowserOrigin)
        XCTAssertFalse(store.publish(.discoverable(gatewayOrigin), browserOrigin: browserOrigin, generation: 3))
        XCTAssertNil(store.activeBrowserOrigin, "A superseded apply cannot re-advertise the link")

        XCTAssertTrue(store.publish(.discoverable(gatewayOrigin), browserOrigin: browserOrigin, generation: 5))
        XCTAssertTrue(store.publishStop(.disabled, generation: 6))
        XCTAssertEqual(store.status, .disabled)
        XCTAssertNil(store.activeBrowserOrigin)
    }

    func testLaunchConfigurationCarriesBrowserOriginSoAChangeRelaunches() throws {
        let identity = RemoteControlBuildIdentity.forTesting(channel: .debug)
        let browserOrigin = try RemoteGatewayOrigin(string: "https://mac.example.ts.net:8443")
        let unset = RemoteGatewayLaunchConfiguration.production(bindHost: "100.64.0.8", buildIdentity: identity)
        let linked = RemoteGatewayLaunchConfiguration.production(
            bindHost: "100.64.0.8",
            browserOrigin: browserOrigin,
            buildIdentity: identity
        )
        XCTAssertNil(unset.browserOrigin)
        XCTAssertEqual(linked.browserOrigin, browserOrigin)
        XCTAssertEqual(linked.port, identity.fixedPort)
        XCTAssertNotEqual(unset, linked, "startIfNeeded reuses a process only for an equal configuration")
    }

    // MARK: - Helpers

    private struct SettingsFixture {
        let settings: GlobalSettingsStore
        let defaults: UserDefaults
        let fileURL: URL
        let fileStore: FailableSettingsFileStore?
    }

    private func makeSettings(failableSaves: Bool = false) throws -> SettingsFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteGatewayBrowserOriginTests-\(UUID().uuidString)")
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        let suiteName = "RemoteGatewayBrowserOriginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let base = GlobalSettingsFileStore(fileURL: fileURL)
        let failable = failableSaves ? FailableSettingsFileStore(base: base) : nil
        let settings = GlobalSettingsStore(defaults: defaults, fileStore: failable ?? base)
        return SettingsFixture(settings: settings, defaults: defaults, fileURL: fileURL, fileStore: failable)
    }
}

/// The settings file-store seam with switchable save failures.
private final class FailableSettingsFileStore: GlobalSettingsFileStoring {
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
