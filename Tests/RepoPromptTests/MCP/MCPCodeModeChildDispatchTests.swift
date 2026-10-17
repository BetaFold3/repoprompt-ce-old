import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Plan §6 D3 Step 4 seam: in-process `code_mode` children re-enter the connection's registered
/// `tools/call` closure with a non-wire origin, a fresh typed sink, child-only ingress rules,
/// released (never acknowledged) delegated-question notices, and no automatic selection.
final class MCPCodeModeChildDispatchTests: XCTestCase {
    private static let noticeKey = AgentDelegatedQuestionNoticeWire.resultKey

    // MARK: - Sink

    func testSinkCapturesOnceCompletesOnceAndEmptyObjectIsACapturedValue() {
        let sink = MCPInProcessToolResultSink()
        guard case .success = sink.capture(.object([:])) else { return XCTFail("first capture") }
        guard case .failure(.alreadyCaptured) = sink.capture(.object(["late": .bool(true)])) else {
            return XCTFail("A second capture must never overwrite")
        }
        let returned = CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
        guard case let .success(envelope) = sink.complete(with: returned) else { return XCTFail("complete") }
        XCTAssertEqual(envelope.value, .object([:]))
        XCTAssertEqual(envelope.result.isError, false)
        guard case .failure(.alreadyClosed) = sink.complete(with: returned) else { return XCTFail("second complete") }
        guard case .failure(.alreadyClosed) = sink.capture(.null) else { return XCTFail("capture after complete") }
    }

    func testAbandonedSinkReleasesItsCaptureAndRejectsCompletion() {
        let sink = MCPInProcessToolResultSink()
        _ = sink.capture(.object(["ok": .bool(true)]))
        sink.abandon()
        sink.abandon()
        let returned = CallTool.Result.err("boom")
        guard case .failure(.alreadyClosed) = sink.complete(with: returned) else {
            return XCTFail("An abandoned sink never completes")
        }
    }

    // MARK: - Child ingress

    func testChildIngressAdmitsOnlyTheFourClassifiedExplorationTools() {
        for toolName in MCPCodeModeChildIngress.allowedToolNames {
            XCTAssertNil(
                MCPCodeModeChildIngress.denial(
                    canonicalToolName: toolName,
                    admissionClass: ServerNetworkManager.admissionClass(forCanonicalToolName: toolName),
                    arguments: ["path": .string("a")]
                ),
                toolName
            )
        }
        for toolName in [
            MCPWindowToolName.applyEdits, MCPWindowToolName.git, MCPWindowToolName.manageSelection,
            MCPWindowToolName.agentRun, "code_mode", "unknown_tool"
        ] {
            XCTAssertEqual(
                MCPCodeModeChildIngress.denial(
                    canonicalToolName: toolName,
                    admissionClass: ServerNetworkManager.admissionClass(forCanonicalToolName: toolName),
                    arguments: nil
                )?.code,
                "code_mode_child_tool_not_allowed",
                toolName
            )
        }
        // Classification fails closed: an allowed name with a missing or different class is denied.
        for admissionClass: MCPToolAdmissionClass? in [nil, .control, .exclusive, .gitRead] {
            XCTAssertEqual(
                MCPCodeModeChildIngress.denial(
                    canonicalToolName: MCPWindowToolName.readFile,
                    admissionClass: admissionClass,
                    arguments: nil
                )?.code,
                "code_mode_child_admission_not_allowed"
            )
        }
    }

    func testChildIngressRejectsEveryRoutingOverrideIncludingExplicitNull() {
        for key in ["context_id", "_tabID", "_windowID", "window_id"] {
            for value: Value in [.string(UUID().uuidString), .int(1), .null] {
                XCTAssertEqual(
                    MCPCodeModeChildIngress.denial(
                        canonicalToolName: MCPWindowToolName.readFile,
                        admissionClass: .smallRead,
                        arguments: ["path": .string("a"), key: value]
                    )?.code,
                    "code_mode_child_routing_override",
                    "\(key)=\(value)"
                )
            }
        }
    }

