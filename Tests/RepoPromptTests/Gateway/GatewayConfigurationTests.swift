import Foundation
@testable import RepoPromptGateway
import RepoPromptShared
import XCTest

final class GatewayConfigurationTests: XCTestCase {
    func testLoopbackDefaultIsSecurityDefault() throws {
        let config = try GatewayConfiguration.parse(arguments: [], environment: [:])
        XCTAssertEqual(config.bindHost, "127.0.0.1")
        XCTAssertEqual(config.port, GatewayConfiguration.defaultPort)
        XCTAssertFalse(config.allowWildcardBind)
    }

    func testArgumentsOverrideEnvironment() throws {
        let config = try GatewayConfiguration.parse(
            arguments: [
                "--bind-host", "127.0.0.2",
                "--port=45678",
                "--static-token", "arg-token",
                "--bootstrap-token", "arg-bootstrap"
            ],
            environment: [
                GatewayConfiguration.EnvironmentKey.bindHost: "127.0.0.9",
                GatewayConfiguration.EnvironmentKey.port: "12345",
                GatewayConfiguration.EnvironmentKey.staticToken: "env-token",
                GatewayConfiguration.EnvironmentKey.bootstrapToken: "env-bootstrap"
            ]
        )

        XCTAssertEqual(config.bindHost, "127.0.0.2")
        XCTAssertEqual(config.port, 45678)
        XCTAssertEqual(config.staticToken, "arg-token")
        XCTAssertEqual(config.bootstrapToken, "arg-bootstrap")
    }

    func testEnvironmentAppliesWhenArgumentsAreAbsent() throws {
        let config = try GatewayConfiguration.parse(
            arguments: [],
            environment: [
                GatewayConfiguration.EnvironmentKey.bindHost: "127.0.0.3",
                GatewayConfiguration.EnvironmentKey.port: "34567",
                GatewayConfiguration.EnvironmentKey.staticToken: "env-token",
                GatewayConfiguration.EnvironmentKey.allowWildcardBind: "false"
            ]
        )

        XCTAssertEqual(config.bindHost, "127.0.0.3")
        XCTAssertEqual(config.port, 34567)
        XCTAssertEqual(config.staticToken, "env-token")
        XCTAssertFalse(config.allowWildcardBind)
    }

    func testWildcardBindIsRejectedWithoutExplicitOptIn() throws {
        XCTAssertThrowsError(try GatewayConfiguration.parse(
            arguments: ["--bind-host", "0.0.0.0"],
            environment: [:]
        )) { error in
            XCTAssertEqual(
                error as? GatewayConfigurationError,
                .wildcardBindRequiresExplicitOptIn("0.0.0.0")
            )
        }
    }

    func testWildcardBindCanBeExplicitlyEnabled() throws {
        let config = try GatewayConfiguration.parse(
            arguments: ["--bind-host", "0.0.0.0", "--allow-wildcard-bind"],
            environment: [:]
        )

        XCTAssertEqual(config.bindHost, "0.0.0.0")
        XCTAssertTrue(config.allowWildcardBind)
    }

    func testInvalidPortIsRejected() throws {
        XCTAssertThrowsError(try GatewayConfiguration.parse(
            arguments: ["--port", "70000"],
            environment: [:]
        )) { error in
            XCTAssertEqual(error as? GatewayConfigurationError, .invalidPort("70000"))
        }
    }

    func testParentPIDDefaultsLeasePathAndBoundedReconnectBudget() throws {
        let root = try GatewayTestHelpers.temporaryRoot("gateway-config-parent")
        defer { try? FileManager.default.removeItem(at: root) }

        let config = try GatewayConfiguration.parse(
            arguments: ["--app-support-root", root.path],
            environment: [GatewayConfiguration.EnvironmentKey.parentPID: "12345"]
        )

        XCTAssertEqual(config.parentPID, 12345)
        XCTAssertEqual(config.appLinkMaximumReconnectAttempts, 24)
        XCTAssertEqual(
            config.processLeaseFileURL.standardizedFileURL.path,
            RemoteGatewayProcessLeaseFile.defaultURL(appSupportRoot: root).standardizedFileURL.path
        )
    }

