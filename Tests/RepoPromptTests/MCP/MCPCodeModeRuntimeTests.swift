import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Plan §6 D3 / Phase 5 runtime tests: the embedded QuickJS-ng host has no ambient globals,
/// interrupts every kind of runaway guest work, enforces memory, stack, output, UTF-8, argument
/// and result limits, fences stale/duplicate/late replies, and tears down cleanly every time.
final class MCPCodeModeRuntimeTests: XCTestCase {
    private func run(
        _ script: String,
        limits: MCPCodeModeLimits = .testing(),
        bridge: MCPCodeModeStubBridge = MCPCodeModeStubBridge()
    ) async -> MCPCodeModeExecutionResult {
        await MCPCodeModeExecutor(limits: limits, invokeChild: bridge.invoker).execute(script: script)
    }

    // MARK: - Isolation

    func testFreshRuntimeExposesOnlyFrozenBridgeGlobalsAndNoHostCapabilities() async {
        let script = """
        const absent = ['require', 'process', 'std', 'os', 'setTimeout', 'setInterval', 'fetch', 'WeakRef',
          'FinalizationRegistry', 'Intl', 'print', 'scriptArgs', 'gc', 'leakedByEarlierRun'];
        text(absent.filter((name) => typeof globalThis[name] !== 'undefined').join(',') || 'none');
        const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'tools');
        text([Object.isFrozen(tools), descriptor.writable, descriptor.configurable].join(','));
        text(Object.keys(tools).sort().join(','));
        tools.read_file = () => 'hijacked';
        globalThis.tools = {};
        text(typeof tools.read_file === 'function' && tools.read_file.name === 'read_file');
        let imported = 'loaded';
        try { await import('fs'); } catch (error) { imported = 'rejected'; }
        text(imported);
        globalThis.leakedByEarlierRun = true;
        """
        let first = await run(script)
        XCTAssertEqual(first.status, .success, first.text)
        XCTAssertEqual(first.output, """
        none
        true,false,false
        file_search,get_code_structure,get_file_tree,read_file
        true
        rejected
        """)
        let second = await run("text(typeof globalThis.leakedByEarlierRun)")
        XCTAssertEqual(second.output, "undefined", "Each call gets a fresh runtime")
    }

    // MARK: - Interruption

    func testInfiniteLoopIsInterruptedAndEarlierCheckpointIsKept() async {
        let result = await run("text('before'); while (true) {}")
        XCTAssertEqual(result.status, .limitExceeded)
        XCTAssertEqual(result.reason, "cpu_time")
        XCTAssertEqual(result.output, "before")
        XCTAssertTrue(result.isError)
    }

    func testCaughtInterruptCannotResumeGuestCode() async {
        let result = await run("try { while (true) {} } catch (error) { text('caught'); } text('after')")
        XCTAssertEqual(result.reason, "cpu_time")
        XCTAssertEqual(result.output, "", "Stop errors are uncatchable")
    }

    func testPromiseJobAndMicrotaskLoopsAreInterrupted() async {
        let promiseLoop = await run("const spin = () => Promise.resolve().then(spin); spin(); await new Promise(() => {});")
        XCTAssertEqual(promiseLoop.reason, "cpu_time", promiseLoop.text)
        let microtaskLoop = await run("const spin = () => queueMicrotask(spin); spin(); await new Promise(() => {});")
        XCTAssertEqual(microtaskLoop.reason, "cpu_time", microtaskLoop.text)
    }

    func testGettersToJSONAndRegexRunInsideTheGuestBudget() async {
        let bridge = MCPCodeModeStubBridge()
        let getter = await run("await tools.read_file({ get path() { while (true) {} } })", bridge: bridge)
        XCTAssertEqual(getter.reason, "cpu_time")
        XCTAssertTrue(bridge.invocations.isEmpty)
        let toJSON = await run("text({ toJSON() { while (true) {} } })")
        XCTAssertEqual(toJSON.reason, "cpu_time")
        let regex = await run("text(/(a+)+$/.test('a'.repeat(40) + 'b'))")
        XCTAssertEqual(regex.reason, "cpu_time")
    }

