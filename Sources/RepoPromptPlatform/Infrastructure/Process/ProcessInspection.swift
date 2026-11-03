import Darwin
import Foundation

/// Identity of one process lifetime: boot session, PID, start time and UID.
/// Executable path and process group are supporting evidence, not identity.
package struct ProcessBirthIdentity: Equatable {
    package let bootSessionID: UUID
    package let pid: pid_t
    package let startSeconds: UInt64
    package let startMicroseconds: UInt64
    package let uid: uid_t

    package init(bootSessionID: UUID, pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64, uid: uid_t) {
        self.bootSessionID = bootSessionID
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.uid = uid
    }
}

/// Why one inspection step produced no usable evidence. Never carries raw response bytes,
/// arguments or environment contents.
package struct ProcessInspectionFailure: Error, Equatable {
    package enum Operation: Equatable {
        case bootIdentity
        case basicInfo
        case executablePath
        case processGroup
        case arguments
        case consistency
    }

    package enum Reason: Error, Equatable {
        /// The PID argument itself was not a valid process ID; no system query was issued.
        case invalidProcessID
        case syscallFailed(errno: Int32)
        /// The query was not attempted because the target is owned by another UID.
        case accessDenied
        /// The response was empty, short, truncated or did not have the expected layout.
        case malformedResponse
        /// Two samples of the same process disagreed on identity.
        case inconsistentObservation
    }

    package let operation: Operation
    package let reason: Reason

    package init(operation: Operation, reason: Reason) {
        self.operation = operation
        self.reason = reason
    }
}

package enum ProcessInspectionField<Value: Sendable & Equatable>: Equatable {
    case available(Value)
    case unavailable(ProcessInspectionFailure)
}

/// Selected environment markers read from the process's current exec string area
/// (`KERN_PROCARGS2`). `nil` means the variable was absent from that area, not that inspection
/// failed; failed inspection is reported through `ProcessInspectionField`. Absence is weak
/// evidence, never proof that a process is unowned: a process can overwrite that memory, and
/// later `setenv` changes never appear in it.
package struct ProcessEnvironmentIdentity: Equatable {
    package static let claudeConfigDirectoryKey = "CLAUDE_CONFIG_DIR"

    package let runtimeID: UUID?
    package let claudeConfigDirectory: String?

    package init(runtimeID: UUID?, claudeConfigDirectory: String?) {
        self.runtimeID = runtimeID
        self.claudeConfigDirectory = claudeConfigDirectory
    }
}

/// One consistent sample of a process. `.observed` establishes the birth identity only;
/// consumers must inspect each supporting field before treating ownership as verified.
package struct ProcessObservation: Equatable {
    package let identity: ProcessBirthIdentity
    package let parentPID: pid_t
    /// At the final sample the process had exited and was awaiting collection by its parent
    /// (`SZOMB`). Supporting evidence only.
    package let isZombie: Bool
    package let executablePath: ProcessInspectionField<String>
    package let processGroupID: ProcessInspectionField<pid_t>
    package let environment: ProcessInspectionField<ProcessEnvironmentIdentity>

    package init(
        identity: ProcessBirthIdentity,
        parentPID: pid_t,
        isZombie: Bool,
        executablePath: ProcessInspectionField<String>,
        processGroupID: ProcessInspectionField<pid_t>,
        environment: ProcessInspectionField<ProcessEnvironmentIdentity>
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.isZombie = isZombie
        self.executablePath = executablePath
        self.processGroupID = processGroupID
        self.environment = environment
    }
}

package enum ProcessInspectionResult: Equatable {
    case observed(ProcessObservation)
    /// The basic identity query confirmed that no process with this PID exists.
    case notFound
    /// No identity could be established. This never implies that the process exited.
    case unavailable(ProcessInspectionFailure)
}

