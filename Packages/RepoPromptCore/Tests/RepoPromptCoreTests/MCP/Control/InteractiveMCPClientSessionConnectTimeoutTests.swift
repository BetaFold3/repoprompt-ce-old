import Foundation
import MCP
import RepoPromptMCPClientKit
@testable import RepoPromptMCPCore
import RepoPromptShared
import XCTest

#if DEBUG
    final class InteractiveMCPClientSessionConnectTimeoutTests: XCTestCase {
        func testInitializationReturnsConnectResultAndDrainsCancelledTimeoutTask() async throws {
            let fixture = try await makeFixture()
            let timeoutCancelled = CLIConnectSignal()
            do {
                let result = try await InteractiveMCPClientSession.debugAwaitInitialization(
                    timeoutNanoseconds: UInt64.max,
                    timeoutSleep: { _ in
                        do {
                            try await Task.sleep(nanoseconds: UInt64.max)
                        } catch {
                            await timeoutCancelled.signal()
                            throw error
                        }
                    }
                ) {
                    try await fixture.client.connect(transport: fixture.clientTransport)
                }

                XCTAssertEqual(result.serverInfo.name, "CLI connect timeout test server")
                let didCancelTimeout = await timeoutCancelled.isSignalled()
                XCTAssertTrue(didCancelTimeout)
                await fixture.cleanup()
            } catch {
                await fixture.cleanup()
                throw error
            }
        }

        func testInitializationTimeoutCancelsConnectOperation() async throws {
            let operationStarted = CLIConnectSignal()
            let operationCancelled = CLIConnectSignal()

            do {
                _ = try await InteractiveMCPClientSession.debugAwaitInitialization(
                    timeoutNanoseconds: 1,
                    timeoutSleep: { _ in
                        await operationStarted.wait()
                    }
                ) {
                    await operationStarted.signal()
                    do {
                        try await Task.sleep(nanoseconds: UInt64.max)
                    } catch {
                        await operationCancelled.signal()
                        throw error
                    }
                    fatalError("Cancelled initialization operation unexpectedly returned")
                }
                XCTFail("Expected initialization timeout")
            } catch let error as InteractiveSessionError {
                guard case .bootstrapResponseTimeout = error else {
                    XCTFail("Expected bootstrap response timeout, got \(error)")
                    return
                }
            }

            let didStartOperation = await operationStarted.isSignalled()
            let didCancelOperation = await operationCancelled.isSignalled()
            XCTAssertTrue(didStartOperation)
            XCTAssertTrue(didCancelOperation)
        }

        func testCallerCancellationCancelsConnectAndTimeoutTasks() async throws {
            let operationStarted = CLIConnectSignal()
            let operationCancelled = CLIConnectSignal()
            let timeoutCancelled = CLIConnectSignal()

            let initialization = Task {
                try await InteractiveMCPClientSession.debugAwaitInitialization(
                    timeoutNanoseconds: UInt64.max,
                    timeoutSleep: { _ in
                        do {
                            try await Task.sleep(nanoseconds: UInt64.max)
                        } catch {
                            await timeoutCancelled.signal()
                            throw error
                        }
                    }
                ) {
                    await operationStarted.signal()
                    do {
                        try await Task.sleep(nanoseconds: UInt64.max)
                    } catch {
                        await operationCancelled.signal()
                        throw error
                    }
                    fatalError("Cancelled initialization operation unexpectedly returned")
                }
            }

            await operationStarted.wait()
            initialization.cancel()

            do {
                _ = try await initialization.value
                XCTFail("Expected caller cancellation")
            } catch is CancellationError {
                // Expected.
            }

            let didCancelOperation = await operationCancelled.isSignalled()
            let didCancelTimeout = await timeoutCancelled.isSignalled()
            XCTAssertTrue(didCancelOperation)
            XCTAssertTrue(didCancelTimeout)
        }

        func testDelayedBootstrapResponseReportsPhaseAndClosesDescriptor() async throws {
            let pair = try makeSocketPair()
            defer { Darwin.close(pair.peer) }
            let clock = CLIStartupClock()
            let session = InteractiveMCPClientSession(sessionToken: "test", clientName: "test")
            await session.debugConfigureStartup(
                connectedFD: pair.client,
                now: { clock.now() },
                phaseObserver: { phase in
                    if phase == .bootstrapResponse { clock.expireResponseDeadline() }
                }
            )
            do {
                try await session.connect(fetchInitialTools: false)
                XCTFail("Expected bootstrap timeout")
            } catch let error as InteractiveSessionError {
                guard case .bootstrapResponseTimeout = error else { return XCTFail("Unexpected \(error)") }
                XCTAssertEqual(error.description, "Timed out waiting for RepoPrompt bootstrap response")
            }
            let timings = await session.startupTimings
            XCTAssertEqual(timings.map(\.phase), [.connect, .bootstrapWrite, .bootstrapResponse])
            XCTAssertEqual(timings.last?.outcome, .timedOut)
            XCTAssertEqual(timings.last?.elapsed, 5)
            XCTAssertEqual(timings.last?.budget, 5)
            XCTAssertTrue(try XCTUnwrap(timings.last).description.hasSuffix("phase=bootstrap_response outcome=timed_out elapsed_s=5.000 budget_s=5.000 budget_kind=deadline"))
            XCTAssertTrue(try XCTUnwrap(timings.last).description.contains("started_at_utc="))
            await assertDescriptorClosed(pair.client)
        }

        func testDelayedInitializeReportsPhaseAndClosesDescriptor() async throws {
            let pair = try makeSocketPair()
            defer { Darwin.close(pair.peer) }
            let initializeReceived = CLIConnectSignal()
            let clock = CLIStartupClock()
            let peer = Task.detached {
                do {
                    _ = try Self.readLine(fd: pair.peer)
                    try Self.acceptBootstrap(fd: pair.peer)
                    let initialize = try Self.readLine(fd: pair.peer)
                    XCTAssertTrue(initialize.contains("\"initialize\""))
                    await initializeReceived.signal()
                    // Deliberately withhold the initialize response.
                } catch {
                    // Release the injected timer even when the bounded fixture read fails.
                    await initializeReceived.signal()
                    throw error
                }
            }
            let session = InteractiveMCPClientSession(sessionToken: "test", clientName: "test")
            await session.debugConfigureStartup(
                connectedFD: pair.client,
                now: { clock.now() },
                timeoutSleep: { budget in
                    XCTAssertEqual(budget, 10_000_000_000)
                    await initializeReceived.wait()
                    clock.advance(to: 10)
                },
                cancellationDidDisconnect: { clock.advance(to: 30) }
            )
            do {
                try await session.connect(fetchInitialTools: false)
                XCTFail("Expected initialize timeout")
            } catch let error as InteractiveSessionError {
                guard case .bootstrapResponseTimeout = error else { return XCTFail("Unexpected \(error)") }
            }
            try await peer.value
            let timings = await session.startupTimings
            XCTAssertEqual(timings.map(\.phase), [.connect, .bootstrapWrite, .bootstrapResponse, .mcpInitialize])
            XCTAssertEqual(timings.last?.outcome, .timedOut)
            XCTAssertEqual(timings.last?.elapsed, 10)
            XCTAssertEqual(timings.last?.budget, 10)
            XCTAssertEqual(clock.now(), 30, "Cancellation drainage must finish without extending the measured phase")
            await assertDescriptorClosed(pair.client)
        }

        func testCallerCancellationIsNotTimeoutAndClosesDescriptorInEachWaitingPhase() async throws {
            for phase in [CLIStartupTiming.Phase.bootstrapResponse, .mcpInitialize] {
                let pair = try makeSocketPair()
                let phaseReached = expectation(description: phase.rawValue)
                let peer: Task<Void, Error>? = phase == .mcpInitialize ? Task.detached {
                    defer { phaseReached.fulfill() }
                    _ = try Self.readLine(fd: pair.peer)
                    try Self.acceptBootstrap(fd: pair.peer)
                    let initialize = try Self.readLine(fd: pair.peer)
                    XCTAssertTrue(initialize.contains("\"initialize\""))
                } : nil
                let session = InteractiveMCPClientSession(sessionToken: "test", clientName: "test")
                await session.debugConfigureStartup(connectedFD: pair.client, phaseObserver: {
                    if phase == .bootstrapResponse, $0 == phase { phaseReached.fulfill() }
                })
                let connect = Task { try await session.connect(fetchInitialTools: false) }
                await fulfillment(of: [phaseReached], timeout: 2)
                connect.cancel()
                do {
                    try await connect.value
                    XCTFail("Expected cancellation")
                } catch is CancellationError {
                    XCTAssertEqual(phase, .mcpInitialize)
                } catch let error as InteractiveSessionError {
                    guard case .cancelled = error else { return XCTFail("Unexpected \(error)") }
                    XCTAssertEqual(phase, .bootstrapResponse)
                }
                try await peer?.value
                let timing = await session.startupTimings.last
                XCTAssertEqual(timing?.phase, phase)
                XCTAssertEqual(timing?.outcome, .cancelled)
                XCTAssertEqual(timing?.budget, phase == .mcpInitialize ? 10 : 5)
                await assertDescriptorClosed(pair.client)
                Darwin.close(pair.peer)
            }
        }

        func testSuccessfulStartupPreservesToolDispatchAndDisconnectCleanup() async throws {
            let pair = try makeSocketPair()
            let server = Server(name: "Startup test server", version: "1", capabilities: .init(tools: .init()))
            await server.withMethodHandler(CallTool.self) { request in
                XCTAssertEqual(request.name, "echo")
                return CallTool.Result(content: [.text(text: "unchanged", annotations: nil, _meta: nil)])
            }
            let peer = Task.detached {
                _ = try Self.readLine(fd: pair.peer)
                try Self.acceptBootstrap(fd: pair.peer)
                let transport = try BootstrapSocketMCPTransport(connectedFD: pair.peer)
                try await server.start(transport: transport)
            }
            let session = InteractiveMCPClientSession(sessionToken: "test", clientName: "test")
            await session.debugConfigureStartup(connectedFD: pair.client)
            do {
                try await session.connect(fetchInitialTools: false)
                try await peer.value
                let result = try await session.callTool(name: "echo", arguments: nil)
                XCTAssertEqual(result.content, [.text(text: "unchanged", annotations: nil, _meta: nil)])
                let timings = await session.startupTimings
                XCTAssertEqual(timings.map(\.phase), [.connect, .bootstrapWrite, .bootstrapResponse, .mcpInitialize])
                XCTAssertTrue(timings.allSatisfy { $0.outcome == .completed })
                XCTAssertNil(timings.first?.budget)
                XCTAssertEqual(timings[1].budget, 5)
                await session.disconnect()
                await server.stop()
                await assertDescriptorClosed(pair.client)
            } catch {
                await session.disconnect()
                await server.stop()
                throw error
            }
        }

        private func makeSocketPair() throws -> (client: Int32, peer: Int32) {
            var fds: [Int32] = [-1, -1]
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                throw POSIXError(.ENFILE)
            }
            // Keep the observed descriptor above Foundation/XCTest's incidental low-FD
            // allocations, which can reuse a just-closed socket before the assertion.
            let client = fcntl(fds[0], F_DUPFD_CLOEXEC, 256)
            Darwin.close(fds[0])
            guard client >= 0 else {
                Darwin.close(fds[1])
                throw POSIXError(.EMFILE)
            }
            var noSigPipe: Int32 = 1
            setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            return (client, fds[1])
        }

        private func assertDescriptorClosed(_ fd: Int32, file: StaticString = #filePath, line: UInt = #line) async {
            // DispatchSource cancellation closes asynchronously. Yield until that callback
            // finishes; the deadline bounds a regression without relying on an arbitrary sleep.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while fcntl(fd, F_GETFD) != -1, clock.now < deadline {
                await Task.yield()
            }
            XCTAssertEqual(fcntl(fd, F_GETFD), -1, file: file, line: line)
            XCTAssertEqual(errno, EBADF, file: file, line: line)
        }

        private static func readLine(fd: Int32) throws -> String {
            var data = Data()
            var byte: UInt8 = 0
            while true {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 2000) > 0, Darwin.read(fd, &byte, 1) == 1 else {
                    throw POSIXError(.ETIMEDOUT)
                }
                if byte == 10 { return String(decoding: data, as: UTF8.self) }
                data.append(byte)
            }
        }

        private static func acceptBootstrap(fd: Int32) throws {
            var data = try JSONEncoder().encode(MCPBootstrapResponse.accepted())
            data.append(10)
            try NonBlockingFDWriter.writeAll(data, to: fd, stallTimeout: 2)
        }

        private func makeFixture() async throws -> CLIConnectFixture {
            let transports = await InMemoryTransport.createConnectedPair()
            let server = Server(
                name: "CLI connect timeout test server",
                version: "1.0",
                capabilities: .init()
            )
            try await server.start(transport: transports.server)
            let client = Client(name: "CLI connect timeout test client", version: "1.0")
            return CLIConnectFixture(
                client: client,
                server: server,
                clientTransport: transports.client
            )
        }
    }

    private struct CLIConnectFixture {
        let client: Client
        let server: Server
        let clientTransport: InMemoryTransport

        func cleanup() async {
            await client.disconnect()
            await server.stop()
        }
    }

    private final class CLIStartupClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        private var responseReads: Int?

        func now() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            if let reads = responseReads {
                responseReads = reads + 1
                // First read establishes the unchanged five-second response deadline.
                if reads > 0 { value = 5 }
            }
            return value
        }

        func expireResponseDeadline() {
            lock.lock()
            defer { lock.unlock() }
            responseReads = 0
        }

        func advance(to value: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            self.value = value
        }
    }

    private actor CLIConnectSignal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            guard !signalled else { return }
            signalled = true
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func wait() async {
            guard !signalled else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func isSignalled() -> Bool {
            signalled
        }
    }
#endif
