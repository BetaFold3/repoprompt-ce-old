import CryptoKit
import Darwin
import Foundation
import RepoPromptAgentCore
import RepoPromptPlatform
import RepoPromptRemoteWire

protocol RemotePairingKeychainStoring: Sendable {
    func get(for key: String, accessMode: KeychainAccessMode) throws -> String
    func save(_ value: String, for key: String, accessMode: KeychainAccessMode) throws
}

extension KeychainService: RemotePairingKeychainStoring {}

enum RemotePairingIdentityStoreError: Error, Equatable {
    case missing
    case notRegularFile
    case wrongOwner
    case insecurePermissions
    case unreadable
    case invalidRegistry
    case invalidHostKey
    case keychainUnavailable(String)
    case writeFailed(String)
    case deviceNotFound(String)
    /// The on-disk registry declares a schema version newer than this build understands. Recovery
    /// is a compatible build or explicit Mac recovery — never a silent downgrade.
    case unsupportedSchemaVersion(Int)
    /// A save was refused because the backing file changed outside this store instance since it was
    /// last loaded (fail-closed; the store does not overwrite unknown state).
    case concurrentModification
    /// A compare-and-update policy mutation found a different current epoch than expected.
    case policyConflict
    /// A credential commit was refused because the credential ID is already assigned to another
    /// record (including a revoked record) in this build's registry.
    case duplicateCredentialID
    /// A policy mutation could not advance the epoch because it is already at `UInt64.max`. Epoch
    /// monotonicity is a security property, so this fails closed rather than wrapping to 0.
    case epochOverflow
}

/// Fingerprint of the backing file used to detect out-of-process modification between load and save.
enum RemotePairingRegistryFingerprint: Equatable {
    case missing
    case present(inode: UInt64, size: Int64, mtimeSeconds: Int, mtimeNanoseconds: Int)
}

final class RemotePairingIdentityStore: @unchecked Sendable {
    static let shared = RemotePairingIdentityStore()

    static let directoryComponents = RemoteControlStorageNamespace.rootComponents
    static let fileName = "paired-devices-v1.json"
    static var hostSigningKeyAccount: String {
        RemoteControlStorageNamespace.hostSigningKeyAccount()
    }

    let url: URL

    /// Random per-process identifier. The gateway must echo this with any applied-policy
    /// acknowledgment so an acknowledgment from a previous app process cannot mark a newer policy
    /// applied (bound in Step 3).
    let launchNonce: String

    private let fileManager: FileManager
    private let expectedOwnerID: UInt32
    private let keychain: RemotePairingKeychainStoring
    private let lock = NSRecursiveLock()
    /// Sidebar/dashboard render-time callers can otherwise pay Keychain + lstat + JSON decode per row.
    /// This store is the ONLY reader and writer of the file: the app funnels every mutation through
    /// save(_:), and the out-of-process gateway learns device/policy state over MCP (`list_devices`),
    /// never by opening this file — so a schema-v2 save cannot break any out-of-process reader.
    /// Trade-off: writes from another app instance stay invisible until an in-process save() — the
    /// pre-cache behavior re-read the file per call and was eventually consistent; the supported
    /// model is a single app instance.
    private var cachedRegistry: PairedDeviceRegistry?
    /// Fingerprint recorded when the registry was last read or written in this instance. `save`
    /// refuses to overwrite if the current on-disk fingerprint no longer matches this.
    private var recordedFingerprint: RemotePairingRegistryFingerprint?
    /// Set once an out-of-process modification is detected; every subsequent read/write fails closed
    /// until the app is relaunched.
    private var fenced = false
    /// Incremented once per committed save. Exposed through `trustSnapshot()` so the gateway can
    /// acknowledge the exact revision it applied.
    private(set) var saveRevision: UInt64 = 0

    init(
        url: URL? = nil,
        fileManager: FileManager = .default,
        expectedOwnerID: UInt32 = getuid(),
        keychain: RemotePairingKeychainStoring = KeychainService.officialV2Shared
    ) {
        self.url = url ?? Self.defaultURL(fileManager: fileManager)
        self.fileManager = fileManager
        self.expectedOwnerID = expectedOwnerID
        self.keychain = keychain
        launchNonce = Self.makeLaunchNonce()
    }

    static func defaultURL(
        channel: RemoteControlBuildChannel = RemoteControlBuildIdentity.current.channel,
        fileManager: FileManager = .default
    ) -> URL {
        RemoteControlStorageNamespace.pairedDevicesURL(channel: channel, fileManager: fileManager)
    }

