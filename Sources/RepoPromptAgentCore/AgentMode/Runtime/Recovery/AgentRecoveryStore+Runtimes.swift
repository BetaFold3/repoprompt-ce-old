import Foundation

// Runtime records (spec R6) share the recovery store's root, atomic writes and preservation rules.
// They are written only on behalf of `AgentProcessRegistry`, with opaque compare-and-swap
// revisions. Nothing here deletes or retires runtime files (no retention or GC in Phase 3).
//
// These members are `nonisolated` and synchronous: runtime files have exactly one writer, the
// registry actor, which serializes them and must not suspend between an ownership decision and
// its durable write. Session-record state is never touched here.

package extension AgentRecoveryStore {
    nonisolated var runtimesDirectoryURL: URL {
        rootURL.appendingPathComponent("runtimes", isDirectory: true)
    }

    nonisolated func runtimeFileURL(runtimeID: UUID) -> URL {
        runtimesDirectoryURL.appendingPathComponent("\(runtimeID.uuidString).json")
    }

    nonisolated func readRuntime(runtimeID: UUID) -> AgentRuntimeRecordState {
        let data: Data
        do {
            data = try Data(contentsOf: runtimeFileURL(runtimeID: runtimeID))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .absent
        } catch {
            return .preserved(.unreadableFile(String(describing: error)))
        }
        switch AgentRuntimeRecordCodec.decode(data, expectedRuntimeID: runtimeID) {
        case let .success(record): return .supported(record)
        case let .failure(reason): return .preserved(reason)
        }
    }

    /// Every runtime file, in file-name order. A directory that cannot be listed throws (callers
    /// treat it as unknown ownership everywhere); a missing directory has no runtimes.
    nonisolated func discoverRuntimes() throws -> [AgentRuntimeDiscoveryEntry] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: runtimesDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw AgentRecoveryStoreError.classifiedStorageFailure(error)
        }
        var entries: [AgentRuntimeDiscoveryEntry] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let runtimeID = UUID(uuidString: stem), runtimeID.uuidString == stem else {
                entries.append(.preserved(runtimeID: nil, reason: .malformed("file name is not a runtime UUID"), bindings: nil))
                continue
            }
            switch readRuntime(runtimeID: runtimeID) {
            case .absent: continue
            case let .supported(record): entries.append(.supported(record))
            case let .preserved(reason):
                entries.append(.preserved(runtimeID: runtimeID, reason: reason, bindings: Self.preservedBindings(at: url)))
            }
        }
        return entries
    }

    /// Lenient read of an unreadable record's bindings: both `conversationIDs` and `worktreePaths`
    /// must be string arrays, any `associations` a well-formed array of objects, and at least one
    /// binding present; anything else cannot scope the uncertainty. Session IDs come from the
    /// associations' sessions (an association without a readable session ID scopes nothing).
    private nonisolated static func preservedBindings(at url: URL) -> AgentRuntimePreservedBindings? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversationIDs = object["conversationIDs"] as? [String],
              let worktreePaths = object["worktreePaths"] as? [String]
        else { return nil }
        var sessionIDs: [UUID] = []
        if let rawAssociations = object["associations"] {
            guard let associations = rawAssociations as? [[String: Any]] else { return nil }
            for association in associations {
                guard let session = association["session"] else { continue }
                guard let session = session as? [String: Any],
                      let raw = session["sessionID"] as? String,
                      let sessionID = UUID(uuidString: raw)
                else { return nil }
                if !sessionIDs.contains(sessionID) { sessionIDs.append(sessionID) }
            }
        }
        guard !(conversationIDs.isEmpty && worktreePaths.isEmpty && sessionIDs.isEmpty) else { return nil }
        return AgentRuntimePreservedBindings(conversationIDs: conversationIDs, worktreePaths: worktreePaths, sessionIDs: sessionIDs)
    }

    /// Writes `record` when the stored revision equals `expectedRevision` (`nil`: no file may
    /// exist). Issues a fresh opaque revision and `updatedAt`, keeps the record's extras, and never
    /// replaces preserved data.
    nonisolated func writeRuntime(
        _ record: AgentRuntimeRecord,
        expectedRevision: AgentRecoveryRecordRevision?
    ) throws -> AgentRuntimeRecord {
        switch readRuntime(runtimeID: record.runtimeID) {
        case .absent:
            guard expectedRevision == nil else {
                throw AgentRecoveryStoreError.revisionConflict(expected: expectedRevision, actual: nil)
            }
        case let .supported(current):
            guard current.revision == expectedRevision else {
                throw AgentRecoveryStoreError.revisionConflict(expected: expectedRevision, actual: current.revision)
            }
        case let .preserved(reason):
            throw AgentRecoveryStoreError.unreadableRecord(record.runtimeID, reason)
        }
        var next = record
        next.revision = .make()
        next.updatedAt = AgentRecoveryTimestamp(now())
        do {
            let data = try AgentRuntimeRecordCodec.encode(next)
            try FileManager.default.createDirectory(at: runtimesDirectoryURL, withIntermediateDirectories: true)
            try fileOperations.writeAtomically(data, runtimeFileURL(runtimeID: next.runtimeID))
        } catch {
            throw AgentRecoveryStoreError.classifiedStorageFailure(error)
        }
        return next
    }
}