    func testChildWaitingConsumesWallTimeButNotGuestCPU() async {
        let bridge = MCPCodeModeStubBridge { tool, arguments, _ in
            try await Task.sleep(for: .milliseconds(400))
            return MCPCodeModeStubBridge.success(tool: tool, arguments: arguments)
        }
        let result = await run(
            "for (let i = 0; i < 3; i++) await tools.read_file({ path: String(i) }); text('done')",
            limits: .testing(cpuMilliseconds: 200),
            bridge: bridge
        )
        XCTAssertEqual(result.status, .success, result.text)
        XCTAssertEqual(result.output, "done")
        XCTAssertEqual(result.counts.completed, 3)
    }

    func testWallTimeoutReturnsCheckpointCountsAndNoUnemittedChildData() async {
        let bridge = MCPCodeModeStubBridge { _, arguments, _ in
            if arguments["path"] == .string("slow") {
                try await Task.sleep(for: .seconds(30))
            }
            return MCPInProcessToolResult(
                value: .object(["secret": .string("UNEMITTED_CHILD_DATA")]),
                result: CallTool.Result(content: [.text(text: "UNEMITTED_CHILD_TEXT", annotations: nil, _meta: nil)], isError: false)
            )
        }
        let started = Date()
        let result = await run(
            "const fast = await tools.read_file({ path: 'fast' }); text('checkpoint'); await tools.read_file({ path: 'slow' }); text('unreachable')",
            limits: .testing(wallMilliseconds: 800),
            bridge: bridge
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result.status, .timeout)
        XCTAssertEqual(result.reason, "wall_time")
        XCTAssertEqual(result.output, "checkpoint")
        XCTAssertFalse(result.text.contains("UNEMITTED_CHILD"))
        XCTAssertEqual(result.counts.calls, 2)
        XCTAssertEqual(result.counts.completed, 1)
        XCTAssertEqual(result.counts.inFlightAtStop, 1)
        XCTAssertEqual(result.counts.calls, result.counts.completed + result.counts.queuedAtStop + result.counts.inFlightAtStop)
        XCTAssertTrue(result.text.hasSuffix("failed calls: none"))
        let cancelledSlowChild = await mcpCodeModeEventually { bridge.cancelledCount == 1 }
        XCTAssertTrue(cancelledSlowChild, "The in-flight child is cancelled once the runtime stops")
    }

    // MARK: - Memory, stack, output

    func testHeapAndStackExhaustionEndTheRunCleanly() async {
        let heap = await run(
            "text('start'); const kept = []; while (true) kept.push('x'.repeat(100000) + kept.length);",
            limits: .testing(cpuMilliseconds: 2000, heapBytes: 8 << 20)
        )
        XCTAssertEqual(heap.status, .limitExceeded, heap.text)
        XCTAssertEqual(heap.reason, "memory")
        XCTAssertEqual(heap.output, "start")
        let stack = await run("function f(n) { return f(n + 1) + 1; } f(0);")
        XCTAssertEqual(stack.status, .limitExceeded, stack.text)
        XCTAssertEqual(stack.reason, "stack")
        let caughtStack = await run("function f() { return f(); } try { f(); } catch (e) { text(e instanceof RangeError); }")
        XCTAssertEqual(caughtStack.status, .success, "A caught stack overflow is ordinary guest behavior")
        XCTAssertEqual(caughtStack.output, "true")
    }

    func testOutputOverflowEndsRunAndKeepsEveryAcceptedEntry() async {
        let result = await run(
            "text('a'.repeat(30)); console.log('b'.repeat(15), 'c'.repeat(14)); text('d'.repeat(30)); text('unreachable')",
            limits: .testing(outputBytes: 64)
        )
        XCTAssertEqual(result.status, .limitExceeded)
        XCTAssertEqual(result.reason, "output")
        XCTAssertEqual(result.output, String(repeating: "a", count: 30) + "\n" + String(repeating: "b", count: 15) + " " + String(repeating: "c", count: 14))
        XCTAssertTrue(result.text.contains("[code_mode] status: limit_exceeded (output)"))
    }

