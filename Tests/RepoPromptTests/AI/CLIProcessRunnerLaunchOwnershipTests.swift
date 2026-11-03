import Darwin
import Foundation
@testable import RepoPromptPlatform
import XCTest

/// Spec R6 launch-ownership hooks at the `CLIProcessRunner` boundary (`run` and `runStreaming`).
///
/// These runner-boundary fixtures spawn only temporary `/bin/sh` scripts written by the test (no
/// provider CLI, no visible app); the runner itself terminates and reaps only the exact fixture
/// child it spawned. Registry, discovery and Stop behavior is covered on injected boundaries in
/// `AgentProcessRegistryTests`; nothing here is live provider qualification.
final class CLIProcessRunnerLaunchOwnershipTests: XCTestCase {
    private struct OwnerRefusal: Error, Equatable {
        let stage: String
    }

    private enum Event: Equatable {
        case prepare
        case spawnFailed
        case commit(pid_t)
        case reaped(pid_t, confirmed: Bool)
    }

    /// Records every hook in order; optionally refuses prepare or commit.
    private actor RecordingOwner: ProcessLaunchOwnership {
        let runtimeID = UUID()
        private let refusePrepare: Bool
        private let refuseCommit: Bool
        private let cancelDuringPrepare: Bool
        private let inputProbe: URL?
        private(set) var events: [Event] = []
        private(set) var inputWasDeliveredBeforeCommit: Bool?

        init(refusePrepare: Bool = false, refuseCommit: Bool = false, cancelDuringPrepare: Bool = false, inputProbe: URL? = nil) {
            self.refusePrepare = refusePrepare
            self.refuseCommit = refuseCommit
            self.cancelDuringPrepare = cancelDuringPrepare
            self.inputProbe = inputProbe
        }

        func prepareSpawn() async throws -> UUID {
            events.append(.prepare)
            if refusePrepare { throw OwnerRefusal(stage: "prepare") }
            // The launching operation is cancelled while its reservation is in flight.
            if cancelDuringPrepare { withUnsafeCurrentTask { $0?.cancel() } }
            return runtimeID
        }

        func spawnFailed() async {
            events.append(.spawnFailed)
        }

        func commitSpawn(pid: pid_t, processGroupID _: pid_t?) async throws {
            events.append(.commit(pid))
            if let inputProbe {
                inputWasDeliveredBeforeCommit = FileManager.default.fileExists(atPath: inputProbe.path)
            }
            if refuseCommit { throw OwnerRefusal(stage: "commit") }
        }

        func rootReaped(pid: pid_t, confirmed: Bool) async {
            events.append(.reaped(pid, confirmed: confirmed))
        }
    }

    private var root: URL!
    private var fakeShell: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProcessRunnerLaunchOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fakeShell = root.appendingPathComponent("fake-shell")
        try writeExecutable(fakeShell, contents: "#!/bin/sh\nexit 1\n")
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func writeExecutable(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
    }

    private func makeRunner(script: String, environment: [String: String] = [:]) throws -> CLIProcessRunner {
        let executable = root.appendingPathComponent("fixture-cli-\(UUID().uuidString)")
        try writeExecutable(executable, contents: script)
        return CLIProcessRunner(config: CLIProcessConfiguration(
            command: "fixture-cli",
            commandSelection: .configuredExactPath(executable.path),
            environment: environment.merging(["SHELL": fakeShell.path]) { current, _ in current },
            additionalPaths: [],
            enableDebugLogging: false
        ))
    }

    private func drain(_ stream: AsyncThrowingStream<CLIProcessRunner.StreamEvent, Error>) async throws -> (stdout: Data, status: Int32?) {
        var output = Data()
        var status: Int32?
        for try await event in stream {
            switch event {
            case let .stdout(chunk): output.append(chunk)
            case .stderr: break
            case let .terminated(exitStatus, _, _): status = exitStatus
            }
        }
        return (output, status)
    }

    // MARK: Prepare refusal

