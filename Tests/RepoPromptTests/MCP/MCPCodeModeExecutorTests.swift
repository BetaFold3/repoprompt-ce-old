import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Plan §6 D3 / Phase 5 bridge tests with a stub re-entry closure: one invocation per attempt,
/// two children in flight, the 32-attempt budget, data-first results with `isError` authority,
/// default rejection and `allowError`, typed transient retry, failure footer, cancellation, and
/// caller task-local inheritance.
final class MCPCodeModeExecutorTests: XCTestCase {
    @TaskLocal static var parentMarker: String?

    private func run(
        _ script: String,
        limits: MCPCodeModeLimits = .testing(),
        bridge: MCPCodeModeStubBridge
    ) async -> MCPCodeModeExecutionResult {
        await MCPCodeModeExecutor(limits: limits, invokeChild: bridge.invoker).execute(script: script)
    }

    // MARK: - Result shape

    func testSuccessfulChildIsDataFirstWithoutText() async {
        let bridge = MCPCodeModeStubBridge()
        let result = await run(
            "const r = await tools.read_file({ path: 'a.swift' }); text([r.isError, r.text === undefined, r.data.tool, r.data.arguments.path].join(','))",
            bridge: bridge
        )
        XCTAssertEqual(result.output, "false,true,read_file,a.swift")
        XCTAssertEqual(result.status, .success)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "false,true,read_file,a.swift\n\n[code_mode] status: success\ncalls: 1 (completed 1, failed 0, queued at stop 0, in flight at stop 0); attempts 1, retries 0\nfailed calls: none")
        XCTAssertEqual(bridge.invocations, [.init(tool: "read_file", arguments: ["path": .string("a.swift")])])
    }

    func testSuccessWithoutCapturedValueFallsBackToTextOnly() async {
        let bridge = MCPCodeModeStubBridge { _, _, _ in
            MCPInProcessToolResult(
                value: nil,
                result: CallTool.Result(
                    content: [.text(text: "one", annotations: nil, _meta: nil), .text(text: "two", annotations: nil, _meta: nil)],
                    isError: false
                )
            )
        }
        let result = await run("const r = await tools.file_search({ pattern: 'x' }); text(JSON.stringify(r))", bridge: bridge)
        XCTAssertEqual(result.output, #"{"isError":false,"text":"one\ntwo"}"#)
    }

    func testFailedResultIsAuthoritativeOverCapturedValueAndRejectsByDefault() async {
        let bridge = MCPCodeModeStubBridge { _, _, _ in
            MCPInProcessToolResult(value: .object(["leak": .string("SUCCESS_DATA")]), result: .err("tool_denied: not here"))
        }
        let result = await run(
            "try { await tools.read_file({ path: 'a' }); } catch (e) { text(JSON.stringify(e)); }",
            bridge: bridge
        )
        XCTAssertFalse(result.output.contains("SUCCESS_DATA"))
        XCTAssertEqual(
            result.output,
            #"{"message":"tool_denied: not here","code":"tool_denied","callID":1,"result":{"code":"tool_denied","error":"tool_denied: not here","isError":true}}"#
        )
        XCTAssertEqual(result.status, .childFailure)
        XCTAssertTrue(result.isError, "A caught child failure still marks the parent result as an error")
        XCTAssertTrue(result.text.hasSuffix("failed calls:\n- #1 read_file: tool_denied (attempts 1)"))
        XCTAssertEqual(result.failedCalls, [.init(callID: 1, tool: .readFile, attempts: 1, code: "tool_denied")])
    }

    func testAllowErrorResolvesTheFailureAndStillCountsIt() async {
        let bridge = MCPCodeModeStubBridge { _, _, _ in
            MCPInProcessToolResult(value: nil, result: .err("Error: plain failure"))
        }
        let result = await run(
            "const r = await tools.get_file_tree({}, { allowError: true }); text([r.isError, r.code, r.error].join('|'))",
            bridge: bridge
        )
        XCTAssertEqual(result.output, "true|tool_error|Error: plain failure")
        XCTAssertEqual(result.status, .childFailure)
        XCTAssertEqual(result.counts.failed, 1)
        XCTAssertEqual(result.structuredContent.objectValue?["status"], .string("child_failure"))
    }

    func testUncaughtChildFailureIsAScriptErrorWithFooter() async {
        let bridge = MCPCodeModeStubBridge { _, _, _ in
            MCPInProcessToolResult(value: nil, result: .err("tool_execution_timeout: too slow"))
        }
        let result = await run("text('partial'); await tools.read_file({ path: 'a' }); text('unreachable')", bridge: bridge)
        XCTAssertEqual(result.status, .scriptError)
        XCTAssertEqual(result.output, "partial")
        XCTAssertTrue(result.text.contains("error: Error: tool_execution_timeout: too slow"))
        XCTAssertTrue(result.text.contains("- #1 read_file: tool_execution_timeout (attempts 1)"))
    }

    func testNonTextSuccessIsABridgeFailure() async {
        let bridge = MCPCodeModeStubBridge { _, _, _ in
            MCPInProcessToolResult(
                value: nil,
                result: CallTool.Result(content: [.image(data: "AA==", mimeType: "image/png", annotations: nil, _meta: nil)], isError: false)
            )
        }
        let result = await run("const r = await tools.read_file({}, { allowError: true }); text(r.code)", bridge: bridge)
        XCTAssertEqual(result.output, "bridge_unsupported_content")
    }

    // MARK: - Retry

    func testTransientPOSIXErrorRetriesOnceWithSameArguments() async {
        let bridge = MCPCodeModeStubBridge { tool, arguments, index in
            if index == 0 { throw POSIXError(.EAGAIN) }
            return MCPCodeModeStubBridge.success(tool: tool, arguments: arguments)
        }
        let result = await run("const r = await tools.read_file({ path: 'a' }); text(r.data.arguments.path)", bridge: bridge)
        XCTAssertEqual(result.status, .success, result.text)
        XCTAssertEqual(result.output, "a")
        XCTAssertEqual(bridge.invocations.count, 2)
        XCTAssertEqual(bridge.invocations[0], bridge.invocations[1])
        XCTAssertEqual(result.counts.retries, 1)
        XCTAssertEqual(result.counts.attempts, 2)
        XCTAssertEqual(result.counts.failed, 0)
        XCTAssertTrue(result.failedCalls.isEmpty)
    }

    func testRetryExhaustionKeepsTheTransientFailure() async {
        let bridge = MCPCodeModeStubBridge { _, _, _ in throw POSIXError(.EINTR) }
        let result = await run("const r = await tools.read_file({}, { allowError: true }); text(r.code)", bridge: bridge)
        XCTAssertEqual(result.output, "transient_io_error")
        XCTAssertEqual(bridge.invocations.count, 2)
        XCTAssertEqual(result.failedCalls, [.init(callID: 1, tool: .readFile, attempts: 2, code: "transient_io_error")])
    }

    func testOtherErrorsAndCancellationAreNeverRetried() async {
        let thrown = MCPCodeModeStubBridge { _, _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        let other = await run("const r = await tools.read_file({}, { allowError: true }); text(r.code)", bridge: thrown)
        XCTAssertEqual(other.output, "tool_threw")
        XCTAssertEqual(thrown.invocations.count, 1)

        let cancelled = MCPCodeModeStubBridge { _, _, _ in throw CancellationError() }
        let cancelledResult = await run("const r = await tools.read_file({}, { allowError: true }); text(r.code)", bridge: cancelled)
        XCTAssertEqual(cancelledResult.output, "cancelled")
        XCTAssertEqual(cancelled.invocations.count, 1)

        XCTAssertEqual(MCPCodeModeExecutor.childReply(fromThrown: POSIXError(.EAGAIN)).disposition, .retryableFailure)
        XCTAssertEqual(MCPCodeModeExecutor.childReply(fromThrown: URLError(.timedOut)).disposition, .failure)
    }

    // MARK: - Capacity and budget

    func testAtMostTwoChildrenRunAtOnceAcrossAllTools() async {
        let bridge = MCPCodeModeStubBridge { tool, arguments, _ in
            try await Task.sleep(for: .milliseconds(80))
            return MCPCodeModeStubBridge.success(tool: tool, arguments: arguments)
        }
        let result = await run(
            """
            const results = await Promise.all([
              tools.read_file({ path: '1' }), tools.file_search({ pattern: 'p' }), tools.get_code_structure({}),
              tools.get_file_tree({}), tools.read_file({ path: '2' }), tools.file_search({ pattern: 'q' }),
            ]);
            text(results.length);
            """,
            bridge: bridge
        )
        XCTAssertEqual(result.output, "6")
        XCTAssertEqual(bridge.maxConcurrent, 2)
        XCTAssertEqual(bridge.invocations.count, 6)
        XCTAssertEqual(Set(bridge.invocations.map(\.tool)), Set(MCPCodeModeTool.allCases.map(\.rawValue)))
    }

    func testThirtyThirdCallEndsTheRunEvenWhenCaught() async {
        let bridge = MCPCodeModeStubBridge()
        let result = await run(
            "for (let i = 0; i < 40; i++) { try { await tools.get_file_tree({}); } catch (e) {} } text('after')",
            bridge: bridge
        )
        XCTAssertEqual(result.status, .limitExceeded)
        XCTAssertEqual(result.reason, "calls")
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(bridge.invocations.count, 32)
        XCTAssertEqual(result.counts.calls, 32)
        XCTAssertEqual(result.counts.completed, 32)
    }

    func testAutomaticRetriesSpendTheSameThirtyTwoAttemptBudget() async {
        let bridge = MCPCodeModeStubBridge { _, _, _ in throw POSIXError(.EAGAIN) }
        let result = await run(
            "for (let i = 0; i < 40; i++) await tools.read_file({ path: String(i) }, { allowError: true });",
            bridge: bridge
        )
        XCTAssertEqual(result.reason, "calls")
        XCTAssertEqual(bridge.invocations.count, 32, "32 actual child attempts, retries included")
        XCTAssertEqual(result.counts.calls, 16)
        XCTAssertEqual(result.counts.retries, 16)
        XCTAssertEqual(result.counts.failed, 16)
    }

    // MARK: - Cancellation and task locals

    func testParentCancellationStopsTheScriptAndCancelsItsChildren() async {
        let bridge = MCPCodeModeStubBridge { tool, arguments, _ in
            if arguments["path"] == .string("slow") {
                try await Task.sleep(for: .seconds(30))
            }
            return MCPCodeModeStubBridge.success(tool: tool, arguments: arguments)
        }
        let executor = MCPCodeModeExecutor(limits: .testing(wallMilliseconds: 30000), invokeChild: bridge.invoker)
        let parent = Task {
            await executor.execute(script: "await tools.read_file({ path: 'fast' }); text('checkpoint'); await tools.read_file({ path: 'slow' });")
        }
        _ = await bridge.waitForInvocation(path: "slow")
        let started = Date()
        parent.cancel()
        let result = await parent.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.output, "checkpoint")
        XCTAssertEqual(result.counts.completed, 1)
        XCTAssertEqual(result.counts.inFlightAtStop, 1)
        let childCancelled = await mcpCodeModeEventually { bridge.cancelledCount == 1 }
        XCTAssertTrue(childCancelled)
    }

    func testLateChildCompletionAfterCancellationIsIgnored() async {
        let bridge = MCPCodeModeStubBridge { tool, arguments, _ in
            // Ignores cancellation and finishes after the parent has returned.
            try? await Task.sleep(for: .milliseconds(300))
            return MCPCodeModeStubBridge.success(tool: tool, arguments: arguments)
        }
        let executor = MCPCodeModeExecutor(limits: .testing(), invokeChild: bridge.invoker)
        let parent = Task { await executor.execute(script: "await tools.read_file({ path: 'a' }); text('unreachable')") }
        _ = await bridge.waitForInvocation(path: "a")
        parent.cancel()
        let result = await parent.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.output, "")
        let finished = await mcpCodeModeEventually { bridge.finishedCount == 1 }
        XCTAssertTrue(finished, "The late child completes without touching the destroyed host")
    }

    func testChildrenInheritTheCallersTaskLocals() async {
        let bridge = MCPCodeModeStubBridge { _, _, _ in
            MCPInProcessToolResult(
                value: .string(MCPCodeModeExecutorTests.parentMarker ?? "missing"),
                result: CallTool.Result(content: [], isError: false)
            )
        }
        let result = await Self.$parentMarker.withValue("parent-invocation") {
            await run("text((await tools.read_file({})).data)", bridge: bridge)
        }
        XCTAssertEqual(result.output, "parent-invocation")
    }

    // MARK: - Script slot lifetime

    func testOwnerExitRunsOnceBeforeAnOrdinaryResultReturns() async {
        let log = MCPCodeModeEventLog()
        let executor = MCPCodeModeExecutor(limits: .testing(), invokeChild: MCPCodeModeStubBridge().invoker)
        let result = await executor.execute(script: "await tools.read_file({}); text('ok')") { log.append("ownerExit") }
        log.append("returned")
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(log.events, ["ownerExit", "returned"])

        let tooLarge = await MCPCodeModeExecutor(limits: .testing(scriptBytes: 4), invokeChild: MCPCodeModeStubBridge().invoker)
            .execute(script: "text('too large')") { log.append("creationFailure") }
        XCTAssertEqual(tooLarge.reason, "script_too_large")
        XCTAssertEqual(log.events, ["ownerExit", "returned", "creationFailure"])
    }

    func testCleanupTimeoutKeepsCheckpointsAndCountsAndReleasesTheSlotOnlyWhenTheOwnerExits() async {
        let gate = MCPCodeModeOwnerExitGate()
        let log = MCPCodeModeEventLog()
        let bridge = MCPCodeModeStubBridge()
        let executor = MCPCodeModeExecutor(
            limits: .testing(wallMilliseconds: 300),
            cleanupAllowance: .milliseconds(100),
            ownerExitGate: gate.hold,
            invokeChild: bridge.invoker
        )
        // The script finishes, but its owner thread is held at exit past wall + allowance.
        let result = await executor.execute(
            script: "text('checkpoint'); await tools.read_file({ path: 'a' }); text('second')"
        ) { log.append("ownerExit") }
        log.append("returned")

        XCTAssertTrue(gate.entered.isSet)
        XCTAssertEqual(result.status, .runtimeError)
        XCTAssertEqual(result.reason, "cleanup_timeout")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.output, "checkpoint\nsecond")
        XCTAssertEqual(result.counts.calls, 1)
        XCTAssertEqual(result.counts.completed, 1)
        XCTAssertEqual(result.counts.attempts, 1)
        XCTAssertTrue(result.text.hasPrefix("checkpoint\nsecond\n\n[code_mode] status: runtime_error (cleanup_timeout)"))
        XCTAssertTrue(result.text.contains("calls: 1 (completed 1, failed 0"))
        XCTAssertEqual(log.events, ["returned"], "The slot stays held while the owner thread runs")

        gate.open()
        let exited = await mcpCodeModeEventually { log.events == ["returned", "ownerExit"] }
        XCTAssertTrue(exited, "Owner exit is reported once after the thread exits: \(log.events)")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log.events, ["returned", "ownerExit"])
    }

    // MARK: - Footer and final size

    private static func longFailures(_ count: Int) -> [MCPCodeModeExecutionResult.FailedCall] {
        (1 ... count).map { index in
            MCPCodeModeExecutionResult.FailedCall(
                callID: index,
                tool: .getCodeStructure,
                attempts: 2,
                code: String(repeating: "c", count: 63)
            )
        }
    }

    func testFooterListsEveryFailureAtMaximumCardinalityWithinItsReserve() {
        // 32 attempts is the runtime ceiling and failure codes are at most 63 bytes, so the
        // worst real footer (with a maximal error line) lists every failed call in the reserve.
        let footer = MCPCodeModeExecutor.footer(
            status: .limitExceeded,
            reason: "calls",
            message: String(repeating: "é", count: 2000),
            counts: .init(calls: 32, attempts: 32, completed: 32, failed: 32),
            failedCalls: Self.longFailures(32),
            afterOutput: true
        )
        XCTAssertLessThanOrEqual(footer.utf8.count, MCPCodeModeLimits.metadataReserveBytes)
        XCTAssertTrue(footer.contains("- #1 get_code_structure:"))
        XCTAssertTrue(footer.contains("- #32 get_code_structure:"))
        XCTAssertFalse(footer.contains("more (see structured failed_calls)"))
    }

    func testFooterSummarizesFailuresBeyondItsReserve() {
        let footer = MCPCodeModeExecutor.footer(
            status: .limitExceeded,
            reason: "calls",
            message: String(repeating: "é", count: 2000),
            counts: .init(calls: 100, attempts: 100, completed: 100, failed: 100),
            failedCalls: Self.longFailures(100),
            afterOutput: true
        )
        XCTAssertLessThanOrEqual(footer.utf8.count, MCPCodeModeLimits.metadataReserveBytes)
        XCTAssertTrue(footer.contains("- #1 get_code_structure:"))
        XCTAssertFalse(footer.contains("- #100 get_code_structure:"))
        XCTAssertTrue(footer.contains("more (see structured failed_calls)"))
    }

    func testStructuredContentCarriesOutputAndAccounting() async {
        let bridge = MCPCodeModeStubBridge()
        let result = await run("await tools.read_file({}); text('ok')", bridge: bridge)
        guard case let .object(object) = result.structuredContent else { return XCTFail("object") }
        XCTAssertEqual(object["output"], .string("ok"))
        XCTAssertEqual(object["failed_calls"], .array([]))
        XCTAssertEqual(object["counts"]?.objectValue?["completed"], .int(1))
        XCTAssertNil(object["reason"])
    }
}
