import Darwin
import Foundation
@testable import RepoPromptMCPCore
import RepoPromptShared
import XCTest

final class MCPProxyTerminalRecordTests: XCTestCase {
    func testHostInputFailuresExitWithoutRetryAndRetainHostProvenance() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "host-input-test")
        _ = try await ledger.beginConnection()
        let snapshot = await ledger.snapshot()

        let cases: [(reason: CLIHostDisconnectProvenance.Reason, errno: Int32, failure: () throws -> Void)] = [
            (.stdinPollFailed, EBADF, { try validateCLIHostInputPollResult(-1, errno: EBADF) }),
            (.stdinReadFailed, EIO, { try validateCLIHostInputReadResult(-1, errno: EIO) })
        ]

        for testCase in cases {
            let runtimeError: CLIRuntimeError
            do {
                try testCase.failure()
                XCTFail("Expected host input validation to fail")
                continue
            } catch let error as CLIRuntimeError {
                runtimeError = error
            } catch {
                XCTFail("Unexpected host input validation error: \(error)")
                continue
            }
            guard case let .hostDisconnected(provenance) = runtimeError else {
                return XCTFail("Expected host-disconnected runtime error")
            }

            XCTAssertEqual(provenance.reason, testCase.reason)
            XCTAssertEqual(provenance.errno, testCase.errno)
            XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: runtimeError))
            XCTAssertEqual(mcpCLIExitCode(for: runtimeError), .ok)
            XCTAssertFalse(CLIEventLogger.shouldPersistEvent(for: runtimeError))

            let record = CLIProxyRuntimePolicy.makeTerminalRecord(
                sessionToken: "host-input-session",
                localPID: 101,
                initialParentPID: 202,
                ledgerSnapshot: snapshot,
                runtimeError: runtimeError,
                fallbackReason: "unexpected_fallback"
            )
            XCTAssertEqual(record.layer, .proxy)
            XCTAssertEqual(record.initiator, .host)
            XCTAssertEqual(record.reason, testCase.reason.rawValue)
            XCTAssertEqual(record.errno, testCase.errno)
            XCTAssertTrue(record.errorDescription?.contains("errno=\(testCase.errno)") == true)
        }

        XCTAssertNoThrow(try validateCLIHostInputPollResult(-1, errno: EINTR))
        XCTAssertNoThrow(try validateCLIHostInputReadResult(-1, errno: EAGAIN))
        XCTAssertNoThrow(try validateCLIHostInputReadResult(-1, errno: EINTR))
    }

    func testSocketReadFailureRemainsRetryablePeerTransportFailure() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "socket-read-test")
        _ = try await ledger.beginConnection()
        let runtimeError = CLIRuntimeError.connectionFailed(
            underlying: SocketProxyError.readFailed(errno: ECONNRESET)
        )

        XCTAssertTrue(CLIProxyRuntimePolicy.shouldRetry(after: runtimeError))
        XCTAssertEqual(CLIProxyRuntimePolicy.failureReason(for: runtimeError), "socket_read_failed")

        let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "socket-read-session",
            localPID: 303,
            initialParentPID: 404,
            ledgerSnapshot: ledger.snapshot(),
            runtimeError: runtimeError,
            fallbackReason: "unexpected_fallback"
        )
        XCTAssertEqual(record.initiator, .peer)
        XCTAssertEqual(record.reason, "socket_read_failed")
        XCTAssertEqual(record.errno, ECONNRESET)
    }

    func testAppSocketClosedRemainsRetryablePeerTransportFailure() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "socket-closed-test")
        _ = try await ledger.beginConnection()
        let runtimeError = CLIRuntimeError.connectionFailed(
            underlying: SocketProxyError.serverClosed
        )

        XCTAssertTrue(CLIProxyRuntimePolicy.shouldRetry(after: runtimeError))
        XCTAssertEqual(CLIProxyRuntimePolicy.failureReason(for: runtimeError), "app_socket_closed")

        let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "socket-closed-session",
            localPID: 303,
            initialParentPID: 404,
            ledgerSnapshot: ledger.snapshot(),
            runtimeError: runtimeError,
            fallbackReason: "unexpected_fallback"
        )
        XCTAssertEqual(record.initiator, .peer)
        XCTAssertEqual(record.reason, "app_socket_closed")
    }

    func testLocalSocketReadFailureIsAttributedToTransport() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "local-read-test")
        _ = try await ledger.beginConnection()
        let runtimeError = CLIRuntimeError.connectionFailed(
            underlying: SocketProxyError.readFailed(errno: EIO)
        )

        let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "local-read-session",
            localPID: 303,
            initialParentPID: 404,
            ledgerSnapshot: ledger.snapshot(),
            runtimeError: runtimeError,
            fallbackReason: "unexpected_fallback"
        )
        XCTAssertEqual(record.initiator, .transport)
        XCTAssertEqual(record.reason, "socket_read_failed")
        XCTAssertEqual(record.errno, EIO)
    }

    func testCancellationNormalizesToStableHostTaskProvenance() async throws {
        let runtimeError = try XCTUnwrap(
            CLIProxyRuntimePolicy.normalizedTerminalRuntimeError(for: CancellationError())
        )
        guard case let .hostDisconnected(provenance) = runtimeError else {
            return XCTFail("Expected host-disconnected cancellation provenance")
        }
        XCTAssertEqual(provenance.reason, .taskCancelled)
        XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: runtimeError))

        let ledger = JSONRPCBridgeLedger(connectionID: "cancelled-proxy-test")
        _ = try await ledger.beginConnection()
        let record = await CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "cancelled-proxy-session",
            localPID: 505,
            initialParentPID: 606,
            ledgerSnapshot: ledger.snapshot(),
            runtimeError: runtimeError,
            fallbackReason: "proxy_unexpected_error"
        )
        XCTAssertEqual(record.initiator, .host)
        XCTAssertEqual(record.reason, CLIHostDisconnectProvenance.Reason.taskCancelled.rawValue)
        XCTAssertNotEqual(record.reason, "proxy_unexpected_error")
    }

    func testProxyTaskGroupOutcomesClassifyCleanCompletionAndCancellation() throws {
        XCTAssertNil(MCPServiceProxyTaskGroupPolicy.terminalRuntimeError(
            firstCompletedOutcome: .transportCompleted,
            serviceTaskIsCancelled: false
        ))

        let cancelledOutcomes: [(MCPServiceProxyTaskOutcome, Bool)] = [
            (.transportCompleted, true),
            (.killSignalWaitCancelled, false),
            (.ppidWatchdogCancelled, false)
        ]
        for (outcome, serviceTaskIsCancelled) in cancelledOutcomes {
            let runtimeError = try XCTUnwrap(MCPServiceProxyTaskGroupPolicy.terminalRuntimeError(
                firstCompletedOutcome: outcome,
                serviceTaskIsCancelled: serviceTaskIsCancelled
            ))
            guard case let .hostDisconnected(provenance) = runtimeError else {
                return XCTFail("Expected host-disconnected cancellation for \(outcome)")
            }
            XCTAssertEqual(provenance.reason, .taskCancelled)
        }
    }

    func testTerminalRecordCopiesLiveLedgerSnapshotAndServerReason() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "terminal-record-test")
        _ = try await ledger.beginConnection()
        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_file"}}"#.utf8)
        let prepared = try await ledger.prepare(frame: request, direction: .clientToServer)
        try await ledger.commit(prepared)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 1)
        XCTAssertTrue(snapshot.hasForwardedProtocolFrame)

        let runtimeError = CLIRuntimeError.terminatedByServer(CLIServerTerminationProvenance(
            reason: .runCompleted,
            message: "Run completed"
        ))
        let record = CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "terminal-record-session",
            localPID: 505,
            initialParentPID: 606,
            ledgerSnapshot: snapshot,
            runtimeError: runtimeError,
            fallbackReason: "unexpected_fallback"
        )

        XCTAssertEqual(record.initiator, .app)
        XCTAssertEqual(record.reason, TerminationReason.runCompleted.rawValue)
        XCTAssertEqual(record.localPID, 505)
        XCTAssertEqual(record.peerPID, 606)
        XCTAssertEqual(record.connectionGeneration, snapshot.connectionGeneration)
        XCTAssertEqual(record.bridgeActiveRequestCount, snapshot.activeRequestCount)
        XCTAssertEqual(record.bridgeResponseInDeliveryCount, snapshot.responseInDeliveryCount)
        XCTAssertEqual(record.bridgeCancellationTombstoneCount, snapshot.cancellationTombstoneCount)
        XCTAssertEqual(record.bridgeRecentCompletionCount, snapshot.recentCompletionCount)
        XCTAssertEqual(record.bridgePendingTransactionCount, snapshot.pendingTransactionCount)
        XCTAssertEqual(record.bridgeHasForwardedProtocolFrame, snapshot.hasForwardedProtocolFrame)
        XCTAssertEqual(record.errorDescription, "Run completed")
    }

    // MARK: - Proxy launch preflight (real descriptors, offline fixtures)

    func testPreflightProceedsForLiveHostPipeAndSocketBeforeFirstFrame() throws {
        // Delayed open: the host holds the write end open but has not sent initialize yet.
        let stdinPipe = try makePipe()
        let stdoutPipe = try makePipe()
        defer { closeAll(stdinPipe, stdoutPipe) }
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: stdinPipe.read, stdoutFD: stdoutPipe.write, hasNoUserArgs: true),
            .proceed
        )

        let socket = try makeSocketPair()
        defer { closeAll(socket) }
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: socket.read, stdoutFD: stdoutPipe.write, hasNoUserArgs: true),
            .proceed
        )
    }

    func testPreflightRejectsEOFInvalidAndNonTransportStdinAsNonInteractive() throws {
        let stdoutPipe = try makePipe()
        defer { closeAll(stdoutPipe) }

        let eofPipe = try makePipe()
        defer { Darwin.close(eofPipe.read) }
        Darwin.close(eofPipe.write)
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: eofPipe.read, stdoutFD: stdoutPipe.write, hasNoUserArgs: true),
            .rejectNonInteractive,
            "pipe whose writer closed"
        )

        let eofSocket = try makeSocketPair()
        defer { Darwin.close(eofSocket.read) }
        Darwin.close(eofSocket.write)
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: eofSocket.read, stdoutFD: stdoutPipe.write, hasNoUserArgs: true),
            .rejectNonInteractive,
            "socket whose peer closed"
        )

        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: -1, stdoutFD: stdoutPipe.write, hasNoUserArgs: true),
            .rejectNonInteractive,
            "invalid descriptor"
        )

        let devNull = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(devNull, 0)
        defer { Darwin.close(devNull) }
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: devNull, stdoutFD: stdoutPipe.write, hasNoUserArgs: true),
            .rejectNonInteractive,
            "character device"
        )

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPProxyPreflight-\(UUID().uuidString).txt")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let regularFile = Darwin.open(fileURL.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(regularFile, 0)
        defer { Darwin.close(regularFile) }
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: regularFile, stdoutFD: stdoutPipe.write, hasNoUserArgs: true),
            .rejectNonInteractive,
            "regular file"
        )
    }

    func testPreflightTTYRejectsFirstAndUserArgsBypassTransportProbes() throws {
        let tty = try makeTTY()
        defer { closeAll(tty) }
        let eofPipe = try makePipe()
        defer { Darwin.close(eofPipe.read) }
        Darwin.close(eofPipe.write)
        let stdoutPipe = try makePipe()
        defer { closeAll(stdoutPipe) }

        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: tty.slave, stdoutFD: stdoutPipe.write, hasNoUserArgs: true),
            .rejectTTY
        )
        // A TTY stdout wins even when stdin would otherwise be a non-interactive rejection.
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: eofPipe.read, stdoutFD: tty.slave, hasNoUserArgs: true),
            .rejectTTY
        )
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: tty.slave, stdoutFD: tty.slave, hasNoUserArgs: false),
            .rejectTTY
        )

        // User args skip the transport probes entirely.
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: eofPipe.read, stdoutFD: stdoutPipe.write, hasNoUserArgs: false),
            .proceed
        )
        XCTAssertEqual(
            classifyProxyLaunchPreflight(stdinFD: -1, stdoutFD: stdoutPipe.write, hasNoUserArgs: false),
            .proceed
        )
    }

    #if DEBUG
        func testPreflightRejectionRecordHasFixedReasonAndNoCorrelationFields() {
            let record = MCPProxyPreflightRejectionDiagnostics.makeRecord(localPID: 707)
            XCTAssertEqual(MCPProxyPreflightRejectionDiagnostics.reason, "proxy_preflight_rejected")
            XCTAssertEqual(record.layer, .proxy)
            XCTAssertEqual(record.initiator, .proxy)
            XCTAssertEqual(record.reason, "proxy_preflight_rejected")
            XCTAssertEqual(record.localPID, 707)
            XCTAssertNil(record.sessionFingerprint)
            XCTAssertNil(record.peerPID)
            XCTAssertNil(record.appConnectionID)
            XCTAssertNil(record.connectionGeneration)
            XCTAssertNil(record.errno)
            XCTAssertNil(record.errorDescription)
            XCTAssertNil(record.bridgeActiveRequestCount)
            XCTAssertNil(record.bridgeResponseInDeliveryCount)
            XCTAssertNil(record.bridgeCancellationTombstoneCount)
            XCTAssertNil(record.bridgeRecentCompletionCount)
            XCTAssertNil(record.bridgePendingTransactionCount)
            XCTAssertNil(record.bridgeHasForwardedProtocolFrame)
        }

        func testPreflightRejectionWritesOnePrivateTerminalRecord() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPProxyPreflightRecord-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let fileURL = try XCTUnwrap(
                MCPProxyPreflightRejectionDiagnostics.writeBestEffort(to: directory, localPID: 808)
            )
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertEqual(contents, [fileURL.lastPathComponent])
            XCTAssertTrue(fileURL.lastPathComponent.hasPrefix("terminal-"))
            XCTAssertEqual(fileURL.pathExtension, "json")

            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(MCPTerminalRecord.self, from: data)
            XCTAssertEqual(decoded.layer, .proxy)
            XCTAssertEqual(decoded.initiator, .proxy)
            XCTAssertEqual(decoded.reason, MCPProxyPreflightRejectionDiagnostics.reason)
            XCTAssertEqual(decoded.localPID, 808)
            XCTAssertNil(decoded.peerPID)
            XCTAssertNil(decoded.sessionFingerprint)
            XCTAssertNil(decoded.errorDescription)

            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(
                Set(object.keys),
                ["id", "timestamp", "monotonicUptime", "layer", "initiator", "reason", "localPID"]
            )
        }

        func testPreflightRejectionWriteFailureReturnsNilAndLeavesBlockerIntact() throws {
            let eofPipe = try makePipe()
            defer { Darwin.close(eofPipe.read) }
            Darwin.close(eofPipe.write)
            let stdoutPipe = try makePipe()
            defer { closeAll(stdoutPipe) }

            // A regular file where the events directory should be makes the write fail.
            let blocker = FileManager.default.temporaryDirectory
                .appendingPathComponent("MCPProxyPreflightBlocker-\(UUID().uuidString)")
            try Data("x".utf8).write(to: blocker)
            defer { try? FileManager.default.removeItem(at: blocker) }

            let outcome = classifyProxyLaunchPreflight(
                stdinFD: eofPipe.read,
                stdoutFD: stdoutPipe.write,
                hasNoUserArgs: true
            )
            XCTAssertEqual(outcome, .rejectNonInteractive)
            XCTAssertNil(MCPProxyPreflightRejectionDiagnostics.writeBestEffort(to: blocker, localPID: 909))
            XCTAssertEqual(try Data(contentsOf: blocker), Data("x".utf8))
        }
    #endif

    // MARK: - Descriptor fixtures

    private struct DescriptorPair {
        let read: Int32
        let write: Int32
    }

    private struct TTYPair {
        let master: Int32
        let slave: Int32
    }

    private func makePipe() throws -> DescriptorPair {
        var fds: [Int32] = [-1, -1]
        guard Darwin.pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
        }
        return DescriptorPair(read: fds[0], write: fds[1])
    }

    private func makeSocketPair() throws -> DescriptorPair {
        var fds: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
        }
        return DescriptorPair(read: fds[0], write: fds[1])
    }

    private func makeTTY() throws -> TTYPair {
        let master = Darwin.posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
        }
        guard Darwin.grantpt(master) == 0, Darwin.unlockpt(master) == 0,
              let slaveName = Darwin.ptsname(master)
        else {
            let error = POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
            Darwin.close(master)
            throw error
        }
        let slave = Darwin.open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
            Darwin.close(master)
            throw error
        }
        XCTAssertEqual(Darwin.isatty(slave), 1)
        return TTYPair(master: master, slave: slave)
    }

    private func closeAll(_ pairs: DescriptorPair...) {
        for pair in pairs {
            Darwin.close(pair.read)
            Darwin.close(pair.write)
        }
    }

    private func closeAll(_ tty: TTYPair) {
        Darwin.close(tty.slave)
        Darwin.close(tty.master)
    }
}