    func testPrepareRefusalSpawnsNothingForBufferedAndStreamingRuns() async throws {
        let spawnMarker = root.appendingPathComponent("spawned")
        let runner = try makeRunner(script: "#!/bin/sh\nprintf spawned > '\(spawnMarker.path)'\n")

        let buffered = RecordingOwner(refusePrepare: true)
        do {
            _ = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5, launchOwnership: buffered)
            XCTFail("A refused reservation must refuse the launch")
        } catch {
            XCTAssertEqual(error as? OwnerRefusal, OwnerRefusal(stage: "prepare"), "the owner's error, never a fresh fallback")
        }
        let bufferedEvents = await buffered.events
        XCTAssertEqual(bufferedEvents, [.prepare])

        let streaming = RecordingOwner(refusePrepare: true)
        do {
            _ = try await runner.runStreaming(args: [], stdin: nil, outputMode: .none, timeout: 5, launchOwnership: streaming)
            XCTFail("A refused reservation must refuse the streaming launch")
        } catch {
            XCTAssertEqual(error as? OwnerRefusal, OwnerRefusal(stage: "prepare"))
        }
        let streamingEvents = await streaming.events
        XCTAssertEqual(streamingEvents, [.prepare])
        XCTAssertFalse(FileManager.default.fileExists(atPath: spawnMarker.path), "zero spawns on a refused reservation")

