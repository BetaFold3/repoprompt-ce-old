#if DEBUG
    import Darwin
    import Foundation
    import RepoPromptShared
    import RepoPromptWorkspace

    /// One opt-in, app-local capture. The lock bounds admission work; only the serial queue
    /// touches files. Neither recording nor failure changes a connection decision.
    final class MCPStartupDiagnostics: @unchecked Sendable {
        static let shared = MCPStartupDiagnostics()
        @TaskLocal static var handshakeID: UUID?

        enum Kind: String, Codable {
            case header, peerObserved, connectionLinked, launchObserved, handshakeReadFailed
            case bootstrapAccepted, bootstrapRejected, acceptedResponseFailed
            case approvalStarted, approvalAccepted, approvalRefused, slotRefused, terminal, stopped
        }

        /// Closed vocabulary: unrecognized upstream strings are never serialized.
        enum Reason: String, Codable {
            case unknown, approval_denied, protocol_version_mismatch, server_not_ready
            case server_unavailable, connection_limit_reached, capacity_exceeded
            case session_blocked, client_cooldown, stale_generation, empty_client_identity
            case approval_rejected, companion_attach_failed, policy_wait_timeout
            case policy_reserved, policy_removed, ownership_timeout, not_consumable
            case policy_reservation_failed, cancelled, slot_refused, handshake_inactive
            case ownership_transfer_failed, ownership_hooks_missing
            case connection_bound_to_other_run, session_token_bound_to_other_run, stale_connection
            case user_boot_from_dashboard, run_completed, run_cancelled, server_shutdown
            case idle_timeout, connection_replaced, tool_execution_watchdog
            case connection_approval_handler_unavailable, tool_list_notification_failure
            case maintenance_prune_failed, maintenance_prune_cancelled, maintenance_prune_nonviable
            case maintenance_prune_connect_timeout, pressure_eviction
            case global_admission_eviction_lifecycle_invalidated, global_admission_eviction_restore_failed
            case companion_grant_replaced, companion_grant_cleared, companion_superseded
            case peer_eof, incomplete_eof, read_error, write_failure, write_stall, write_hangup
            case receive_buffer_overflow, local_disconnect, connect_failure, connect_cancelled
            case connection_start_failure, connection_start_cancelled, connection_cleanup_unspecified
            case per_client_admission_eviction, global_admission_eviction
        }

        enum Site: String, Codable {
            case initialFence, clientCooldown, afterPendingPublished, afterGlobalPrune
            case afterGlobalEviction, globalNoProgress, afterClientPrune
            case afterClientEviction, clientNoProgress, beforeCommit
        }

        enum Code: String, Codable {
            case starting, ready, ended, deadline, overflow, writeFailure, busy, forbidden
            case notFound, retentionFull
        }

        enum IdentityState: String, Codable { case observed, unknown }

        struct ProcessInstance: Codable {
            let pid: Int32
            let startSeconds: Int64
            let startMicroseconds: Int32
            init(_ identity: MCPHelperProcessIdentity) {
                pid = identity.pid
                startSeconds = identity.startSeconds
                startMicroseconds = identity.startMicroseconds
            }
        }

        struct Event: Codable {
            var kind: Kind
            var schema: Int?
            var reason: Reason?
            var site: Site?
            var handshakeID: UUID?
            var connectionID: UUID?
            var runID: UUID?
            var generation: UInt64?
            var peerPID: Int32?
            var identityState: IdentityState?
            var peer: ProcessInstance?
            var ancestors: [ProcessInstance]?
            var sessionFingerprint: MCPTerminalFingerprint?
            var launchFingerprint: MCPTerminalFingerprint?
        }

        struct Status {
            let code: Code
            let captureID: UUID?
            let records: Int
            let bytes: Int
            let drained: Bool
        }

        private struct Record: Encodable {
            let captureID: UUID
            let sequence: Int
            let uptimeOffset: TimeInterval
            let utc: Date
            let appPID: Int32
            let appIdentityKnown: Bool
            let app: ProcessInstance?
            let event: Event
            let stop: Code?
        }

        /// Metadata is lock-protected; file/timer state is writer-queue confined. App identity
        /// is initialized on that queue before publishing ready under the lock, then immutable.
        private final class Capture: @unchecked Sendable {
            let id = UUID()
            let owner: UUID
            let started: TimeInterval
            var app: ProcessInstance?
            var code = Code.starting
            var records = 0
            var bytes = 0
            var drained = false
            // Queue-confined file state.
            var file: FileHandle?
            var timer: DispatchSourceTimer?
            init(owner: UUID, started: TimeInterval) {
                self.owner = owner
                self.started = started
            }
        }

        private let lock = NSLock()
        private let queue = DispatchQueue(label: "com.repoprompt.mcp.startup-diagnostics")
        private let directory: URL?
        private let reader: any MCPProcessTableReading
        private let now: @Sendable () -> TimeInterval
        private let write: @Sendable (FileHandle, Data) throws -> Void
        private let recordLimit: Int
        private let byteLimit: Int
        private let stopReserve = 2048
        private var capture: Capture?

        init(
            directory: URL? = nil,
            reader: any MCPProcessTableReading = MCPSystemProcessTableReader(),
            recordLimit: Int = 1024,
            byteLimit: Int = 1024 * 1024,
            now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            write: @escaping @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
        ) {
            self.directory = directory
            self.reader = reader
            self.recordLimit = max(2, min(1024, recordLimit))
            self.byteLimit = max(4096, min(1024 * 1024, byteLimit))
            self.now = now
            self.write = write
        }

        func begin(owner: UUID) async -> Status {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let capture, !capture.drained {
                    lock.unlock()
                    continuation.resume(returning: Status(code: .busy, captureID: nil, records: 0, bytes: 0, drained: false))
                    return
                }
                let current = Capture(owner: owner, started: now())
                capture = current
                // Enqueue under the same lock used by record/end, preserving order.
                queue.async {
                    do {
                        let directory = self.directory ?? MCPFilesystemConstants.eventsDirectoryURL()
                            .appendingPathComponent("startup-diagnostics", isDirectory: true)
                        let fm = FileManager.default
                        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let attributes = try fm.attributesOfItem(atPath: directory.path)
                        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteUnknown) }
                        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                        guard try fm.contentsOfDirectory(atPath: directory.path).count(where: { $0.hasSuffix(".jsonl") }) < 4 else {
                            self.finishFailedBegin(current, code: .retentionFull)
                            continuation.resume(returning: self.snapshot(current))
                            return
                        }
                        let url = directory.appendingPathComponent(current.id.uuidString + ".jsonl")
                        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
                        current.file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        if case let .present(identity, _, _) = self.reader.entry(for: getpid()) {
                            current.app = ProcessInstance(identity)
                        }
                        let header = try self.encode(Event(kind: .header, schema: 1), capture: current, sequence: 0)
                        try self.write(current.file!, header)
                        self.lock.lock()
                        current.records = 1
                        current.bytes = header.count
                        current.code = .ready
                        self.lock.unlock()
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        let remaining = max(0, current.started + 180 - self.now())
                        timer.schedule(deadline: .now() + remaining)
                        timer.setEventHandler { [weak self, weak current] in
                            guard let self, let current else { return }
                            lock.lock()
                            if current.code == .ready { stopLocked(current, code: .deadline) }
                            lock.unlock()
                        }
                        current.timer = timer
                        timer.resume()
                        continuation.resume(returning: self.snapshot(current))
                    } catch {
                        self.finishFailedBegin(current, code: .writeFailure)
                        continuation.resume(returning: self.snapshot(current))
                    }
                }
                lock.unlock()
            }
        }

        /// The autoclosure (including any diagnostic process reads) is not evaluated when disabled.
        func record(_ event: @autoclosure () -> Event) {
            lock.lock()
            defer { lock.unlock() }
            guard let capture, capture.code == .ready else { return }
            guard now() - capture.started < 180 else {
                stopLocked(capture, code: .deadline)
                return
            }
            do {
                let data = try encode(event(), capture: capture, sequence: capture.records)
                guard capture.records < recordLimit - 1,
                      capture.bytes + data.count <= byteLimit - stopReserve
                else {
                    stopLocked(capture, code: .overflow)
                    return
                }
                capture.records += 1
                capture.bytes += data.count
                queue.async { self.append(data, to: capture) }
            } catch {
                stopLocked(capture, code: .writeFailure)
            }
        }

        func peerEvent(handshakeID: UUID, peerPID: Int32?, generation: UInt64) -> Event {
            let snapshot = peerPID.flatMap { MCPHelperPeerProcessSnapshot.capture(peerPID: $0, reader: reader) }
            return Event(
                kind: .peerObserved, handshakeID: handshakeID, generation: generation,
                peerPID: peerPID, identityState: snapshot == nil ? .unknown : .observed, peer: snapshot.map { ProcessInstance($0.peer) },
                ancestors: snapshot.map { $0.ancestors.map(ProcessInstance.init) }
            )
        }

        func status(owner: UUID, captureID: UUID, end: Bool = false) async -> Status {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard let current = capture, current.id == captureID else {
                    lock.unlock()
                    continuation.resume(returning: Status(code: .notFound, captureID: nil, records: 0, bytes: 0, drained: true))
                    return
                }
                guard current.owner == owner else {
                    lock.unlock()
                    continuation.resume(returning: Status(code: .forbidden, captureID: nil, records: 0, bytes: 0, drained: false))
                    return
                }
                if current.code == .ready {
                    if now() - current.started >= 180 { stopLocked(current, code: .deadline) }
                    else if end { stopLocked(current, code: .ended) }
                }
                queue.async { continuation.resume(returning: self.snapshot(current)) }
                lock.unlock()
            }
        }

        private func encode(_ event: Event, capture: Capture, sequence: Int, stop: Code? = nil) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            var data = try encoder.encode(Record(
                captureID: capture.id, sequence: sequence, uptimeOffset: max(0, now() - capture.started),
                utc: Date(), appPID: getpid(), appIdentityKnown: capture.app != nil, app: capture.app, event: event, stop: stop
            ))
            data.append(0x0A)
            return data
        }

        /// Lock held. Reserve the final record before enqueueing; later events cannot overtake it.
        private func stopLocked(_ current: Capture, code: Code) {
            current.code = code
            let data = try? encode(Event(kind: .stopped), capture: current, sequence: current.records, stop: code)
            if let data, data.count <= stopReserve, current.bytes + data.count <= byteLimit {
                current.records += 1
                current.bytes += data.count
                queue.async { self.append(data, to: current) }
            }
            queue.async {
                current.timer?.cancel()
                current.timer = nil
                try? current.file?.close()
                current.file = nil
                self.lock.lock()
                current.drained = true
                self.lock.unlock()
            }
        }

        private func append(_ data: Data, to current: Capture) {
            guard let file = current.file else { return }
            do { try write(file, data) }
            catch {
                try? file.close()
                current.file = nil
                current.timer?.cancel()
                current.timer = nil
                lock.lock()
                if current.code == .ready { stopLocked(current, code: .writeFailure) }
                current.code = .writeFailure
                lock.unlock()
            }
        }

        private func finishFailedBegin(_ current: Capture, code: Code) {
            try? current.file?.close()
            current.file = nil
            lock.lock()
            current.code = code
            current.drained = true
            lock.unlock()
        }

        private func snapshot(_ current: Capture) -> Status {
            lock.lock()
            defer { lock.unlock() }
            return Status(code: current.code, captureID: current.id, records: current.records, bytes: current.bytes, drained: current.drained)
        }
    }
#endif
