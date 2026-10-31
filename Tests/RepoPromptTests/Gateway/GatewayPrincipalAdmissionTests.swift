@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

#if DEBUG
    final class GatewayPrincipalAdmissionTests: XCTestCase {
        func testLaunchScopedCredentialMarksGatewayPrincipal() async {
            let manager = ServerNetworkManager.shared
            await manager.debugSetGatewayLaunchCredentialForTesting("launch-secret")

            let principal = await manager.debugGatewayPrincipalDecisionForTesting(
                gatewayCredential: "launch-secret"
            )

            XCTAssertEqual(principal, .gateway)
            await manager.debugSetGatewayLaunchCredentialForTesting(nil)
        }

        func testClientNameClaimAloneDoesNotMarkGatewayPrincipal() async {
            let manager = ServerNetworkManager.shared
            await manager.debugSetGatewayLaunchCredentialForTesting("launch-secret")

            let principalFromMissingCredential = await manager.debugGatewayPrincipalDecisionForTesting(
                gatewayCredential: nil
            )
            XCTAssertEqual(principalFromMissingCredential, .standard)

            let forgedConnectionID = UUID()
            await manager.debugInstallIdentityContextForTesting(
                connectionID: forgedConnectionID,
                clientName: "repoprompt-gateway",
                principal: .standard
            )

            let storedPrincipal = await manager.debugConnectionPrincipalForTesting(forgedConnectionID)
            let isGateway = await manager.isGatewayPrincipalConnection(forgedConnectionID)
            XCTAssertEqual(storedPrincipal, .standard)
            XCTAssertFalse(isGateway)
            await manager.debugSetGatewayLaunchCredentialForTesting(nil)
        }

        func testInvalidGatewayCredentialIsRejectedByAdmissionDecision() async {
            let manager = ServerNetworkManager.shared
            await manager.debugSetGatewayLaunchCredentialForTesting("launch-secret")

            let principal = await manager.debugGatewayPrincipalDecisionForTesting(
                gatewayCredential: "wrong-secret"
            )

            XCTAssertNil(principal)
            await manager.debugSetGatewayLaunchCredentialForTesting(nil)
        }

        // MARK: - Plan 2026-10-30 Step 1: verified paired-device identity

        /// Only a `.gateway`-principal connection whose bootstrap name is a per-device app link
        /// (`remote:<device8>`) carries a device identity into request routing.
        func testGatewayPrincipalPerDeviceLinkCarriesRemoteDeviceIntoRequestRouting() async {
            let manager = ServerNetworkManager.shared
            let deviceConnectionID = UUID()
            await manager.debugInstallIdentityContextForTesting(
                connectionID: deviceConnectionID,
                clientName: "remote:1a2b3c4d",
                principal: .gateway
            )
            let deviceID = await manager.gatewayRemoteDeviceID(for: deviceConnectionID)
            let routing = await manager.requestRoutingContext(for: deviceConnectionID)
            XCTAssertEqual(deviceID, "remote:1a2b3c4d")
            XCTAssertEqual(routing.gatewayRemoteDeviceID, "remote:1a2b3c4d")

            let defaultLinkID = UUID()
            await manager.debugInstallIdentityContextForTesting(
                connectionID: defaultLinkID,
                clientName: "repoprompt-gateway",
                principal: .gateway
            )
            let defaultLinkDevice = await manager.gatewayRemoteDeviceID(for: defaultLinkID)
            XCTAssertNil(defaultLinkDevice)
            let unknownConnectionDevice = await manager.gatewayRemoteDeviceID(for: UUID())
            XCTAssertNil(unknownConnectionDevice)
        }

        func testRemoteDeviceNameWithoutGatewayPrincipalCarriesNoDeviceIdentity() async {
            let manager = ServerNetworkManager.shared
            let forgedConnectionID = UUID()
            await manager.debugInstallIdentityContextForTesting(
                connectionID: forgedConnectionID,
                clientName: "remote:1a2b3c4d",
                principal: .standard
            )
            let deviceID = await manager.gatewayRemoteDeviceID(for: forgedConnectionID)
            let routing = await manager.requestRoutingContext(for: forgedConnectionID)
            XCTAssertNil(deviceID)
            XCTAssertNil(routing.gatewayRemoteDeviceID)
        }

        func testGatewayRemoteDeviceNameGrammar() {
            func device(_ name: String?, _ principal: MCPConnectionPrincipal = .gateway) -> String? {
                ServerNetworkManager.gatewayRemoteDeviceID(bootstrapClientName: name, principal: principal)
            }
            XCTAssertEqual(device("remote:1a2b3c4d"), "remote:1a2b3c4d")
            XCTAssertEqual(device("  remote:1a2b3c4d\n"), "remote:1a2b3c4d")
            XCTAssertNil(device("remote:1a2b3c4d", .standard))
            XCTAssertNil(device("remote:"))
            XCTAssertNil(device("remote:1a2b 3c4d"))
            XCTAssertNil(device("repoprompt-gateway"))
            XCTAssertNil(device("Remote:1a2b3c4d"))
            XCTAssertNil(device(nil))
        }

        // MARK: - M4 connection-approval routing

        /// Pairing consent is the authorization event: a gateway-principal-carried
        /// `remote:<device8>` link auto-admits with no per-connection approval prompt,
        /// on connect and on reconnect alike.
        func testGatewayCarriedRemoteDeviceLinkAutoAdmitsWithoutPrompt() async {
            for _ in 0 ..< 2 { // connect, then reconnect
                let route = await ServerController.connectionApprovalRoute(
                    clientName: "remote:1a2b3c4d",
                    autoApproveAllClients: false,
                    isGatewayPrincipal: true,
                    isVerifiedBundledRepoPromptCLI: {
                        XCTFail("Gateway principal must not reach CLI verification")
                        return false
                    },
                    isAllowListed: {
                        XCTFail("Gateway principal must not consult the allow-list")
                        return false
                    }
                )
                XCTAssertEqual(route, .autoApproveGatewayPrincipal)
            }
        }

        func testRemoteDeviceNameWithoutGatewayPrincipalStillPrompts() async {
            let route = await ServerController.connectionApprovalRoute(
                clientName: "remote:1a2b3c4d",
                autoApproveAllClients: false,
                isGatewayPrincipal: false,
                isVerifiedBundledRepoPromptCLI: { false },
                isAllowListed: { false }
            )
            XCTAssertEqual(route, .promptUser)
        }

        func testApprovalRouteOrderingContract() async {
            // Global auto-approve wins over everything.
            let globalRoute = await ServerController.connectionApprovalRoute(
                clientName: "remote:1a2b3c4d",
                autoApproveAllClients: true,
                isGatewayPrincipal: true,
                isVerifiedBundledRepoPromptCLI: { false },
                isAllowListed: { false }
            )
            XCTAssertEqual(globalRoute, .autoApproveAllClients)

            // RepoPrompt CLI names require executable verification and never use the allow-list.
            let unverifiedCLIRoute = await ServerController.connectionApprovalRoute(
                clientName: "RepoPrompt CLI",
                autoApproveAllClients: false,
                isGatewayPrincipal: false,
                isVerifiedBundledRepoPromptCLI: { false },
                isAllowListed: {
                    XCTFail("RepoPrompt CLI names must not consult the allow-list")
                    return true
                }
            )
            XCTAssertEqual(unverifiedCLIRoute, .promptUserUnverifiedRepoPromptCLI)

            let verifiedCLIRoute = await ServerController.connectionApprovalRoute(
                clientName: "RepoPrompt CLI",
                autoApproveAllClients: false,
                isGatewayPrincipal: false,
                isVerifiedBundledRepoPromptCLI: { true },
                isAllowListed: { false }
            )
            XCTAssertEqual(verifiedCLIRoute, .autoApproveVerifiedRepoPromptCLI)

            // Allow-listed non-CLI clients auto-approve; unknown clients prompt.
            let allowListedRoute = await ServerController.connectionApprovalRoute(
                clientName: "some-agent",
                autoApproveAllClients: false,
                isGatewayPrincipal: false,
                isVerifiedBundledRepoPromptCLI: { false },
                isAllowListed: { true }
            )
            XCTAssertEqual(allowListedRoute, .autoApproveAllowListed)
        }
    }
#endif