        // The gate was released: an unowned launch still runs afterwards.
        let after = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5)
        XCTAssertEqual(after.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spawnMarker.path))
    }

    // MARK: Commit refusal

    func testCommitRefusalReapsTheExactRootWithoutDeliveringInput() async throws {
        let received = root.appendingPathComponent("received")
        let script = "#!/bin/sh\nif IFS= read -r line; then printf '%s' \"$line\" > '\(received.path)'; fi\n"
        let runner = try makeRunner(script: script)

        let buffered = RecordingOwner(refuseCommit: true)
        do {
            _ = try await runner.run(args: [], stdin: "secret-input\n", outputMode: .none, timeout: 5, launchOwnership: buffered)
            XCTFail("A refused commit must fail the launch")
        } catch {
            XCTAssertEqual(error as? OwnerRefusal, OwnerRefusal(stage: "commit"))
        }
        let bufferedEvents = await buffered.events
        guard bufferedEvents.count == 3, case let .commit(pid) = bufferedEvents[1] else {
            return XCTFail("Unexpected events \(bufferedEvents)")
        }
        XCTAssertEqual(
            bufferedEvents,
            [.prepare, .commit(pid), .reaped(pid, confirmed: true)],
            "the exact root is reaped by its own wait and reported as a confirmed reap"
        )

        let streaming = RecordingOwner(refuseCommit: true)
        do {
            _ = try await runner.runStreaming(args: [], stdin: "secret-input\n", outputMode: .none, timeout: 5, launchOwnership: streaming)
            XCTFail("A refused commit must fail the streaming launch")
        } catch {
            XCTAssertEqual(error as? OwnerRefusal, OwnerRefusal(stage: "commit"))
        }
        let streamingEvents = await streaming.events
        guard streamingEvents.count == 3, case let .commit(streamPID) = streamingEvents[1] else {
            return XCTFail("Unexpected events \(streamingEvents)")
        }
        XCTAssertEqual(streamingEvents, [.prepare, .commit(streamPID), .reaped(streamPID, confirmed: true)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.path), "no stdin line reaches a refused child")
    }

    // MARK: Successful ownership

    func testCommittedLaunchCarriesTheMarkerAndCommitsBeforeInput() async throws {
        let received = root.appendingPathComponent("received")
        let script = """
        #!/bin/sh
        IFS= read -r line
        printf '%s' "$line" > '\(received.path)'
        printf '%s' "$RPCE_RUNTIME_ID"
        """
        let runner = try makeRunner(script: script, environment: [ProcessLauncher.runtimeMarkerEnvironmentKey: "inherited-marker"])

        let buffered = RecordingOwner(inputProbe: received)
        let result = try await runner.run(
            args: [],
            stdin: "hello\n",
            outputMode: .none,
            timeout: 5,
            additionalRemovedKeys: [ProcessLauncher.runtimeMarkerEnvironmentKey],
            launchOwnership: buffered
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), buffered.runtimeID.uuidString)
        XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), "hello")
        let bufferedEvents = await buffered.events
        guard bufferedEvents.count == 3, case let .commit(pid) = bufferedEvents[1] else {
            return XCTFail("Unexpected events \(bufferedEvents)")
        }
        XCTAssertEqual(bufferedEvents, [.prepare, .commit(pid), .reaped(pid, confirmed: true)])
        let bufferedInputBeforeCommit = await buffered.inputWasDeliveredBeforeCommit
        XCTAssertEqual(bufferedInputBeforeCommit, false)

        try FileManager.default.removeItem(at: received)
        let streaming = RecordingOwner(inputProbe: received)
        let stream = try await runner.runStreaming(
            args: [],
            stdin: "hello\n",
            outputMode: .none,
            timeout: 5,
            additionalRemovedKeys: [ProcessLauncher.runtimeMarkerEnvironmentKey],
            launchOwnership: streaming
        )
        let drained = try await drain(stream)
        XCTAssertEqual(drained.status, 0)
        XCTAssertEqual(String(decoding: drained.stdout, as: UTF8.self), streaming.runtimeID.uuidString)
        let streamingEvents = await streaming.events
        guard streamingEvents.count == 3, case let .commit(streamPID) = streamingEvents[1] else {
            return XCTFail("Unexpected events \(streamingEvents)")
        }
        XCTAssertEqual(streamingEvents, [.prepare, .commit(streamPID), .reaped(streamPID, confirmed: true)])
        let streamingInputBeforeCommit = await streaming.inputWasDeliveredBeforeCommit
        XCTAssertEqual(streamingInputBeforeCommit, false)
    }

    // MARK: Cancellation after reservation

    func testCancellationDuringReservationSpawnsNothingAndReleasesTheReservation() async throws {
        let spawnMarker = root.appendingPathComponent("spawned-after-cancel")
        let runner = try makeRunner(script: "#!/bin/sh\nprintf spawned > '\(spawnMarker.path)'\n")

        // Each launch runs in its own task: the owner cancels that task, never the test's.
        let buffered = RecordingOwner(cancelDuringPrepare: true)
        let bufferedTask = Task {
            try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5, launchOwnership: buffered)
        }
        do {
            _ = try await bufferedTask.value
            XCTFail("A launch cancelled during its reservation must not spawn")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let bufferedEvents = await buffered.events
        XCTAssertEqual(bufferedEvents, [.prepare, .spawnFailed], "the reservation is released, never committed")

        let streaming = RecordingOwner(cancelDuringPrepare: true)
        let streamingTask = Task {
            try await runner.runStreaming(args: [], stdin: nil, outputMode: .none, timeout: 5, launchOwnership: streaming)
        }
        do {
            _ = try await streamingTask.value
            XCTFail("A streaming launch cancelled during its reservation must not spawn")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let streamingEvents = await streaming.events
        XCTAssertEqual(streamingEvents, [.prepare, .spawnFailed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: spawnMarker.path), "zero spawns after cancellation")

        // The gate was released: an unowned launch still runs afterwards.
        let after = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5)
        XCTAssertEqual(after.status, 0)
    }

    func testUnownedLaunchStripsTheInheritedMarkerOnlyWhenTheManagedCallerAsks() async throws {
        let runner = try makeRunner(
            script: "#!/bin/sh\nprintf '%s' \"$RPCE_RUNTIME_ID\"\n",
            environment: [ProcessLauncher.runtimeMarkerEnvironmentKey: "inherited-marker"]
        )
        let stripped = try await runner.run(
            args: [],
            stdin: nil,
            outputMode: .none,
            timeout: 5,
            additionalRemovedKeys: [ProcessLauncher.runtimeMarkerEnvironmentKey]
        )
        XCTAssertEqual(String(decoding: stripped.stdout, as: UTF8.self), "", "managed boundaries never pass an inherited marker")

        let unchanged = try await runner.run(args: [], stdin: nil, outputMode: .none, timeout: 5)
        XCTAssertEqual(
            String(decoding: unchanged.stdout, as: UTF8.self),
            "inherited-marker",
            "without an owner or removal the Platform environment contract is unchanged"
        )
    }
}