    func testRepeatedEmptyEntriesStopAtTheOutputLimit() async {
        let small = await run("for (let i = 0; i < 1000; i++) console.log(); text('unreachable')", limits: .testing(outputBytes: 8))
        XCTAssertEqual(small.status, .limitExceeded)
        XCTAssertEqual(small.reason, "output")
        XCTAssertEqual(small.output, String(repeating: "\n", count: 8), "Every separator counts against the limit")

        // The review's empty-entry PoC, safe once the separator is bounded: production limits.
        let production = await run("for (let i = 0; i < 30000; i++) console.log(); text('unreachable')", limits: .production)
        XCTAssertEqual(production.reason, "output")
        XCTAssertEqual(production.output.utf8.count, Int(MCPCodeModeLimits.production.outputBytes))
        XCTAssertLessThanOrEqual(production.text.utf8.count, MCPCodeModeLimits.finalResultBytes)
    }

    func testEmptyEntryOnAFullBufferStopsAndKeepsTheCheckpoint() async {
        let full = "text('x'.repeat(8)); "
        for emptyEntry in ["text()", "text(undefined)", "text(() => 1)", "console.log()", "console.log(undefined)"] {
            let result = await run(full + emptyEntry + "; text('unreachable')", limits: .testing(outputBytes: 8))
            XCTAssertEqual(result.status, .limitExceeded, emptyEntry)
            XCTAssertEqual(result.reason, "output", emptyEntry)
            XCTAssertEqual(result.output, String(repeating: "x", count: 8), emptyEntry)
        }
        // The top-level return value goes through the same check.
        let returnedFunction = await run(full + "return () => 1", limits: .testing(outputBytes: 8))
        XCTAssertEqual(returnedFunction.reason, "output")
        XCTAssertEqual(returnedFunction.output, String(repeating: "x", count: 8))
        let returnedUndefined = await run(full + "return undefined", limits: .testing(outputBytes: 8))
        XCTAssertEqual(returnedUndefined.status, .success, "No return value means no entry")
        let returnFits = await run("text('x'.repeat(7)); return () => 1", limits: .testing(outputBytes: 8))
        XCTAssertEqual(returnFits.status, .success, "An empty entry and its separator fill the last byte")
        XCTAssertEqual(returnFits.output, String(repeating: "x", count: 7) + "\n")
    }

    func testSeparatorCountsAtAnExactUTF8Boundary() async {
        let exact = await run("text('é'); text('é')", limits: .testing(outputBytes: 5))
        XCTAssertEqual(exact.status, .success)
        XCTAssertEqual(exact.output, "é\né")
        let thenEmpty = await run("text('é'); text('é'); console.log()", limits: .testing(outputBytes: 5))
        XCTAssertEqual(thenEmpty.reason, "output")
        XCTAssertEqual(thenEmpty.output, "é\né")
        let oneShort = await run("text('é'); text('é')", limits: .testing(outputBytes: 4))
        XCTAssertEqual(oneShort.reason, "output")
        XCTAssertEqual(oneShort.output, "é", "The second entry is refused whole, never split")
    }

    func testFinalTextStaysWithinThirtyTwoKiBIncludingFooter() async {
        let atLimit = await run("text('x'.repeat(\(MCPCodeModeLimits.production.outputBytes)))", limits: .production)
        XCTAssertEqual(atLimit.status, .success)
        XCTAssertLessThanOrEqual(atLimit.text.utf8.count, MCPCodeModeLimits.finalResultBytes)
        let overLimit = await run("text('x'.repeat(\(MCPCodeModeLimits.production.outputBytes + 1)))", limits: .production)
        XCTAssertEqual(overLimit.reason, "output")
        XCTAssertEqual(overLimit.output, "")
    }

    // MARK: - UTF-8 boundaries

