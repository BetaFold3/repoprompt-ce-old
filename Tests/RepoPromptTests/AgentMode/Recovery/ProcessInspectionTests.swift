import Darwin
import Foundation
@testable import RepoPromptPlatform
import XCTest

/// Lossless-restart Phase 3 (R6) single-PID process inspection. Every case uses a scripted
/// system-query backend and synthetic `KERN_PROCARGS2` buffers; no real process is inspected,
/// spawned or signalled.
final class ProcessInspectionTests: XCTestCase {
    private typealias Reason = ProcessInspectionFailure.Reason
    private typealias BasicInfo = ProcessInspection.BasicInfo

    private static let pid: pid_t = 4242
    private static let uid: uid_t = 501
    private static let boot = "6A1F2B3C-4D5E-4F60-8172-8394A5B6C7D8"
    private static let runtimeID = UUID(uuidString: "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9")!

    private static func basic(
        pid: pid_t = ProcessInspectionTests.pid,
        parentPID: pid_t = 100,
        uid: uid_t = ProcessInspectionTests.uid,
        startSeconds: UInt64 = 1_760_000_000,
        startMicroseconds: UInt64 = 123_456
    ) -> BasicInfo {
        BasicInfo(pid: pid, parentPID: parentPID, uid: uid, startSeconds: startSeconds, startMicroseconds: startMicroseconds)
    }

    private static func expectedIdentity() -> ProcessBirthIdentity {
        ProcessBirthIdentity(
            bootSessionID: UUID(uuidString: boot)!,
            pid: pid,
            startSeconds: 1_760_000_000,
            startMicroseconds: 123_456,
            uid: uid
        )
    }