/// Read-only, single-PID OS inspection. Stateless and synchronous: callers must run it off
/// the main actor because system queries can block. It never signals, retries, caches or
/// decides process ownership.
package struct ProcessInspection {
    /// Basic process information as returned by `PROC_PIDTBSDINFO`.
    struct BasicInfo: Equatable {
        var pid: pid_t
        var parentPID: pid_t
        var uid: uid_t
        var startSeconds: UInt64
        var startMicroseconds: UInt64
        var isZombie = false
    }

    /// Narrow system-query seam. Production uses Darwin directly; tests script responses.
    struct Backend {
        var bootSessionUUID: @Sendable () -> Result<String, ProcessInspectionFailure.Reason>
        var basicInfo: @Sendable (pid_t) -> Result<BasicInfo, ProcessInspectionFailure.Reason>
        var executablePath: @Sendable (pid_t) -> Result<String, ProcessInspectionFailure.Reason>
        var processGroup: @Sendable (pid_t) -> Result<pid_t, ProcessInspectionFailure.Reason>
        var processArguments: @Sendable (pid_t) -> Result<[UInt8], ProcessInspectionFailure.Reason>
        var effectiveUID: @Sendable () -> uid_t
    }

    private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    package static func inspect(pid: pid_t) -> ProcessInspectionResult {
        ProcessInspection(backend: .live).observe(pid: pid)
    }

    func observe(pid: pid_t) -> ProcessInspectionResult {
        guard pid > 0 else {
            return .unavailable(.init(operation: .basicInfo, reason: .invalidProcessID))
        }

        let firstBoot: UUID
        switch readBootSessionID() {
        case let .success(value): firstBoot = value
        case let .failure(failure): return .unavailable(failure)
        }

        let firstBasic: BasicInfo
        switch readBasicInfo(pid: pid) {
        case let .found(info): firstBasic = info
        case .notFound: return .notFound
        case let .unavailable(failure): return .unavailable(failure)
        }

        let executablePath = field(.executablePath, backend.executablePath(pid))
        let processGroupID = field(.processGroup, backend.processGroup(pid))
        let environment: ProcessInspectionField<ProcessEnvironmentIdentity> =
            if firstBasic.uid == backend.effectiveUID() {
                switch backend.processArguments(pid) {
                case let .success(buffer):
                    switch Self.parseEnvironmentIdentity(procArgs2: buffer) {
                    case let .success(identity): .available(identity)
                    case let .failure(reason): .unavailable(.init(operation: .arguments, reason: reason))
                    }
                case let .failure(reason):
                    .unavailable(.init(operation: .arguments, reason: reason))
                }
            } else {
                .unavailable(.init(operation: .arguments, reason: .accessDenied))
            }

        let finalBasic: BasicInfo
        switch readBasicInfo(pid: pid) {
        case let .found(info): finalBasic = info
        case .notFound: return .notFound
        case let .unavailable(failure): return .unavailable(failure)
        }

        let finalBoot: UUID
        switch readBootSessionID() {
        case let .success(value): finalBoot = value
        case let .failure(failure): return .unavailable(failure)
        }

        let identity = Self.identity(boot: firstBoot, basic: firstBasic)
        guard identity == Self.identity(boot: finalBoot, basic: finalBasic) else {
            return .unavailable(.init(operation: .consistency, reason: .inconsistentObservation))
        }

        // Reparenting alone is not an identity change; report the latest parent.
        return .observed(ProcessObservation(
            identity: identity,
            parentPID: finalBasic.parentPID,
            isZombie: finalBasic.isZombie,
            executablePath: executablePath,
            processGroupID: processGroupID,
            environment: environment
        ))
    }

    private enum BasicInfoRead {
        case found(BasicInfo)
        case notFound
        case unavailable(ProcessInspectionFailure)
    }

    private func readBasicInfo(pid: pid_t) -> BasicInfoRead {
        switch backend.basicInfo(pid) {
        case let .success(info):
            guard info.pid == pid else {
                return .unavailable(.init(operation: .basicInfo, reason: .malformedResponse))
            }
            return .found(info)
        case .failure(.syscallFailed(errno: ESRCH)):
            return .notFound
        case let .failure(reason):
            return .unavailable(.init(operation: .basicInfo, reason: reason))
        }
    }

    private func readBootSessionID() -> Result<UUID, ProcessInspectionFailure> {
        switch backend.bootSessionUUID() {
        case let .success(text):
            guard let value = UUID(uuidString: text) else {
                return .failure(.init(operation: .bootIdentity, reason: .malformedResponse))
            }
            return .success(value)
        case let .failure(reason):
            return .failure(.init(operation: .bootIdentity, reason: reason))
        }
    }

    private func field<Value: Sendable & Equatable>(
        _ operation: ProcessInspectionFailure.Operation,
        _ result: Result<Value, ProcessInspectionFailure.Reason>
    ) -> ProcessInspectionField<Value> {
        switch result {
        case let .success(value): .available(value)
        case let .failure(reason): .unavailable(.init(operation: operation, reason: reason))
        }
    }

    private static func identity(boot: UUID, basic: BasicInfo) -> ProcessBirthIdentity {
        ProcessBirthIdentity(
            bootSessionID: boot,
            pid: basic.pid,
            startSeconds: basic.startSeconds,
            startMicroseconds: basic.startMicroseconds,
            uid: basic.uid
        )
    }

    // MARK: - KERN_PROCARGS2 parsing

    private static let runtimeIDKey = Array(ProcessLauncher.runtimeMarkerEnvironmentKey.utf8)
    private static let claudeConfigDirectoryKey = Array(ProcessEnvironmentIdentity.claudeConfigDirectoryKey.utf8)

    /// Extracts only the selected markers from a `KERN_PROCARGS2` buffer laid out as
    /// `argc (Int32) | exec path NUL | NUL padding | argc argument strings | NUL run | environment strings`.
    /// The NUL run after the arguments covers an argv area zero-filled by a process-title rewrite
    /// (libuv `uv_set_process_title`). No other argument or environment content is decoded or copied.
    static func parseEnvironmentIdentity(
        procArgs2 buffer: [UInt8]
    ) -> Result<ProcessEnvironmentIdentity, ProcessInspectionFailure.Reason> {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count >= countSize else { return .failure(.malformedResponse) }
        let argumentCount = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount >= 0, Int(argumentCount) <= buffer.count else { return .failure(.malformedResponse) }

        func endOfString(from start: Int) -> Int? {
            buffer[start...].firstIndex(of: 0)
        }

        // Executable path: must be non-empty and NUL-terminated.
        var cursor = countSize
        guard cursor < buffer.count, buffer[cursor] != 0, let execEnd = endOfString(from: cursor) else {
            return .failure(.malformedResponse)
        }
        cursor = execEnd + 1
        while cursor < buffer.count, buffer[cursor] == 0 {
            cursor += 1
        }

        for _ in 0 ..< argumentCount {
            guard cursor < buffer.count, let end = endOfString(from: cursor) else {
                return .failure(.malformedResponse)
            }
            cursor = end + 1
        }
        // With an empty environment this reaches the trailing apple strings, whose keys never match.
        while cursor < buffer.count, buffer[cursor] == 0 {
            cursor += 1
        }

        var runtimeIDValue: ArraySlice<UInt8>?
        var claudeConfigDirectoryValue: ArraySlice<UInt8>?
        // Environment entries end at the first empty string or at the end of the buffer.
        while cursor < buffer.count, buffer[cursor] != 0 {
            guard let end = endOfString(from: cursor) else { return .failure(.malformedResponse) }
            let entry = buffer[cursor ..< end]
            cursor = end + 1
            guard let separator = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = entry[entry.startIndex ..< separator]
            if key.elementsEqual(runtimeIDKey) {
                guard runtimeIDValue == nil else { return .failure(.malformedResponse) }
                runtimeIDValue = entry[(separator + 1)...]
            } else if key.elementsEqual(claudeConfigDirectoryKey) {
                guard claudeConfigDirectoryValue == nil else { return .failure(.malformedResponse) }
                claudeConfigDirectoryValue = entry[(separator + 1)...]
            }
        }

        var runtimeID: UUID?
        if let runtimeIDValue {
            guard let text = String(bytes: runtimeIDValue, encoding: .utf8),
                  let value = UUID(uuidString: text)
            else { return .failure(.malformedResponse) }
            runtimeID = value
        }
        var claudeConfigDirectory: String?
        if let claudeConfigDirectoryValue {
            guard let text = String(bytes: claudeConfigDirectoryValue, encoding: .utf8) else {
                return .failure(.malformedResponse)
            }
            claudeConfigDirectory = text
        }
        return .success(ProcessEnvironmentIdentity(runtimeID: runtimeID, claudeConfigDirectory: claudeConfigDirectory))
    }
}