    /// Normalization records routing-key presence in every form it unwraps, whatever the value,
    /// while its payload and extraction behaviour stay unchanged for transport callers.
    func testNormalizerRecordsRoutingKeyPresenceThroughWrappedAndJSONStringForms() {
        func normalize(_ params: [String: Value]) -> NormalizedArgs {
            MCPToolArgsNormalizer.normalize(
                params: params,
                originalToolName: MCPWindowToolName.readFile,
                canonicalToolName: MCPWindowToolName.readFile
            )
        }
        let nestedNull = normalize(["args": .object(["path": .string("a"), "_windowID": .null])])
        XCTAssertEqual(nestedNull.encounteredRoutingKeys, ["_windowID"])
        XCTAssertNil(nestedNull.windowID)
        XCTAssertEqual(nestedNull.payload, ["path": .string("a")])

        let jsonString = normalize(["payload": .string(#"{"path":"a","window_id":2,"context_id":"nope"}"#)])
        XCTAssertEqual(jsonString.encounteredRoutingKeys, ["window_id", "context_id"])
        XCTAssertEqual(jsonString.payload["window_id"], .int(2))

        let wrapped = normalize([MCPWindowToolName.readFile: .object(["path": .string("a"), "_tabID": .string("x")])])
        XCTAssertEqual(wrapped.encounteredRoutingKeys, ["_tabID"])

        XCTAssertEqual(normalize(["path": .string("a")]).encounteredRoutingKeys, [])
    }

    // MARK: - Notices at the final handoff

    func testChildHandoffReleasesNoticesWithoutSettlingAndCapturesTheSanitizedValue() async {
        let attached = Self.valueWithNotice()
        let (transaction, recorder) = Self.transactionWithNoticeParticipant()
        let sink = MCPInProcessToolResultSink()

        let value = await ServerNetworkManager.finalHandoffValue(
            attached,
            delivery: transaction,
            origin: .codeModeChild(parentInvocationID: UUID()),
            sink: sink
        )

        XCTAssertEqual(value, .object(["ok": .bool(true)]))
        XCTAssertEqual(recorder.events, ["abandon"], "A child never settles (acknowledges) a notice")
        guard case let .success(envelope) = sink.complete(with: CallTool.Result.err("unused")) else {
            return XCTFail("complete")
        }
        XCTAssertEqual(envelope.value, value)
        // Neither child text nor structured content carries the notice, whatever D1 says.
        for structured in [false, true] {
            let result = ServerNetworkManager.makeToolResult(
                toolName: MCPWindowToolName.readFile, args: [:], value: value, structured: structured
            )
            XCTAssertNil(result.structuredContent?.objectValue?[Self.noticeKey])
            XCTAssertFalse(Self.texts(result).contains { $0.contains("delegated child question") })
        }
        // An unregistered reserved field (not owned by a participant) is still stripped.
        let stray = await ServerNetworkManager.finalHandoffValue(
            attached,
            delivery: MCPToolResultDeliveryTransaction(),
            origin: .codeModeChild(parentInvocationID: UUID()),
            sink: nil
        )
        XCTAssertEqual(stray, .object(["ok": .bool(true)]))
    }

    func testTransportHandoffStillSettlesOnceAndDeliversTheNoticeInTextAndStructuredContent() async {
        let attached = Self.valueWithNotice()
        let (transaction, recorder) = Self.transactionWithNoticeParticipant()

        let value = await ServerNetworkManager.finalHandoffValue(
            attached,
            delivery: transaction,
            origin: .transport,
            sink: nil
        )
        transaction.abandon()

        XCTAssertEqual(value, attached)
        XCTAssertEqual(recorder.events, ["settle(true)"], "Ordinary delivery settles exactly once")
        let result = ServerNetworkManager.makeToolResult(
            toolName: MCPWindowToolName.readFile, args: [:], value: value, structured: true
        )
        XCTAssertNotNil(result.structuredContent?.objectValue?[Self.noticeKey])
        XCTAssertEqual(Self.texts(result).last, "notice text")
    }

    // MARK: - Re-entry

    func testUnknownConnectionFailsAsConnectionUnavailableWithoutAValue() async throws {
        let child = try await ServerNetworkManager.shared.invokeCodeModeChild(
            connectionID: UUID(),
            parentInvocationID: UUID(),
            params: CallTool.Parameters(name: MCPWindowToolName.readFile, arguments: ["path": .string("a")])
        )
        XCTAssertNil(child.value)
        XCTAssertEqual(child.result.isError, true)
        XCTAssertTrue(Self.texts(child.result).joined().contains("tool_execution_connection_terminal"))
    }

    #if DEBUG
        @MainActor
        func testChildReentersTheRegisteredHandlerCapturesTheProviderValueAndNeverAutoSelects() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let context = fixture.contextA
                do {
                    let clientName = "code-mode-child-\(UUID().uuidString)"
                    await manager.installClientConnectionPolicy(
                        for: clientName,
                        windowID: context.window.windowID,
                        restrictedTools: [],
                        tabID: context.tabID,
                        runID: UUID(),
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let endpoint = try await fixture.makeAdditionalEndpoint(
                        label: "code-mode-child",
                        clientName: clientName,
                        requiredToolNames: [MCPWindowToolName.readFile, MCPWindowToolName.manageSelection]
                    )
                    let connectionID = endpoint.connectionID
                    let registered = await manager.debugHasRegisteredToolCallHandler(connectionID: connectionID)
                    XCTAssertTrue(registered)
                    _ = try await endpoint.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "clear"])

                    func child(_ name: String, _ arguments: [String: Value]) async throws -> MCPInProcessToolResult {
                        try await manager.invokeCodeModeChild(
                            connectionID: connectionID,
                            parentInvocationID: UUID(),
                            params: CallTool.Parameters(name: name, arguments: arguments)
                        )
                    }

                    // Concurrent children get their own sinks and their own provider values.
                    async let whole = child(MCPWindowToolName.readFile, ["path": .string(context.fileURL.path)])
                    async let firstLine = child(
                        MCPWindowToolName.readFile,
                        ["path": .string(context.fileURL.path), "start_line": .int(1), "limit": .int(1)]
                    )
                    let (wholeResult, firstLineResult) = try await (whole, firstLine)
                    for result in [wholeResult, firstLineResult] {
                        XCTAssertEqual(result.result.isError, false, Self.texts(result.result).joined())
                        let object = try XCTUnwrap(result.value?.objectValue)
                        XCTAssertNil(object[Self.noticeKey])
                        // Default-off D1: the typed capture does not depend on structuredContent.
                        XCTAssertNil(result.result.structuredContent)
                    }
                    let wholeContent = try XCTUnwrap(wholeResult.value?.objectValue?["content"]?.stringValue)
                    XCTAssertTrue(wholeContent.contains(context.sentinel), wholeContent)
                    XCTAssertNotEqual(wholeResult.value, firstLineResult.value)

                    // Child reads never enqueue automatic selection.
                    let afterChild = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection, arguments: ["op": "get", "view": "files"]
                    )
                    let afterChildText = try Self.endpointText(afterChild)
                    XCTAssertFalse(afterChildText.contains(context.fileURL.lastPathComponent), afterChildText)

                    // Control: the same read over the wire still auto-selects.
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.readFile, arguments: ["path": context.fileURL.path]
                    )
                    let afterDirect = try await endpoint.callTool(
                        name: MCPWindowToolName.manageSelection, arguments: ["op": "get", "view": "files"]
                    )
                    let afterDirectText = try Self.endpointText(afterDirect)
                    XCTAssertTrue(afterDirectText.contains(context.fileURL.lastPathComponent), afterDirectText)

                    // The remaining allowlisted tools capture their provider values too.
                    for (name, arguments) in [
                        (MCPWindowToolName.search, ["pattern": Value.string(context.sentinel), "mode": .string("content")]),
                        (MCPWindowToolName.getFileTree, ["type": Value.string("roots")]),
                        (
                            MCPWindowToolName.getCodeStructure,
                            ["scope": Value.string("paths"), "paths": .array([.string(context.fileURL.path)])]
                        )
                    ] {
                        let captured = try await child(name, arguments)
                        XCTAssertEqual(captured.result.isError, false, "\(name): \(Self.texts(captured.result).joined())")
                        let object = try XCTUnwrap(captured.value?.objectValue, name)
                        XCTAssertNil(object[Self.noticeKey], name)
                    }

                    // Child searches never enqueue automatic selection; the same search over the wire does.
                    // (Search auto-selection applies only to content mode with context_lines > 1.)
                    _ = try await endpoint.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "clear"])
                    let childSearch = try await child(
                        MCPWindowToolName.search,
                        ["pattern": .string(context.sentinel), "mode": .string("content"), "context_lines": .int(2)]
                    )
                    XCTAssertEqual(childSearch.result.isError, false, Self.texts(childSearch.result).joined())
                    let afterChildSearchText = try await Self.endpointText(
                        endpoint.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "get", "view": "files"])
                    )
                    XCTAssertFalse(
                        afterChildSearchText.contains(context.fileURL.lastPathComponent), afterChildSearchText
                    )
                    _ = try await endpoint.callTool(
                        name: MCPWindowToolName.search,
                        arguments: ["pattern": context.sentinel, "mode": "content", "context_lines": 2]
                    )
                    let afterDirectSearchText = try await Self.endpointText(
                        endpoint.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "get", "view": "files"])
                    )
                    XCTAssertTrue(
                        afterDirectSearchText.contains(context.fileURL.lastPathComponent), afterDirectSearchText
                    )

                    // Child-only ingress denials return the handler's error result and no value,
                    // including wrapped, nested, JSON-string, invalid, and explicit-null routing forms.
                    let path = Value.string(context.fileURL.path)
                    let tabString = Value.string(context.tabID.uuidString)
                    let jsonStringPayload = try String(
                        decoding: JSONSerialization.data(
                            withJSONObject: ["path": context.fileURL.path, "_tabID": context.tabID.uuidString]
                        ),
                        as: UTF8.self
                    )
                    let routing = "code_mode_child_routing_override"
                    let notAllowed = "code_mode_child_tool_not_allowed"
                    for (label, name, arguments, code) in [
                        ("top context_id", MCPWindowToolName.readFile, ["path": path, "context_id": tabString], routing),
                        ("top null _windowID", MCPWindowToolName.readFile, ["path": path, "_windowID": .null], routing),
                        ("top window_id", MCPWindowToolName.readFile, ["path": path, "window_id": .int(context.window.windowID)], routing),
                        ("args null _windowID", MCPWindowToolName.readFile, ["args": .object(["path": path, "_windowID": .null])], routing),
                        ("args invalid _windowID", MCPWindowToolName.readFile, ["args": .object(["path": path, "_windowID": .string("not-a-window")])], routing),
                        ("args _windowID", MCPWindowToolName.readFile, ["args": .object(["path": path, "_windowID": .int(context.window.windowID)])], routing),
                        ("args window_id", MCPWindowToolName.readFile, ["args": .object(["path": path, "window_id": .int(context.window.windowID)])], routing),
                        ("args invalid context_id", MCPWindowToolName.readFile, ["args": .object(["path": path, "context_id": .string("nope")])], routing),
                        ("args JSON-string _tabID", MCPWindowToolName.readFile, ["args": .string(jsonStringPayload)], routing),
                        ("JSON-string payload _tabID", MCPWindowToolName.readFile, ["payload": .string(jsonStringPayload)], routing),
                        ("tool-name wrapper context_id", MCPWindowToolName.readFile, [MCPWindowToolName.readFile: .object(["path": path, "context_id": tabString])], routing),
                        ("not allowlisted", MCPWindowToolName.manageSelection, ["op": Value.string("clear")], notAllowed),
                        ("unknown tool", "not_a_tool", [:], notAllowed)
                    ] {
                        let denied = try await child(name, arguments)
                        let text = Self.texts(denied.result).joined()
                        XCTAssertNil(denied.value, label)
                        XCTAssertEqual(denied.result.isError, true, label)
                        XCTAssertTrue(
                            text.contains(code == routing ? "may not override routing" : "not available inside code_mode"),
                            "\(label): \(text)"
                        )
                    }

                    // A connection's own policy still binds its children: D1 pinned on at registration
                    // and a restricted allowlisted tool.
                    let restrictedClientName = "code-mode-child-restricted-\(UUID().uuidString)"
                    await manager.installClientConnectionPolicy(
                        for: restrictedClientName,
                        windowID: context.window.windowID,
                        restrictedTools: [MCPWindowToolName.getFileTree],
                        tabID: context.tabID,
                        runID: UUID(),
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let settings = GlobalSettingsStore.shared
                    let previousStructuredResults = settings.mcpStructuredResultsMode()
                    settings.setMCPStructuredResultsMode(.on, commit: false)
                    let restrictedEndpoint: PersistentMCPTestEndpoint
                    do {
                        defer { settings.setMCPStructuredResultsMode(previousStructuredResults, commit: false) }
                        restrictedEndpoint = try await fixture.makeAdditionalEndpoint(
                            label: "code-mode-child-restricted",
                            clientName: restrictedClientName,
                            requiredToolNames: [MCPWindowToolName.readFile]
                        )
                    }
                    func restrictedChild(_ name: String, _ arguments: [String: Value]) async throws -> MCPInProcessToolResult {
                        try await manager.invokeCodeModeChild(
                            connectionID: restrictedEndpoint.connectionID,
                            parentInvocationID: UUID(),
                            params: CallTool.Parameters(name: name, arguments: arguments)
                        )
                    }
                    let structuredRead = try await restrictedChild(MCPWindowToolName.readFile, ["path": path])
                    XCTAssertEqual(structuredRead.result.isError, false, Self.texts(structuredRead.result).joined())
                    let structuredValue = try XCTUnwrap(structuredRead.value?.objectValue)
                    XCTAssertNil(structuredValue[Self.noticeKey])
                    let structuredContent = try XCTUnwrap(structuredRead.result.structuredContent?.objectValue)
                    XCTAssertNil(structuredContent[Self.noticeKey])
                    XCTAssertEqual(structuredValue["content"], structuredContent["content"])
                    let restricted = try await restrictedChild(MCPWindowToolName.getFileTree, ["type": .string("roots")])
                    XCTAssertNil(restricted.value)
                    XCTAssertEqual(restricted.result.isError, true)
                    XCTAssertTrue(
                        Self.texts(restricted.result).joined().contains(
                            ServerNetworkManager.restrictedToolDenialMessage(forCanonicalToolName: MCPWindowToolName.getFileTree)
                        ),
                        Self.texts(restricted.result).joined()
                    )
                    // A provider error is returned as the handler's error result, with no value.
                    let missing = try await child(
                        MCPWindowToolName.readFile,
                        ["path": .string(context.rootURL.appendingPathComponent("Missing.swift").path)]
                    )
                    XCTAssertNil(missing.value)

                    // Publication/re-entry fence: only the live lifecycle generation is admitted.
                    let observedGeneration = await manager.debugConnectionLifecycleGeneration(connectionID: connectionID)
                    let liveGeneration = try XCTUnwrap(observedGeneration)
                    let liveAdmitted = await manager.debugIsToolCallReentryLive(
                        connectionID: connectionID, lifecycleGeneration: liveGeneration
                    )
                    let staleAdmitted = await manager.debugIsToolCallReentryLive(
                        connectionID: connectionID, lifecycleGeneration: liveGeneration &+ 1
                    )
                    let unknownAdmitted = await manager.debugIsToolCallReentryLive(
                        connectionID: connectionID, lifecycleGeneration: nil
                    )
                    XCTAssertTrue(liveAdmitted)
                    XCTAssertFalse(staleAdmitted)
                    XCTAssertFalse(unknownAdmitted)

                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                    // Teardown removed the handle; re-entry fails closed and never picks another connection.
                    let unregistered = await manager.debugHasRegisteredToolCallHandler(connectionID: connectionID)
                    XCTAssertFalse(unregistered)
                    // A registration resuming after teardown completed publishes nothing.
                    let latePublished = await manager.debugPublishLateRegisteredToolCallHandlerForTesting(
                        connectionID: connectionID, expectedLifecycleGeneration: liveGeneration
                    )
                    XCTAssertFalse(latePublished)
                    let lateRegistered = await manager.debugHasRegisteredToolCallHandler(connectionID: connectionID)
                    XCTAssertFalse(lateRegistered)
                    let afterTeardown = try await child(MCPWindowToolName.readFile, ["path": .string(context.fileURL.path)])
                    XCTAssertNil(afterTeardown.value)
                    XCTAssertTrue(Self.texts(afterTeardown.result).joined().contains("tool_execution_connection_terminal"))
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }
    #endif

    // MARK: - Eligibility

    @MainActor
    func testLeaseEligibilityDefaultsNativeAndKnowledgeAndDiscoveryNormalizeToNative() {
        func agentMode(_ profile: AgentSessionProfile, _ eligibility: MCPCodeModeEligibility?) -> MCPBootstrapLeaseSpec {
            if let eligibility {
                return MCPBootstrapLeaseSpec.agentMode(
                    tabID: UUID(), runID: UUID(), gateID: UUID(), windowID: 1, agent: .claudeCode,
                    sessionProfile: profile, codeModeEligibility: eligibility
                )
            }
            return MCPBootstrapLeaseSpec.agentMode(
                tabID: UUID(), runID: UUID(), gateID: UUID(), windowID: 1, agent: .claudeCode,
                sessionProfile: profile
            )
        }
        let companion = MCPCodeModeEligibility.codexReadOnlyCompanion(serverName: "RepoPrompt-Direct")
        XCTAssertEqual(agentMode(.standard, nil).codeModeEligibility, .native)
        XCTAssertEqual(agentMode(.standard, .directTools).codeModeEligibility, .directTools)
        XCTAssertEqual(agentMode(.standard, companion).codeModeEligibility, companion)
        XCTAssertEqual(agentMode(.knowledge, .directTools).codeModeEligibility, .native)
        XCTAssertEqual(agentMode(.knowledge, companion).codeModeEligibility, .native)

        let headless = MCPBootstrapLeaseSpec.headless(
            runID: UUID(), gateID: UUID(), clientName: "discovery", windowID: 1, restrictedTools: [],
            ttl: 30, purpose: .discoverRun
        )
        XCTAssertEqual(headless.codeModeEligibility, .native)
        for purpose in [MCPRunPurpose.discoverRun, .unknown] {
            let spec = MCPBootstrapLeaseSpec(
                runID: UUID(), gateID: UUID(), windowID: 1, tabID: nil, clientName: "c",
                restrictedTools: [], additionalTools: nil, oneShot: true, reason: nil, ttl: 30,
                purpose: purpose, taskLabelKind: nil, allowsAgentExternalControlTools: false,
                requiresExpectedAgentPID: false, codeModeEligibility: .directTools
            )
            XCTAssertEqual(spec.codeModeEligibility, .native, purpose.rawValue)
        }
    }

    // MARK: - Helpers

    private static func valueWithNotice() -> Value {
        .object([
            "ok": .bool(true),
            noticeKey: .array([.object(["kind": .string("delegated_question"), "text": .string("notice text")])])
        ])
    }

    private static func transactionWithNoticeParticipant() -> (MCPToolResultDeliveryTransaction, Recorder) {
        let transaction = MCPToolResultDeliveryTransaction()
        let recorder = Recorder()
        transaction.register(
            unannotate: { value in
                guard case var .object(object) = value else { return value }
                object.removeValue(forKey: noticeKey)
                return .object(object)
            },
            settle: { value, handOff in
                recorder.append("settle(\(handOff))")
                return value
            },
            abandon: { recorder.append("abandon") }
        )
        return (transaction, recorder)
    }

    private static func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { block in
            if case let .text(text, _, _) = block { return text }
            return nil
        }
    }

    #if DEBUG
        /// Joined text blocks of a successful wire `tools/call` response.
        private static func endpointText(_ response: PersistentMCPTestRPCResponse) throws -> String {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(response.rawJSON.utf8)) as? [String: Any]
            )
            let result = try XCTUnwrap(object["result"] as? [String: Any], response.rawJSON)
            XCTAssertNotEqual(result["isError"] as? Bool, true, response.rawJSON)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]], response.rawJSON)
            return content.compactMap { $0["text"] as? String }.joined()
        }
    #endif

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ event: String) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
