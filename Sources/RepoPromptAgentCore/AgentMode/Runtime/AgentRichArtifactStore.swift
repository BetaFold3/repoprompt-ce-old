import Darwin
import Foundation
import ImageIO

/// Acquire AFTER session gates; physical moves acquire only this fence. A cancelled waiter
/// eventually acquires, checks cancellation, and releases: it never leaves a filesystem worker.
package final class AgentRichArtifactFilesystemFence: @unchecked Sendable {
    package static let shared = AgentRichArtifactFilesystemFence()
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}
    package func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if held {
                waiters.append(continuation)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    package func release() {
        lock.lock()
        if waiters.isEmpty {
            held = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// Immutable session-relative bundles. DataService, not this helper, owns lifetime authority.
/// Directory-relative no-follow access rejects symlinks in EVERY component below the trusted,
/// once-resolved workspace root. Generated UUID filenames are the only accepted asset names.
package enum AgentRichArtifactStore {
    fileprivate final class Directory: @unchecked Sendable {
        let fd: Int32
        init(root: URL) throws {
            fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw AgentRichArtifactError.unsafePath }
        }

        init(parent: Directory, name: String, create: Bool = false) throws {
            if create, mkdirat(parent.fd, name, 0o700) != 0, errno != EEXIST { throw Self.failure() }
            fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw AgentRichArtifactError.unsafePath }
        }

        deinit { close(fd) }
        static func failure() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        func read(_ name: String, limit: Int) throws -> Data {
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else { throw AgentRichArtifactError.unsafePath }
            defer { close(file) }
            var info = stat()
            guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1, info.st_size > 0, info.st_size <= limit
            else { throw AgentRichArtifactError.unsafePath }
            let bytes = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
            guard bytes.count == info.st_size else { throw AgentRichArtifactError.invalidManifest }
            return bytes
        }

        func write(_ name: String, bytes: Data, cancellation: Cancellation?) throws {
            let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard file >= 0 else { throw Self.failure() }
            defer { close(file) }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
            for offset in stride(from: 0, to: bytes.count, by: 64 * 1024) {
                try cancellation?.check()
                try handle.write(contentsOf: bytes[offset ..< min(bytes.count, offset + 64 * 1024)])
            }
        }

        func removeTree(_ name: String) throws {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return }
                throw Self.failure()
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                let child = try Directory(parent: self, name: name)
                // fdopendir owns its duplicated descriptor. Names are used ONLY with openat/
                // unlinkat, never appended to a path interpreted outside this directory.
                let duplicate = dup(child.fd)
                guard duplicate >= 0 else { throw Self.failure() }
                guard let stream = fdopendir(duplicate) else {
                    close(duplicate)
                    throw Self.failure()
                }
                // Enumerate fully before unlinking: removing entries mid-readdir may skip some.
                var components: [String] = []
                while let entry = readdir(stream) {
                    let component = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    if component != ".", component != ".." { components.append(component) }
                }
                closedir(stream)
                for component in components {
                    try child.removeTree(component)
                }
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw Self.failure() }
            } else {
                // Unlink a symlink itself, never follow it during session cleanup.
                guard unlinkat(fd, name, 0) == 0 else { throw Self.failure() }
            }
        }
    }

    package final class Staged: @unchecked Sendable {
        private let parent: Directory
        private let name: String
        private let finalName: String
        fileprivate init(parent: Directory, name: String, finalName: String) {
            self.parent = parent
            self.name = name
            self.finalName = finalName
        }

        fileprivate func install() throws {
            guard renameatx_np(parent.fd, name, parent.fd, finalName, UInt32(RENAME_EXCL)) == 0 else {
                throw Directory.failure()
            }
        }

        fileprivate func discard() throws {
            try parent.removeTree(name)
        }
    }

    /// Awaited to actual completion, even on cancellation. Two admitted operations bound dispatch
    /// work; callers copy bundles sequentially. Never use a detached, abandonable filesystem task.
    package static func offMain<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    package final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        fileprivate func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        package func check() throws {
            lock.lock()
            let value = cancelled
            lock.unlock()
            if value { throw CancellationError() }
        }
    }

    package static func cancellable<T>(_ work: @escaping @Sendable (Cancellation) throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await offMain { try work(cancellation) }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func validateAsset(_ bytes: Data, manifest: AgentRichArtifactManifest, id: UUID) throws {
        guard let record = manifest.images.first(where: {
            if case let .asset(asset) = $0.terminal.outcome { return asset.assetID == id }
            return false
        }), case let .asset(asset) = record.terminal.outcome,
        let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        CGImageSourceGetType(source) as String? == "public.jpeg",
        CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        (properties[kCGImagePropertyPixelWidth] as? Int) == asset.width,
        (properties[kCGImagePropertyPixelHeight] as? Int) == asset.height
        else { throw AgentRichArtifactError.invalidManifest }
    }

    private static func sessionDirectory(root: URL, sessionID: UUID, create: Bool = false) throws -> Directory {
        let workspace = try Directory(root: root)
        let parent = try Directory(parent: workspace, name: "agent_rich_artifacts", create: create)
        return try Directory(parent: parent, name: sessionID.uuidString, create: create)
    }

    private static func readBundle(
        root: URL, sessionID: UUID, reference: RichPresentationReference
    ) throws -> (AgentRichArtifactManifest, Directory) {
        let session = try sessionDirectory(root: root, sessionID: sessionID)
        let bundle = try Directory(parent: session, name: reference.artifactID.uuidString)
        let manifest = try JSONDecoder().decode(
            AgentRichArtifactManifest.self,
            from: bundle.read("manifest.json", limit: AgentRichArtifactManifest.maxEncodedBytes)
        )
        try manifest.validate(reference: reference)
        return (manifest, bundle)
    }

    package static func read(root: URL, sessionID: UUID, reference: RichPresentationReference) throws -> AgentRichArtifactManifest {
        let (manifest, bundle) = try readBundle(root: root, sessionID: sessionID, reference: reference)
        for id in manifest.assetIDs {
            try validateAsset(bundle.read(id.uuidString + ".jpg", limit: 4 * 1024 * 1024), manifest: manifest, id: id)
        }
        return manifest
    }

    /// History read: the validated manifest only. Assets are read separately so a missing image
    /// degrades to its placeholder while a missing manifest degrades to the labeled fallback.
    /// The strict `read`/`copy` contracts (every asset must validate) are unchanged.
    package static func readManifest(root: URL, sessionID: UUID, reference: RichPresentationReference) throws -> AgentRichArtifactManifest {
        try readBundle(root: root, sessionID: sessionID, reference: reference).0
    }

    /// History read of one asset named by `manifest`, validated against its recorded dimensions.
    package static func readAsset(root: URL, sessionID: UUID, manifest: AgentRichArtifactManifest, assetID: UUID) throws -> Data {
        guard manifest.assetIDs.contains(assetID) else { throw AgentRichArtifactError.invalidManifest }
        let session = try sessionDirectory(root: root, sessionID: sessionID)
        let bundle = try Directory(parent: session, name: manifest.artifactID.uuidString)
        let bytes = try bundle.read(assetID.uuidString + ".jpg", limit: 4 * 1024 * 1024)
        try validateAsset(bytes, manifest: manifest, id: assetID)
        return bytes
    }

    package static func stage(
        root: URL, sessionID: UUID, manifest: AgentRichArtifactManifest, assets: [UUID: Data], cancellation: Cancellation? = nil
    ) throws -> Staged {
        try cancellation?.check()
        try manifest.validate()
        guard Set(manifest.assetIDs) == Set(assets.keys) else { throw AgentRichArtifactError.invalidManifest }
        let parent = try sessionDirectory(root: root, sessionID: sessionID, create: true)
        let name = ".staging-" + UUID().uuidString
        let staged = Staged(parent: parent, name: name, finalName: manifest.artifactID.uuidString)
        let directory = try Directory(parent: parent, name: name, create: true)
        do {
            for id in manifest.assetIDs {
                guard let bytes = assets[id], !bytes.isEmpty, bytes.count <= 4 * 1024 * 1024 else {
                    throw AgentRichArtifactError.invalidManifest
                }
                try cancellation?.check()
                try validateAsset(bytes, manifest: manifest, id: id)
                try directory.write(id.uuidString + ".jpg", bytes: bytes, cancellation: cancellation)
            }
            // Never install a bundle that the bounded reader would refuse.
            let encoded = try AgentRichArtifactManifest.encoded(manifest)
            try directory.write("manifest.json", bytes: encoded, cancellation: cancellation)
            return staged
        } catch {
            try? staged.discard()
            throw error
        }
    }

    /// Only the bounded exclusive rename runs on main, together with final app authority checks.
    package static func install(_ stage: Staged) throws {
        try stage.install()
    }

    package static func discard(_ stage: Staged) {
        do { try stage.discard() }
        catch { print("[RichArtifact] staging cleanup failed: \(error)") }
    }

    package static func copy(root: URL, source: UUID, destination: UUID, reference: RichPresentationReference, cancellation: Cancellation? = nil) throws {
        let manifest: AgentRichArtifactManifest
        let bundle: Directory
        do { (manifest, bundle) = try readBundle(root: root, sessionID: source, reference: reference) }
        catch { throw AgentRichArtifactError.missingArtifact(reference.artifactID) }
        var assets: [UUID: Data] = [:]
        for id in manifest.assetIDs {
            try cancellation?.check()
            assets[id] = try bundle.read(id.uuidString + ".jpg", limit: 4 * 1024 * 1024)
        }
        let staged = try stage(root: root, sessionID: destination, manifest: manifest, assets: assets, cancellation: cancellation)
        defer { discard(staged) }
        try install(staged)
        _ = try read(root: root, sessionID: destination, reference: reference)
    }

    package static func removeSession(root: URL, sessionID: UUID) throws {
        // A root that does not exist holds no tree (nothing to remove); a symlinked root still refuses.
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) != 0, errno == ENOENT { return }
        let workspace = try Directory(root: root)
        var info = stat()
        guard fstatat(workspace.fd, "agent_rich_artifacts", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw Directory.failure()
        }
        let parent = try Directory(parent: workspace, name: "agent_rich_artifacts")
        try parent.removeTree(sessionID.uuidString)
    }
}