    func testUTF8ScriptOutputArgumentAndResultBoundaries() async {
        XCTAssertEqual("text('éé')".utf8.count, 12)
        let fits = await run("text('éé')", limits: .testing(scriptBytes: 12))
        XCTAssertEqual(fits.status, .success, "12 UTF-8 bytes fit a 12-byte script limit")
        let tooLarge = await run("text('ééé')", limits: .testing(scriptBytes: 12))
        XCTAssertEqual(tooLarge.status, .limitExceeded)
        XCTAssertEqual(tooLarge.reason, "script_too_large")

        let exactOutput = await run("text('é'.repeat(5))", limits: .testing(outputBytes: 10))
        XCTAssertEqual(exactOutput.output, String(repeating: "é", count: 5))
        let splitOutput = await run("text('é'.repeat(6))", limits: .testing(outputBytes: 11))
        XCTAssertEqual(splitOutput.reason, "output")
        XCTAssertEqual(splitOutput.output, "", "A character is never split and an entry is never partial")
        let surrogate = await run("text('\\uD800x')")
        XCTAssertEqual(surrogate.output, "\u{FFFD}x")

        let bridge = MCPCodeModeStubBridge()
        let arguments = await run(
            "try { await tools.read_file({ path: 'é'.repeat(20) }); } catch (e) { text(e instanceof RangeError); }",
            limits: .testing(argumentBytes: 32),
            bridge: bridge
        )
        XCTAssertEqual(arguments.output, "true")
        XCTAssertTrue(bridge.invocations.isEmpty, "Oversized arguments never dispatch a child")

        let bigResult = MCPCodeModeStubBridge { _, _, _ in
            MCPInProcessToolResult(
                value: .object(["blob": .string(String(repeating: "é", count: 100))]),
                result: CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)], isError: false)
            )
        }
        let result = await run(
            "try { await tools.read_file({}); } catch (e) { text(e.code); }",
            limits: .testing(resultBytes: 64),
            bridge: bigResult
        )
        XCTAssertEqual(result.output, "child_result_too_large")
        XCTAssertEqual(result.status, .childFailure)
        XCTAssertEqual(result.failedCalls.map(\.code), ["child_result_too_large"])
    }

    // MARK: - Arguments, promises, errors

    func testArgumentValidationAndPromisePrinting() async {
        let bridge = MCPCodeModeStubBridge()
        let result = await run(
            """
            const outcomes = [];
            for (const bad of [null, 7, 'path', [1], () => 1]) {
              try { await tools.read_file(bad); outcomes.push('ok'); } catch (e) { outcomes.push(e.name); }
            }
            const cyclic = {}; cyclic.self = cyclic;
            try { await tools.read_file(cyclic); } catch (e) { outcomes.push(e.name); }
            try { text(Promise.resolve(1)); } catch (e) { outcomes.push(e.name); }
            const omitted = await tools.get_file_tree();
            outcomes.push(Object.keys(omitted.data.arguments).length);
            text(outcomes.join(','));
            """,
            bridge: bridge
        )
        XCTAssertEqual(result.output, "TypeError,TypeError,TypeError,TypeError,TypeError,TypeError,TypeError,0")
        XCTAssertEqual(bridge.invocations, [.init(tool: "get_file_tree", arguments: [:])])
    }

    func testScriptErrorsAndReturnValue() async {
        let thrown = await run("text('kept'); throw new Error('boom')")
        XCTAssertEqual(thrown.status, .scriptError)
        XCTAssertEqual(thrown.reason, "script_exception")
        XCTAssertEqual(thrown.message, "Error: boom")
        XCTAssertEqual(thrown.output, "kept")
        let syntax = await run("this is not javascript")
        XCTAssertEqual(syntax.status, .scriptError)
        let returned = await run("return { total: 3 }")
        XCTAssertEqual(returned.status, .success)
        XCTAssertEqual(returned.output, "{\n \"total\": 3\n}")
    }

    func testNeverSettlingPromiseEndsImmediately() async {
        let started = Date()
        let result = await run("text('waiting'); await new Promise(() => {});", limits: .testing(wallMilliseconds: 10000))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(result.status, .scriptError)
        XCTAssertEqual(result.reason, "unsettleable_promise")
        XCTAssertEqual(result.output, "waiting")
    }

    func testUnawaitedChildrenAreDrainedAndCountedAfterTheScriptSettles() async {
        let bridge = MCPCodeModeStubBridge { tool, arguments, _ in
            try await Task.sleep(for: .milliseconds(100))
            return MCPCodeModeStubBridge.success(tool: tool, arguments: arguments)
        }
        let result = await run("tools.read_file({ path: 'a' }); tools.read_file({ path: 'b' }); tools.read_file({ path: 'c' }); text('returned')", bridge: bridge)
        XCTAssertEqual(result.status, .success, result.text)
        XCTAssertEqual(result.counts.calls, 3)
        XCTAssertEqual(result.counts.completed, 3)
        XCTAssertEqual(bridge.invocations.count, 3)
    }

    // MARK: - Replies and lifecycle

    func testStaleDuplicateUnknownLateAndMalformedRepliesAreFenced() async throws {
        let runtime = try MCPCodeModeRuntime(
            script: """
            const first = await tools.read_file({ path: 'a' });
            let second;
            try { await tools.read_file({ path: 'b' }); } catch (e) { second = e.code; }
            text(first.text + ',' + second);
            """,
            limits: .testing()
        )
        let (requests, sink) = AsyncStream.makeStream(of: MCPCodeModeChildRequest.self)
        try runtime.start { sink.yield($0) }
        var iterator = requests.makeAsyncIterator()

        let firstRequest = await iterator.next()
        let first = try XCTUnwrap(firstRequest)
        XCTAssertEqual(first.tool, .readFile)
        XCTAssertEqual(String(decoding: first.argumentsJSON, as: UTF8.self), #"{"path":"a"}"#)
        XCTAssertEqual(runtime.submitReply(callID: first.callID, attempt: 2, reply: .ok("x")), .notAccepted, "stale attempt")
        XCTAssertEqual(runtime.submitReply(callID: 99, attempt: 1, reply: .ok("x")), .notAccepted, "unknown call")
        XCTAssertEqual(runtime.submitReply(callID: first.callID, attempt: 1, reply: .ok("one")), .accepted)
        XCTAssertEqual(runtime.submitReply(callID: first.callID, attempt: 1, reply: .ok("dup")), .notAccepted, "duplicate")

        let secondRequest = await iterator.next()
        let second = try XCTUnwrap(secondRequest)
        let malformed = MCPCodeModeReply(disposition: .success, payloadJSON: Data("not json".utf8), failureCode: nil)
        XCTAssertEqual(runtime.submitReply(callID: second.callID, attempt: 1, reply: malformed), .accepted)

        guard case let .finished(outcome) = await runtime.awaitCompletion() else { return XCTFail("finished") }
        XCTAssertEqual(outcome.status, .success)
        XCTAssertEqual(outcome.output, "one,bridge_malformed_reply")
        XCTAssertEqual(outcome.failedCalls.map(\.code), ["bridge_malformed_reply"])
        XCTAssertEqual(runtime.submitReply(callID: second.callID, attempt: 1, reply: .ok("late")), .notAccepted, "late")
        XCTAssertTrue(runtime.isStopRequested)
    }

    func testRepeatedStartStopJoinReleasesEveryRuntime() async throws {
        weak var lastRuntime: MCPCodeModeRuntime?
        for iteration in 0 ..< 25 {
            let runtime = try MCPCodeModeRuntime(
                script: "text('\(iteration)'); await tools.read_file({ path: 'slow' }); text('unreachable')",
                limits: .testing()
            )
            lastRuntime = runtime
            let (requests, sink) = AsyncStream.makeStream(of: MCPCodeModeChildRequest.self)
            try runtime.start { sink.yield($0) }
            var iterator = requests.makeAsyncIterator()
            let nextRequest = await iterator.next()
            let request = try XCTUnwrap(nextRequest)
            runtime.requestStop()
            runtime.requestStop()
            guard case let .finished(outcome) = await runtime.awaitCompletion() else { return XCTFail("finished") }
            XCTAssertEqual(outcome.status, .cancelled)
            XCTAssertEqual(outcome.output, "\(iteration)")
            XCTAssertEqual(outcome.counts.inFlightAtStop, 1)
            XCTAssertEqual(runtime.submitReply(callID: request.callID, attempt: 1, reply: .ok("late")), .notAccepted)
        }
        let released = await mcpCodeModeEventually { lastRuntime == nil }
        XCTAssertTrue(released, "A joined runtime is released with its host")

        let neverStarted = try MCPCodeModeRuntime(script: "text(1)", limits: .testing())
        XCTAssertEqual(neverStarted.submitReply(callID: 1, attempt: 1, reply: .ok("x")), .notAccepted)
    }

    func testOwnerExitRunsOnceBeforeFinishedCompletion() async throws {
        let log = MCPCodeModeEventLog()
        let runtime = try MCPCodeModeRuntime(script: "text('x')", limits: .testing())
        try runtime.start(onChildRequest: { _ in }, onOwnerExit: { log.append("ownerExit") })
        guard case let .finished(outcome) = await runtime.awaitCompletion() else { return XCTFail("finished") }
        log.append("completion")
        XCTAssertEqual(outcome.output, "x")
        XCTAssertEqual(log.events, ["ownerExit", "completion"])
    }

    func testCleanupDeadlineKeepsCommittedProgressAndDefersOwnerExitUntilTheThreadExits() async throws {
        let gate = MCPCodeModeOwnerExitGate()
        let log = MCPCodeModeEventLog()
        var runtime: MCPCodeModeRuntime? = try MCPCodeModeRuntime(
            script: "text('checkpoint'); await tools.read_file({ path: 'a' }); text('unreachable')",
            limits: .testing(),
            cleanupAllowance: .milliseconds(100),
            ownerExitGate: gate.hold
        )
        weak var weakRuntime = runtime
        let (requests, sink) = AsyncStream.makeStream(of: MCPCodeModeChildRequest.self)
        try runtime?.start(onChildRequest: { sink.yield($0) }, onOwnerExit: { log.append("ownerExit") })
        var iterator = requests.makeAsyncIterator()
        let nextRequest = await iterator.next()
        let request = try XCTUnwrap(nextRequest)

        // The owner tears QuickJS down, then is held at exit past the stop + allowance deadline.
        runtime?.requestStop()
        let completion = await runtime?.awaitCompletion()
        log.append("completion")
        XCTAssertTrue(gate.entered.isSet, "The deadline fired while the owner thread was still alive")
        XCTAssertEqual(completion, .cleanupTimedOut(MCPCodeModeRuntimeProgress(
            output: "checkpoint",
            counts: .init(calls: 1, attempts: 1, completed: 0, failed: 0, queuedAtStop: 0, inFlightAtStop: 1, retries: 0)
        )))
        XCTAssertEqual(runtime?.submitReply(callID: request.callID, attempt: 1, reply: .ok("late")), .notAccepted)
        XCTAssertEqual(log.events, ["completion"], "No owner exit is reported while the thread runs")

        runtime = nil
        XCTAssertNotNil(weakRuntime, "The owner thread keeps its runtime and host alive")
        gate.open()
        let exited = await mcpCodeModeEventually { log.events == ["completion", "ownerExit"] }
        XCTAssertTrue(exited, "Owner exit is reported exactly once, after the thread exits: \(log.events)")
        let released = await mcpCodeModeEventually { weakRuntime == nil }
        XCTAssertTrue(released, "The host is joined and destroyed only once its owner thread exits")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log.events, ["completion", "ownerExit"])
    }

    func testInvalidLimitsAreRejected() {
        var limits = MCPCodeModeLimits.production
        limits.maxInFlight = 3
        XCTAssertThrowsError(try MCPCodeModeRuntime(script: "", limits: limits)) { error in
            XCTAssertEqual(error as? MCPCodeModeRuntimeError, .invalidLimits)
        }
        limits = .production
        limits.wallMilliseconds = 0
        XCTAssertThrowsError(try MCPCodeModeRuntime(script: "", limits: limits))
    }
}

private extension MCPCodeModeReply {
    static func ok(_ text: String) -> MCPCodeModeReply {
        MCPCodeModeReply(disposition: .success, payloadJSON: Data(#"{"text":"\#(text)","isError":false}"#.utf8), failureCode: nil)
    }
}
