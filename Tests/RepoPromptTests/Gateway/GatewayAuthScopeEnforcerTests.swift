@testable import RepoPromptGateway
import XCTest

final class GatewayAuthScopeEnforcerTests: XCTestCase {
    private let allScopes: Set<String> = [
        GatewayRemoteScope.sessionsObserve,
        GatewayRemoteScope.sessionsOperate,
        GatewayRemoteScope.interactionsRespond,
        GatewayRemoteScope.workspaceRead
    ]

    /// Exhaustive frame-type → required-scope matrix from the M4 plan scope table.
    private let scopeTable: [(frameType: String, requiredScope: String)] = [
        ("subscribe", GatewayRemoteScope.sessionsObserve),
        ("unsubscribe", GatewayRemoteScope.sessionsObserve),
        ("poll", GatewayRemoteScope.sessionsObserve),
        ("list_agents", GatewayRemoteScope.sessionsObserve),
        ("list_sessions", GatewayRemoteScope.sessionsObserve),
        // Read-only open-workspace discovery for the browser chooser.
        ("list_workspaces", GatewayRemoteScope.sessionsObserve),
        ("get_log", GatewayRemoteScope.sessionsObserve),
        ("extract_handoff", GatewayRemoteScope.sessionsObserve),
        // M5: Web Push wake registration is observation-adjacent.
        ("push_subscribe", GatewayRemoteScope.sessionsObserve),
        ("push_unsubscribe", GatewayRemoteScope.sessionsObserve),
        ("start", GatewayRemoteScope.sessionsOperate),
        ("steer", GatewayRemoteScope.sessionsOperate),
        ("cancel", GatewayRemoteScope.sessionsOperate),
        ("open_workspace", GatewayRemoteScope.sessionsOperate),
        ("fork_session", GatewayRemoteScope.sessionsOperate),
        ("respond", GatewayRemoteScope.interactionsRespond)
    ]

    func testEveryScopedOperationRequiresExactlyItsScope() {
        for (frameType, requiredScope) in scopeTable {
            XCTAssertEqual(
                ScopeEnforcer.requiredScope(forFrameType: frameType),
                requiredScope,
                "requiredScope(\(frameType))"
            )

            // Granting exactly the required scope allows the operation.
            XCTAssertEqual(
                ScopeEnforcer.decision(frameType: frameType, grantedScopes: [requiredScope]),
                .allowed,
                "\(frameType) with its own scope"
            )

            // Granting every OTHER scope must still deny with the required scope named.
            let otherScopes = allScopes.subtracting([requiredScope])
            XCTAssertEqual(
                ScopeEnforcer.decision(frameType: frameType, grantedScopes: otherScopes),
                .denied(requiredScope: requiredScope),
                "\(frameType) without its scope"
            )

            // Empty grants deny.
            XCTAssertEqual(
                ScopeEnforcer.decision(frameType: frameType, grantedScopes: []),
                .denied(requiredScope: requiredScope),
                "\(frameType) with no scopes"
            )
        }
    }

    func testConnectionControlFramesRequireNoScope() {
        for frameType in ["hello", "ping"] {
            XCTAssertNil(ScopeEnforcer.requiredScope(forFrameType: frameType))
            XCTAssertEqual(
                ScopeEnforcer.decision(frameType: frameType, grantedScopes: []),
                .allowed,
                frameType
            )
        }
    }

    func testWorkspaceReadIsReservedAndGrantsNoCurrentOperation() {
        for (frameType, requiredScope) in scopeTable {
            XCTAssertEqual(
                ScopeEnforcer.decision(
                    frameType: frameType,
                    grantedScopes: [GatewayRemoteScope.workspaceRead]
                ),
                .denied(requiredScope: requiredScope),
                frameType
            )
        }
    }

    func testUnknownOperationIsNeverAllowed() {
        XCTAssertEqual(
            ScopeEnforcer.decision(frameType: "exec_shell", grantedScopes: allScopes),
            .unknownOperation
        )
        XCTAssertThrowsError(
            try ScopeEnforcer.validate(frameType: "exec_shell", grantedScopes: allScopes)
        )
    }

    func testValidateThrowsScopeEnforcementErrorWithCode() {
        do {
            try ScopeEnforcer.validate(frameType: "steer", grantedScopes: [GatewayRemoteScope.sessionsObserve])
            XCTFail("Expected insufficient scope error")
        } catch let error as ScopeEnforcementError {
            XCTAssertEqual(error.code, "insufficient_scope")
            XCTAssertEqual(error.requiredScope, GatewayRemoteScope.sessionsOperate)
            XCTAssertEqual(error.operation, "steer")
        } catch {
            XCTFail("Expected ScopeEnforcementError, got \(error)")
        }
    }

    func testScopeVocabularyMatchesAppRemoteScopeRawValues() {
        // Gateway string constants must stay aligned with the app's RemoteScope enum.
        XCTAssertEqual(GatewayRemoteScope.sessionsObserve, "sessions:observe")
        XCTAssertEqual(GatewayRemoteScope.sessionsOperate, "sessions:operate")
        XCTAssertEqual(GatewayRemoteScope.interactionsRespond, "interactions:respond")
        XCTAssertEqual(GatewayRemoteScope.workspaceRead, "workspace:read")
    }
}