    func hostPublicKeyInfo() throws -> RemoteHostPublicKeyInfo {
        try withLock {
            let key = try hostPrivateKeyLocked()
            let publicKey = key.publicKey
            return RemoteHostPublicKeyInfo(
                rawRepresentation: publicKey.rawRepresentation,
                fingerprint: RemotePairingCrypto.fingerprint(for: publicKey)
            )
        }
    }

    func hostSigningPrivateKey() throws -> P256.Signing.PrivateKey {
        try withLock { try hostPrivateKeyLocked() }
    }

    func registry() throws -> PairedDeviceRegistry {
        try withLock {
            if fenced {
                throw RemotePairingIdentityStoreError.concurrentModification
            }
            if let cachedRegistry {
                return cachedRegistry
            }

            let hostFingerprint = try hostPublicKeyInfo().fingerprint
            switch Self.load(from: url, expectedOwnerID: expectedOwnerID) {
            case let .success(registry):
                guard registry.hostPublicKeyFingerprint == hostFingerprint else {
                    throw RemotePairingIdentityStoreError.invalidRegistry
                }
                cachedRegistry = registry
                recordedFingerprint = Self.fingerprint(of: url)
                return registry
            case let .failure(error):
                guard error == .missing else { throw error }
                let registry = PairedDeviceRegistry(hostPublicKeyFingerprint: hostFingerprint, devices: [])
                cachedRegistry = registry
                recordedFingerprint = .missing
                return registry
            }
        }
    }

    /// A single lock-scope read of the registry plus the current committed save revision, used by
    /// the trust projection so the view and its revision cannot tear.
    func trustSnapshot() throws -> (registry: PairedDeviceRegistry, revision: UInt64) {
        try withLock {
            let registry = try registry()
            return (registry, saveRevision)
        }
    }

    func listDevices(includeRevoked: Bool = true) throws -> [PairedDeviceRecord] {
        let devices = try registry().devices.sorted { lhs, rhs in
            lhs.createdAt < rhs.createdAt
        }
        return includeRevoked ? devices : devices.filter { !$0.isRevoked }
    }

    func device(id: String) throws -> PairedDeviceRecord? {
        try registry().devices.first { $0.id == id }
    }

    func upsertDevice(_ record: PairedDeviceRecord) throws {
        try withLock {
            var registry = try registry()
            var updated = record
            // Ordinary metadata/push/scope updates must never drop an existing passkey policy, and
            // must not advance the epoch (that would invalidate live grants in Step 3).
            if let existing = registry.devices.first(where: { $0.id == record.id }) {
                updated.passkey = existing.passkey
            }
            registry.devices.removeAll { $0.id == record.id }
            registry.devices.append(updated)
            try save(registry)
        }
    }

    @discardableResult
    func upsertDevicePreservingCounterFloor(_ record: PairedDeviceRecord) throws -> PairedDeviceRecord {
        try withLock {
            var registry = try registry()
            let existing = registry.devices.first { $0.id == record.id }
            var updated = record
            updated.counterFloor = max(existing?.counterFloor ?? 0, record.counterFloor)
            // Approved re-pairing preserves the passkey requirement and credential but advances the
            // epoch (a re-pair is a security event). A brand-new device keeps the record's own
            // policy (which defaults to `.off`).
            if let existing {
                var policy = existing.passkey
                policy.epoch = try Self.advanceEpoch(existing.passkey.epoch)
                updated.passkey = policy
            }
            registry.devices.removeAll { $0.id == record.id }
            registry.devices.append(updated)
            try save(registry)
            return updated
        }
    }

    /// Compare-and-update a device's passkey policy under the store lock. The caller supplies the
    /// epoch it last observed; a mismatch fails without writing. The store advances the epoch after
    /// the transform. When the transform sets a credential, its ID must be unused across the whole
    /// registry (including revoked records).
    @discardableResult
    func updatePasskeyPolicy(
        deviceID: String,
        expectedEpoch: UInt64,
        _ transform: (inout RemotePasskeyPolicyRecord) throws -> Void
    ) throws -> PairedDeviceRecord {
        try withLock {
            var registry = try registry()
            guard let index = registry.devices.firstIndex(where: { $0.id == deviceID }) else {
                throw RemotePairingIdentityStoreError.deviceNotFound(deviceID)
            }
            guard registry.devices[index].passkey.epoch == expectedEpoch else {
                throw RemotePairingIdentityStoreError.policyConflict
            }
            var policy = registry.devices[index].passkey
            try transform(&policy)
            policy.epoch = try Self.advanceEpoch(registry.devices[index].passkey.epoch)

            if let credential = policy.credential {
                for (other, device) in registry.devices.enumerated() where other != index {
                    if device.passkey.credential?.credentialID == credential.credentialID {
                        throw RemotePairingIdentityStoreError.duplicateCredentialID
                    }
                }
            }

            registry.devices[index].passkey = policy
            try save(registry)
            return registry.devices[index]
        }
    }