    func testProcessLeaseRoundTripsAndRemovesOnlyOwnedPID() throws {
        let root = try GatewayTestHelpers.temporaryRoot("gateway-process-lease")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = RemoteGatewayProcessLeaseFile.defaultURL(appSupportRoot: root)
        let lease = RemoteGatewayProcessLease(
            pid: 123,
            parentPID: 456,
            executablePath: "/tmp/repoprompt-gateway",
            bindHost: "127.0.0.1",
            port: 47391,
            appSupportRoot: root.path,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        try RemoteGatewayProcessLeaseFile.write(lease, to: fileURL)
        let decoded = try XCTUnwrap(RemoteGatewayProcessLeaseFile.read(from: fileURL))
        XCTAssertEqual(decoded, lease)
        XCTAssertTrue(decoded.matches(
            bindHost: "127.0.0.1",
            port: 47391,
            appSupportRoot: root.path,
            executablePath: "/tmp/repoprompt-gateway"
        ))

        RemoteGatewayProcessLeaseFile.removeIfOwned(fileURL: fileURL, pid: 999)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        RemoteGatewayProcessLeaseFile.removeIfOwned(fileURL: fileURL, pid: 123)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testStaticTokenAuthIsDisabledByDefaultAndRequiresExplicitDevOptIn() throws {
        // M4: a configured static token alone no longer authorizes remote WS hello.
        let withoutFlag = try GatewayConfiguration.parse(
            arguments: ["--static-token", "dev-token"],
            environment: [:]
        )
        XCTAssertFalse(withoutFlag.allowStaticTokenAuth)

        let viaArgument = try GatewayConfiguration.parse(
            arguments: ["--static-token", "dev-token", "--allow-static-token-auth"],
            environment: [:]
        )
        XCTAssertTrue(viaArgument.allowStaticTokenAuth)

        let viaEnvironment = try GatewayConfiguration.parse(
            arguments: [],
            environment: [GatewayConfiguration.EnvironmentKey.allowStaticTokenAuth: "true"]
        )
        XCTAssertTrue(viaEnvironment.allowStaticTokenAuth)
    }

    func testLegacyGatewayRejectsPasskeyPolicyVersionFlag() throws {
        // Remote passkey unlock, Step 2 (decision 8): the current gateway has no passkey policy
        // support, so it MUST reject `--passkey-policy-version` at config parse — before any
        // listener binds. That rejection is what makes the app's fail-closed launch guard work: an
        // incompatible gateway cannot serve a registry whose policy it can't enforce. A future
        // (Step 3) gateway will recognize and validate the flag instead.
        XCTAssertThrowsError(try GatewayConfiguration.parse(
            arguments: ["--passkey-policy-version=1"],
            environment: [:]
        )) { error in
            XCTAssertEqual(error as? GatewayConfigurationError, .unknownArgument("--passkey-policy-version"))
        }
    }

    func testBrowserOriginIsOptionalHTTPSWithExplicitPortAndBecomesTheExtraHostAuthority() throws {
        XCTAssertNil(try GatewayConfiguration.parse(arguments: [], environment: [:]).browserOriginAuthority)
        XCTAssertNil(
            try GatewayConfiguration.parse(
                arguments: [],
                environment: [GatewayConfiguration.EnvironmentKey.browserOrigin: ""]
            ).browserOriginAuthority,
            "The app passes an empty value when the port is unset"
        )

        let viaEnvironment = try GatewayConfiguration.parse(
            arguments: [],
            environment: [GatewayConfiguration.EnvironmentKey.browserOrigin: "https://Mac.Example.ts.net:8443"]
        )
        XCTAssertEqual(viaEnvironment.browserOriginAuthority, "mac.example.ts.net:8443")
        let viaArgument = try GatewayConfiguration.parse(
            arguments: ["--browser-origin", "https://mac.example.ts.net:9443/"],
            environment: [GatewayConfiguration.EnvironmentKey.browserOrigin: "https://other.example.ts.net:8443"]
        )
        XCTAssertEqual(viaArgument.browserOriginAuthority, "mac.example.ts.net:9443")

        for invalid in [
            "http://mac.example.ts.net:8443",
            "https://mac.example.ts.net",
            "https://mac.example.ts.net:8443/path",
            "https://mac.example.ts.net:8443/?q=1",
            "https://user@mac.example.ts.net:8443",
            "not a url"
        ] {
            XCTAssertThrowsError(
                try GatewayConfiguration.parse(arguments: ["--browser-origin", invalid], environment: [:]),
                invalid
            ) { error in
                XCTAssertEqual(error as? GatewayConfigurationError, .invalidBrowserOrigin(invalid), invalid)
            }
        }
    }
}
