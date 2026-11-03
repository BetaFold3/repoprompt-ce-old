import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// WS5: the production process-table reader classifies a real child process as alive while it
/// runs and as exited once it is SIGKILLed (zombie or reaped), compares process instances by PID
/// and start time, and captures a peer's ancestor chain.
final class MCPHelperProcessLivenessTests: XCTestCase {
    private let reader = MCPSystemProcessTableReader()

    private func spawnSleep() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        return process
    }

    func testRealChildIsAliveThenExitedAfterSIGKILL() async throws {
        let child = try spawnSleep()
        let pid = child.processIdentifier
        let snapshot = try XCTUnwrap(MCPHelperPeerProcessSnapshot.capture(peerPID: pid, reader: reader))
        XCTAssertEqual(snapshot.peer.pid, pid)
        XCTAssertEqual(snapshot.ancestors.first?.pid, getpid(), "the test process is the child's parent")
        XCTAssertNotNil(snapshot.chainIdentity(of: getpid()))
        XCTAssertEqual(MCPHelperProcessLiveness.classify(snapshot.peer, reader: reader), .alive(snapshot.peer))

        XCTAssertEqual(kill(pid, SIGKILL), 0)
        var liveness = MCPHelperProcessLiveness.classify(snapshot.peer, reader: reader)
        for _ in 0 ..< 500 where liveness != .exited {
            try await Task.sleep(nanoseconds: 10_000_000)
            liveness = MCPHelperProcessLiveness.classify(snapshot.peer, reader: reader)
        }
        XCTAssertEqual(liveness, .exited, "a killed child is exited whether still a zombie or already reaped")
        child.waitUntilExit()
        XCTAssertEqual(reader.entry(for: pid), .absent)
        XCTAssertEqual(MCPHelperProcessLiveness.classify(snapshot.peer, reader: reader), .exited)
    }

    func testProcessIdentityIncludesTheStartTime() throws {
        guard case let .present(identity, parentPID, isZombie) = reader.entry(for: getpid()) else {
            return XCTFail("the test process must be readable")
        }
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertEqual(parentPID, getppid())
        XCTAssertFalse(isZombie)
        XCTAssertEqual(MCPHelperProcessLiveness.classify(identity, reader: reader), .alive(identity))

        // The same PID with another start time is a different (reused) process instance.
        let reused = MCPHelperProcessIdentity(
            pid: identity.pid,
            startSeconds: identity.startSeconds - 1,
            startMicroseconds: identity.startMicroseconds
        )
        XCTAssertNotEqual(reused, identity)
        XCTAssertEqual(MCPHelperProcessLiveness.classify(reused, reader: reader), .exited)

        let snapshot = try XCTUnwrap(MCPHelperPeerProcessSnapshot.capture(peerPID: getpid(), reader: reader))
        XCTAssertTrue(snapshot.chainContains(identity))
        XCTAssertFalse(snapshot.chainContains(reused))
    }

    func testMissingPIDIsAbsent() {
        // PIDs are bounded well below Int32.max on macOS.
        XCTAssertEqual(reader.entry(for: pid_t.max), .absent)
        XCTAssertNil(MCPHelperPeerProcessSnapshot.capture(peerPID: pid_t.max, reader: reader))
    }
}