// MARK: - Darwin backend

extension ProcessInspection.Backend {
    static let live = ProcessInspection.Backend(
        bootSessionUUID: {
            var size = 0
            guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else {
                return .failure(.syscallFailed(errno: errno))
            }
            guard size > 1, size <= 64 else { return .failure(.malformedResponse) }
            var bytes = [UInt8](repeating: 0, count: size)
            guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
                return .failure(.syscallFailed(errno: errno))
            }
            guard size <= bytes.count, let end = bytes[..<size].firstIndex(of: 0),
                  let text = String(bytes: bytes[..<end], encoding: .utf8)
            else { return .failure(.malformedResponse) }
            return .success(text)
        },
        basicInfo: { pid in
            readBasicInfo(pid: pid) { pid, info in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            }
        },
        executablePath: { pid in
            readExecutablePath(pid: pid) { pid, bytes in
                proc_pidpath(pid, &bytes, UInt32(bytes.count))
            }
        },
        processGroup: { pid in
            let group = getpgid(pid)
            guard group >= 0 else { return .failure(.syscallFailed(errno: errno)) }
            return .success(group)
        },
        processArguments: { pid in
            var argumentMax: Int32 = 0
            var argumentMaxSize = MemoryLayout<Int32>.size
            var argumentMaxName: [Int32] = [CTL_KERN, KERN_ARGMAX]
            guard sysctl(&argumentMaxName, 2, &argumentMax, &argumentMaxSize, nil, 0) == 0 else {
                return .failure(.syscallFailed(errno: errno))
            }
            guard argumentMax > 0 else { return .failure(.malformedResponse) }
            var bytes = [UInt8](repeating: 0, count: Int(argumentMax))
            var size = bytes.count
            var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            guard sysctl(&name, 3, &bytes, &size, nil, 0) == 0 else {
                return .failure(.syscallFailed(errno: errno))
            }
            guard size <= bytes.count else { return .failure(.malformedResponse) }
            return .success(Array(bytes[..<size]))
        },
        effectiveUID: { geteuid() }
    )

    /// `proc_pidinfo` and `proc_pidpath` return 0 on failure and may leave `errno` untouched,
    /// so `errno` is cleared first: a stale `ESRCH` must never be read as confirmed absence.
    /// A zero return with no fresh `errno` is ambiguous and reported as malformed.
    private static func failureReasonAfterZeroReturn(_ capturedErrno: Int32) -> ProcessInspectionFailure.Reason {
        capturedErrno == 0 ? .malformedResponse : .syscallFailed(errno: capturedErrno)
    }

    static func readBasicInfo(
        pid: pid_t,
        query: (pid_t, inout proc_bsdinfo) -> Int32
    ) -> Result<ProcessInspection.BasicInfo, ProcessInspectionFailure.Reason> {
        var info = proc_bsdinfo()
        errno = 0
        let written = query(pid, &info)
        let capturedErrno = errno
        guard written > 0 else { return .failure(failureReasonAfterZeroReturn(capturedErrno)) }
        guard written == Int32(MemoryLayout<proc_bsdinfo>.size) else { return .failure(.malformedResponse) }
        return .success(ProcessInspection.BasicInfo(
            pid: pid_t(bitPattern: info.pbi_pid),
            parentPID: pid_t(bitPattern: info.pbi_ppid),
            uid: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            isZombie: info.pbi_status == UInt32(SZOMB)
        ))
    }

    static func readExecutablePath(
        pid: pid_t,
        query: (pid_t, inout [UInt8]) -> Int32
    ) -> Result<String, ProcessInspectionFailure.Reason> {
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        errno = 0
        let length = query(pid, &bytes)
        let capturedErrno = errno
        guard length > 0 else { return .failure(failureReasonAfterZeroReturn(capturedErrno)) }
        guard Int(length) <= bytes.count,
              let text = String(bytes: bytes[..<Int(length)], encoding: .utf8)
        else { return .failure(.malformedResponse) }
        return .success(text)
    }
}