    @discardableResult
    func revokeDevice(id: String, revokedAt: Date = Date()) throws -> PairedDeviceRecord {
        try withLock {
            var registry = try registry()
            guard let index = registry.devices.firstIndex(where: { $0.id == id }) else {
                throw RemotePairingIdentityStoreError.deviceNotFound(id)
            }
            registry.devices[index].revokedAt = revokedAt
            registry.devices[index].pushSubscription = nil
            // Revocation advances the policy epoch (invalidating grants in Step 3) while keeping the
            // requirement and any stored credential: a valid passkey never revives a revoked pairing.
            registry.devices[index].passkey.epoch = try Self.advanceEpoch(registry.devices[index].passkey.epoch)
            try save(registry)
            return registry.devices[index]
        }
    }

    func updateLastSeen(deviceID: String, at date: Date = Date()) throws {
        try withLock {
            var registry = try registry()
            guard let index = registry.devices.firstIndex(where: { $0.id == deviceID }) else {
                throw RemotePairingIdentityStoreError.deviceNotFound(deviceID)
            }
            registry.devices[index].lastSeenAt = date
            try save(registry)
        }
    }

    /// Private on purpose: every durable mutation must funnel through the typed helpers above so a
    /// caller cannot overwrite the latest passkey/security state from a stale full-registry
    /// snapshot. The disk-version fence below is the second line of defence for cross-instance
    /// writes.
    private func save(_ registry: PairedDeviceRegistry) throws {
        try withLock {
            guard Self.validateRegistry(registry) else {
                throw RemotePairingIdentityStoreError.invalidRegistry
            }

            // Disk-version fence: refuse to overwrite a file that changed outside this instance.
            let current = Self.fingerprint(of: url)
            if let recorded = recordedFingerprint {
                if current != recorded {
                    cachedRegistry = nil
                    fenced = true
                    throw RemotePairingIdentityStoreError.concurrentModification
                }
            } else {
                recordedFingerprint = current
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(registry)
            } catch {
                // Encoding never touched the destination; the cache still matches disk.
                throw RemotePairingIdentityStoreError.writeFailed(error.localizedDescription)
            }

            // Secure temp-file + atomic rename. The rename is the sole commit point; any failure
            // leaves the previous destination authoritative (POSIX rename is atomic), so the cache
            // and fingerprint are left untouched on throw.
            try atomicSecureWrite(data, to: url)

            recordedFingerprint = Self.fingerprint(of: url)
            cachedRegistry = registry
            saveRevision &+= 1
        }
    }

    private func atomicSecureWrite(_ data: Data, to target: URL) throws {
        let parent = target.deletingLastPathComponent()
        do {
            // Attributes apply only to a newly created directory, so a pre-existing (possibly
            // read-only) parent is left as-is and a genuine write failure surfaces instead of being
            // masked by a permission reset.
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RemotePairingIdentityStoreError.writeFailed(error.localizedDescription)
        }

        let tempURL = parent.appendingPathComponent(".paired-devices.\(UUID().uuidString).tmp")
        let descriptor = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw RemotePairingIdentityStoreError.writeFailed("temp create failed (errno \(errno))")
        }

        var didClose = false
        func closeDescriptor() {
            if !didClose {
                close(descriptor)
                didClose = true
            }
        }