    /// Builds `argc | exec path NUL | padding | argv strings | env strings | NUL | apple strings`.
    private static func procArgs(
        argumentCount: Int32? = nil,
        executable: String = "/usr/local/bin/claude",
        padding: Int = 3,
        arguments: [String] = ["claude", "--print"],
        environment: [String] = [],
        trailing: [UInt8] = [0] + Array("executable_path=/usr/local/bin/claude".utf8) + [0]
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: argumentCount ?? Int32(arguments.count)) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(executable.utf8) + [0])
        bytes.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for argument in arguments {
            bytes.append(contentsOf: Array(argument.utf8) + [0])
        }
        for entry in environment {
            bytes.append(contentsOf: Array(entry.utf8) + [0])
        }
        bytes.append(contentsOf: trailing)
        return bytes
    }

    private static func parse(_ buffer: [UInt8]) -> Result<ProcessEnvironmentIdentity, Reason> {
        ProcessInspection.parseEnvironmentIdentity(procArgs2: buffer)
    }

    // MARK: - Inspection

    func testStableIdentityReportsSupportingEvidenceSelectedEnvironmentAndFinalParent() {
        let script = ScriptedBackend()
        script.basic = [.success(Self.basic(parentPID: 100)), .success(Self.basic(parentPID: 1))]
        script.arguments = .success(Self.procArgs(environment: [
            "PATH=/usr/bin:/bin",
            "RPCE_RUNTIME_ID=\(Self.runtimeID.uuidString)",
            "CLAUDE_CONFIG_DIR=/Users/me/.claude-rotator/profiles/a"
        ]))

        let result = script.inspection.observe(pid: Self.pid)

        guard case let .observed(observation) = result else { return XCTFail("expected observation, got \(result)") }
        XCTAssertEqual(observation.identity, Self.expectedIdentity())
        XCTAssertEqual(observation.parentPID, 1, "reparenting is not an identity change; the final parent is reported")
        XCTAssertFalse(observation.isZombie)
        XCTAssertEqual(observation.executablePath, .available("/usr/local/bin/claude"))
        XCTAssertEqual(observation.processGroupID, .available(Self.pid))
        XCTAssertEqual(observation.environment, .available(ProcessEnvironmentIdentity(
            runtimeID: Self.runtimeID,
            claudeConfigDirectory: "/Users/me/.claude-rotator/profiles/a"
        )))
        XCTAssertEqual(script.calls, ["boot", "basic", "path", "group", "uid", "arguments", "basic", "boot"])
    }

    func testMissingSelectedVariablesAreAbsentNotFailure() {
        let script = ScriptedBackend()
        script.arguments = .success(Self.procArgs(environment: ["PATH=/usr/bin", "HOME=/Users/me"]))

        guard case let .observed(observation) = script.inspection.observe(pid: Self.pid) else { return XCTFail() }
        XCTAssertEqual(observation.environment, .available(ProcessEnvironmentIdentity(runtimeID: nil, claudeConfigDirectory: nil)))
    }

    func testOtherUIDTargetSkipsArgumentQueryAndReportsAccessDenied() {
        let script = ScriptedBackend()
        script.effectiveUID = 502

        guard case let .observed(observation) = script.inspection.observe(pid: Self.pid) else { return XCTFail() }
        XCTAssertEqual(observation.environment, .unavailable(.init(operation: .arguments, reason: .accessDenied)))
        XCTAssertFalse(script.calls.contains("arguments"))
    }

    func testNonpositivePIDIsRejectedWithoutAnySystemQuery() {
        for pid: pid_t in [0, -1, -4242] {
            let script = ScriptedBackend()
            XCTAssertEqual(
                script.inspection.observe(pid: pid),
                .unavailable(.init(operation: .basicInfo, reason: .invalidProcessID))
            )
            XCTAssertEqual(script.calls, [])
        }
    }

    func testConfirmedNoSuchProcessIsNotFound() {
        let script = ScriptedBackend()
        script.basic = [.failure(.syscallFailed(errno: ESRCH))]

        XCTAssertEqual(script.inspection.observe(pid: Self.pid), .notFound)
        XCTAssertEqual(script.calls, ["boot", "basic"])
    }

    func testDisappearanceDuringInspectionIsNotFound() {
        let script = ScriptedBackend()
        script.basic = [.success(Self.basic()), .failure(.syscallFailed(errno: ESRCH))]
        script.path = .failure(.syscallFailed(errno: ESRCH))
        script.group = .failure(.syscallFailed(errno: ESRCH))
        script.arguments = .failure(.syscallFailed(errno: EINVAL))

        XCTAssertEqual(script.inspection.observe(pid: Self.pid), .notFound)
    }

    func testAmbiguousBasicInfoFailuresAreUnavailableNeverNotFound() {
        let cases: [(Result<BasicInfo, Reason>, Reason)] = [
            (.failure(.syscallFailed(errno: EPERM)), .syscallFailed(errno: EPERM)),
            (.failure(.syscallFailed(errno: EINVAL)), .syscallFailed(errno: EINVAL)),
            (.failure(.malformedResponse), .malformedResponse),
            (.success(Self.basic(pid: Self.pid + 1)), .malformedResponse)
        ]
        for (response, reason) in cases {
            let script = ScriptedBackend()
            script.basic = [response]
            XCTAssertEqual(
                script.inspection.observe(pid: Self.pid),
                .unavailable(.init(operation: .basicInfo, reason: reason))
            )
        }
    }

    func testAmbiguousFinalBasicInfoFailureIsUnavailable() {
        let script = ScriptedBackend()
        script.basic = [.success(Self.basic()), .failure(.syscallFailed(errno: EPERM))]

        XCTAssertEqual(
            script.inspection.observe(pid: Self.pid),
            .unavailable(.init(operation: .basicInfo, reason: .syscallFailed(errno: EPERM)))
        )
    }

    func testPIDReuseOrIdentityChangeDuringSamplingIsInconsistent() {
        let changed: [BasicInfo] = [
            Self.basic(startSeconds: 1_760_000_001),
            Self.basic(startMicroseconds: 123_457),
            Self.basic(uid: 502)
        ]
        for final in changed {
            let script = ScriptedBackend()
            script.basic = [.success(Self.basic()), .success(final)]
            XCTAssertEqual(
                script.inspection.observe(pid: Self.pid),
                .unavailable(.init(operation: .consistency, reason: .inconsistentObservation))
            )
        }
    }

    func testBootSessionChangeDuringSamplingIsInconsistent() {
        let script = ScriptedBackend()
        script.boot = [.success(Self.boot), .success("11111111-2222-4333-8444-555555555555")]

        XCTAssertEqual(
            script.inspection.observe(pid: Self.pid),
            .unavailable(.init(operation: .consistency, reason: .inconsistentObservation))
        )
    }

    func testUnavailableOrMalformedBootIdentityIsUnavailableNeverExit() {
        let cases: [([Result<String, Reason>], Reason)] = [
            ([.failure(.syscallFailed(errno: ENOENT))], .syscallFailed(errno: ENOENT)),
            ([.success("not-a-uuid")], .malformedResponse),
            ([.success(Self.boot), .failure(.syscallFailed(errno: ENOMEM))], .syscallFailed(errno: ENOMEM))
        ]
        for (responses, reason) in cases {
            let script = ScriptedBackend()
            script.boot = responses
            XCTAssertEqual(
                script.inspection.observe(pid: Self.pid),
                .unavailable(.init(operation: .bootIdentity, reason: reason))
            )
        }
    }

    func testPartialSupportingEvidenceStillObservesIdentityWithUnavailableFields() {
        let script = ScriptedBackend()
        script.path = .failure(.syscallFailed(errno: EPERM))
        script.group = .failure(.syscallFailed(errno: ESRCH))
        script.arguments = .failure(.syscallFailed(errno: EINVAL))

        guard case let .observed(observation) = script.inspection.observe(pid: Self.pid) else {
            return XCTFail("supporting-evidence failures must not hide a consistent identity or imply exit")
        }
        XCTAssertEqual(observation.identity, Self.expectedIdentity())
        XCTAssertEqual(observation.executablePath, .unavailable(.init(operation: .executablePath, reason: .syscallFailed(errno: EPERM))))
        XCTAssertEqual(observation.processGroupID, .unavailable(.init(operation: .processGroup, reason: .syscallFailed(errno: ESRCH))))
        XCTAssertEqual(observation.environment, .unavailable(.init(operation: .arguments, reason: .syscallFailed(errno: EINVAL))))
    }

    func testZombieAtFinalSampleIsReportedAsSupportingEvidence() {
        let script = ScriptedBackend()
        var zombie = Self.basic()
        zombie.isZombie = true
        script.basic = [.success(Self.basic()), .success(zombie)]
        script.path = .failure(.syscallFailed(errno: ESRCH))
        script.arguments = .failure(.syscallFailed(errno: EINVAL))

        guard case let .observed(observation) = script.inspection.observe(pid: Self.pid) else { return XCTFail() }
        XCTAssertTrue(observation.isZombie)
        XCTAssertEqual(observation.identity, Self.expectedIdentity())
    }

    func testDarwinBasicInfoMapsZombieStatus() {
        func read(status: Int32) -> ProcessInspection.BasicInfo? {
            try? ProcessInspection.Backend.readBasicInfo(pid: Self.pid) { pid, info in
                info.pbi_pid = UInt32(pid)
                info.pbi_status = UInt32(status)
                return Int32(MemoryLayout<proc_bsdinfo>.size)
            }.get()
        }

        XCTAssertEqual(read(status: SZOMB)?.isZombie, true)
        XCTAssertEqual(read(status: SRUN)?.isZombie, false)
    }

    func testMalformedArgumentBufferMakesOnlyEnvironmentUnavailable() {
        let script = ScriptedBackend()
        script.arguments = .success(Self.procArgs(argumentCount: 9))

        guard case let .observed(observation) = script.inspection.observe(pid: Self.pid) else { return XCTFail() }
        XCTAssertEqual(observation.environment, .unavailable(.init(operation: .arguments, reason: .malformedResponse)))
        XCTAssertEqual(observation.executablePath, .available("/usr/local/bin/claude"))
    }

    func testResultNeverCarriesArgumentOrEnvironmentContents() {
        let script = ScriptedBackend()
        script.arguments = .success(Self.procArgs(
            arguments: ["claude", "--api-secret-argument"],
            environment: ["SECRET_ENV=hunter2", "CLAUDE_CONFIG_DIR=/dup-home-a", "CLAUDE_CONFIG_DIR=/dup-home-b"]
        ))

        let description = String(describing: script.inspection.observe(pid: Self.pid))
        XCTAssertTrue(description.contains("malformedResponse"))
        for fragment in ["--api-secret-argument", "SECRET_ENV", "hunter2", "dup-home"] {
            XCTAssertFalse(description.contains(fragment), "result leaked \(fragment)")
        }
    }

    // MARK: - Darwin zero-return errno handling (fake queries; no system call is issued)

    func testZeroReturnWithStaleErrnoIsAmbiguousNotAbsence() {
        errno = ESRCH
        XCTAssertEqual(
            ProcessInspection.Backend.readBasicInfo(pid: Self.pid) { _, _ in 0 }.failureReason,
            .malformedResponse
        )
        errno = ESRCH
        XCTAssertEqual(
            ProcessInspection.Backend.readExecutablePath(pid: Self.pid) { _, _ in 0 }.failureReason,
            .malformedResponse
        )
    }

    func testZeroReturnWithFreshErrnoReportsThatErrno() {
        errno = 0
        XCTAssertEqual(
            ProcessInspection.Backend.readBasicInfo(pid: Self.pid) { _, _ in
                errno = ESRCH
                return 0
            }.failureReason,
            .syscallFailed(errno: ESRCH)
        )
        XCTAssertEqual(
            ProcessInspection.Backend.readExecutablePath(pid: Self.pid) { _, _ in
                errno = EPERM
                return 0
            }.failureReason,
            .syscallFailed(errno: EPERM)
        )
    }

    func testShortBasicInfoIsMalformedAndPathLengthBoundsTheString() {
        XCTAssertEqual(
            ProcessInspection.Backend.readBasicInfo(pid: Self.pid) { _, _ in 8 }.failureReason,
            .malformedResponse
        )
        let path = ProcessInspection.Backend.readExecutablePath(pid: Self.pid) { _, bytes in
            let value = Array("/bin/tool".utf8)
            bytes.replaceSubrange(0 ..< value.count, with: value)
            return Int32(value.count)
        }
        XCTAssertEqual(try? path.get(), "/bin/tool")
    }

    // MARK: - KERN_PROCARGS2 parsing

    func testParserSelectsOnlyMarkersFromEnvironmentAndSplitsAtFirstEquals() {
        let buffer = Self.procArgs(
            arguments: ["claude", "RPCE_RUNTIME_ID=\(UUID().uuidString)", "CLAUDE_CONFIG_DIR=/from/argv"],
            environment: [
                "NOEQUALS",
                "RPCE_RUNTIME_ID_SUFFIX=x",
                "CLAUDE_CONFIG_DIR=/Users/me/odd=name/../profile ",
                "RPCE_RUNTIME_ID=\(Self.runtimeID.uuidString)"
            ]
        )

        XCTAssertEqual(Self.parse(buffer), .success(ProcessEnvironmentIdentity(
            runtimeID: Self.runtimeID,
            claudeConfigDirectory: "/Users/me/odd=name/../profile "
        )))
    }

    func testParserPreservesEmptyHomeValueAndStopsAtEnvironmentTerminator() {
        let afterTerminator = Array("RPCE_RUNTIME_ID=not-a-uuid".utf8) + [0]
        let buffer = Self.procArgs(environment: ["CLAUDE_CONFIG_DIR="], trailing: [0] + afterTerminator)

        XCTAssertEqual(Self.parse(buffer), .success(ProcessEnvironmentIdentity(runtimeID: nil, claudeConfigDirectory: "")))

        // An empty environment followed by the default apple-string trailer selects nothing.
        XCTAssertEqual(
            Self.parse(Self.procArgs(environment: [])),
            .success(ProcessEnvironmentIdentity(runtimeID: nil, claudeConfigDirectory: nil))
        )
    }

    func testParserAcceptsZeroArgumentsNoPaddingAndBufferEndingAfterEnvironment() {
        let buffer = Self.procArgs(padding: 0, arguments: [], environment: ["CLAUDE_CONFIG_DIR=/h"], trailing: [])

        XCTAssertEqual(Self.parse(buffer), .success(ProcessEnvironmentIdentity(runtimeID: nil, claudeConfigDirectory: "/h")))
    }

    func testParserReadsEnvironmentAfterZeroFilledArgumentTail() {
        // A process-title rewrite keeps argv[0] and zero-fills the rest of the argv area.
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/usr/local/bin/node".utf8) + [0, 0])
        buffer.append(contentsOf: Array("claude".utf8) + [UInt8](repeating: 0, count: 24))
        buffer.append(contentsOf: Array("RPCE_RUNTIME_ID=\(Self.runtimeID.uuidString)".utf8) + [0])
        buffer.append(contentsOf: Array("CLAUDE_CONFIG_DIR=/h".utf8) + [0, 0])

        XCTAssertEqual(Self.parse(buffer), .success(ProcessEnvironmentIdentity(runtimeID: Self.runtimeID, claudeConfigDirectory: "/h")))
    }

    func testParserRejectsMalformedLayouts() {
        var unterminatedExecutable: [UInt8] = []
        withUnsafeBytes(of: Int32(0)) { unterminatedExecutable.append(contentsOf: $0) }
        unterminatedExecutable.append(contentsOf: Array("/bin/claude".utf8))

        var unterminatedEnvironment = Self.procArgs(environment: ["PATH=/bin"], trailing: [])
        unterminatedEnvironment.append(contentsOf: Array("CLAUDE_CONFIG_DIR=/trunc".utf8))

        let cases: [(String, [UInt8])] = [
            ("empty", []),
            ("short count", [1, 0]),
            ("negative count", Self.procArgs(argumentCount: -1)),
            ("count beyond buffer", Self.procArgs(argumentCount: Int32.max)),
            ("count beyond strings", Self.procArgs(argumentCount: 5, trailing: [])),
            ("missing executable", Self.procArgs(executable: "", padding: 0)),
            ("unterminated executable", unterminatedExecutable),
            ("unterminated environment", unterminatedEnvironment)
        ]
        for (label, buffer) in cases {
            XCTAssertEqual(Self.parse(buffer), .failure(.malformedResponse), label)
        }
    }

    func testParserRejectsDuplicateSelectedKeys() {
        for key in ["RPCE_RUNTIME_ID", "CLAUDE_CONFIG_DIR"] {
            let value = key == "RPCE_RUNTIME_ID" ? Self.runtimeID.uuidString : "/h"
            let buffer = Self.procArgs(environment: ["\(key)=\(value)", "PATH=/bin", "\(key)=\(value)"])
            XCTAssertEqual(Self.parse(buffer), .failure(.malformedResponse), key)
        }
    }

    func testParserAcceptsLowercaseMarkerAsSameIdentity() {
        let buffer = Self.procArgs(environment: ["RPCE_RUNTIME_ID=\(Self.runtimeID.uuidString.lowercased())"])

        XCTAssertEqual(Self.parse(buffer), .success(ProcessEnvironmentIdentity(runtimeID: Self.runtimeID, claudeConfigDirectory: nil)))
    }

    func testParserRejectsInvalidMarker() {
        for marker in ["", "not-a-uuid", "{\(Self.runtimeID.uuidString)}"] {
            let buffer = Self.procArgs(environment: ["RPCE_RUNTIME_ID=\(marker)"])
            XCTAssertEqual(Self.parse(buffer), .failure(.malformedResponse), marker)
        }
    }

    func testParserRejectsInvalidSelectedStringEncodingButIgnoresUnselectedBytes() {
        let invalid: [UInt8] = [0xC3, 0x28]
        var selected = Self.procArgs(trailing: [])
        selected.append(contentsOf: Array("CLAUDE_CONFIG_DIR=".utf8) + invalid + [0, 0])
        XCTAssertEqual(Self.parse(selected), .failure(.malformedResponse))

        var unselected = Self.procArgs(trailing: [])
        unselected.append(contentsOf: Array("OTHER=".utf8) + invalid + [0, 0])
        XCTAssertEqual(Self.parse(unselected), .success(ProcessEnvironmentIdentity(runtimeID: nil, claudeConfigDirectory: nil)))
    }
}

