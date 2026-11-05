import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
import RepoPromptShared
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Plan §6 D3 app integration: the registered `code_mode` parent tool, its fail-fast script cap,
/// owner-exit lease lifetime, retained partial results, authoritative error status, and wire
/// projection, exercised both directly and through a real connection's registered handler.
final class MCPCodeModeToolIntegrationTests: XCTestCase {
    private static let noticeKey = AgentDelegatedQuestionNoticeWire.resultKey

    // MARK: - Catalog and policy

    func testCodeModeCatalogEntryHasItsContractAdmissionClassAndRestrictions() {
        XCTAssertEqual(
            Array(MCPWindowToolGroup.orderedToolNames.suffix(2)),
            [MCPWindowToolName.codeMode, MCPWindowToolName.presentRich]
        )
        XCTAssertEqual(
            MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.codeMode),
            .bounded(deadline: .seconds(62), cancellationGrace: MCPTimeoutPolicy.boundedToolCancellationCleanupGrace)
        )
        // The parent never holds a read slot while its children run.
        XCTAssertEqual(MCPToolAdmissionPolicy.classification(forCanonicalToolName: MCPWindowToolName.codeMode), .control)
        XCTAssertTrue(DiscoverMCPToolPolicy.restrictedTools.contains(MCPWindowToolName.codeMode))
        XCTAssertTrue(AgentDelegatedQuestionNoticeWire.isEligible(toolName: MCPWindowToolName.codeMode))
        XCTAssertTrue(MCPIntegrationHelper.repoPromptToolNames.contains(MCPWindowToolName.codeMode))
        XCTAssertEqual(
            MCPCodeModeChildIngress.allowedToolNames,
            [MCPWindowToolName.readFile, MCPWindowToolName.search, MCPWindowToolName.getCodeStructure, MCPWindowToolName.getFileTree]
        )
        XCTAssertFalse(MCPCodeModeChildIngress.allowedToolNames.contains(MCPWindowToolName.codeMode))
        XCTAssertEqual(MCPToolOutputSchemas.schemasByToolName[MCPWindowToolName.codeMode], MCPToolOutputSchemas.codeMode)
    }

    @MainActor
    func testRegisteredToolAcceptsOnlyAScriptAndDescribesTheContract() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.codeMode })
        XCTAssertEqual(tool.outputSchema, MCPToolOutputSchemas.codeMode)
        XCTAssertEqual(tool.annotations.readOnlyHint, true)
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue)
        XCTAssertEqual(schema["properties"]?.objectValue.map { Set($0.keys) }, ["script"])
        XCTAssertEqual(schema["required"], .array([.string("script")]))
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        for fragment in [
            MCPCodeModeExecutor.descriptionNotes, "{data, isError: false}", "allowError", "Promise.all", "`Intl`",
            "text(...)", "32 KiB", "28 KiB", "4 KiB", "tools.read_file", "tools.file_search",
            "tools.get_code_structure", "tools.get_file_tree", "code_mode cannot be routed",
            "rejected on the code_mode call and inside the script", "call `bind_context` before code_mode"
        ] {
            XCTAssertTrue(tool.description.contains(fragment), fragment)
        }
    }

    // MARK: - Script cap

    func testScriptAdmissionIsAtomicFailFastPerConnectionAndPerWindow() throws {
        let admission = MCPCodeModeScriptAdmission()
        let first = UUID()
        let second = UUID()
        let lease = try XCTUnwrap(admission.tryAcquire(connectionID: first, windowID: 1))
        XCTAssertNil(admission.tryAcquire(connectionID: first, windowID: 2), "One script per connection")
        XCTAssertNil(admission.tryAcquire(connectionID: second, windowID: 1), "One script per window")
        let other = try XCTUnwrap(admission.tryAcquire(connectionID: second, windowID: 2))
        XCTAssertTrue(admission.isHeld(connectionID: first))
        XCTAssertTrue(admission.isHeld(windowID: 1))

        XCTAssertTrue(lease.release())
        XCTAssertFalse(lease.release(), "Release is idempotent")
        XCTAssertFalse(admission.isHeld(connectionID: first))
        XCTAssertFalse(admission.isHeld(windowID: 1))
        XCTAssertTrue(admission.isHeld(connectionID: second, windowID: 2))

        // A stale lease never frees a newer holder of the same slots.
        let newer = try XCTUnwrap(admission.tryAcquire(connectionID: first, windowID: 1))
        XCTAssertFalse(lease.release())
        XCTAssertTrue(admission.isHeld(connectionID: first))
        newer.release()
        other.release()

        // Concurrent attempts on one window: exactly one wins; nothing queues.
        let lock = NSLock()
        var winners: [MCPCodeModeScriptAdmission.Lease] = []
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if let acquired = admission.tryAcquire(connectionID: UUID(), windowID: 9) {
                lock.withLock { winners.append(acquired) }
            }
        }
        XCTAssertEqual(winners.count, 1)
        winners.forEach { $0.release() }
        XCTAssertFalse(admission.isHeld(windowID: 9))
    }

    // MARK: - Retention

    func testRetentionAbandonsAnUnstartedScriptAndWaitsForARunningOne() async throws {
        let unstarted = MCPCodeModeResultRetention()
        let abandoned = await unstarted.resolve()
        XCTAssertNil(abandoned)
        XCTAssertFalse(unstarted.begin(), "An abandoned invocation never starts late")

        let running = MCPCodeModeResultRetention()
        XCTAssertTrue(running.begin())
        XCTAssertFalse(running.begin())
        let waiter = Task { await running.resolve() }
        try await Task.sleep(for: .milliseconds(20))
        let final = Value.object(["status": .string("cancelled")])
        running.finish(final)
        running.finish(.object(["status": .string("late")]))
        let waited = await waiter.value
        XCTAssertEqual(waited, final)
        let again = await running.resolve()
        XCTAssertEqual(again, final)
    }

    // MARK: - Parent bridge

    func testRunRejectsBadArgumentsAndBusyScriptsWithoutStartingOrHoldingALease() async throws {
        let admission = MCPCodeModeScriptAdmission()
        let connectionID = UUID()
        let invocationID = UUID()
        for arguments: [String: Value] in [
            [:],
            ["script": .int(1)],
            ["script": .string("return 1"), "context_id": .string("tab")]
        ] {
            do {
                _ = try await MCPCodeModeToolExecution.run(
                    arguments: arguments, windowID: 7, admission: admission, retention: nil,
                    connectionID: connectionID, parentInvocationID: invocationID
                )
                XCTFail("Expected invalid params for \(arguments)")
            } catch let error as MCPError {
                guard case .invalidParams = error else { return XCTFail("\(error)") }
            }
            XCTAssertFalse(admission.isHeld(connectionID: connectionID, windowID: 7))
        }

        do {
            _ = try await MCPCodeModeToolExecution.run(
                arguments: ["script": .string("return 1")], windowID: 7, admission: admission, retention: nil,
                connectionID: nil, parentInvocationID: invocationID
            )
            XCTFail("Expected a missing-context error")
        } catch let error as MCPError {
            guard case .internalError = error else { return XCTFail("\(error)") }
        }

        // A handler that already abandoned the invocation never starts its script.
        let abandoned = MCPCodeModeResultRetention()
        _ = await abandoned.resolve()
        do {
            _ = try await MCPCodeModeToolExecution.run(
                arguments: ["script": .string("return 1")], windowID: 7, admission: admission, retention: abandoned,
                connectionID: connectionID, parentInvocationID: invocationID
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(admission.isHeld(connectionID: connectionID, windowID: 7))

        // Busy is fail-fast and never queues; the retention resolves with no value.
        let holder = try XCTUnwrap(admission.tryAcquire(connectionID: UUID(), windowID: 7))
        let busyRetention = MCPCodeModeResultRetention()
        do {
            _ = try await MCPCodeModeToolExecution.run(
                arguments: ["script": .string("return 1")], windowID: 7, admission: admission, retention: busyRetention,
                connectionID: connectionID, parentInvocationID: invocationID
            )
            XCTFail("Expected code_mode_busy")
        } catch let error as MCPCodeModeToolError {
            XCTAssertEqual(error, .busy)
            XCTAssertEqual(error.code, "code_mode_busy")
        }
        let busyValue = await busyRetention.resolve()
        XCTAssertNil(busyValue)
        XCTAssertFalse(admission.isHeld(connectionID: connectionID))
        holder.release()
    }

    func testRunReleasesTheLeaseOnOwnerExitNotOnReturn() async throws {
        let admission = MCPCodeModeScriptAdmission()
        let connectionID = UUID()

        // Normal end: the owner exits before execute returns, so the slots are already free.
        let normalRetention = MCPCodeModeResultRetention()
        let normal = try await MCPCodeModeToolExecution.run(
            arguments: ["script": .string("text('checkpoint'); return 'done'")], windowID: 11, admission: admission,
            retention: normalRetention, connectionID: connectionID, parentInvocationID: UUID(),
            makeExecutor: { MCPCodeModeExecutor(limits: .testing(), invokeChild: $0) }
        )
        XCTAssertEqual(normal.objectValue?["status"], .string("success"))
        XCTAssertFalse(admission.isHeld(connectionID: connectionID, windowID: 11))
        let retainedNormal = await normalRetention.resolve()
        XCTAssertEqual(retainedNormal, normal)

        // Cleanup timeout: execute returns while the owner thread still runs; both slots stay held
        // until the actual owner exit.
        let gate = MCPCodeModeOwnerExitGate()
        let retention = MCPCodeModeResultRetention()
        let value = try await MCPCodeModeToolExecution.run(
            arguments: ["script": .string("text('checkpoint'); return 'done'")], windowID: 11, admission: admission,
            retention: retention, connectionID: connectionID, parentInvocationID: UUID(),
            makeExecutor: {
                MCPCodeModeExecutor(
                    limits: .testing(wallMilliseconds: 300),
                    cleanupAllowance: .milliseconds(100),
                    ownerExitGate: gate.hold,
                    invokeChild: $0
                )
            }
        )
        XCTAssertTrue(gate.entered.isSet)
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"], .string("runtime_error"))
        XCTAssertEqual(object["reason"], .string("cleanup_timeout"))
        XCTAssertTrue(object["output"]?.stringValue?.hasPrefix("checkpoint") == true, "\(object)")
        XCTAssertTrue(MCPCodeModeToolResult.isError(toolName: MCPWindowToolName.codeMode, value: value))
        let retained = await retention.resolve()
        XCTAssertEqual(retained, value)
        XCTAssertTrue(admission.isHeld(connectionID: connectionID))
        XCTAssertTrue(admission.isHeld(windowID: 11))
        XCTAssertNil(admission.tryAcquire(connectionID: UUID(), windowID: 11), "A stuck runtime keeps its window slot")

        gate.open()
        let released = await mcpCodeModeEventually { !admission.isHeld(connectionID: connectionID, windowID: 11) }
        XCTAssertTrue(released, "The owner exit releases both slots")
    }

    // MARK: - Result projection

    func testWireProjectionKeepsOutputOnceAndStatusDrivesIsError() async {
        let bridge = MCPCodeModeStubBridge()
        let success = await MCPCodeModeExecutor(limits: .testing(), invokeChild: bridge.invoker).execute(
            script: "const r = await tools.read_file({ path: 'a' }); text('tool=' + r.data.tool); return 'ok'"
        )
        XCTAssertEqual(success.status, .success, success.text)
        let successValue = MCPCodeModeToolResult.value(from: success)
        XCTAssertEqual(MCPCodeModeToolResult.text(from: successValue), success.text)
        XCTAssertEqual(successValue.objectValue?["output"]?.stringValue, success.output)
        XCTAssertFalse(MCPCodeModeToolResult.isError(toolName: MCPWindowToolName.codeMode, value: successValue))
        XCTAssertEqual(
            MCPCodeModeToolResult.structuredContent(toolName: MCPWindowToolName.codeMode, value: successValue),
            success.structuredContent
        )

        let off = ServerNetworkManager.makeToolResult(
            toolName: MCPWindowToolName.codeMode, args: [:], value: successValue, structured: false
        )
        let on = ServerNetworkManager.makeToolResult(
            toolName: MCPWindowToolName.codeMode, args: [:], value: successValue, structured: true
        )
        XCTAssertEqual(Self.texts(off), [success.text])
        XCTAssertEqual(Self.texts(on), [success.text])
        XCTAssertEqual(off.isError, false)
        XCTAssertEqual(on.isError, false)
        XCTAssertNil(off.structuredContent)
        XCTAssertEqual(on.structuredContent, success.structuredContent, "No footer key and no duplicate text")
        XCTAssertEqual(Self.texts(on).joined().components(separatedBy: "tool=read_file").count, 2, "Output appears once")

        let failingBridge = MCPCodeModeStubBridge { _, _, _ in
            MCPInProcessToolResult(
                value: nil,
                result: CallTool.Result(content: [.text(text: "boom", annotations: nil, _meta: nil)], isError: true)
            )
        }
        let failure = await MCPCodeModeExecutor(limits: .testing(), invokeChild: failingBridge.invoker).execute(
            script: "text('before'); await tools.read_file({ path: 'a' }, { allowError: true }); return 'after'"
        )
        XCTAssertNotEqual(failure.status, .success, failure.text)
        XCTAssertFalse(failure.failedCalls.isEmpty, failure.text)
        let failureValue = MCPCodeModeToolResult.value(from: failure)
        XCTAssertTrue(MCPCodeModeToolResult.isError(toolName: MCPWindowToolName.codeMode, value: failureValue))
        for structured in [false, true] {
            let result = ServerNetworkManager.makeToolResult(
                toolName: MCPWindowToolName.codeMode, args: [:], value: failureValue, structured: structured
            )
            XCTAssertEqual(result.isError, true, "A failed script is never green")
            XCTAssertEqual(Self.texts(result), [failure.text])
            XCTAssertTrue(Self.texts(result).joined().hasPrefix("before"))
            if structured {
                XCTAssertEqual(result.structuredContent, failure.structuredContent)
            } else {
                XCTAssertNil(result.structuredContent)
            }
        }

        // Only code_mode reads its status; every other tool's success value stays green.
        let otherValue = Value.object(["status": .string("failed")])
        XCTAssertFalse(MCPCodeModeToolResult.isError(toolName: MCPWindowToolName.readFile, value: otherValue))
        XCTAssertEqual(
            ServerNetworkManager.makeToolResult(
                toolName: MCPWindowToolName.readFile, args: [:], value: otherValue, structured: false
            ).isError,
            false
        )
    }

    /// F2: the footer is split on UTF-8 bytes, so non-ASCII output ending in `\r` (CRLF content
    /// split on `\n`) keeps its output and its footer intact.
    func testWireProjectionKeepsNonASCIIOutputEndingInCarriageReturn() async {
        let bridge = MCPCodeModeStubBridge()
        let result = await MCPCodeModeExecutor(limits: .testing(), invokeChild: bridge.invoker).execute(
            script: "text('h\u{e9}llo\\r'); return 'w\u{f6}rld\\r'"
        )
        XCTAssertEqual(result.status, .success, result.text)
        XCTAssertTrue(result.output.hasSuffix("\r"), result.output.debugDescription)
        XCTAssertTrue(result.output.contains("h\u{e9}llo"), result.output.debugDescription)
        // In `text`, the output's `\r` and the footer's leading `\n` form one `\r\n` grapheme.

        let value = MCPCodeModeToolResult.value(from: result)
        XCTAssertEqual(value.objectValue?["output"]?.stringValue, result.output)
        let footer = value.objectValue?[MCPCodeModeToolResult.footerKey]?.stringValue
        XCTAssertEqual(footer.map { Array($0.utf8.prefix(2)) }, Array("\n\n".utf8), "The footer keeps both newlines")
        XCTAssertEqual(Array(MCPCodeModeToolResult.text(from: value).utf8), Array(result.text.utf8))
        XCTAssertEqual(
            MCPCodeModeToolResult.structuredContent(toolName: MCPWindowToolName.codeMode, value: value),
            result.structuredContent
        )
    }

    // MARK: - Registered handler

    #if DEBUG
        @MainActor
        func testRegisteredParentRunsChildrenAndCapsScriptsPerConnectionAndWindow() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let contextA = fixture.contextA
                let gate = CodeModeChildGate()
                let firstRunID = UUID()
                let trackingHandler = ClaudeAgentToolTrackingHandler(mcpHost: manager)
                let trackedSession = AgentTabSession(tabID: UUID())
                do {
                    let first = try await Self.makeEligibleEndpoint(
                        fixture: fixture, context: contextA, label: "first", runID: firstRunID
                    )
                    // The real observer -> tracker -> Claude handler path for this run's cards.
                    trackedSession.runState = .running
                    await trackingHandler.startTracking(runID: firstRunID, session: trackedSession, clientNameHint: nil)
                    let second = try await Self.makeEligibleEndpoint(fixture: fixture, context: contextA, label: "second")
                    let otherWindow = try await Self.makeEligibleEndpoint(
                        fixture: fixture, context: fixture.contextB, label: "other-window"
                    )
                    for endpoint in [first, second, otherWindow] {
                        let registered = await manager.debugHasRegisteredToolCallHandler(connectionID: endpoint.connectionID)
                        XCTAssertTrue(registered, "The production bootstrap published the registered handler")
                    }

                    // Real children through the registered handler: the parent awaits them without
                    // a read deadlock and they never enqueue automatic selection.
                    _ = try await first.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "clear"])
                    let path = contextA.fileURL.path
                    let script = """
                    const [whole, line, found] = await Promise.all([
                      tools.read_file({ path: \(Self.jsString(path)) }),
                      tools.read_file({ path: \(Self.jsString(path)), start_line: 1, limit: 1 }),
                      tools.file_search({ pattern: \(Self.jsString(contextA.sentinel)), mode: 'content' })
                    ]);
                    text('lines=' + whole.data.total_lines);
                    return { sentinel: whole.data.content.includes(\(Self.jsString(contextA.sentinel))), differs: whole.data.content !== line.data.content, searched: !found.isError };
                    """
                    let realResponse = try await first.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": script])
                    let real = try Self.wireResult(realResponse)
                    XCTAssertNotEqual(real["isError"] as? Bool, true, realResponse.rawJSON)
                    let realText = Self.wireText(real)
                    XCTAssertTrue(realText.contains("lines="), realText)
                    // A returned object is rendered as indented JSON.
                    XCTAssertTrue(realText.contains("\"sentinel\": true"), realText)
                    XCTAssertTrue(realText.contains("\"differs\": true"), realText)
                    XCTAssertTrue(realText.contains("\"searched\": true"), realText)
                    XCTAssertTrue(realText.contains("[code_mode] status: success"), realText)
                    XCTAssertNil(real["structuredContent"], "D1 is off for this connection")
                    // Each child became a flat card linked to the parent's observer invocation.
                    do {
                        try await AsyncTestWait.waitUntil("code_mode child cards linked to their parent", timeout: 10) {
                            await MainActor.run {
                                let parents = trackedSession.items.filter { $0.toolName == MCPWindowToolName.codeMode }
                                let children = trackedSession.items.filter { $0.codeModeParentInvocationID != nil }
                                guard parents.count == 1, let parentID = parents.first?.toolInvocationID else { return false }
                                return children.count == 3
                                    && children.allSatisfy { $0.codeModeParentInvocationID == parentID && $0.kind == .toolResult }
                            }
                        }
                        let parentCard = try XCTUnwrap(trackedSession.items.first { $0.toolName == MCPWindowToolName.codeMode })
                        XCTAssertNil(parentCard.codeModeParentInvocationID, "The parent card is not a child")
                        XCTAssertEqual(
                            Set(trackedSession.items.compactMap { $0.codeModeParentInvocationID == nil ? nil : $0.toolName }),
                            [MCPWindowToolName.readFile, MCPWindowToolName.search]
                        )
                    }
                    await trackingHandler.stopTracking(for: trackedSession)
                    let selection = try await Self.wireText(Self.wireResult(
                        first.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "get", "view": "files"])
                    ))
                    XCTAssertFalse(selection.contains(contextA.fileURL.lastPathComponent), selection)

                    // Hold a child open, then contend for the cap.
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                        try await gate.enterAndWait(returning: .object([
                            "content": .string("gated"), "total_lines": .int(1)
                        ]))
                    }
                    let held = Task {
                        try await first.callTool(
                            name: MCPWindowToolName.codeMode,
                            arguments: ["script": "text('started'); const r = await tools.read_file({ path: 'gated.swift' }); return r.data.content;"],
                            timeoutSeconds: 30
                        )
                    }
                    let entered = await mcpCodeModeEventually(timeout: 10) { gate.entered == 1 }
                    XCTAssertTrue(entered)
                    XCTAssertTrue(MCPCodeModeScriptAdmission.shared.isHeld(connectionID: first.connectionID))
                    XCTAssertTrue(MCPCodeModeScriptAdmission.shared.isHeld(windowID: contextA.window.windowID))

                    // Same window, different connection: fail fast, never queued.
                    let busy = try await Self.wireResult(
                        second.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": "return 1"])
                    )
                    XCTAssertEqual(busy["isError"] as? Bool, true)
                    XCTAssertTrue(Self.wireText(busy).contains("code_mode_busy"), Self.wireText(busy))
                    // Ordinary tools on that connection are unaffected by the held script.
                    let directRead = try await Self.wireResult(
                        second.callTool(name: MCPWindowToolName.search, arguments: ["pattern": contextA.sentinel, "mode": "content"])
                    )
                    XCTAssertNotEqual(directRead["isError"] as? Bool, true)
                    // Another window runs its own script concurrently.
                    let concurrent = try await Self.wireResult(
                        otherWindow.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": "return 'other'"])
                    )
                    XCTAssertNotEqual(concurrent["isError"] as? Bool, true, Self.wireText(concurrent))
                    XCTAssertTrue(Self.wireText(concurrent).contains("other"))

                    gate.release()
                    let heldResult = try await Self.wireResult(held.value)
                    XCTAssertNotEqual(heldResult["isError"] as? Bool, true, Self.wireText(heldResult))
                    XCTAssertTrue(Self.wireText(heldResult).hasPrefix("started\ngated"), Self.wireText(heldResult))
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)

                    let releasedSlots = await mcpCodeModeEventually {
                        !MCPCodeModeScriptAdmission.shared.isHeld(
                            connectionID: first.connectionID, windowID: contextA.window.windowID
                        )
                    }
                    XCTAssertTrue(releasedSlots)
                    let retry = try await Self.wireResult(
                        second.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": "return 2"])
                    )
                    XCTAssertNotEqual(retry["isError"] as? Bool, true, Self.wireText(retry))

                    // A failing script is an error result with its footer, never green.
                    let failed = try await Self.wireResult(second.callTool(
                        name: MCPWindowToolName.codeMode,
                        arguments: ["script": "text('partial'); await tools.read_file({ path: 'Missing-\(UUID().uuidString).swift' }); return 'never'"]
                    ))
                    XCTAssertEqual(failed["isError"] as? Bool, true)
                    let failedText = Self.wireText(failed)
                    XCTAssertTrue(failedText.hasPrefix("partial"), failedText)
                    XCTAssertTrue(failedText.contains("[code_mode] status: "), failedText)
                    XCTAssertFalse(failedText.contains("never"), failedText)

                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    gate.release()
                    await trackingHandler.stopTracking(for: trackedSession)
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        @MainActor
        func testCancellingTheParentKeepsCheckpointAndCountsAndReleasesEveryPermit() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let context = fixture.contextA
                let gate = CodeModeChildGate()
                do {
                    let endpoint = try await Self.makeEligibleEndpoint(fixture: fixture, context: context, label: "cancel")
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                        try await gate.enterAndWait(returning: .object(["content": .string("unexpected")]))
                    }
                    let requestID = endpoint.client.nextRequestIDForTesting()
                    let call = Task {
                        try await endpoint.callTool(
                            name: MCPWindowToolName.codeMode,
                            arguments: ["script": "text('checkpoint'); await tools.read_file({ path: 'held.swift' }); text('after'); return 'done'"],
                            timeoutSeconds: 30
                        )
                    }
                    let entered = await mcpCodeModeEventually(timeout: 10) { gate.entered == 1 }
                    XCTAssertTrue(entered)
                    try endpoint.client.sendNotification(method: "notifications/cancelled", params: ["requestId": requestID])

                    let response = try await call.value
                    let result = try Self.wireResult(response)
                    let text = Self.wireText(result)
                    XCTAssertEqual(result["isError"] as? Bool, true, response.rawJSON)
                    XCTAssertTrue(text.hasPrefix("checkpoint"), text)
                    XCTAssertFalse(text.contains("after"), text)
                    XCTAssertTrue(text.contains("[code_mode] status: cancelled"), text)
                    XCTAssertTrue(text.contains("calls: 1"), text)
                    XCTAssertFalse(text.contains("tool_execution_timeout"), text)

                    let childCancelled = await mcpCodeModeEventually { gate.cancelled == 1 }
                    XCTAssertTrue(childCancelled, "The in-flight child is cancelled with its parent")
                    let slotsReleased = await mcpCodeModeEventually {
                        !MCPCodeModeScriptAdmission.shared.isHeld(
                            connectionID: endpoint.connectionID, windowID: context.window.windowID
                        )
                    }
                    XCTAssertTrue(slotsReleased)
                    try await AsyncTestWait.waitUntil("parent and child permits released", timeout: 10) {
                        await !manager.hasInFlightCalls(for: endpoint.connectionID)
                    }
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)

                    // Every permit came back: the same connection runs a script with a real child.
                    let after = try await Self.wireResult(endpoint.callTool(
                        name: MCPWindowToolName.codeMode,
                        arguments: ["script": "const r = await tools.read_file({ path: \(Self.jsString(context.fileURL.path)) }); return r.data.total_lines > 0;"]
                    ))
                    XCTAssertNotEqual(after["isError"] as? Bool, true, Self.wireText(after))
                    XCTAssertTrue(Self.wireText(after).hasPrefix("true"), Self.wireText(after))

                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    gate.release()
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        @MainActor
        func testToolsListAdvertisesCodeModeOnlyToEligibleConnectionsAndItsSchemaOnlyWithStructuredResults() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let context = fixture.contextA
                let settings = GlobalSettingsStore.shared
                let previousStructuredResults = settings.mcpStructuredResultsMode()
                do {
                    let eligible = try await Self.makeEligibleEndpoint(fixture: fixture, context: context, label: "list-off")
                    let eligibleTools = try await Self.listedTools(eligible)
                    let codeModeOff = try XCTUnwrap(eligibleTools[MCPWindowToolName.codeMode])
                    XCTAssertNil(codeModeOff["outputSchema"], "No schema while structured results are off")
                    XCTAssertNotNil(eligibleTools[MCPWindowToolName.readFile])

                    settings.setMCPStructuredResultsMode(.on, commit: false)
                    let structured: PersistentMCPTestEndpoint
                    do {
                        defer { settings.setMCPStructuredResultsMode(previousStructuredResults, commit: false) }
                        structured = try await Self.makeEligibleEndpoint(fixture: fixture, context: context, label: "list-on")
                    }
                    let structuredTools = try await Self.listedTools(structured)
                    let codeModeOn = try XCTUnwrap(structuredTools[MCPWindowToolName.codeMode])
                    XCTAssertNotNil(codeModeOn["outputSchema"])
                    let structuredCall = try await Self.wireResult(structured.callTool(
                        name: MCPWindowToolName.codeMode, arguments: ["script": "text('one'); return 2"]
                    ))
                    XCTAssertNotEqual(structuredCall["isError"] as? Bool, true, Self.wireText(structuredCall))
                    let content = try XCTUnwrap(structuredCall["structuredContent"] as? [String: Any])
                    XCTAssertEqual(content["status"] as? String, "success")
                    XCTAssertEqual(content["output"] as? String, "one\n2")
                    XCTAssertNil(content[MCPCodeModeToolResult.footerKey], "The footer stays text-only")
                    XCTAssertNotNil(content["counts"] as? [String: Any])
                    XCTAssertTrue(Self.wireText(structuredCall).hasPrefix("one\n2"))

                    // Native (default) policies neither list nor execute it.
                    let nativeClientName = "code-mode-native-\(UUID().uuidString)"
                    await manager.installClientConnectionPolicy(
                        for: nativeClientName,
                        windowID: context.window.windowID,
                        restrictedTools: [],
                        tabID: context.tabID,
                        runID: UUID(),
                        additionalTools: [],
                        purpose: .agentModeRun
                    )
                    let native = try await fixture.makeAdditionalEndpoint(
                        label: "list-native", clientName: nativeClientName, requiredToolNames: [MCPWindowToolName.readFile]
                    )
                    let nativeTools = try await Self.listedTools(native)
                    XCTAssertNil(nativeTools[MCPWindowToolName.codeMode])
                    XCTAssertNotNil(nativeTools[MCPWindowToolName.readFile])
                    let nativeCall = try await Self.wireResult(
                        native.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": "return 1"])
                    )
                    XCTAssertEqual(nativeCall["isError"] as? Bool, true)
                    XCTAssertTrue(
                        Self.wireText(nativeCall).contains(ServerNetworkManager.codeModeNotEligibleMessage),
                        Self.wireText(nativeCall)
                    )

                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    settings.setMCPStructuredResultsMode(previousStructuredResults, commit: false)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        /// D1 on: children keep their selection behavior and release no notices; the parent result
        /// carries a pending delegated-question notice exactly once, in text and structured form.
        @MainActor
        func testParentDeliversADelegatedQuestionNoticeOnceWithStructuredResults() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let context = fixture.contextA
                let vm = context.window.agentModeViewModel
                let settings = GlobalSettingsStore.shared
                let previousStructuredResults = settings.mcpStructuredResultsMode()
                let runID = UUID()
                var questionTask: Task<AgentAskUserResponse, Error>?
                var childTabID: UUID?
                var interactionID: UUID?
                var parentSession: AgentTabSession?
                do {
                    settings.setMCPStructuredResultsMode(.on, commit: false)
                    let endpoint: PersistentMCPTestEndpoint
                    do {
                        defer { settings.setMCPStructuredResultsMode(previousStructuredResults, commit: false) }
                        endpoint = try await Self.makeEligibleEndpoint(
                            fixture: fixture, context: context, label: "notice", runID: runID
                        )
                    }
                    _ = try await endpoint.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "clear"])

                    // Delivery is keyed by the connection's run ID, not its tab: the parent run lives in its
                    // own compose tab of the window.
                    let parentTab = await context.window.promptManager.createBackgroundComposeTab(
                        strategy: .blank, name: "code_mode notice parent"
                    )
                    let parent = try XCTUnwrap(vm.session(for: XCTUnwrap(parentTab).id, createIfNeeded: true))
                    parentSession = parent
                    let parentSessionID = UUID()
                    _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: parentSessionID, on: parent))
                    parent.hasLoadedPersistedState = true
                    parent.parentSessionID = nil
                    parent.runID = runID
                    parent.runState = .running
                    parent.beginRunAttempt(source: "code-mode-notice-test")

                    let childTab = await context.window.promptManager.createBackgroundComposeTab(
                        strategy: .blank, name: "code_mode notice child"
                    )
                    let resolvedChildTabID = try XCTUnwrap(childTab).id
                    childTabID = resolvedChildTabID
                    let childSessionID = UUID()
                    let child = try XCTUnwrap(vm.session(for: resolvedChildTabID, createIfNeeded: true))
                    _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: childSessionID, on: child))
                    child.hasLoadedPersistedState = true
                    child.parentSessionID = parentSessionID
                    child.mcpControlContext = AgentMCPControlContext(
                        sessionID: childSessionID,
                        activationID: UUID(),
                        registration: .init(sessionID: childSessionID, generation: 0),
                        currentEpoch: nil,
                        preparedEpoch: nil,
                        pendingEpochTransition: nil,
                        originatingConnectionID: nil,
                        interactionTransport: .mcp(sessionID: childSessionID, originatingConnectionID: nil),
                        suppressUserNotifications: true,
                        forceAutoEditEnabled: false,
                        autoEditEnabledBeforeOverride: false,
                        taskLabelKind: .engineer
                    )
                    vm.test_setMCPControlledTabIDs([resolvedChildTabID])
                    let interaction = AgentAskUserInteraction(
                        timeoutSeconds: 60,
                        questions: [AgentAskUserQuestion(
                            id: "route", question: "Which route should the code_mode child use?",
                            options: [AgentAskUserOption(label: "A"), AgentAskUserOption(label: "B")],
                            allowsCustom: true
                        )]
                    )
                    interactionID = interaction.id
                    let key = AgentDelegatedQuestionNoticeKey(childSessionID: childSessionID, interactionID: interaction.id)
                    questionTask = Task { @MainActor in
                        try await vm.askUser(tabID: resolvedChildTabID, interaction: interaction)
                    }
                    try await AsyncTestWait.waitUntil("child question addressed to parent", timeout: 5) {
                        await MainActor.run {
                            child.pendingAskUser?.isAwaitingParentAgent == true
                                && vm.mcpHasDeliverableDelegatedQuestionNotices(parentRunID: runID, excludingChildSessionIDs: [])
                        }
                    }

                    let path = Self.jsString(context.fileURL.path)
                    let response = try await endpoint.callTool(
                        name: MCPWindowToolName.codeMode,
                        arguments: ["script": """
                        const [a, b] = await Promise.all([tools.read_file({ path: \(path) }), tools.read_file({ path: \(path), start_line: 1, limit: 1 })]);
                        text('read=' + (a.data.content.length > 0) + ',' + (b.data.content.length > 0));
                        return 'ok';
                        """]
                    )
                    let result = try Self.wireResult(response)
                    XCTAssertNotEqual(result["isError"] as? Bool, true, response.rawJSON)
                    let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
                    XCTAssertEqual(blocks.count, 2, "The script text plus one notice block")
                    let scriptText = try XCTUnwrap(blocks.first?["text"] as? String)
                    XCTAssertTrue(scriptText.hasPrefix("read=true,true\nok"), scriptText)
                    XCTAssertFalse(scriptText.contains(interaction.id.uuidString), "Children carried no notice")
                    let noticeText = try XCTUnwrap(blocks.last?["text"] as? String)
                    XCTAssertTrue(noticeText.contains(interaction.id.uuidString), noticeText)
                    let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
                    XCTAssertEqual(structured["status"] as? String, "success")
                    XCTAssertNil(structured[MCPCodeModeToolResult.footerKey])
                    let entries = try XCTUnwrap(structured[Self.noticeKey] as? [[String: Any]])
                    XCTAssertEqual(entries.count, 1)
                    XCTAssertEqual(entries.first?["text"] as? String, noticeText)
                    XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.acknowledged, true)
                    XCTAssertEqual(vm.delegatedQuestionNotices.records[key]?.deliveredRunIDs, [runID])
                    XCTAssertEqual(
                        parent.items.filter {
                            $0.kind == .system && $0.text.hasPrefix(AgentDelegatedQuestionNoticeWire.noticeHeader)
                        }.map(\.text),
                        [noticeText]
                    )

                    // Child reads still never enqueue automatic selection with D1 on.
                    let selection = try await Self.wireText(Self.wireResult(
                        endpoint.callTool(name: MCPWindowToolName.manageSelection, arguments: ["op": "get", "view": "files"])
                    ))
                    XCTAssertFalse(selection.contains(context.fileURL.lastPathComponent), selection)
                    // A later script never carries the acknowledged notice again.
                    let later = try await Self.wireResult(endpoint.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": "return 3"]))
                    XCTAssertEqual((later["content"] as? [[String: Any]])?.count, 1)
                    XCTAssertNil((later["structuredContent"] as? [String: Any])?[Self.noticeKey])

                    vm.skipAskUser(tabID: resolvedChildTabID, interactionID: interaction.id)
                    _ = try await questionTask?.value
                    questionTask = nil
                    parent.endCurrentRunAttempt(source: "code-mode-notice-test")
                    parent.runState = .idle
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    settings.setMCPStructuredResultsMode(previousStructuredResults, commit: false)
                    if let childTabID, let interactionID {
                        vm.skipAskUser(tabID: childTabID, interactionID: interactionID)
                    }
                    _ = try? await questionTask?.value
                    parentSession?.endCurrentRunAttempt(source: "code-mode-notice-test")
                    parentSession?.runState = .idle
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        /// CM-02: the parent cannot be routed. Two windows hold different contents at the same
        /// relative path; every routing override on the code_mode call fails closed before any
        /// route is resolved, and an ordinary bound call reads its own window.
        @MainActor
        func testParentRoutingOverridesFailClosedAndBoundReadsStayInTheirWindow() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let contextA = fixture.contextA
                let contextB = fixture.contextB
                let sharedPath = "Sources/SharedCodeModeRoute.swift"
                let sentinelA = "code_mode_route_A_\(UUID().uuidString.prefix(8))"
                let sentinelB = "code_mode_route_B_\(UUID().uuidString.prefix(8))"
                do {
                    try "// \(sentinelA)\n".write(
                        to: contextA.rootURL.appendingPathComponent(sharedPath), atomically: true, encoding: .utf8
                    )
                    try "// \(sentinelB)\n".write(
                        to: contextB.rootURL.appendingPathComponent(sharedPath), atomically: true, encoding: .utf8
                    )
                    // Re-ingest each root so both catalogs list the new same-path file.
                    for context in [contextA, contextB] {
                        _ = await WorkspaceCheckoutRefreshService(
                            store: context.window.workspaceFileContextStore,
                            searchService: WorkspaceSearchService()
                        ).refreshAfterCheckoutMutation(rootPath: context.rootURL.path)
                    }
                    let endpointA = try await Self.makeEligibleEndpoint(fixture: fixture, context: contextA, label: "route-a")
                    let endpointB = try await Self.makeEligibleEndpoint(fixture: fixture, context: contextB, label: "route-b")
                    // Each bound direct read resolves the same path in its own window.
                    for (endpoint, sentinel) in [(endpointA, sentinelA), (endpointB, sentinelB)] {
                        try await AsyncTestWait.waitUntil("bound read of \(sentinel)", timeout: 15) {
                            let response = try? await endpoint.callTool(
                                name: MCPWindowToolName.readFile, arguments: ["path": sharedPath]
                            )
                            return response.flatMap { try? Self.wireText(Self.wireResult($0)) }?.contains(sentinel) == true
                        }
                    }

                    let script = """
                    const r = await tools.read_file({ path: \(Self.jsString(sharedPath)) });
                    return r.data.content;
                    """
                    let windowB = contextB.window.windowID
                    let wrappedJSON = try XCTUnwrap(String(
                        data: JSONSerialization.data(withJSONObject: ["script": script, "_windowID": windowB]),
                        encoding: .utf8
                    ))
                    let overrides: [(label: String, arguments: [String: Any])] = [
                        ("_windowID", ["script": script, "_windowID": windowB]),
                        ("_windowID string", ["script": script, "_windowID": String(windowB)]),
                        ("window_id", ["script": script, "window_id": windowB]),
                        ("context_id", ["script": script, "context_id": UUID().uuidString]),
                        ("_tabID", ["script": script, "_tabID": contextB.tabID.uuidString]),
                        ("null _windowID", ["script": script, "_windowID": NSNull()]),
                        ("null context_id", ["script": script, "context_id": NSNull()]),
                        ("invalid window_id", ["script": script, "window_id": "not-a-window"]),
                        ("args object", ["args": ["script": script, "_windowID": windowB]]),
                        ("args JSON string", ["args": wrappedJSON]),
                        ("tool-name wrapper", [MCPWindowToolName.codeMode: ["script": script, "window_id": windowB]]),
                        ("tool-name wrapper in args", ["args": [MCPWindowToolName.codeMode: ["script": script, "_tabID": NSNull()]]])
                    ]
                    let denial = MCPCodeModeChildIngress.parentRoutingOverrideDenial
                    for override in overrides {
                        let result = try await Self.wireResult(
                            endpointA.callTool(name: MCPWindowToolName.codeMode, arguments: override.arguments)
                        )
                        let text = Self.wireText(result)
                        XCTAssertEqual(result["isError"] as? Bool, true, override.label)
                        XCTAssertTrue(text.contains(denial.message), "\(override.label): \(text)")
                        XCTAssertFalse(text.contains(sentinelB), "\(override.label) read the other window: \(text)")
                        XCTAssertFalse(text.contains("[code_mode] status"), "\(override.label) ran a script: \(text)")
                        XCTAssertFalse(
                            MCPCodeModeScriptAdmission.shared.isHeld(connectionID: endpointA.connectionID),
                            override.label
                        )
                    }

                    // The normal bound connection stays the authority, for both windows.
                    for (endpoint, sentinel, other) in [(endpointA, sentinelA, sentinelB), (endpointB, sentinelB, sentinelA)] {
                        let result = try await Self.wireResult(
                            endpoint.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": script])
                        )
                        let text = Self.wireText(result)
                        XCTAssertNotEqual(result["isError"] as? Bool, true, text)
                        XCTAssertTrue(text.contains(sentinel), text)
                        XCTAssertFalse(text.contains(other), text)
                    }
                    // Routing inside the script keeps its own child denial.
                    let child = try await Self.wireResult(endpointA.callTool(
                        name: MCPWindowToolName.codeMode,
                        arguments: ["script": """
                        const r = await tools.read_file({ path: \(Self.jsString(sharedPath)), _windowID: \(windowB) }, { allowError: true });
                        return r.isError ? 'denied:' + r.code : r.data.content;
                        """]
                    ))
                    let childText = Self.wireText(child)
                    XCTAssertTrue(childText.contains("denied:"), childText)
                    XCTAssertFalse(childText.contains(sentinelB), childText)

                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        /// CM-03 / F1: a child's typed POSIX EINTR/EAGAIN (directly or under a Cocoa error's
        /// `NSUnderlyingErrorKey`) crosses the real registered handler as a retryable disposition,
        /// one child call per attempt. Non-transient errors, look-alike error text, cancellation,
        /// and denials are never retried.
        @MainActor
        func testRegisteredHandlerRetriesOnlyTypedTransientChildErrors() async throws {
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                let manager = fixture.networkManager
                let endpoint: PersistentMCPTestEndpoint
                do {
                    endpoint = try await Self.makeEligibleEndpoint(fixture: fixture, context: fixture.contextA, label: "retry")
                } catch {
                    await fixture.cleanup()
                    throw error
                }
                let success = Value.object(["content": .string("recovered"), "total_lines": .int(1)])
                let wrappedEAGAIN = NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))]
                )
                let scenarios: [(label: String, outcomes: [Result<Value, Error>], retried: Bool)] = [
                    ("EAGAIN once", [.failure(POSIXError(.EAGAIN)), .success(success)], true),
                    ("EINTR once", [.failure(POSIXError(.EINTR)), .success(success)], true),
                    ("Cocoa-wrapped EAGAIN once", [.failure(wrappedEAGAIN), .success(success)], true),
                    ("ENOENT", [.failure(POSIXError(.ENOENT)), .success(success)], false),
                    (
                        "EAGAIN look-alike text",
                        [.failure(NSError(domain: "Custom", code: 35, userInfo: [
                            NSLocalizedDescriptionKey: "EAGAIN: Resource temporarily unavailable"
                        ])), .success(success)],
                        false
                    ),
                    ("cancellation", [.failure(CancellationError()), .success(success)], false)
                ]
                let script = """
                const r = await tools.read_file({ path: 'Retry.swift' }, { allowError: true });
                return r.isError ? 'failed:' + r.code : r.data.content;
                """
                do {
                    for scenario in scenarios {
                        let outcomes = CodeModeChildOutcomes(scenario.outcomes)
                        await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                            try outcomes.next()
                        }
                        let result = try await Self.wireResult(
                            endpoint.callTool(name: MCPWindowToolName.codeMode, arguments: ["script": script])
                        )
                        let text = Self.wireText(result)
                        if scenario.retried {
                            XCTAssertNotEqual(result["isError"] as? Bool, true, "\(scenario.label): \(text)")
                            XCTAssertTrue(text.hasPrefix("recovered"), "\(scenario.label): \(text)")
                            XCTAssertTrue(text.contains("attempts 2, retries 1"), "\(scenario.label): \(text)")
                            XCTAssertEqual(outcomes.invocations, 2, scenario.label)
                        } else {
                            XCTAssertEqual(result["isError"] as? Bool, true, "\(scenario.label): \(text)")
                            XCTAssertTrue(text.hasPrefix("failed:"), "\(scenario.label): \(text)")
                            XCTAssertFalse(text.contains("transient_io_error"), "\(scenario.label): \(text)")
                            XCTAssertTrue(text.contains("attempts 1, retries 0"), "\(scenario.label): \(text)")
                            XCTAssertEqual(outcomes.invocations, 1, scenario.label)
                        }
                    }

                    // A denied child never reaches its operation and is never retried.
                    let outcomes = CodeModeChildOutcomes([.failure(POSIXError(.EAGAIN))])
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile) {
                        try outcomes.next()
                    }
                    let denied = try await Self.wireResult(endpoint.callTool(
                        name: MCPWindowToolName.codeMode,
                        arguments: ["script": """
                        const r = await tools.read_file({ path: 'Retry.swift', window_id: 1 }, { allowError: true });
                        return r.isError ? 'failed:' + r.code : r.data.content;
                        """]
                    ))
                    let deniedText = Self.wireText(denied)
                    XCTAssertTrue(deniedText.hasPrefix("failed:"), deniedText)
                    XCTAssertTrue(deniedText.contains("attempts 1, retries 0"), deniedText)
                    XCTAssertEqual(outcomes.invocations, 0)

                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await fixture.cleanup()
                    try await fixture.assertCleanedUp()
                } catch {
                    await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.readFile, operation: nil)
                    await fixture.cleanup()
                    throw error
                }
            }
        }

        // MARK: - Wire helpers

        @MainActor
        private static func makeEligibleEndpoint(
            fixture: PersistentMCPTestFixture,
            context: PersistentMCPTestContext,
            label: String,
            runID: UUID = UUID()
        ) async throws -> PersistentMCPTestEndpoint {
            let clientName = "code-mode-\(label)-\(UUID().uuidString)"
            await fixture.networkManager.installClientConnectionPolicy(
                for: clientName,
                windowID: context.window.windowID,
                restrictedTools: [],
                tabID: context.tabID,
                runID: runID,
                additionalTools: [],
                purpose: .agentModeRun,
                codeModeEligibility: .directTools
            )
            return try await fixture.makeAdditionalEndpoint(
                label: "code-mode-\(label)",
                clientName: clientName,
                requiredToolNames: [MCPWindowToolName.readFile, MCPWindowToolName.codeMode]
            )
        }

        private static func listedTools(_ endpoint: PersistentMCPTestEndpoint) async throws -> [String: [String: Any]] {
            let response = try await endpoint.client.request(method: "tools/list", params: [:])
            let result = try wireResult(response)
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            var byName: [String: [String: Any]] = [:]
            for tool in tools {
                if let name = tool["name"] as? String { byName[name] = tool }
            }
            return byName
        }

        private static func wireResult(_ response: PersistentMCPTestRPCResponse) throws -> [String: Any] {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(response.rawJSON.utf8)) as? [String: Any], response.rawJSON
            )
            return try XCTUnwrap(object["result"] as? [String: Any], response.rawJSON)
        }

        private static func wireText(_ result: [String: Any]) -> String {
            ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        }

        private static func jsString(_ string: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
    #endif

    private static func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { block in
            if case let .text(text, _, _) = block { return text }
            return nil
        }
    }
}

/// Scripted outcomes for an overridden child operation, one per invocation; counts invocations.
private final class CodeModeChildOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [Result<Value, Error>]
    private var count = 0

    init(_ outcomes: [Result<Value, Error>]) {
        remaining = outcomes
    }

    var invocations: Int {
        lock.withLock { count }
    }

    func next() throws -> Value {
        let outcome: Result<Value, Error> = lock.withLock {
            count += 1
            return remaining.isEmpty ? .failure(POSIXError(.EIO)) : remaining.removeFirst()
        }
        return try outcome.get()
    }
}

/// Holds an overridden child operation open until released; records entry and cancellation.
private final class CodeModeChildGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredCount = 0
    private var cancelledCount = 0
    private var isReleased = false

    var entered: Int {
        lock.withLock { enteredCount }
    }

    var cancelled: Int {
        lock.withLock { cancelledCount }
    }

    func release() {
        lock.withLock { isReleased = true }
    }

    func enterAndWait(returning value: Value) async throws -> Value {
        lock.withLock { enteredCount += 1 }
        do {
            while !lock.withLock({ isReleased }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            lock.withLock { cancelledCount += 1 }
            throw error
        }
        return value
    }
}