        do {
            if !data.isEmpty {
                try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    var offset = 0
                    while offset < raw.count {
                        let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                        // Negative is an error; zero means the write made no forward progress. Treat
                        // both as failure rather than spinning forever on a non-advancing write.
                        if written <= 0 {
                            throw RemotePairingIdentityStoreError.writeFailed("write made no progress (errno \(errno))")
                        }
                        offset += written
                    }
                }
            }
            guard fsync(descriptor) == 0 else {
                throw RemotePairingIdentityStoreError.writeFailed("fsync failed (errno \(errno))")
            }
            // Close before rename and surface a close() failure as a commit failure: deferred write
            // errors can first appear at close, and renaming a file whose final close failed would
            // risk publishing an incomplete registry.
            if close(descriptor) != 0 {
                didClose = true
                throw RemotePairingIdentityStoreError.writeFailed("close failed (errno \(errno))")
            }
            didClose = true
            guard rename(tempURL.path, target.path) == 0 else {
                throw RemotePairingIdentityStoreError.writeFailed("rename failed (errno \(errno))")
            }
        } catch {
            closeDescriptor()
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    static func fingerprint(of url: URL) -> RemotePairingRegistryFingerprint {
        var fileStatus = Darwin.stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            return .missing
        }
        return .present(
            inode: UInt64(fileStatus.st_ino),
            size: Int64(fileStatus.st_size),
            mtimeSeconds: fileStatus.st_mtimespec.tv_sec,
            mtimeNanoseconds: fileStatus.st_mtimespec.tv_nsec
        )
    }

    static func load(
        from url: URL,
        expectedOwnerID: UInt32 = getuid()
    ) -> Result<PairedDeviceRegistry, RemotePairingIdentityStoreError> {
        var fileStatus = Darwin.stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            return .failure(errno == ENOENT ? .missing : .unreadable)
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else {
            return .failure(.notRegularFile)
        }
        guard fileStatus.st_uid == expectedOwnerID else {
            return .failure(.wrongOwner)
        }
        guard fileStatus.st_mode & 0o077 == 0 else {
            return .failure(.insecurePermissions)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return .failure(.unreadable)
        }
        return RemotePairingRegistryCodec.decode(data)
    }

    static func validateRegistry(_ registry: PairedDeviceRegistry) -> Bool {
        guard registry.schemaVersion == PairedDeviceRegistry.currentSchemaVersion,
              RemotePairingCrypto.isValidFingerprint(registry.hostPublicKeyFingerprint)
        else {
            return false
        }

        var seenIDs: Set<String> = []
        var seenCredentialIDs: Set<Data> = []
        for device in registry.devices {
            guard validateDeviceRecord(device), !seenIDs.contains(device.id) else {
                return false
            }
            seenIDs.insert(device.id)
            if let credentialID = device.passkey.credential?.credentialID {
                guard !seenCredentialIDs.contains(credentialID) else { return false }
                seenCredentialIDs.insert(credentialID)
            }
        }
        return true
    }

    static func validateDeviceRecord(_ record: PairedDeviceRecord) -> Bool {
        guard record.schemaVersion == PairedDeviceRecord.currentSchemaVersion,
              RemotePairingCrypto.isValidDeviceID(record.id),
              !record.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.scopes.isEmpty,
              RemotePairingCrypto.fingerprint(forRawPublicKey: record.publicKeyRawRepresentation) != nil,
              validatePolicy(record.passkey)
        else {
            return false
        }
        return true
    }

    static func validatePolicy(_ policy: RemotePasskeyPolicyRecord) -> Bool {
        guard policy.schemaVersion == RemotePasskeyPolicyRecord.currentSchemaVersion else {
            return false
        }
        switch policy.state {
        case .off:
            return policy.credential == nil
        case .required:
            guard let credential = policy.credential else { return true }
            return validateCredential(credential)
        }
    }

    static func validateCredential(_ credential: RemotePasskeyCredentialRecord) -> Bool {
        (1 ... 1023).contains(credential.credentialID.count)
            && (1 ... 1024).contains(credential.publicKeyCOSE.count)
            && !credential.rpID.isEmpty
            && credential.rpID == credential.rpID.lowercased()
            && (1 ... 64).contains(credential.userHandle.count)
    }

    /// Advance a policy epoch by one, refusing to wrap. A strictly greater epoch is what lets a
    /// newer policy invalidate older grants in Step 3, so an epoch at `UInt64.max` fails closed
    /// rather than silently resetting to 0.
    static func advanceEpoch(_ current: UInt64) throws -> UInt64 {
        guard current < UInt64.max else {
            throw RemotePairingIdentityStoreError.epochOverflow
        }
        return current + 1
    }

    private static func makeLaunchNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0 ... 255)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func hostPrivateKeyLocked() throws -> P256.Signing.PrivateKey {
        do {
            let encoded = try keychain.get(
                for: Self.hostSigningKeyAccount,
                accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
            )
            guard let data = Data(base64Encoded: encoded) else {
                throw RemotePairingIdentityStoreError.invalidHostKey
            }
            return try RemotePairingCrypto.hostPrivateKey(rawRepresentation: data)
        } catch KeychainService.KeychainError.itemNotFound {
            let key = P256.Signing.PrivateKey()
            do {
                try keychain.save(
                    key.rawRepresentation.base64EncodedString(),
                    for: Self.hostSigningKeyAccount,
                    accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
                )
            } catch {
                throw RemotePairingIdentityStoreError.keychainUnavailable(error.localizedDescription)
            }
            return key
        } catch let error as RemotePairingIdentityStoreError {
            throw error
        } catch RemotePairingCryptoError.invalidPrivateKey {
            throw RemotePairingIdentityStoreError.invalidHostKey
        } catch {
            throw RemotePairingIdentityStoreError.keychainUnavailable(error.localizedDescription)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