private extension Result {
    var failureReason: Failure? {
        if case let .failure(reason) = self { reason } else { nil }
    }
}

/// Scripted system-query backend. Sequenced responses are consumed in order; the last
/// response repeats once the sequence is exhausted.
private final class ScriptedBackend: @unchecked Sendable {
    typealias Reason = ProcessInspectionFailure.Reason

    private let lock = NSLock()
    var boot: [Result<String, Reason>] = [.success("6A1F2B3C-4D5E-4F60-8172-8394A5B6C7D8")]
    var basic: [Result<ProcessInspection.BasicInfo, Reason>] = [.success(ProcessInspection.BasicInfo(
        pid: 4242,
        parentPID: 100,
        uid: 501,
        startSeconds: 1_760_000_000,
        startMicroseconds: 123_456
    ))]
    var path: Result<String, Reason> = .success("/usr/local/bin/claude")
    var group: Result<pid_t, Reason> = .success(4242)
    var arguments: Result<[UInt8], Reason> = .success({
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(1)) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array("/usr/local/bin/claude".utf8) + [0, 0])
        bytes.append(contentsOf: Array("claude".utf8) + [0, 0])
        return bytes
    }())
    var effectiveUID: uid_t = 501
    private(set) var calls: [String] = []

    var inspection: ProcessInspection {
        ProcessInspection(backend: ProcessInspection.Backend(
            bootSessionUUID: { self.record("boot") { Self.next(&self.boot) } },
            basicInfo: { _ in self.record("basic") { Self.next(&self.basic) } },
            executablePath: { _ in self.record("path") { self.path } },
            processGroup: { _ in self.record("group") { self.group } },
            processArguments: { _ in self.record("arguments") { self.arguments } },
            effectiveUID: { self.record("uid") { self.effectiveUID } }
        ))
    }

    private func record<T>(_ call: String, _ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
        return body()
    }

    private static func next<T>(_ sequence: inout [T]) -> T {
        sequence.count > 1 ? sequence.removeFirst() : sequence[0]
    }
}
